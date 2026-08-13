defmodule Arbor.Memory.PreferencesMutationAdmissionSecurityRegressionTest do
  @moduledoc """
  Public-API security regression for PreferencesStore reserved-child admission.

  Uses only APIs present on the immediate parent so parent failure is
  behavioral (ETS/Signal mutation before a rejected child start), not a
  compile or setup failure.
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.AsyncWriter.Supervisor, as: WriterSupervisor
  alias Arbor.Memory.MemoryStore
  alias Arbor.Memory.MutationAdmission
  alias Arbor.Memory.Preferences
  alias Arbor.Memory.PreferencesStore
  alias Arbor.Memory.Provenance
  alias Arbor.Memory.Signals
  alias Arbor.Memory.Test.AsyncWriterHangBackend, as: Hang
  alias Arbor.Memory.Test.MutationAdmissionFakeBackend, as: Fake
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B2A"
  @moduletag security_regression: true

  @store_name :arbor_memory_durable
  @ets_table :arbor_preferences
  @namespace "preferences"
  @admission_registry Arbor.Memory.MutationAdmission.Registry
  @guardian_supervisor Arbor.Memory.MutationAdmission.GuardianSupervisor
  @fake_name :pref_sec_ma_fake

  setup do
    ensure_durable_store!()
    ensure_preferences_ets!()
    ensure_provenance!()
    ensure_default_admission!()
    :ok
  end

  test "capacity exhaustion rejects every Preferences mutation before ETS or signals" do
    hang_name = :preferences_capacity_hang_backend
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

    agents = %{
      save: unique_agent("save"),
      save_for: unique_agent("save_for"),
      create: unique_agent("create"),
      adjust: unique_agent("adjust"),
      pin: unique_agent("pin"),
      unpin: unique_agent("unpin"),
      context: unique_agent("context")
    }

    before_signals =
      Map.new(agents, fn {_name, agent_id} -> {agent_id, recent_pref_signals(agent_id)} end)

    assert {:error, :store_unavailable} =
             PreferencesStore.save_preferences(agents.save, Preferences.new(agents.save))

    assert {:error, :store_unavailable} =
             PreferencesStore.save_preferences_for_agent(
               agents.save_for,
               Preferences.new(agents.save_for)
             )

    assert {:error, :store_unavailable} = PreferencesStore.get_or_create(agents.create)

    assert {:error, :store_unavailable} =
             PreferencesStore.adjust_preference(agents.adjust, :decay_rate, 0.12)

    assert {:error, :store_unavailable} = PreferencesStore.pin_memory(agents.pin, "mem_1")
    assert {:error, :store_unavailable} = PreferencesStore.unpin_memory(agents.unpin, "mem_1")

    assert {:error, :store_unavailable} =
             PreferencesStore.set_context_preference(agents.context, :include_goals, false)

    Enum.each(agents, fn {_name, agent_id} ->
      assert [] = :ets.lookup(@ets_table, agent_id)
      assert recent_pref_signals(agent_id) == before_signals[agent_id]
      assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    end)

    assert length(writer_children()) == 1
    assert Hang.cas_count(hang_name) == 1

    Hang.release(hang_name)
    wait_until(fn -> writer_children() == [] end)
    wait_until(fn -> match?({:ok, %{active_roots: 0}}, MutationAdmission.status(holder)) end)

    Enum.each(agents, fn {_name, agent_id} ->
      assert durable_absent?(agent_id)
    end)
  end

  test "post-drain save, default creation, adjust, pin, unpin, context, and restore are denied" do
    agent_id = unique_agent("drain")
    create_id = unique_agent("create_drain")
    other_id = unique_agent("other")
    prefs = Preferences.new(agent_id)
    other_prefs = Preferences.new(other_id)

    assert :ok = PreferencesStore.save_preferences(agent_id, prefs)
    await_durable!(agent_id)
    before = durable_bytes!(agent_id)
    before_ets = :ets.lookup(@ets_table, agent_id)
    before_signals = recent_pref_signals(agent_id)
    assert [{^agent_id, _}] = before_ets

    assert :ok = MemoryStore.persist(@namespace, agent_id, Preferences.serialize(prefs))
    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:ok, _create_fence} = MutationAdmission.drain(create_id)

    assert {:error, :store_unavailable} = PreferencesStore.save_preferences(agent_id, prefs)

    assert {:error, :store_unavailable} =
             PreferencesStore.save_preferences_for_agent(agent_id, prefs)

    assert {:error, :store_unavailable} = PreferencesStore.get_or_create(create_id)

    assert {:error, :store_unavailable} =
             PreferencesStore.adjust_preference(agent_id, :decay_rate, 0.12)

    assert {:error, :store_unavailable} = PreferencesStore.pin_memory(agent_id, "mem_drain")
    assert {:error, :store_unavailable} = PreferencesStore.unpin_memory(agent_id, "mem_drain")

    assert {:error, :store_unavailable} =
             PreferencesStore.set_context_preference(agent_id, :include_goals, false)

    assert :ets.lookup(@ets_table, agent_id) == before_ets
    assert [] = :ets.lookup(@ets_table, create_id)
    assert durable_bytes!(agent_id) == before
    assert recent_pref_signals(agent_id) == before_signals
    assert {:ok, %{active_roots: 0, gate: :draining}} = MutationAdmission.status(agent_id)

    true = :ets.delete(@ets_table, agent_id)
    assert :ok = PreferencesStore.restore_from_store()
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert durable_bytes!(agent_id) == before

    assert :ok = PreferencesStore.save_preferences(other_id, other_prefs)
    assert [{^other_id, %Preferences{agent_id: ^other_id}}] = :ets.lookup(@ets_table, other_id)

    assert wait_until(fn ->
             match?({:ok, %{active_roots: 0}}, MutationAdmission.status(other_id))
           end)
  end

  test "invalid reducer input is rejected before reservation" do
    agent_id = unique_agent("invalid")
    before_children = writer_children()

    assert {:error, {:out_of_range, :decay_rate, _range}} =
             PreferencesStore.adjust_preference(agent_id, :decay_rate, 99.0)

    assert {:error, {:invalid_param, :not_a_param}} =
             PreferencesStore.adjust_preference(agent_id, :not_a_param, :nope)

    assert [] = :ets.lookup(@ets_table, agent_id)
    assert durable_absent?(agent_id)
    assert recent_pref_signals(agent_id) == []
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
    assert writer_children() == before_children
  end

  test "post-drain content cleanup and absence remain usable and root-free" do
    agent_id = unique_agent("cleanup")
    prefs = Preferences.new(agent_id)
    assert :ok = PreferencesStore.save_preferences(agent_id, prefs)
    await_durable!(agent_id)

    payload = Preferences.serialize(prefs)
    sidecar = taint(:trusted, :internal, "pref_sec_cleanup")
    assert :ok = Provenance.put(:preference, agent_id, "prefs", payload, sidecar)
    assert {:ok, ids_before} = Provenance.list_item_ids(:preference, agent_id)
    assert "prefs" in ids_before

    assert {:ok, _fence} = MutationAdmission.drain(agent_id)
    assert {:ok, false} = PreferencesStore.agent_content_absent?(agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)

    assert :ok = PreferencesStore.delete_agent_content(agent_id)
    assert :ok = PreferencesStore.delete_agent_content(agent_id)
    assert {:ok, true} = PreferencesStore.agent_content_absent?(agent_id)
    assert durable_absent?(agent_id)
    assert [] = :ets.lookup(@ets_table, agent_id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:preference, agent_id)
    assert {:ok, %{active_roots: 0}} = MutationAdmission.status(agent_id)
  end

  defp unique_agent(label), do: "pref_sec_#{label}_#{System.unique_integer([:positive])}"

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

  defp recent_pref_signals(agent_id) do
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
    case Process.whereis(@store_name) do
      nil ->
        :ok

      _pid ->
        _ = stop_supervised(BufferedStore)
        :ok
    end

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

  defp ensure_preferences_ets! do
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
