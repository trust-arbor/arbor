defmodule Arbor.Security.EventsRecordingAdapter do
  @moduledoc false
  @behaviour Arbor.Security.Contracts.EventLogAdapter

  @table __MODULE__

  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :ordered_set])

      _tid ->
        :ok
    end

    reset()
  end

  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  def invocations do
    @table
    |> :ets.tab2list()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @impl true
  def persist_security_event(event_type, data) do
    seq = System.unique_integer([:monotonic, :positive])
    event = %{type: event_type, data: data}
    :ets.insert(@table, {seq, {:persist_security_event, event_type, data}, event})
    :ok
  end

  @impl true
  def read_security_events(_opts) do
    events =
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 2))

    {:ok, events}
  end
end

defmodule Arbor.Security.EventsAtomKeyAdapterFixture do
  @moduledoc false
  @behaviour Arbor.Security.Contracts.EventLogAdapter

  def persist_security_event(_event_type, _data), do: :ok

  def read_security_events(_opts) do
    {:ok, [%{type: "authorization_granted", data: %{principal_id: "legacy_agent"}}]}
  end
end

defmodule Arbor.Security.EventsRaisingAdapter do
  @moduledoc false
  @behaviour Arbor.Security.Contracts.EventLogAdapter

  def persist_security_event(_event_type, _data), do: raise("adapter boom")
  def read_security_events(_opts), do: {:error, :event_log_unavailable}
end

defmodule Arbor.Security.EventsTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security.Events
  alias Arbor.Security.EventsAtomKeyAdapterFixture
  alias Arbor.Security.EventsRaisingAdapter
  alias Arbor.Security.EventsRecordingAdapter

  setup do
    previous = Application.get_env(:arbor_security, :event_log_adapter)
    EventsRecordingAdapter.setup()
    Application.put_env(:arbor_security, :event_log_adapter, EventsRecordingAdapter)

    on_exit(fn -> restore_adapter(previous) end)

    :ok
  end

  describe "authorization events" do
    test "records authorization_granted through the adapter" do
      assert :ok = Events.record_authorization_granted("agent_001", "arbor://fs/read/docs")

      assert invocations() == [
               persist(:authorization_granted, %{
                 principal_id: "agent_001",
                 resource_uri: "arbor://fs/read/docs",
                 trace_id: nil
               })
             ]

      {:ok, [event]} = Events.get_by_type(:authorization_granted)
      assert event.data.principal_id == "agent_001"
      assert event.data.resource_uri == "arbor://fs/read/docs"
    end

    test "records authorization_denied with reason" do
      assert :ok =
               Events.record_authorization_denied(
                 "agent_002",
                 "arbor://shell/exec/rm",
                 :no_capability
               )

      assert invocations() == [
               persist(:authorization_denied, %{
                 principal_id: "agent_002",
                 resource_uri: "arbor://shell/exec/rm",
                 reason: ":no_capability",
                 trace_id: nil
               })
             ]
    end

    test "records authorization_pending with proposal_id" do
      assert :ok =
               Events.record_authorization_pending(
                 "agent_003",
                 "arbor://code/hot_load/Kernel",
                 "prop_123"
               )

      assert invocations() == [
               persist(:authorization_pending, %{
                 principal_id: "agent_003",
                 resource_uri: "arbor://code/hot_load/Kernel",
                 proposal_id: "prop_123",
                 trace_id: nil
               })
             ]
    end

    test "records approval_answered with answer metadata" do
      assert :ok =
               Events.record_approval_answered(
                 "human_1",
                 "irq_123",
                 :interaction,
                 :approve,
                 agent_id: "agent_1",
                 principal_id: "agent_1",
                 resource_uri: "arbor://shell/exec/git",
                 note: "bounded command"
               )

      assert invocations() == [
               persist(:approval_answered, %{
                 actor_id: "human_1",
                 approval_id: "irq_123",
                 source: :interaction,
                 decision: :approve,
                 resource_uri: "arbor://shell/exec/git",
                 agent_id: "agent_1",
                 principal_id: "agent_1",
                 note: "bounded command",
                 trace_id: nil
               })
             ]
    end

    test "records orchestration_task_dispatched with task metadata" do
      assert :ok =
               Events.record_orchestration_task_dispatched(
                 "human_1",
                 "task_123",
                 "agent_1",
                 task_preview: "write a patch",
                 metadata: %{ticket: "A-1"},
                 trace_id: "trace_abc"
               )

      assert invocations() == [
               persist(:orchestration_task_dispatched, %{
                 actor_id: "human_1",
                 task_id: "task_123",
                 agent_id: "agent_1",
                 task_preview: "write a patch",
                 metadata: %{ticket: "A-1"},
                 trace_id: "trace_abc"
               })
             ]
    end

    test "includes trace_id when provided" do
      assert :ok =
               Events.record_authorization_granted("agent_001", "arbor://fs/read/docs",
                 trace_id: "trace_abc"
               )

      assert invocations() == [
               persist(:authorization_granted, %{
                 principal_id: "agent_001",
                 resource_uri: "arbor://fs/read/docs",
                 trace_id: "trace_abc"
               })
             ]
    end
  end

  describe "capability events" do
    test "records capability_granted" do
      cap = %{id: "cap_001", principal_id: "agent_001", resource_uri: "arbor://fs/read/docs"}
      assert :ok = Events.record_capability_granted(cap)

      assert invocations() == [
               persist(:capability_granted, %{
                 capability_id: "cap_001",
                 principal_id: "agent_001",
                 resource_uri: "arbor://fs/read/docs"
               })
             ]
    end

    test "records capability_revoked" do
      assert :ok = Events.record_capability_revoked("cap_002")

      assert invocations() == [
               persist(:capability_revoked, %{capability_id: "cap_002"})
             ]
    end
  end

  describe "identity events" do
    test "records identity_registered" do
      assert :ok = Events.record_identity_registered("agent_new")

      assert invocations() == [
               persist(:identity_registered, %{agent_id: "agent_new"})
             ]
    end

    test "records identity_verification_succeeded" do
      assert :ok = Events.record_identity_verification_succeeded("agent_verified")

      assert invocations() == [
               persist(:identity_verification_succeeded, %{
                 agent_id: "agent_verified",
                 trace_id: nil,
                 signature: nil,
                 payload_hash: nil,
                 nonce: nil,
                 signed_at: nil
               })
             ]
    end

    test "records identity_verification_failed" do
      assert :ok = Events.record_identity_verification_failed("agent_bad", :invalid_signature)

      assert invocations() == [
               persist(:identity_verification_failed, %{
                 agent_id: "agent_bad",
                 reason: ":invalid_signature",
                 trace_id: nil,
                 nonce: nil,
                 signed_at: nil
               })
             ]
    end
  end

  describe "query helpers" do
    test "get_for_principal filters by principal_id" do
      assert :ok = Events.record_authorization_granted("agent_A", "arbor://fs/read")

      assert :ok =
               Events.record_authorization_denied(
                 "agent_B",
                 "arbor://shell/exec",
                 :no_capability
               )

      assert :ok = Events.record_authorization_granted("agent_A", "arbor://fs/write")

      {:ok, events} = Events.get_for_principal("agent_A")
      assert Enum.all?(events, fn e -> e.data.principal_id == "agent_A" end)
      assert length(events) == 2
    end

    test "get_for_principal also matches agent_id field" do
      assert :ok = Events.record_identity_registered("agent_C")

      {:ok, events} = Events.get_for_principal("agent_C")
      assert events != []
    end

    test "get_for_principal also matches legacy atom-key fixtures" do
      Application.put_env(:arbor_security, :event_log_adapter, EventsAtomKeyAdapterFixture)

      assert {:ok, [%{data: %{principal_id: "legacy_agent"}}]} =
               Events.get_for_principal("legacy_agent")
    end

    test "get_recent returns events" do
      assert :ok = Events.record_authorization_granted("agent_first", "arbor://a")
      assert :ok = Events.record_authorization_granted("agent_second", "arbor://b")

      {:ok, events} = Events.get_recent(10)
      assert events != []
    end

    test "get_history returns all events" do
      assert :ok = Events.record_authorization_granted("agent_all", "arbor://test")

      {:ok, events} = Events.get_history()
      assert is_list(events)
      assert events != []
    end

    test "get_history is unavailable without an adapter" do
      Application.delete_env(:arbor_security, :event_log_adapter)
      assert {:error, :event_log_unavailable} = Events.get_history()
    end
  end

  describe "resilience" do
    test "recording succeeds even when the adapter is absent" do
      Application.delete_env(:arbor_security, :event_log_adapter)
      assert :ok = Events.record_authorization_granted("agent_resilient", "arbor://test")
    end

    test "recording succeeds even when the adapter raises" do
      Application.put_env(:arbor_security, :event_log_adapter, EventsRaisingAdapter)
      assert :ok = Events.record_authorization_granted("agent_resilient", "arbor://test")
    end
  end

  describe "telemetry" do
    test "record still emits security telemetry when persist is best-effort" do
      parent = self()
      handler_id = "arbor-security-events-telemetry-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler_id,
          [:arbor, :security, :authorization_granted],
          fn event, measurements, metadata, _config ->
            send(parent, {:telemetry_event, event, measurements, metadata})
          end,
          %{}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = Events.record_authorization_granted("agent_tel", "arbor://fs/read")

      assert_receive {:telemetry_event, [:arbor, :security, :authorization_granted], %{count: 1},
                      metadata}

      assert metadata.type == :authorization_granted
      assert metadata.data.principal_id == "agent_tel"
      assert metadata.signal_opts[:stream_id] == "security:events"
    end
  end

  describe "adapter inversion" do
    test "production Events source has no Persistence or Historian reference" do
      source =
        File.read!(Path.expand("../../../lib/arbor/security/events.ex", __DIR__))

      refute source =~ "Arbor.Persistence"
      refute source =~ "Arbor.Historian"
      refute source =~ ~s("Persistence")
      refute source =~ ~s("Historian")
    end
  end

  defp invocations, do: EventsRecordingAdapter.invocations()

  defp persist(type, data), do: {:persist_security_event, type, data}

  defp restore_adapter(nil), do: Application.delete_env(:arbor_security, :event_log_adapter)

  defp restore_adapter(adapter),
    do: Application.put_env(:arbor_security, :event_log_adapter, adapter)
end
