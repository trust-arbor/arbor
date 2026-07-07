defmodule Arbor.Signals.TelemetryTest do
  use Arbor.Signals.TestCase

  alias Arbor.Signals
  alias Arbor.Signals.Signal
  alias Arbor.Signals.Telemetry

  test "bridge honors explicit signal metadata from telemetry events" do
    bridge_id = "arbor-signals-telemetry-test-#{System.unique_integer([:positive])}"
    original_restricted = Application.get_env(:arbor_signals, :restricted_topics)

    Application.put_env(:arbor_signals, :restricted_topics, [])

    on_exit(fn ->
      Telemetry.detach(bridge_id)
      restore_env(:arbor_signals, :restricted_topics, original_restricted)
    end)

    parent = self()

    {:ok, sub_id} =
      Signals.subscribe(
        "security.authorization_denied",
        fn signal ->
          send(parent, {:bridged_signal, signal})
          :ok
        end,
        async: false
      )

    on_exit(fn -> Signals.unsubscribe(sub_id) end)

    {:ok, ^bridge_id} =
      Telemetry.attach_bridge(
        [[:arbor, :security, :authorization_denied]],
        id: bridge_id,
        category: :telemetry
      )

    :telemetry.execute(
      [:arbor, :security, :authorization_denied],
      %{count: 1},
      %{
        signal_category: :security,
        signal_type: :authorization_denied,
        signal_data: %{principal_id: "agent_001", resource_uri: "arbor://fs/read"},
        signal_opts: [source: "security-kernel"],
        signal_durable: false
      }
    )

    assert_receive {:bridged_signal, %Signal{} = signal}

    assert signal.category == :security
    assert signal.type == :authorization_denied
    assert signal.source == "security-kernel"
    assert signal.data.principal_id == "agent_001"
    assert signal.data.resource_uri == "arbor://fs/read"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
