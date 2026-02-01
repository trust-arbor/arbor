# credo:disable-for-this-file Credo.Check.Refactor.Apply
# apply/3 needed to start ETS backend without compile-time dependency on arbor_persistence
defmodule Arbor.Security.EventsTest do
  use ExUnit.Case, async: false

  alias Arbor.Security.Events

  setup do
    name = :security_events
    backend = Arbor.Persistence.EventLog.ETS

    case apply(backend, :start_link, [[name: name]]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    on_exit(fn ->
      try do
        if Process.whereis(name), do: GenServer.stop(name)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "authorization events" do
    test "records and retrieves authorization_granted" do
      :ok = Events.record_authorization_granted("agent_001", "arbor://fs/read/docs")

      {:ok, events} = Events.get_history()
      assert events != []

      event = List.last(events)
      assert event.type == "authorization_granted"
      assert event.data.principal_id == "agent_001"
      assert event.data.resource_uri == "arbor://fs/read/docs"
    end

    test "records authorization_denied with reason" do
      :ok = Events.record_authorization_denied("agent_002", "arbor://shell/exec/rm", :no_capability)

      {:ok, [event]} = Events.get_by_type(:authorization_denied)
      assert event.data.principal_id == "agent_002"
      assert event.data.reason == ":no_capability"
    end

    test "records authorization_pending with proposal_id" do
      :ok =
        Events.record_authorization_pending(
          "agent_003",
          "arbor://code/hot_load/Kernel",
          "prop_123"
        )

      {:ok, [event]} = Events.get_by_type(:authorization_pending)
      assert event.data.proposal_id == "prop_123"
    end

    test "includes trace_id when provided" do
      :ok =
        Events.record_authorization_granted("agent_001", "arbor://fs/read/docs",
          trace_id: "trace_abc"
        )

      {:ok, events} = Events.get_by_type(:authorization_granted)
      event = List.last(events)
      assert event.data.trace_id == "trace_abc"
    end
  end

  describe "capability events" do
    test "records capability_granted" do
      cap = %{id: "cap_001", principal_id: "agent_001", resource_uri: "arbor://fs/read/docs"}
      :ok = Events.record_capability_granted(cap)

      {:ok, [event]} = Events.get_by_type(:capability_granted)
      assert event.data.capability_id == "cap_001"
      assert event.data.principal_id == "agent_001"
    end

    test "records capability_revoked" do
      :ok = Events.record_capability_revoked("cap_002")

      {:ok, [event]} = Events.get_by_type(:capability_revoked)
      assert event.data.capability_id == "cap_002"
    end
  end

  describe "identity events" do
    test "records identity_registered" do
      :ok = Events.record_identity_registered("agent_new")

      {:ok, [event]} = Events.get_by_type(:identity_registered)
      assert event.data.agent_id == "agent_new"
    end

    test "records identity_verification_succeeded" do
      :ok = Events.record_identity_verification_succeeded("agent_verified")

      {:ok, [event]} = Events.get_by_type(:identity_verification_succeeded)
      assert event.data.agent_id == "agent_verified"
    end

    test "records identity_verification_failed" do
      :ok = Events.record_identity_verification_failed("agent_bad", :invalid_signature)

      {:ok, [event]} = Events.get_by_type(:identity_verification_failed)
      assert event.data.agent_id == "agent_bad"
      assert event.data.reason == ":invalid_signature"
    end
  end

  describe "query helpers" do
    test "get_for_principal filters by principal_id" do
      :ok = Events.record_authorization_granted("agent_A", "arbor://fs/read")
      :ok = Events.record_authorization_denied("agent_B", "arbor://shell/exec", :no_capability)
      :ok = Events.record_authorization_granted("agent_A", "arbor://fs/write")

      {:ok, events} = Events.get_for_principal("agent_A")
      assert Enum.all?(events, fn e -> e.data.principal_id == "agent_A" end)
      assert events != []
    end

    test "get_for_principal also matches agent_id field" do
      :ok = Events.record_identity_registered("agent_C")

      {:ok, events} = Events.get_for_principal("agent_C")
      assert events != []
    end

    test "get_recent returns events" do
      :ok = Events.record_authorization_granted("agent_first", "arbor://a")
      :ok = Events.record_authorization_granted("agent_second", "arbor://b")

      {:ok, events} = Events.get_recent(10)
      assert events != []
    end

    test "get_history returns all events" do
      :ok = Events.record_authorization_granted("agent_all", "arbor://test")

      {:ok, events} = Events.get_history()
      assert is_list(events)
      assert events != []
    end
  end

  describe "resilience" do
    test "dual_emit succeeds even without EventLog (signal still emits)" do
      GenServer.stop(:security_events)
      Process.sleep(50)

      assert :ok = Events.record_authorization_granted("agent_resilient", "arbor://test")
    end
  end
end
