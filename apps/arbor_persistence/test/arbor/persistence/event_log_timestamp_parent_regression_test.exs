defmodule Arbor.Persistence.EventLogTimestampParentRegressionTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog
  alias Arbor.Persistence.Repo

  @moduletag :database
  @moduletag :integration

  setup do
    case Repo.query!("SELECT to_regclass('public.event_log_operations')").rows do
      [[nil]] -> :ok
      [[_table]] -> Repo.query!("DELETE FROM public.event_log_operations")
    end

    Repo.query!("DELETE FROM public.events")
    :ok
  end

  test "security regression: zero-precision timestamp retry survives database round-trip" do
    timestamp = DateTime.from_naive!(~N[2026-07-11 12:34:56], "Etc/UTC")

    event =
      Event.new("parent-timestamp-precision", "arbor.review.ordinary", %{value: 1},
        id: "evt_parent_timestamp_precision",
        timestamp: timestamp
      )

    assert {:ok, [first]} = EventLog.append("parent-timestamp-precision", event, repo: Repo)

    assert {:ok, [retried]} =
             EventLog.append("parent-timestamp-precision", event, repo: Repo)

    assert retried.id == first.id
    assert retried.global_position == first.global_position
    assert {:ok, 1} = EventLog.stream_version("parent-timestamp-precision", repo: Repo)
  end
end
