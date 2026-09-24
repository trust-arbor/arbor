defmodule Arbor.Historian.SecurityInvocationDurabilitySecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  alias Arbor.Persistence.EventLog.ETS

  test "security regression: a volatile target cannot acknowledge a durable security invocation" do
    previous = Application.fetch_env(:arbor_historian, :durable_event_log_target)
    name = __MODULE__.Store
    start_supervised!({ETS, name: name})

    Application.put_env(:arbor_historian, :durable_event_log_target, %{
      name: name,
      backend: ETS,
      opts: []
    })

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:arbor_historian, :durable_event_log_target, value)
        :error -> Application.delete_env(:arbor_historian, :durable_event_log_target)
      end
    end)

    id = "inv_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    event = %{
      "schema" => "arbor.security.invocation.v1",
      "invocation_id" => id,
      "id" => id <> ":attempt:0",
      "sequence" => 0,
      "stage" => "attempt",
      "timestamp" => DateTime.to_iso8601(DateTime.utc_now()),
      "tool" => "synthetic_export",
      "principal_id" => "agent_durability_fixture"
    }

    assert {:error, :invocation_audit_unavailable} =
             Arbor.Historian.persist_security_invocation(event)

    assert {:ok, []} = Arbor.Persistence.read_stream(name, ETS, "security:invocation:" <> id, [])
  end
end
