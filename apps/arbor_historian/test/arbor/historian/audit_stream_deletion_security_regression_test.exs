defmodule Arbor.Historian.AuditStreamDeletionSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Historian
  alias Arbor.Persistence
  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.ETS

  @moduletag :fast

  setup do
    durable = :audit_deletion_regression_durable
    hot = :audit_deletion_regression_hot

    start_supervised!({ETS, name: durable, trim_interval_ms: :disabled}, id: durable)
    start_supervised!({ETS, name: hot, mode: :projection, trim_interval_ms: :disabled}, id: hot)

    for {key, name} <- [durable_event_log_target: durable, hot_event_log_target: hot] do
      previous = Application.fetch_env(:arbor_historian, key)
      Application.put_env(:arbor_historian, key, %{name: name, backend: ETS, opts: []})

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:arbor_historian, key, value)
          :error -> Application.delete_env(:arbor_historian, key)
        end
      end)
    end

    %{durable: durable, hot: hot}
  end

  for prefix <- ["security:authority_mutation:", "security:invocation:"] do
    @prefix prefix
    test "security regression: deletion refuses #{@prefix} audit streams before either store changes",
         %{durable: durable, hot: hot} do
      for stream <- [@prefix, @prefix <> "agent_regression"] do
        event = Event.new(stream, "security.audit", %{"evidence" => "retain"})
        assert {:ok, [persisted]} = Persistence.append(durable, ETS, stream, event)

        assert {:ok, %{projected: 1}} =
                 Persistence.project_committed_events(hot, ETS, [persisted])

        for delete <- [
              &Historian.delete_stream_content/2,
              &Historian.delete_complete_history_stream_content/2
            ] do
          assert {:error, :delete_not_supported} = delete.(stream, [])
          assert {:ok, false} = Historian.stream_content_absent?(stream)
          assert {:ok, [^persisted]} = Persistence.read_stream(durable, ETS, stream)
          assert {:ok, [^persisted]} = Persistence.read_stream(hot, ETS, stream)
        end
      end
    end
  end

  test "ordinary complete-history deletion remains supported", %{durable: durable} do
    stream = "session:audit_deletion_regression"
    assert {:ok, [_]} = Persistence.append(durable, ETS, stream, Event.new(stream, "test", %{}))
    assert :ok = Historian.delete_stream_content(stream)
    assert {:ok, true} = Historian.stream_content_absent?(stream)
  end
end
