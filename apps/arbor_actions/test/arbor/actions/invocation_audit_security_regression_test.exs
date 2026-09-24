defmodule Arbor.Actions.InvocationAuditSecurityRegressionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  defmodule Sink do
    def persist_security_invocation(event) do
      send(Application.fetch_env!(:arbor_security, :invocation_audit_test_owner), {:audit, event})

      case Application.get_env(:arbor_security, :invocation_audit_test_failure) do
        true -> {:error, :unavailable}
        _ -> {:ok, event["id"]}
      end
    end
  end

  setup do
    keys = [
      :invocation_audit_mode,
      :invocation_audit_sink,
      :invocation_audit_test_owner,
      :invocation_audit_test_failure
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:arbor_security, &1)})
    Application.put_env(:arbor_security, :invocation_audit_mode, :required)
    Application.put_env(:arbor_security, :invocation_audit_sink, Sink)
    Application.put_env(:arbor_security, :invocation_audit_test_owner, self())
    Application.delete_env(:arbor_security, :invocation_audit_test_failure)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)
    end)

    :ok
  end

  test "security regression: public refused action has source-owned correlated attempt and outcome" do
    result =
      Arbor.Actions.authorize_and_execute(
        "agent_audit_without_grants",
        Arbor.Actions.File.Read,
        %{path: "/private/synthetic-secret-value"},
        %{invocation_id: "forged", correlation_id: "forged", password: "must-not-record"}
      )

    assert {:error, _} = result
    assert_receive {:audit, attempt}
    assert attempt["stage"] == "attempt"
    refute attempt["invocation_id"] == "forged"
    events = drain_audit([attempt])
    assert Enum.any?(events, &(&1["stage"] == "outcome" and &1["outcome"] == "refused"))
    assert Enum.all?(events, &(&1["invocation_id"] == attempt["invocation_id"]))
    refute inspect(events) =~ "must-not-record"
    refute inspect(events) =~ "synthetic-secret-value"
  end

  test "security regression: unavailable required audit refuses public action before authorization" do
    Application.put_env(:arbor_security, :invocation_audit_test_failure, true)

    assert {:error, :invocation_audit_unavailable} =
             Arbor.Actions.authorize_and_execute(
               "agent_audit_without_grants",
               Arbor.Actions.File.Read,
               %{path: "mix.exs"}
             )

    assert_receive {:audit, %{"stage" => "attempt"}}
    refute_receive {:audit, %{"stage" => "outcome"}}
  end

  defp drain_audit(events) do
    receive do
      {:audit, event} -> drain_audit(events ++ [event])
    after
      0 -> events
    end
  end
end
