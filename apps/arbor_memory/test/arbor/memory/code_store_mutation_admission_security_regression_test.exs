defmodule Arbor.Memory.CodeStoreMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for CodeStore reserved two-child admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (ETS mutation and immediate persist/embed start before a rejected
  second child, or unadmitted drained-agent hydration), not a compile or
  setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.CodeStore
  alias Arbor.Memory.Config
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Test.AsyncWriterHangBackend, as: Hang
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Memory.TestBootstrap.AdmissionBackend
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B2C"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_code_store
  @namespace "code_patterns"
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :code_sec_ma_fake
  @counters :code_sec_counters
  # Matches config/test.exs; never delete this key from a shared restore path.
  @embedding_test_fallback_baseline true

  defmodule CountingSeam do
    @moduledoc false

    def fetch(_agent_id, _namespace, _key, _opts) do
      bump(:vector)
      {:error, :not_found}
    end

    def encode_operation(_closed) do
      bump(:vector)
      {:error, :unavailable}
    end

    def execute(_agent_id, _operation, _opts) do
      bump(:vector)
      {:error, :unavailable}
    end

    def reconcile(_agent_id, _operation, _opts) do
      bump(:vector)
      {:error, :unavailable}
    end

    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok

    defp bump(key) do
      case Process.whereis(:code_sec_counters) do
        nil -> :ok
        pid -> Agent.update(pid, fn counts -> Map.update!(counts, key, &(&1 + 1)) end)
      end
    end
  end

  defmodule BlockingEmbedSeam do
    @moduledoc false

    def fetch(agent_id, namespace, key, _opts) do
      tester = Application.fetch_env!(:arbor_memory, :code_store_sec_embed_tester)
      send(tester, {:embed_blocked, self(), agent_id, namespace, key})

      receive do
        :release_embed -> {:error, :not_found}
      after
        10_000 -> {:error, :unavailable}
      end
    end

    def encode_operation(_closed), do: {:error, :unavailable}
    def execute(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def reconcile(_agent_id, _operation, _opts), do: {:error, :unavailable}
    def search(_agent_id, _vector, _opts), do: {:ok, []}
    def list(_agent_id, _opts), do: {:ok, []}
    def destroy(_agent_id, _opts), do: :ok
  end

  setup do
    restore_shared_env()
    ensure_durable_store!()
    ensure_code_store!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "second-child capacity exhaustion cancels the persist reservation with no effect" do
    hang_name = :code_store_capacity_hang_backend
    {:ok, _} = Hang.start_link(agent_name: hang_name)
    Hang.arm_hang(hang_name)
    replace_store!(Hang, agent_name: hang_name)

    {:ok, counters} = Agent.start_link(fn -> %{provider: 0, vector: 0} end, name: @counters)
    original_seam = Application.get_env(:arbor_memory, :strict_vector_seam)
    Application.put_env(:arbor_memory, :strict_vector_seam, CountingSeam)
    tracer = start_embed_tracer()

    original = Application.get_env(:arbor_memory, :async_writer_max_children)
    Application.put_env(:arbor_memory, :async_writer_max_children, 1)
    restart_writer_supervisor!()

    on_exit(fn ->
      run_independently([
        {:stop_embed_tracer, fn -> stop_embed_tracer(tracer) end},
        {:restore_seam, fn -> restore_seam(original_seam) end},
        {:stop_counters, fn -> stop_named_process(@counters) end},
        {:hang_release, fn -> Hang.release(hang_name) end},
        {:hang_stop, fn -> Hang.stop(hang_name) end},
        {:restore_max_children, fn -> restore_max_children(original) end},
        {:restart_writer_supervisor, &restart_writer_supervisor/0},
        {:restore_embedding_test_fallback, &restore_embedding_test_fallback/0}
      ])
    end)

    agent_id = unique_agent("cap")
    before_children = writer_children()
    before_counts = Agent.get(counters, & &1)

    result = store_pattern(agent_id, "capacity rollback")

    assert [] = :ets.lookup(@ets_table, agent_id)
    assert durable_absent?(agent_id)
    assert Hang.cas_count(hang_name) == 0
    assert writer_children() == before_children
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert Agent.get(counters, & &1) == before_counts
    assert {:error, :store_unavailable} = result
  end

  test "post-drain store, delete, and clear are denied while an open agent remains writable" do
    agent_id = unique_agent("drain")
    other_id = unique_agent("other")

    assert {:ok, entry} = store_pattern(agent_id, "keep me")
    await_durable!(agent_id, entry.id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    before_ets = :ets.lookup(@ets_table, agent_id)
    before_bytes = durable_bytes!(agent_id, entry.id)
    assert [{^agent_id, _}] = before_ets

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    assert {:error, :store_unavailable} = store_pattern(agent_id, "after drain")
    assert {:error, :store_unavailable} = CodeStore.delete(agent_id, entry.id)
    assert {:error, :store_unavailable} = CodeStore.clear(agent_id)

    assert :ets.lookup(@ets_table, agent_id) == before_ets
    assert durable_bytes!(agent_id, entry.id) == before_bytes
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)

    assert {:ok, other_entry} = store_pattern(other_id, "open agent")
    assert {:ok, ^other_entry} = CodeStore.get(other_id, other_entry.id)

    wait_until(fn ->
      match?({:ok, %{active_roots: 0}}, MutationAdmission.status(other_id))
    end)
  end

  test "start_link hydrates an open survivor and skips drained or malformed rows" do
    target = unique_agent("hydrate_t")
    survivor = unique_agent("hydrate_s")
    target_id = "code_target_1"
    survivor_id = "code_surv_1"
    target_payload = code_payload(target, target_id, "target pattern")
    survivor_payload = code_payload(survivor, survivor_id, "survivor pattern")

    assert :ok = MemoryStore.persist(@namespace, "#{target}:#{target_id}", target_payload)
    assert :ok = MemoryStore.persist(@namespace, "#{survivor}:#{survivor_id}", survivor_payload)

    assert :ok =
             MemoryStore.persist(
               @namespace,
               "#{target}:code_cross",
               code_payload(survivor, "code_cross", "ownership mismatch")
             )

    assert :ok =
             MemoryStore.persist(
               @namespace,
               "#{survivor}:code_key_id",
               code_payload(survivor, "code_payload_id", "key id mismatch")
               |> Map.put("id", "code_payload_id")
             )

    unbound =
      code_payload(survivor, "code_unbound", "missing owner")
      |> Map.put("id", "code_unbound")
      |> Map.delete("agent_id")

    assert :ok = MemoryStore.persist(@namespace, "#{survivor}:code_unbound", unbound)

    # store/2 accepts empty binaries and always writes metadata; historical
    # rows may omit metadata. Hydration must still project that entry shape.
    compatible_id = "code_compat_1"

    compatible =
      code_payload(survivor, compatible_id, "store contract")
      |> Map.put("code", "")
      |> Map.put("language", "")
      |> Map.put("purpose", "")
      |> Map.delete("metadata")

    assert :ok = MemoryStore.persist(@namespace, "#{survivor}:#{compatible_id}", compatible)

    wrong_typed_id = "code_wrong_type"

    wrong_typed =
      code_payload(survivor, wrong_typed_id, "wrong typed")
      |> Map.put("code", 123)

    assert :ok = MemoryStore.persist(@namespace, "#{survivor}:#{wrong_typed_id}", wrong_typed)

    true = :ets.delete(@ets_table, target)
    true = :ets.delete(@ets_table, survivor)
    assert [] = :ets.lookup(@ets_table, target)
    assert [] = :ets.lookup(@ets_table, survivor)

    assert {:ok, _fence} = MutationAdmission.drain(target)

    name = :code_store_mutation_admission_security_hydration
    assert {:ok, pid} = CodeStore.start_link(name: name)

    on_exit(fn ->
      run_independently([
        {:stop_hydrate_store,
         fn ->
           if Process.alive?(pid) do
             _ = GenServer.stop(pid)
           end
         end}
      ])
    end)

    assert [] = CodeStore.list(target)
    assert [] = :ets.lookup(@ets_table, target)
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(target)

    assert {:ok, survivor_entry} = CodeStore.get(survivor, survivor_id)
    assert survivor_entry.agent_id == survivor
    assert survivor_entry.id == survivor_id
    assert survivor_entry.purpose == "survivor pattern"
    assert survivor_entry.code == survivor_payload["code"]
    assert {:error, :not_found} = CodeStore.get(survivor, "code_cross")
    assert {:error, :not_found} = CodeStore.get(survivor, "code_payload_id")
    assert {:error, :not_found} = CodeStore.get(survivor, "code_unbound")
    assert {:error, :not_found} = CodeStore.get(survivor, wrong_typed_id)
    assert {:ok, compatible_entry} = CodeStore.get(survivor, compatible_id)
    assert compatible_entry.code == ""
    assert compatible_entry.language == ""
    assert compatible_entry.purpose == ""
    assert compatible_entry.metadata == %{}

    wait_until(fn ->
      match?({:ok, %{active_roots: 0}}, MutationAdmission.status(survivor))
    end)
  end

  test "both reservations precede ETS and drain waits for both activated children" do
    hang_name = :code_store_child_root_hang_backend
    {:ok, _} = Hang.start_link(agent_name: hang_name)
    Hang.arm_hang(hang_name)
    replace_store!(Hang, agent_name: hang_name)

    bind_fake_admission!()

    original_seam = Application.get_env(:arbor_memory, :strict_vector_seam)
    original_tester = Application.get_env(:arbor_memory, :code_store_sec_embed_tester)
    Application.put_env(:arbor_memory, :strict_vector_seam, BlockingEmbedSeam)
    Application.put_env(:arbor_memory, :code_store_sec_embed_tester, self())
    Application.put_env(:arbor_ai, :embedding_test_fallback, @embedding_test_fallback_baseline)

    on_exit(fn ->
      run_independently([
        {:restore_seam, fn -> restore_env(:arbor_memory, :strict_vector_seam, original_seam) end},
        {:restore_embed_tester,
         fn -> restore_env(:arbor_memory, :code_store_sec_embed_tester, original_tester) end},
        {:restore_embedding_test_fallback, &restore_embedding_test_fallback/0},
        {:release_fake_sync, &release_fake_sync/0},
        {:hang_release, fn -> Hang.release(hang_name) end},
        {:hang_stop, fn -> Hang.stop(hang_name) end},
        {:restore_bootstrap_admission, &restore_bootstrap_admission/0},
        {:stop_fake, fn -> Fake.stop(@fake_name) end}
      ])
    end)

    agent_id = unique_agent("order")
    Fake.arm_sync(@fake_name, [:cas], 1)

    task =
      Task.async(fn ->
        store_pattern(agent_id, "two child order")
      end)

    # Persist child root CAS is parked in Worker.init/1: no applied roots and
    # no parent ETS effect. Do not query the DynamicSupervisor while its
    # synchronous start_child/2 call is waiting for this init to finish.
    assert {:ok, :cas, persist_root} = Fake.await_sync_arrival(2_000)
    assert latest_admission_key() == admission_key(agent_id)
    assert Task.yield(task, 0) == nil
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert admission_root_count(agent_id) == 0
    release_child_and_arm_next(persist_root)

    # Embed child root CAS is likewise parked in init/1: the persist root is
    # applied, while the parent ETS effect still has not happened.
    assert {:ok, :cas, embed_root} = Fake.await_sync_arrival(2_000)
    assert latest_admission_key() == admission_key(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert admission_root_count(agent_id) == 1
    release_child_and_arm_next(embed_root)

    # Parent acquire CAS is parked before apply: both reserved child roots
    # exist and the ETS insert has not happened.
    assert {:ok, :cas, parent_root} = Fake.await_sync_arrival(2_000)
    assert latest_admission_key() == admission_key(agent_id)
    assert length(writer_children()) == 2
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert admission_root_count(agent_id) == 2
    Fake.release_sync(@fake_name, parent_root)

    assert {:ok, entry} = Task.await(task, 5_000)
    logical_key = "#{agent_id}:#{entry.id}"

    assert_receive {:embed_blocked, embed_worker, ^agent_id, @namespace, ^logical_key}, 5_000
    assert {:ok, _ref, _blocked} = Hang.await_hang()
    assert [{^agent_id, [^entry | _]}] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, %{active_roots: 2}} = MutationAdmission.status(agent_id)

    drain_task = Task.async(fn -> MutationAdmission.drain(agent_id) end)
    assert Task.yield(drain_task, 0) == nil

    Hang.release(hang_name)
    send(embed_worker, :release_embed)
    assert {:ok, _fence} = Task.await(drain_task, 5_000)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
  end

  test "legacy delete/clear stay compatible, reads are root-free, and cleanup remains usable after drain" do
    agent_id = unique_agent("compat")

    assert {:ok, keep} = store_pattern(agent_id, "keep")
    assert {:ok, drop} = store_pattern(agent_id, "drop")
    await_durable!(agent_id, keep.id)
    await_durable!(agent_id, drop.id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert :ok = CodeStore.delete(agent_id, drop.id)
    assert {:ok, ^keep} = CodeStore.get(agent_id, keep.id)
    assert {:error, :not_found} = CodeStore.get(agent_id, drop.id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert :ok = CodeStore.clear(agent_id)
    assert [] = CodeStore.list(agent_id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    assert {:ok, entry} = store_pattern(agent_id, "read me")
    await_durable!(agent_id, entry.id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    before_roots = MutationAdmission.status(agent_id)
    assert [^entry] = CodeStore.find_by_purpose(agent_id, "read")
    assert [^entry] = CodeStore.list(agent_id)
    assert {:ok, ^entry} = CodeStore.get(agent_id, entry.id)
    assert MutationAdmission.status(agent_id) == before_roots
    assert {:ok, %{active_roots: 0}} = before_roots

    payload = serialize_live(entry)
    sidecar = taint(:trusted, :internal, "code_sec_cleanup")
    assert :ok = Provenance.put(:code_item, agent_id, entry.id, payload, sidecar)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, agent_id)
    assert entry.id in ids_before

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:ok, false} = CodeStore.agent_content_absent?(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert :ok = CodeStore.delete_agent_content(agent_id)
    assert :ok = CodeStore.delete_agent_content(agent_id)
    assert {:ok, true} = CodeStore.agent_content_absent?(agent_id)
    assert durable_absent?(agent_id, entry.id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  defp store_pattern(agent_id, purpose) do
    CodeStore.store(agent_id, %{
      code: "fn x -> x end # #{purpose}",
      language: "elixir",
      purpose: purpose
    })
  end

  defp code_payload(agent_id, entry_id, purpose) do
    %{
      "id" => entry_id,
      "agent_id" => agent_id,
      "code" => "fn x -> x end # #{purpose}",
      "language" => "elixir",
      "purpose" => purpose,
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "metadata" => %{}
    }
  end

  defp serialize_live(entry) do
    %{
      "id" => entry.id,
      "agent_id" => entry.agent_id,
      "code" => entry.code,
      "language" => entry.language,
      "purpose" => entry.purpose,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "metadata" => entry.metadata
    }
  end

  defp unique_agent(label), do: "code_sec_#{label}_#{System.unique_integer([:positive])}"

  # Replace the fake's current barrier with the next one before releasing the
  # exact waiter. The backend worker cannot race through an unarmed interval.
  defp release_child_and_arm_next(child_ref) when is_reference(child_ref) do
    tester = self()

    result =
      Agent.get_and_update(@fake_name, fn %{sync: %{waiting: waiting} = sync} = state ->
        case Enum.split_with(waiting, fn {_pid, ref} -> ref == child_ref end) do
          {[{pid, ^child_ref}], []} when is_pid(pid) ->
            next_sync = %{
              sync
              | mode: :armed,
                events: MapSet.new([:cas]),
                need: 1,
                arrived: 0,
                waiting: [],
                tester: tester
            }

            {{:ok, pid}, %{state | sync: next_sync}}

          _other ->
            {{:error, :missing_exact_waiter}, state}
        end
      end)

    case result do
      {:ok, pid} ->
        send(pid, {:sync_go, child_ref})
        :ok

      {:error, :missing_exact_waiter} ->
        flunk("missing fake CAS waiter for exact barrier ref")
    end
  end

  defp release_fake_sync do
    case Process.whereis(@fake_name) do
      nil -> :ok
      _pid -> Fake.release_sync(@fake_name)
    end
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp admission_root_count(agent_id) do
    key = admission_key(agent_id)

    case Fake.peek(@fake_name, key) do
      %{data: data} when is_map(data) ->
        roots = Map.get(data, "roots") || Map.get(data, :roots) || %{}
        map_size(roots)

      _ ->
        0
    end
  end

  defp admission_key(agent_id),
    do: Base.encode16(:crypto.hash(:sha256, agent_id), case: :lower)

  defp latest_admission_key do
    case List.last(Fake.history(@fake_name)) do
      %{key: key} when is_binary(key) -> key
      _other -> nil
    end
  end

  defp durable_absent?(agent_id) do
    match?(
      {:error, :not_found},
      MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)
    )
  end

  defp durable_absent?(agent_id, entry_id) do
    match?(
      {:error, :not_found},
      MemoryStore.load_tainted_authoritative_with_status(@namespace, "#{agent_id}:#{entry_id}")
    )
  end

  defp durable_bytes!(agent_id, entry_id) do
    assert {:ok, _value, _status, record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{agent_id}:#{entry_id}"
             )

    :erlang.term_to_binary(record.data)
  end

  defp await_durable!(agent_id, entry_id) do
    assert wait_until(fn ->
             match?(
               {:ok, _, _, _, _},
               MemoryStore.load_tainted_authoritative_with_status(
                 @namespace,
                 "#{agent_id}:#{entry_id}"
               )
             )
           end)
  end

  defp taint(level, sensitivity, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end

  defp writer_children do
    case Process.whereis(WriterSupervisor.name()) do
      nil -> []
      pid -> DynamicSupervisor.which_children(pid)
    end
  end

  defp wait_until(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(fun, deadline)
  end

  defp wait_loop(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition not met before timeout")
      else
        receive do
        after
          10 -> wait_loop(fun, deadline)
        end
      end
    end
  end

  defp restore_shared_env do
    disable_embed_tracer()
    restore_max_children(nil)
    restore_seam(nil)
    restore_env(:arbor_memory, :code_store_sec_embed_tester, nil)
    restore_embedding_test_fallback()
    stop_named_process(@counters)
    :ok
  end

  # Run every step even if an earlier one fails, then surface the collected
  # failures. Raises after the sweep so on_exit never needs ExUnit helpers.
  defp run_independently(steps) when is_list(steps) do
    case collect_cleanup_failures(steps) do
      [] -> :ok
      failures -> raise "cleanup failed: #{inspect(failures)}"
    end
  end

  defp collect_cleanup_failures(steps) when is_list(steps) do
    Enum.reduce(steps, [], fn {label, fun}, acc ->
      try do
        _ = fun.()
        acc
      rescue
        exception ->
          [{label, {:error, Exception.message(exception)}} | acc]
      catch
        kind, reason ->
          [{label, {kind, inspect(reason)}} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp restore_embedding_test_fallback do
    Application.put_env(:arbor_ai, :embedding_test_fallback, @embedding_test_fallback_baseline)
  end

  defp ensure_default_admission! do
    case MutationAdmission.readiness() do
      {:ok, %{durability: :node_restart}} ->
        :ok

      _ ->
        start_parent_admission_stack!()
    end
  end

  defp start_parent_admission_stack! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    unless Process.whereis(@admission_registry) do
      start_supervised!({Registry, keys: :unique, name: @admission_registry})
    end

    unless Process.whereis(@guardian_supervisor) do
      start_supervised!({@guardian_supervisor, []})
    end

    unless Process.whereis(MutationAdmission) do
      start_supervised!(
        {MutationAdmission,
         [
           target: %{
             namespace: :memory_mutation_admission,
             backend: Fake,
             opts: [agent_name: @fake_name]
           }
         ]}
      )
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
  end

  defp bind_fake_admission! do
    unless Process.whereis(@fake_name) do
      {:ok, _} = Fake.start_link(agent_name: @fake_name)
    end

    unless Process.whereis(@admission_registry) do
      start_supervised!({Registry, keys: :unique, name: @admission_registry})
    end

    unless Process.whereis(@guardian_supervisor) do
      start_supervised!({@guardian_supervisor, []})
    end

    restart_admission!(fake_admission_target())
  end

  defp restore_bootstrap_admission do
    _ = restart_admission(bootstrap_admission_target())
    :ok
  end

  defp bootstrap_admission_target do
    %{
      namespace: Config.fixed_mutation_admission_namespace(),
      backend: AdmissionBackend,
      opts: [agent_name: AdmissionBackend.name()]
    }
  end

  defp fake_admission_target do
    %{
      namespace: Config.fixed_mutation_admission_namespace(),
      backend: Fake,
      opts: [agent_name: @fake_name]
    }
  end

  defp restart_admission(target) do
    _ = Supervisor.terminate_child(Arbor.Memory.Supervisor, MutationAdmission)

    case Supervisor.delete_child(Arbor.Memory.Supervisor, MutationAdmission) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _} -> :ok
    end

    Supervisor.start_child(Arbor.Memory.Supervisor, {MutationAdmission, [target: target]})
  end

  defp restart_admission!(target) do
    case restart_admission(target) do
      {:ok, _} ->
        :ok

      {:error, {:already_started, _}} ->
        flunk("MutationAdmission still running on the previous backend")

      {:error, reason} ->
        flunk("failed to start MutationAdmission: #{inspect(reason)}")
    end

    assert {:ok, %{durability: :node_restart}} = MutationAdmission.readiness()
  end

  defp ensure_durable_store! do
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert is_pid(
                 start_supervised!(
                   {BufferedStore, name: @store_name, backend: nil, write_mode: :sync}
                 )
               )

        :ok
    end

    assert MemoryStore.available?()
  end

  defp replace_store!(backend, backend_opts) do
    stop_durable_store!()

    assert is_pid(
             start_supervised!(
               {BufferedStore,
                name: @store_name,
                backend: backend,
                backend_opts: backend_opts,
                write_mode: :sync,
                ack_mode: :backend}
             )
           )
  end

  defp stop_durable_store! do
    case Process.whereis(@store_name) do
      nil ->
        :ok

      _pid ->
        _ = stop_supervised(BufferedStore)

        if Process.whereis(@store_name) do
          _ = Supervisor.terminate_child(Arbor.Memory.Supervisor, BufferedStore)
          _ = Supervisor.delete_child(Arbor.Memory.Supervisor, BufferedStore)
        end

        if Process.whereis(@store_name) do
          flunk("failed to stop durable store")
        end
    end
  catch
    :exit, _ -> :ok
  end

  defp ensure_code_store! do
    case Process.whereis(CodeStore) do
      pid when is_pid(pid) ->
        if :ets.whereis(@ets_table) == :undefined do
          assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, CodeStore)
          restart_code_store_child!()
        else
          :ok
        end

      nil ->
        restart_code_store_child!()
    end
  end

  defp restart_code_store_child! do
    case Supervisor.restart_child(Arbor.Memory.Supervisor, CodeStore) do
      {:ok, _pid} ->
        assert is_pid(Process.whereis(CodeStore))
        assert :ets.whereis(@ets_table) != :undefined
        :ok

      {:error, {:already_started, _pid}} ->
        assert is_pid(Process.whereis(CodeStore))
        assert :ets.whereis(@ets_table) != :undefined
        :ok

      other ->
        flunk("failed to restart CodeStore: #{inspect(other)}")
    end
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp restart_writer_supervisor do
    id = WriterSupervisor.name()
    _ = Supervisor.terminate_child(Arbor.Memory.Supervisor, id)
    _ = Supervisor.delete_child(Arbor.Memory.Supervisor, id)
    _ = Supervisor.start_child(Arbor.Memory.Supervisor, {WriterSupervisor, []})
    :ok
  end

  defp restart_writer_supervisor! do
    case restart_writer_supervisor() do
      :ok ->
        case Process.whereis(WriterSupervisor.name()) do
          pid when is_pid(pid) -> :ok
          _ -> flunk("failed to restart writer supervisor")
        end
    end
  end

  defp restore_max_children(nil),
    do: Application.delete_env(:arbor_memory, :async_writer_max_children)

  defp restore_max_children(value),
    do: Application.put_env(:arbor_memory, :async_writer_max_children, value)

  defp restore_seam(nil), do: Application.delete_env(:arbor_memory, :strict_vector_seam)
  defp restore_seam(seam), do: Application.put_env(:arbor_memory, :strict_vector_seam, seam)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp stop_named_process(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp start_embed_tracer do
    tracer = spawn(fn -> embed_tracer_loop() end)
    :erlang.trace_pattern({Arbor.AI, :embed, 1}, true, [:local])
    :erlang.trace_pattern({Arbor.AI, :embed, 2}, true, [:local])
    :erlang.trace(:new, true, [:call, {:tracer, tracer}])
    tracer
  end

  defp stop_embed_tracer(tracer) when is_pid(tracer) do
    disable_embed_tracer()
    send(tracer, :stop)
    :ok
  end

  defp disable_embed_tracer do
    :erlang.trace(:new, false, [:call])
    :erlang.trace_pattern({Arbor.AI, :embed, 1}, false, [:local])
    :erlang.trace_pattern({Arbor.AI, :embed, 2}, false, [:local])
    :ok
  end

  defp embed_tracer_loop do
    receive do
      {:trace, _pid, :call, {Arbor.AI, :embed, _args}} ->
        case Process.whereis(@counters) do
          nil -> :ok
          pid -> Agent.update(pid, fn counts -> Map.update!(counts, :provider, &(&1 + 1)) end)
        end

        embed_tracer_loop()

      :stop ->
        :ok

      _other ->
        embed_tracer_loop()
    end
  end
end
