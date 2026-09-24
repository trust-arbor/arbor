defmodule Arbor.Historian.SecurityInvocationSinkTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Persistence.EventLog.ETS

  setup do
    old = Application.fetch_env(:arbor_historian, :durable_event_log_target)
    name = __MODULE__.Store
    start_supervised!({ETS, name: name})
    Application.put_env(:arbor_historian, :durable_event_log_target,
      %{name: name, backend: ETS, opts: []})
    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:arbor_historian, :durable_event_log_target, value)
        :error -> Application.delete_env(:arbor_historian, :durable_event_log_target)
      end
    end)
    %{name: name}
  end

  test "exact frozen invocation event is idempotent and retains correlation" do
    event = event()
    assert {:ok, id} = Arbor.Historian.persist_security_invocation(event)
    assert id == event["id"]
    assert {:ok, ^id} = Arbor.Historian.persist_security_invocation(event)
    assert {:ok, %{outcome: "indeterminate", events: [stored]}} =
      Arbor.Historian.security_invocation(event["invocation_id"])
    assert stored.correlation_id == event["invocation_id"]
    assert stored.data == event
  end

  test "different content at the same event id is never an acknowledgment" do
    event = event()
    assert {:ok, _} = Arbor.Historian.persist_security_invocation(event)
    assert {:error, :invocation_audit_unavailable} =
      Arbor.Historian.persist_security_invocation(Map.put(event, "tool", "different"))
  end

  test "missing durable target cannot acknowledge an event" do
    Application.put_env(:arbor_historian, :durable_event_log_target, :unavailable)
    assert {:error, :invocation_audit_unavailable} = Arbor.Historian.persist_security_invocation(event())
  end

  defp event do
    id = "inv_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    %{"schema" => "arbor.security.invocation.v1", "invocation_id" => id,
      "id" => id <> ":attempt:0", "sequence" => 0, "stage" => "attempt",
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()), "tool" => "synthetic_export",
      "principal_id" => "agent_audit_fixture"}
  end
end
