defmodule Arbor.Memory.ThinkingMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for Thinking mutation admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (missing admission gate), not a compile or setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Memory.Thinking
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B1C"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_thinking
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :thinking_sec_ma_fake

  setup do
    ensure_durable_store!()
    ensure_thinking!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "post-drain thinking record is rejected with no durable, ETS, Provenance, or stream effect" do
    agent_id = unique_agent("mut")

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)

    assert {:error, :store_unavailable} =
             Thinking.record_thinking(agent_id, "post-drain mutation")

    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:thinking_entry, agent_id)
    assert ids == []
    refute Map.has_key?(:sys.get_state(Thinking).streams, agent_id)
  end

  test "post-drain incomplete stream mutation is rejected with no owner effect" do
    agent_id = unique_agent("stream")

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:error, :store_unavailable} = Thinking.process_stream_chunk(agent_id, "partial")
    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:thinking_entry, agent_id)
    assert ids == []
    refute Map.has_key?(:sys.get_state(Thinking).streams, agent_id)
  end

  test "post-drain authoritative read cannot rehydrate stripped projections" do
    agent_id = unique_agent("read")
    taint = taint(:trusted, :internal, "thinking_sec_read")

    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "seed before drain", taint)
    assert durable_present?(agent_id)
    await_idle_roots!(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert true == :ets.delete(@ets_table, agent_id)
    assert :ok = Provenance.delete(:thinking_entry, agent_id, entry.id)

    assert {:error, :store_unavailable} = Thinking.recent_thinking_tainted(agent_id)
    assert [] = Thinking.recent_thinking(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:thinking_entry, agent_id)
    refute entry.id in ids
    assert durable_present?(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "post-drain public reload cannot rehydrate stripped projections" do
    agent_id = unique_agent("reload")
    taint = taint(:trusted, :internal, "thinking_sec_reload")

    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "reload seed", taint)
    assert durable_present?(agent_id)
    await_idle_roots!(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert true == :ets.delete(@ets_table, agent_id)
    assert :ok = Provenance.delete(:thinking_entry, agent_id, entry.id)

    assert {:error, :store_unavailable} = Thinking.reload_from_durable()
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:thinking_entry, agent_id)
    refute entry.id in ids
    assert durable_present?(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "a retained deferred root does not admit a later public request after drain starts" do
    agent_id = unique_agent("reuse")
    taint = taint(:trusted, :internal, "thinking_sec_reuse")
    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "arm deferred", taint)
    await_idle_roots!(agent_id)

    drain_task =
      with_provenance_unregistered(fn ->
        assert {:ok, _extra} = Thinking.record_thinking_tainted(agent_id, "arm pending", taint)

        task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 10_000) end)

        assert eventually(fn ->
                 match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id))
               end)

        assert {:error, :store_unavailable} = Thinking.record_thinking(agent_id, "later write")

        assert {:error, :store_unavailable} =
                 Thinking.process_stream_chunk(agent_id, "later chunk")

        refute_live_text(agent_id, "later write")
        refute Map.has_key?(:sys.get_state(Thinking).streams, agent_id)
        task
      end)

    assert {:ok, ids} = Provenance.list_item_ids(:thinking_entry, agent_id)
    refute Enum.any?(ids, &(&1 != entry.id and String.starts_with?(&1, "thk_")))
    assert :ok = Thinking.delete_agent_content(agent_id)
    assert {:ok, _fence} = Task.await(drain_task, 10_000)
  end

  test "legacy queued convergence without a retained root cannot project after drain" do
    agent_id = unique_agent("legacy")
    taint = taint(:trusted, :internal, "thinking_sec_legacy")
    assert {:ok, entry} = Thinking.record_thinking_tainted(agent_id, "legacy converge", taint)
    assert durable_present?(agent_id)
    await_idle_roots!(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert true == :ets.delete(@ets_table, agent_id)
    assert :ok = Provenance.delete(:thinking_entry, agent_id, entry.id)

    pid = Process.whereis(Thinking)

    :sys.replace_state(pid, fn state ->
      pending = Map.get(state, :pending_projection, %{})

      state
      |> Map.delete(:owner_roots)
      |> Map.put(:pending_projection, Map.put(pending, agent_id, 1))
    end)

    send(pid, {:converge_projection, agent_id})
    _ = :sys.get_state(pid)

    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:thinking_entry, agent_id)
    refute entry.id in ids
    assert durable_present?(agent_id)
    assert :ok = Thinking.delete_agent_content(agent_id)
  end

  test "public reload quarantines malformed durable authority and still reconciles a sibling" do
    target = unique_agent("malformed")
    sibling = unique_agent("sibling")
    taint = taint(:trusted, :internal, "thinking_sec_quarantine")

    assert {:ok, target_entry} =
             Thinking.record_thinking_tainted(target, "keep live target", taint)

    target_entry_id = target_entry.id

    assert {:ok, sibling_entry} =
             Thinking.record_thinking_tainted(sibling, "sibling to restore", taint)

    await_idle_roots!(target)
    await_idle_roots!(sibling)

    target_ets_before = :erlang.term_to_binary(:ets.lookup(@ets_table, target))

    target_prov_before =
      :erlang.term_to_binary(
        :ets.lookup(:arbor_memory_provenance, {:thinking_entry, target, target_entry.id})
      )

    assert {:ok, [^target_entry_id]} = Provenance.list_item_ids(:thinking_entry, target)
    assert MapSet.member?(:sys.get_state(Thinking).owned_agents, target)

    {:ok, _value, _status, record, _location} =
      MemoryStore.load_tainted_authoritative_with_status("thinking", target)

    assert {:ok, _replaced} =
             MemoryStore.compare_and_swap_tainted(
               "thinking",
               target,
               record,
               %{"version" => 1, "entries" => "not-a-list"},
               taint: taint
             )

    assert true == :ets.delete(@ets_table, sibling)

    assert :ok = Thinking.reload_from_durable()

    assert :erlang.term_to_binary(:ets.lookup(@ets_table, target)) == target_ets_before

    assert :erlang.term_to_binary(
             :ets.lookup(:arbor_memory_provenance, {:thinking_entry, target, target_entry.id})
           ) == target_prov_before

    assert {:ok, [^target_entry_id]} = Provenance.list_item_ids(:thinking_entry, target)
    assert MapSet.member?(:sys.get_state(Thinking).owned_agents, target)
    refute Map.has_key?(:sys.get_state(Thinking).pending_projection, target)
    refute Map.has_key?(:sys.get_state(Thinking).streams, target)

    assert [{^sibling, entries}] = :ets.lookup(@ets_table, sibling)
    assert Enum.any?(entries, &(&1.id == sibling_entry.id))

    assert :ok = Thinking.delete_agent_content(target)
    assert :ok = Thinking.delete_agent_content(sibling)
  end

  defp unique_agent(label), do: "thinking_sec_#{label}_#{System.unique_integer([:positive])}"

  defp durable_present?(agent_id) do
    match?(
      {:ok, _value, _status, _record, _location},
      MemoryStore.load_tainted_authoritative_with_status("thinking", agent_id)
    )
  end

  defp durable_absent?(agent_id) do
    match?(
      {:error, :not_found},
      MemoryStore.load_tainted_authoritative_with_status("thinking", agent_id)
    )
  end

  defp refute_live_text(agent_id, text) do
    case :ets.lookup(@ets_table, agent_id) do
      [] ->
        :ok

      [{^agent_id, entries}] when is_list(entries) ->
        refute Enum.any?(entries, &(&1.text == text))
    end
  end

  defp await_idle_roots!(agent_id) do
    assert eventually(
             fn ->
               match?({:ok, %{active_roots: 0}}, MutationAdmission.status(agent_id))
             end,
             80
           )
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

  defp ensure_thinking! do
    case Process.whereis(Thinking) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Thinking) do
          {:ok, pid} when is_pid(pid) -> pid
          {:error, {:already_started, pid}} when is_pid(pid) -> pid
          other -> flunk("failed to restart Thinking: #{inspect(other)}")
        end
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

  defp with_provenance_unregistered(fun) when is_function(fun, 0) do
    pid = Process.whereis(Provenance)
    assert is_pid(pid)
    assert Process.unregister(Provenance)

    try do
      fun.()
    after
      case Process.whereis(Provenance) do
        ^pid -> :ok
        nil -> Process.register(pid, Provenance)
        other -> flunk("Provenance name owned by #{inspect(other)}")
      end
    end
  end

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: fun.() || flunk("condition not met")

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually(fun, attempts - 1)
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
end
