defmodule Arbor.Persistence.AgentTelemetryDatabaseTest do
  use Arbor.Persistence.DatabaseCase, async: false

  @moduletag :database
  @moduletag :integration

  alias Arbor.Persistence
  alias Arbor.Persistence.AgentTelemetry
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.TelemetryEvent

  setup do
    Repo.delete_all(TelemetryEvent)
    :ok
  end

  test "persist, query, and lifetime aggregates round-trip on the compiled adapter" do
    agent_id = "agent_db_#{System.unique_integer([:positive])}"
    window_start = DateTime.add(DateTime.utc_now(), -1, :second)
    insertion_started_at = DateTime.utc_now()

    assert :ok =
             Persistence.persist_event(agent_id, :turn_completed, %{
               input_tokens: 10,
               output_tokens: 4,
               cached_tokens: 1,
               cost: 0.02
             })

    assert :ok =
             Persistence.persist_event(agent_id, :tool_call, %{
               tool_name: "file.read",
               result: :ok,
               duration_ms: 9,
               metadata: %{decision: :classified, details: %{outcome: :ok}}
             })

    assert :ok = Persistence.persist_event(agent_id, :compaction, %{utilization: 0.8})
    insertion_completed_at = DateTime.utc_now()

    assert {:ok, events} = Persistence.query_events(agent_id, order: :asc, limit: 10)
    assert length(events) == 3
    assert Enum.map(events, & &1.event_type) == ["turn_completed", "tool_call", "compaction"]
    assert Enum.all?(events, &(&1.agent_id == agent_id))
    assert Enum.all?(events, &(is_map(&1.data) and map_size(&1.data) >= 0))
    assert Enum.all?(events, &Regex.match?(~r/^tevt_[0-9a-f]{16}$/, &1.id))

    assert {:ok, [tool]} =
             Persistence.query_events(agent_id, event_type: :tool_call, limit: 5)

    assert tool.event_type == "tool_call"
    assert tool.data["tool_name"] == "file.read"
    assert tool.data["result"] == "ok"
    assert tool.data["duration_ms"] == 9

    assert tool.data["metadata"] == %{
             "decision" => "classified",
             "details" => %{"outcome" => "ok"}
           }

    persisted_tool = Repo.get!(TelemetryEvent, tool.id)
    assert %DateTime{time_zone: "Etc/UTC"} = persisted_tool.timestamp
    assert DateTime.compare(persisted_tool.timestamp, insertion_started_at) in [:gt, :eq]
    assert DateTime.compare(persisted_tool.timestamp, insertion_completed_at) in [:lt, :eq]

    window_end = DateTime.add(DateTime.utc_now(), 1, :second)

    assert {:ok, window_events} =
             Persistence.query_events(agent_id,
               since: window_start,
               until: window_end,
               order: :desc,
               limit: 2
             )

    assert length(window_events) == 2

    assert {:ok, []} =
             Persistence.query_events(agent_id,
               since: DateTime.add(window_end, 60, :second)
             )

    lifetime = Persistence.load_lifetime(agent_id)
    assert is_map(lifetime)
    assert lifetime[:turn_count] == 1
    assert lifetime[:compaction_count] == 1
    assert to_number(lifetime[:lifetime_input_tokens]) == 10
    assert to_number(lifetime[:lifetime_output_tokens]) == 4
    assert_in_delta to_number(lifetime[:lifetime_cost]), 0.02, 0.0001

    assert AgentTelemetry.query_events(agent_id, limit: 1) ==
             Persistence.query_events(agent_id, limit: 1)
  end

  test "unsupported event types are rejected without inserting a row" do
    agent_id = "agent_invalid_#{System.unique_integer([:positive])}"

    assert {:error, %Ecto.Changeset{} = changeset} =
             Persistence.persist_event(agent_id, :unsupported, %{})

    assert {"is invalid", _metadata} = changeset.errors[:event_type]
    assert {:ok, []} = Persistence.query_events(agent_id)
  end

  defp to_number(%Decimal{} = dec), do: Decimal.to_float(dec)
  defp to_number(n) when is_number(n), do: n
  defp to_number(other), do: other
end
