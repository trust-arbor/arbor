defmodule Arbor.Security.TelemetryTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security.Telemetry

  test "emits normalized security telemetry metadata for signal bridges" do
    parent = self()
    handler_id = "arbor-security-telemetry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:arbor, :security, :authorization_denied],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             Telemetry.emit(
               :authorization_denied,
               %{principal_id: "agent_001", resource_uri: "arbor://fs/read"},
               signal_durable: true,
               stream_id: "security:events"
             )

    assert_receive {:telemetry_event, event, measurements, metadata}

    assert event == [:arbor, :security, :authorization_denied]
    assert measurements == %{count: 1}
    assert metadata.category == :security
    assert metadata.type == :authorization_denied
    assert metadata.data.principal_id == "agent_001"
    assert metadata.signal_category == :security
    assert metadata.signal_type == :authorization_denied
    assert metadata.signal_data.resource_uri == "arbor://fs/read"
    assert metadata.signal_durable == true
    assert metadata.signal_opts[:stream_id] == "security:events"
  end
end
