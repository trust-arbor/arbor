defmodule Arbor.Signals.DurableEmitLineageTest do
  @moduledoc """
  Security regression: durable_emit must not drop audit lineage at the
  EventLog boundary (correlation_id, cause_id→causation_id, agent_id,
  caller metadata + source_node).

  Emits through `Arbor.Signals.durable_emit/4` and reads through the
  public `Arbor.Persistence.read_stream/4` EventLog API. Proves lineage
  and caller metadata are visible to readers after the synchronous hot
  ETS append.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  @event_log_name Arbor.Historian.EventLog.ETS
  @event_log_backend Arbor.Persistence.EventLog.ETS

  setup do
    Arbor.Signals.TestCase.ensure_processes()

    unless Code.ensure_loaded?(Arbor.Persistence.Event) do
      flunk(
        "Arbor.Persistence.Event must be available for durable_emit lineage regression " <>
          "(umbrella build with arbor_persistence beams required)"
      )
    end

    case Application.ensure_all_started(:arbor_persistence) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("failed to start arbor_persistence: #{inspect(reason)}")
    end

    unless Code.ensure_loaded?(@event_log_backend) do
      flunk("Arbor.Persistence.EventLog.ETS must be available for lineage regression")
    end

    case Process.whereis(@event_log_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case @event_log_backend.start_link(name: @event_log_name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> flunk("failed to start Historian EventLog.ETS: #{inspect(reason)}")
        end
    end

    :ok
  end

  test "security regression: durable_emit preserves lineage and caller metadata at EventLog boundary" do
    suffix = System.unique_integer([:positive])
    stream_id = "audit_lineage_#{suffix}"
    type = :"lineage_probe_#{suffix}"
    corr = "corr_lineage_#{suffix}"
    cause = "cause_lineage_#{suffix}"
    agent = "agent_lineage_#{suffix}"

    assert :ok =
             Arbor.Signals.durable_emit(
               :activity,
               type,
               %{probe: true},
               stream_id: stream_id,
               correlation_id: corr,
               cause_id: cause,
               agent_id: agent,
               metadata: %{
                 # String-key entry first: keyword (atom) entries must be last.
                 # Spoof both atom and string keys; system stamp must replace both.
                 "source_node" => "spoofed_string_node",
                 audit_reason: "lineage_regression",
                 source_node: :spoofed_atom_node
               }
             )

    event = read_event!(stream_id, type)

    assert event.correlation_id == corr
    assert event.causation_id == cause
    assert event.agent_id == agent
    assert event.metadata["audit_reason"] == "lineage_regression"

    # System-stamped source_node is the sole persisted value (JSON-canonical string keys).
    system_node = to_string(node())
    assert event.metadata["source_node"] == system_node

    refute event.metadata["source_node"] in [
             "spoofed_atom_node",
             ":spoofed_atom_node",
             "spoofed_string_node"
           ]

    # No residual atom-key spoof after JSON admission (keys are strings only).
    refute Map.has_key?(event.metadata, :source_node)
  end

  test "security regression: absent lineage opts stay nil without empty sentinels" do
    suffix = System.unique_integer([:positive])
    stream_id = "audit_lineage_absent_#{suffix}"
    type = :"lineage_absent_#{suffix}"

    assert :ok =
             Arbor.Signals.durable_emit(
               :activity,
               type,
               %{probe: true},
               stream_id: stream_id
             )

    event = read_event!(stream_id, type)

    assert is_nil(event.correlation_id)
    assert is_nil(event.causation_id)
    assert is_nil(event.agent_id)
    assert is_map(event.metadata)
    assert Map.has_key?(event.metadata, "source_node")
    refute Map.get(event.metadata, "correlation_id") in ["", "nil"]
  end

  defp read_event!(stream_id, type) do
    assert {:ok, events} =
             Arbor.Persistence.read_stream(
               @event_log_name,
               @event_log_backend,
               stream_id
             )

    type_str = to_string(type)

    Enum.find(events, &(&1.type == type_str)) ||
      flunk(
        "expected event type #{inspect(type_str)} in stream #{inspect(stream_id)}, got: #{inspect(events)}"
      )
  end
end
