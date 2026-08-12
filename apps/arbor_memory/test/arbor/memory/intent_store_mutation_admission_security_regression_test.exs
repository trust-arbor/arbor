defmodule Arbor.Memory.IntentStoreMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for IntentStore mutation admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (missing admission gate), not a compile or setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.IntentStore
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"
  @moduletag packet: "VP-05D2C3I1B1B"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_intents
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :intent_sec_ma_fake

  setup do
    ensure_durable_store!()
    ensure_intent_store!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "post-drain intent mutation is rejected with no durable, ETS, or Provenance row" do
    agent_id = unique_agent("mut")
    intent = Intent.think("post-drain mutation")

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:error, :store_unavailable} = IntentStore.record_intent(agent_id, intent)
    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:intent, agent_id)
    refute intent.id in ids
  end

  test "post-drain authoritative read cannot rehydrate stripped projections" do
    agent_id = unique_agent("read")
    taint = taint(:trusted, :internal, "intent_sec_read")
    intent = Intent.think("seed before drain")

    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)
    assert durable_present?(agent_id)
    await_idle_roots!(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert true == :ets.delete(@ets_table, agent_id)
    assert :ok = Provenance.delete(:intent, agent_id, intent.id)

    assert {:error, :store_unavailable} = IntentStore.recent_intents_tainted(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:intent, agent_id)
    refute intent.id in ids
    assert durable_present?(agent_id)
  end

  test "a retained deferred root does not admit a later public request after drain starts" do
    agent_id = unique_agent("reuse")
    taint = taint(:trusted, :internal, "intent_sec_reuse")
    intent = Intent.think("arm deferred")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)
    await_idle_roots!(agent_id)

    {drain_task, later} =
      with_provenance_unregistered(fn ->
        extra = Intent.think("arm pending")
        assert {:ok, ^extra} = IntentStore.record_intent_tainted(agent_id, extra, taint)

        task = Task.async(fn -> MutationAdmission.drain(agent_id, timeout_ms: 10_000) end)

        assert eventually(fn ->
                 match?({:ok, %{gate: :draining}}, MutationAdmission.status(agent_id))
               end)

        later = Intent.think("unrelated later write")
        assert {:error, :store_unavailable} = IntentStore.record_intent(agent_id, later)
        refute_live_intent(agent_id, later.id)
        {task, later}
      end)

    assert {:ok, ids} = Provenance.list_item_ids(:intent, agent_id)
    refute later.id in ids
    assert :ok = IntentStore.delete_agent_content(agent_id)
    assert {:ok, _fence} = Task.await(drain_task, 10_000)
  end

  test "legacy queued convergence without a retained root cannot project after drain" do
    agent_id = unique_agent("legacy")
    taint = taint(:trusted, :internal, "intent_sec_legacy")
    intent = Intent.think("legacy converge")
    assert {:ok, ^intent} = IntentStore.record_intent_tainted(agent_id, intent, taint)
    assert durable_present?(agent_id)
    await_idle_roots!(agent_id)

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert true == :ets.delete(@ets_table, agent_id)
    assert :ok = Provenance.delete(:intent, agent_id, intent.id)

    pid = Process.whereis(IntentStore)

    :sys.replace_state(pid, fn state ->
      pending = Map.get(state, :pending_projection, %{})

      state
      |> Map.delete(:owner_roots)
      |> Map.put(:pending_projection, Map.put(pending, agent_id, 1))
    end)

    send(pid, {:converge_projection, agent_id})
    _ = :sys.get_state(pid)

    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ids} = Provenance.list_item_ids(:intent, agent_id)
    refute intent.id in ids
    assert durable_present?(agent_id)
  end

  defp unique_agent(label), do: "intent_sec_#{label}_#{System.unique_integer([:positive])}"

  defp durable_present?(agent_id) do
    match?(
      {:ok, _value, _status, _record, _location},
      MemoryStore.load_tainted_authoritative_with_status("intents", agent_id)
    )
  end

  defp durable_absent?(agent_id) do
    match?(
      {:error, :not_found},
      MemoryStore.load_tainted_authoritative_with_status("intents", agent_id)
    )
  end

  defp refute_live_intent(agent_id, intent_id) do
    case :ets.lookup(@ets_table, agent_id) do
      [] ->
        :ok

      [{^agent_id, data}] ->
        refute Enum.any?(Map.get(data, :intents, []), &(&1.id == intent_id))
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

  defp ensure_intent_store! do
    case Process.whereis(IntentStore) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, IntentStore) do
          {:ok, pid} when is_pid(pid) -> pid
          {:error, {:already_started, pid}} when is_pid(pid) -> pid
          other -> flunk("failed to restart IntentStore: #{inspect(other)}")
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
