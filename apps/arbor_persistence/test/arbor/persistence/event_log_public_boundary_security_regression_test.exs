defmodule Arbor.Persistence.EventLogPublicBoundarySecurityRegressionTest do
  use ExUnit.Case, async: true

  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Agent, as: AgentEventLog
  alias Arbor.Persistence.EventLog.Ecto, as: EctoEventLog
  alias Arbor.Persistence.EventLog.ETS

  defmodule DeadlineExtendingBackend do
    @moduledoc false

    def append(stream_id, events, opts) do
      Process.sleep(35)

      AgentEventLog.append(
        stream_id,
        events,
        Keyword.put(opts, :append_timeout_ms, 1_000)
      )
    end
  end

  defmodule DeadlineExtendingETSBackend do
    @moduledoc false

    def append(stream_id, events, opts) do
      Process.sleep(35)

      ETS.append(
        stream_id,
        events,
        Keyword.put(opts, :append_timeout_ms, 1_000)
      )
    end
  end

  setup do
    name = :"event_log_public_deadline_#{System.unique_integer([:positive])}"
    ets_name = :"event_log_public_ets_deadline_#{System.unique_integer([:positive])}"
    start_supervised!({AgentEventLog, name: name})
    start_supervised!({ETS, name: ets_name})
    {:ok, name: name, ets_name: ets_name}
  end

  test "security regression: facade validation and backend delegation cannot restart the deadline",
       %{name: name} do
    event = Event.new("public-deadline", "must-not-commit", %{})

    assert {:error, {:append_indeterminate, _operation}} =
             Persistence.append(name, DeadlineExtendingBackend, "public-deadline", event,
               append_timeout_ms: 10
             )

    assert {:ok, 0} = AgentEventLog.stream_version("public-deadline", name: name)
    refute AgentEventLog.stream_exists?("public-deadline", name: name)
  end

  test "security regression: the public deadline cannot restart before ETS delegation", %{
    ets_name: name
  } do
    event = Event.new("public-ets-deadline", "must-not-commit", %{})

    assert {:error, {:append_indeterminate, _operation}} =
             Persistence.append(name, DeadlineExtendingETSBackend, "public-ets-deadline", event,
               append_timeout_ms: 10
             )

    assert {:ok, 0} = ETS.stream_version("public-ets-deadline", name: name)
    refute ETS.stream_exists?("public-ets-deadline", name: name)
  end

  test "security regression: malformed authorization opts are rejected before authorization", %{
    name: name
  } do
    event = Event.new("invalid-auth-opts", "event", %{})

    assert {:error, :invalid_options} =
             Persistence.authorize_append(
               "agent_untrusted",
               name,
               AgentEventLog,
               "invalid-auth-opts",
               event,
               [{:trace_id, "trace"} | :improper]
             )
  end

  test "malformed facade names are rejected without interpolation or backend dispatch" do
    event = Event.new("invalid-name", "event", %{})

    for invalid_name <- [%{not: :a_name}, nil] do
      assert {:error, :invalid_precondition} =
               Persistence.append(invalid_name, AgentEventLog, "invalid-name", event)
    end
  end

  test "malformed loaded repo modules are rejected before callback dispatch" do
    event = Event.new("invalid-loaded-repo", "event", %{})

    assert {:error, :invalid_precondition} =
             EctoEventLog.append("invalid-loaded-repo", event, repo: String)
  end
end
