defmodule Arbor.Memory.SelfKnowledgeMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for IdentityConsolidator reserved-child admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (ETS mutation before a rejected child start, or unadmitted
  durable reprojection), not a compile or setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.Config
  alias Arbor.Memory.IdentityConsolidator
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.SelfKnowledge
  alias Arbor.Memory.Signals
  alias Arbor.Memory.Test.AsyncWriterHangBackend, as: Hang
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Memory.TestBootstrap.AdmissionBackend
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B2B"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @ets_table :arbor_self_knowledge
  @namespace "self_knowledge"
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :sk_sec_ma_fake

  setup do
    restart_writer_supervisor!()
    on_exit(&restart_writer_supervisor!/0)

    ensure_durable_store!()
    ensure_self_knowledge_ets!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "capacity exhaustion rejects save before ETS, durable, events, or roots" do
    hang_name = :self_knowledge_capacity_hang_backend
    {:ok, _} = Hang.start_link(agent_name: hang_name)
    Hang.arm_hang(hang_name)
    replace_store!(Hang, agent_name: hang_name)

    original = Application.get_env(:arbor_memory, :async_writer_max_children)
    Application.put_env(:arbor_memory, :async_writer_max_children, 1)
    restart_writer_supervisor!()

    on_exit(fn ->
      Hang.release(hang_name)
      Hang.stop(hang_name)
      restore_max_children(original)
      restart_writer_supervisor!()
    end)

    holder = unique_agent("holder")

    assert :ok =
             MemoryStore.persist_async("async_writer", "slot", %{"cap" => 1}, agent_id: holder)

    assert {:ok, _ref, _blocked} = Hang.await_hang()
    assert length(writer_children()) == 1

    agent_id = unique_agent("save")
    sk = SelfKnowledge.new(agent_id) |> SelfKnowledge.add_trait(:curious, 0.8)
    before_history = identity_history(agent_id)
    before_signals = recent_identity_signals(agent_id)

    result = IdentityConsolidator.save_self_knowledge(agent_id, sk)

    assert [] = :ets.lookup(@ets_table, agent_id)
    assert identity_history(agent_id) == before_history
    assert recent_identity_signals(agent_id) == before_signals
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert length(writer_children()) == 1
    assert Hang.cas_count(hang_name) == 1
    assert {:error, :store_unavailable} = result

    Hang.release(hang_name)
    wait_until(fn -> writer_children() == [] end)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(holder)) end)
    assert durable_absent?(agent_id)
  end

  test "post-drain save is denied with unchanged ETS and durable bytes" do
    agent_id = unique_agent("drain")
    other_id = unique_agent("other")

    sk =
      agent_id
      |> SelfKnowledge.new()
      |> SelfKnowledge.add_trait(:curious, 0.8)

    other_sk =
      other_id
      |> SelfKnowledge.new()
      |> SelfKnowledge.add_trait(:methodical, 0.7)

    assert :ok = IdentityConsolidator.save_self_knowledge(agent_id, sk)
    await_durable!(agent_id)
    before = durable_bytes!(agent_id)
    before_ets = :ets.lookup(@ets_table, agent_id)
    assert [{^agent_id, _}] = before_ets

    changed =
      sk
      |> SelfKnowledge.add_trait(:methodical, 0.9)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    result = IdentityConsolidator.save_self_knowledge(agent_id, changed)

    assert :ets.lookup(@ets_table, agent_id) == before_ets
    assert durable_bytes!(agent_id) == before
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)
    assert {:error, :store_unavailable} = result

    assert :ok = IdentityConsolidator.save_self_knowledge(other_id, other_sk)
    assert [{^other_id, %SelfKnowledge{agent_id: ^other_id}}] = :ets.lookup(@ets_table, other_id)

    assert wait_until(fn ->
             match?({:ok, %{active_roots: 0}}, MutationAdmission.status(other_id))
           end)
  end

  test "drained lazy load preserves the durable read without projecting ETS or roots" do
    agent_id = unique_agent("proj_drain")

    sk =
      agent_id
      |> SelfKnowledge.new()
      |> SelfKnowledge.add_capability("elixir", 0.8, "tests")

    assert :ok = IdentityConsolidator.save_self_knowledge(agent_id, sk)
    await_durable!(agent_id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    true = :ets.delete(@ets_table, agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    loaded = IdentityConsolidator.get_self_knowledge(agent_id)
    assert same_self_knowledge?(loaded, sk)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)
    assert writer_children() == []
  end

  test "open-gate lazy load projects the exact row while the parent root covers ETS insert" do
    bind_fake_admission!()

    on_exit(fn ->
      restore_bootstrap_admission!()
      Fake.stop(@fake_name)
    end)

    agent_id = unique_agent("proj_open")

    sk =
      agent_id
      |> SelfKnowledge.new()
      |> SelfKnowledge.add_capability("elixir", 0.8, "tests")

    assert :ok = IdentityConsolidator.save_self_knowledge(agent_id, sk)
    await_durable!(agent_id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)

    true = :ets.delete(@ets_table, agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)

    Fake.arm_withhold_cas_reply(@fake_name)

    task =
      Task.async(fn ->
        IdentityConsolidator.get_self_knowledge(agent_id)
      end)

    assert_receive {:cas_applied, _key, _ref, _stored}, 2_000
    assert [] = :ets.lookup(@ets_table, agent_id)

    Fake.arm_sync(@fake_name, [:cas], 1)
    Fake.release_withheld_cas_reply(@fake_name)

    assert {:ok, :cas, ref_rel} = Fake.await_sync_arrival(2_000)
    assert [{^agent_id, projected}] = :ets.lookup(@ets_table, agent_id)
    assert same_self_knowledge?(projected, sk)
    # Release is parked inside MutationAdmission.handle_call/3; do not call
    # status/1 here or the GenServer deadlocks. Observe the still-applied root.
    assert admission_root_count(agent_id) == 1

    Fake.release_sync(@fake_name, ref_rel)

    assert %SelfKnowledge{agent_id: ^agent_id} = Task.await(task, 2_000)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
  end

  test "activated hang save leaves one child root so drain waits for completion" do
    hang_name = :self_knowledge_child_root_hang_backend
    {:ok, _} = Hang.start_link(agent_name: hang_name)
    Hang.arm_hang(hang_name)
    replace_store!(Hang, agent_name: hang_name)

    on_exit(fn ->
      Hang.release(hang_name)
      Hang.stop(hang_name)
    end)

    agent_id = unique_agent("hang_save")
    sk = SelfKnowledge.new(agent_id) |> SelfKnowledge.add_trait(:curious, 0.8)

    assert :ok = IdentityConsolidator.save_self_knowledge(agent_id, sk)
    assert {:ok, _ref, _blocked} = Hang.await_hang()
    assert {:ok, %{active_roots: 1}} = MutationAdmission.status(agent_id)

    drain_task = Task.async(fn -> MutationAdmission.drain(agent_id) end)
    assert Task.yield(drain_task, 0) == nil

    Hang.release(hang_name)
    assert {:ok, _fence} = Task.await(drain_task, 2_000)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id)) end)
  end

  test "apply_accepted_change and rollback do not emit change events after save denial" do
    apply_id = unique_agent("apply")
    rollback_id = unique_agent("rollback")

    apply_sk = SelfKnowledge.new(apply_id)

    rollback_sk =
      rollback_id
      |> SelfKnowledge.new()
      |> SelfKnowledge.add_trait(:curious, 0.8)
      |> SelfKnowledge.snapshot()
      |> SelfKnowledge.add_trait(:methodical, 0.9)

    assert :ok = IdentityConsolidator.save_self_knowledge(apply_id, apply_sk)
    assert :ok = IdentityConsolidator.save_self_knowledge(rollback_id, rollback_sk)
    await_durable!(apply_id)
    await_durable!(rollback_id)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(apply_id)) end)

    wait_until(fn ->
      match?({:ok, %{active_roots: 0}}, MutationAdmission.status(rollback_id))
    end)

    before_apply_history = identity_history(apply_id)
    before_apply_signals = recent_identity_signals(apply_id)
    before_apply_ets = :ets.lookup(@ets_table, apply_id)
    before_rollback_history = identity_history(rollback_id)
    before_rollback_signals = recent_identity_signals(rollback_id)
    before_rollback_ets = :ets.lookup(@ets_table, rollback_id)

    assert {:ok, _fence} = MutationAdmission.drain(apply_id)
    assert {:ok, _fence} = MutationAdmission.drain(rollback_id)

    change = %{field: :personality_traits, new_value: {:curious, 0.8}}

    assert {:error, :store_unavailable} =
             IdentityConsolidator.apply_accepted_change(apply_id, %{change: change})

    assert identity_history(apply_id) == before_apply_history
    assert recent_identity_signals(apply_id) == before_apply_signals
    assert :ets.lookup(@ets_table, apply_id) == before_apply_ets

    assert {:error, :store_unavailable} = IdentityConsolidator.rollback(rollback_id)
    assert identity_history(rollback_id) == before_rollback_history
    assert recent_identity_signals(rollback_id) == before_rollback_signals
    assert :ets.lookup(@ets_table, rollback_id) == before_rollback_ets
  end

  test "post-drain content cleanup and absence remain usable and root-free" do
    agent_id = unique_agent("cleanup")

    sk =
      agent_id
      |> SelfKnowledge.new()
      |> SelfKnowledge.add_capability("elixir", 0.8, "tests")

    assert :ok = IdentityConsolidator.save_self_knowledge(agent_id, sk)
    await_durable!(agent_id)

    payload = SelfKnowledge.serialize(sk)
    sidecar = taint(:trusted, :internal, "sk_sec_cleanup")
    assert :ok = Provenance.put(:self_knowledge, agent_id, "identity", payload, sidecar)
    assert {:ok, ids_before} = Provenance.list_item_ids(:self_knowledge, agent_id)
    assert "identity" in ids_before

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:ok, false} = IdentityConsolidator.agent_content_absent?(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert :ok = IdentityConsolidator.delete_agent_content(agent_id)
    assert :ok = IdentityConsolidator.delete_agent_content(agent_id)
    assert {:ok, true} = IdentityConsolidator.agent_content_absent?(agent_id)
    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:self_knowledge, agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  defp unique_agent(label), do: "sk_sec_#{label}_#{System.unique_integer([:positive])}"

  defp same_self_knowledge?(%SelfKnowledge{} = left, %SelfKnowledge{} = right) do
    SelfKnowledge.serialize(left) ==
      SelfKnowledge.serialize(SelfKnowledge.deserialize(SelfKnowledge.serialize(right)))
  end

  defp same_self_knowledge?(_left, _right), do: false

  defp admission_root_count(agent_id) do
    key = Base.encode16(:crypto.hash(:sha256, agent_id), case: :lower)

    case Fake.peek(@fake_name, key) do
      %{data: data} when is_map(data) ->
        roots = Map.get(data, "roots") || Map.get(data, :roots) || %{}
        map_size(roots)

      _ ->
        0
    end
  end

  defp durable_absent?(agent_id) do
    match?(
      {:error, :not_found},
      MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)
    )
  end

  defp durable_bytes!(agent_id) do
    assert {:ok, _value, _status, record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)

    :erlang.term_to_binary(record.data)
  end

  defp await_durable!(agent_id) do
    assert wait_until(fn ->
             match?(
               {:ok, _, _, _, _},
               MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id)
             )
           end)
  end

  defp identity_history(agent_id) do
    case IdentityConsolidator.history(agent_id) do
      {:ok, events} when is_list(events) ->
        Enum.map(events, fn event ->
          {Map.get(event, :type) || Map.get(event, "type"),
           Map.get(event, :id) || Map.get(event, "id")}
        end)

      _ ->
        []
    end
  end

  defp recent_identity_signals(agent_id) do
    case Signals.query_recent(agent_id, types: [:cognitive_adjustment]) do
      {:ok, signals} -> Enum.map(signals, fn signal -> {signal.type, signal.id} end)
      _ -> []
    end
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

  defp wait_until(fun, attempts \\ 80)
  defp wait_until(fun, 0), do: fun.() || flunk("condition not met")

  defp wait_until(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        25 -> wait_until(fun, attempts - 1)
      end
    end
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

    restart_admission!(%{
      namespace: Config.fixed_mutation_admission_namespace(),
      backend: Fake,
      opts: [agent_name: @fake_name]
    })
  end

  defp restore_bootstrap_admission! do
    restart_admission!(%{
      namespace: Config.fixed_mutation_admission_namespace(),
      backend: AdmissionBackend,
      opts: [agent_name: AdmissionBackend.name()]
    })
  end

  defp restart_admission!(target) do
    _ = Supervisor.terminate_child(Arbor.Memory.Supervisor, MutationAdmission)

    case Supervisor.delete_child(Arbor.Memory.Supervisor, MutationAdmission) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      other -> flunk("could not remove MutationAdmission: #{inspect(other)}")
    end

    case Supervisor.start_child(Arbor.Memory.Supervisor, {MutationAdmission, [target: target]}) do
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

  defp ensure_self_knowledge_ets! do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end

    :ok
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

  defp restart_writer_supervisor! do
    id = WriterSupervisor.name()
    _ = Supervisor.terminate_child(Arbor.Memory.Supervisor, id)
    _ = Supervisor.delete_child(Arbor.Memory.Supervisor, id)

    case Supervisor.start_child(Arbor.Memory.Supervisor, {WriterSupervisor, []}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, reason} -> flunk("failed to restart writer supervisor: #{inspect(reason)}")
    end
  end

  defp restore_max_children(nil),
    do: Application.delete_env(:arbor_memory, :async_writer_max_children)

  defp restore_max_children(value),
    do: Application.put_env(:arbor_memory, :async_writer_max_children, value)
end
