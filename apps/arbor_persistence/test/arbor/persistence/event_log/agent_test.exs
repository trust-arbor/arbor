defmodule Arbor.Persistence.EventLog.AgentTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Agent, as: ELAgent

  setup do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    name = :"el_agent_#{:erlang.unique_integer([:positive])}"
    start_supervised!({ELAgent, name: name})
    {:ok, name: name}
  end

  describe "append/3" do
    test "appends a single event", %{name: name} do
      event = Event.new("stream-1", "test_event", %{value: 1})
      assert {:ok, [persisted]} = ELAgent.append("stream-1", event, name: name)

      assert persisted.stream_id == "stream-1"
      assert persisted.event_number == 1
      assert persisted.global_position == 1
    end

    test "appends multiple events", %{name: name} do
      events = [
        Event.new("s1", "a", %{}),
        Event.new("s1", "b", %{})
      ]

      {:ok, persisted} = ELAgent.append("s1", events, name: name)
      assert length(persisted) == 2
      assert Enum.map(persisted, & &1.event_number) == [1, 2]
    end

    test "maintains separate numbering per stream", %{name: name} do
      {:ok, [e1]} = ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      {:ok, [e2]} = ELAgent.append("s2", Event.new("s2", "t", %{}), name: name)

      assert e1.event_number == 1
      assert e2.event_number == 1
      assert e1.global_position == 1
      assert e2.global_position == 2
    end

    test "forwards and enforces CAS and freshness options", %{name: name} do
      event = Event.new("guarded", "started", %{})
      assert {:ok, [_]} = ELAgent.append("guarded", event, name: name, expected_version: 0)

      assert {:error, :version_conflict} =
               ELAgent.append("guarded", Event.new("guarded", "duplicate", %{}),
                 name: name,
                 expected_version: 0
               )

      assert {:ok, [_]} =
               ELAgent.append("guarded", Event.new("guarded", "continued", %{}),
                 name: name,
                 expected_version: 1,
                 max_current_age_ms: 60_000
               )

      assert {:error, :deadline_exceeded} =
               ELAgent.append("guarded", Event.new("guarded", "expired", %{}),
                 name: name,
                 expected_version: 2,
                 max_current_age_ms: 0
               )

      assert {:ok, nil} =
               ELAgent.read_stream_head("guarded", name: name, max_current_age_ms: 0)

      assert {:ok, %Event{event_number: 2}} = ELAgent.read_stream_head("guarded", name: name)
    end

    test "security regression: a timed-out queued append cannot commit after the agent resumes",
         %{
           name: name
         } do
      stream_id = "timed-out"
      event = Event.new(stream_id, "must-not-commit", %{})
      :ok = :sys.suspend(name)

      task =
        Task.async(fn ->
          ELAgent.append(stream_id, event,
            name: name,
            expected_version: 0,
            call_timeout_ms: 25
          )
        end)

      result =
        try do
          Task.await(task, 1_000)
        after
          :ok = :sys.resume(name)
        end

      assert {:error, {:append_indeterminate, operation}} = result

      # This call is handled after the expired append already queued in the mailbox.
      assert {:ok, 0} = ELAgent.stream_version(stream_id, name: name)
      refute ELAgent.stream_exists?(stream_id, name: name)
      assert {:ok, :absent} = ELAgent.reconcile_append(operation, name: name)
    end

    test "security regression: an expired post-decision candidate preserves the original state" do
      parent = self()
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_agent_delayed_candidate_#{:erlang.unique_integer([:positive])}"

      start_supervised!(
        {ELAgent,
         name: name,
         append_candidate_hook: fn ->
           send(parent, :candidate_built)
           Process.sleep(35)
         end},
        id: name
      )

      event = Event.new("post-decision-timeout", "must-not-commit", %{})

      assert {:error, {:append_indeterminate, operation}} =
               ELAgent.append("post-decision-timeout", event,
                 name: name,
                 expected_version: 0,
                 call_timeout_ms: 10
               )

      assert_receive :candidate_built
      assert {:ok, 0} = ELAgent.stream_version("post-decision-timeout", name: name)
      refute ELAgent.stream_exists?("post-decision-timeout", name: name)
      assert {:ok, :absent} = ELAgent.reconcile_append(operation, name: name)
    end

    test "normalizes an agent killed during transport instead of exiting the caller" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"el_agent_killed_#{:erlang.unique_integer([:positive])}"

      {:ok, pid} = ELAgent.start_link(name: name)

      Process.unlink(pid)
      :ok = :sys.suspend(pid)
      event = Event.new("killed", "event", %{})
      assert {:ok, operation} = Arbor.Persistence.EventLog.build_operation("killed", [event])

      task =
        Task.async(fn ->
          ELAgent.append("killed", event,
            name: name,
            call_timeout_ms: 1_000
          )
        end)

      wait_for_queued_call(pid)
      Process.exit(pid, :kill)

      assert {:error, {:append_indeterminate, ^operation}} = Task.await(task, 1_000)
    end

    test "returns stable errors for unavailable agents and invalid call deadlines" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      missing_name = :"missing_el_agent_#{:erlang.unique_integer([:positive])}"
      event = Event.new("missing", "event", %{})

      assert {:error, :backend_unavailable} =
               ELAgent.append("missing", event, name: missing_name, call_timeout_ms: 25)

      assert {:error, :invalid_precondition} =
               ELAgent.append("missing", event, name: missing_name, call_timeout_ms: :infinity)
    end

    test "forged operations and improper reconcile options are rejected before Agent access", %{
      name: name
    } do
      event = Event.new("forged", "created", %{value: 1})

      assert {:ok, operation} =
               Arbor.Persistence.EventLog.build_operation("forged", [event])

      Enum.each(forged_operations(operation), fn forged ->
        assert {:error, :invalid_append_operation} =
                 ELAgent.reconcile_append(forged, name: name)
      end)

      assert {:error, :invalid_precondition} =
               ELAgent.reconcile_append(operation, [{:name, name} | :improper])

      assert Process.alive?(Process.whereis(name))
    end

    test "same exact append is idempotent and changed content under one ID conflicts", %{
      name: name
    } do
      event = Event.new("idempotent", "created", %{value: 1})
      assert {:ok, [first]} = ELAgent.append("idempotent", event, name: name)
      assert {:ok, [retried]} = ELAgent.append("idempotent", event, name: name)
      assert retried == first

      changed = %Event{event | data: %{value: 2}}

      assert {:error, :event_identity_conflict} =
               ELAgent.append("idempotent", changed, name: name)

      assert {:ok, 1} = ELAgent.stream_version("idempotent", name: name)
    end

    test "append, retry, and read return one canonical JSON representation", %{name: name} do
      event =
        Event.new("canonical", "arbor.review.ordinary", %{outer: %{value: 1}},
          metadata: %{source: "agent"}
        )

      expected_data = %{"outer" => %{"value" => 1}}
      expected_metadata = %{"source" => "agent"}

      assert {:ok, [first]} = ELAgent.append("canonical", event, name: name)
      assert first.data == expected_data
      assert first.metadata == expected_metadata

      assert {:ok, [retried]} = ELAgent.append("canonical", event, name: name)
      assert retried == first

      assert {:ok, [read]} = ELAgent.read_stream("canonical", name: name)
      assert read == first
    end

    test "malformed public names are rejected without raising" do
      event = Event.new("invalid-name", "event", %{})

      for invalid_name <- [%{not: :a_server}, nil] do
        assert {:error, :invalid_precondition} =
                 ELAgent.append("invalid-name", event, name: invalid_name)
      end
    end

    test "position exhaustion returns controlled errors before mutation", %{name: name} do
      :sys.replace_state(name, fn state ->
        %{state | versions: %{"full-stream" => 2_147_483_647}}
      end)

      assert {:error, :stream_position_exhausted} =
               ELAgent.append("full-stream", Event.new("full-stream", "event", %{}), name: name)

      :sys.replace_state(name, fn state ->
        %{state | versions: %{}, global_position: 2_147_483_647}
      end)

      assert {:error, :global_position_exhausted} =
               ELAgent.append("global-full", Event.new("global-full", "event", %{}), name: name)
    end
  end

  defp forged_operations(operation) do
    oversized_ids = Enum.map(1..1_001, &"evt_forged_#{&1}")

    [
      rebuild_operation(operation, event_ids: ["evt_forged" | :improper]),
      rebuild_operation(operation, event_ids: oversized_ids, fingerprints: %{})
    ]
  end

  defp rebuild_operation(operation, attrs) do
    operation.__struct__
    |> struct(Map.merge(Map.from_struct(operation), Map.new(attrs)))
  end

  describe "read_stream/2" do
    test "reads all events from a stream", %{name: name} do
      events = for i <- 1..3, do: Event.new("s1", "t#{i}", %{})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name)
      assert length(read) == 3
    end

    test "reads from a specific event number", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "t#{i}", %{})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name, from: 3)
      assert length(read) == 3
    end

    test "limits results", %{name: name} do
      events = for i <- 1..5, do: Event.new("s1", "t", %{i: i})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name, limit: 2)
      assert length(read) == 2
    end

    test "reads backward", %{name: name} do
      events = for i <- 1..3, do: Event.new("s1", "t", %{i: i})
      ELAgent.append("s1", events, name: name)

      {:ok, read} = ELAgent.read_stream("s1", name: name, direction: :backward)
      numbers = Enum.map(read, & &1.event_number)
      assert numbers == [3, 2, 1]
    end
  end

  describe "read_all/1" do
    test "reads all events in global order", %{name: name} do
      ELAgent.append("s1", Event.new("s1", "a", %{}), name: name)
      ELAgent.append("s2", Event.new("s2", "b", %{}), name: name)

      {:ok, all} = ELAgent.read_all(name: name)
      assert length(all) == 2
      assert Enum.map(all, & &1.type) == ["a", "b"]
    end

    test "reads from global position", %{name: name} do
      for i <- 1..5 do
        ELAgent.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, all} = ELAgent.read_all(name: name, from: 3)
      assert length(all) == 3
    end
  end

  describe "child_spec/1" do
    test "returns valid child spec" do
      spec = ELAgent.child_spec(name: :test_el)
      assert spec.id == :test_el
      assert spec.type == :worker
      assert {ELAgent, :start_link, [_opts]} = spec.start
    end

    test "uses module as default id" do
      spec = ELAgent.child_spec([])
      assert spec.id == ELAgent
    end
  end

  describe "read_all/1 with limit" do
    test "limits global read results", %{name: name} do
      for i <- 1..5 do
        ELAgent.append("s1", Event.new("s1", "t#{i}", %{}), name: name)
      end

      {:ok, all} = ELAgent.read_all(name: name, limit: 2)
      assert length(all) == 2
    end
  end

  describe "stream_exists?/2 and stream_version/2" do
    test "stream_exists? returns true for existing stream", %{name: name} do
      ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      assert ELAgent.stream_exists?("s1", name: name)
    end

    test "stream_exists? returns false for missing stream", %{name: name} do
      refute ELAgent.stream_exists?("nope", name: name)
    end

    test "stream_version returns current version", %{name: name} do
      ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      ELAgent.append("s1", Event.new("s1", "t", %{}), name: name)
      assert {:ok, 2} = ELAgent.stream_version("s1", name: name)
    end

    test "stream_version returns 0 for missing stream", %{name: name} do
      assert {:ok, 0} = ELAgent.stream_version("nope", name: name)
    end
  end

  defp wait_for_queued_call(pid, attempts \\ 100)

  defp wait_for_queued_call(_pid, 0), do: flunk("append call did not reach suspended Agent")

  defp wait_for_queued_call(pid, attempts) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} when count > 0 ->
        :ok

      _other ->
        Process.sleep(2)
        wait_for_queued_call(pid, attempts - 1)
    end
  end
end
