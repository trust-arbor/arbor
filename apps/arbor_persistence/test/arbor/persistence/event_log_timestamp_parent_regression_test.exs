defmodule Arbor.Persistence.EventLogTimestampParentRegressionTest do
  use Arbor.Persistence.DatabaseCase, async: false

  alias Arbor.Persistence.Event
  alias Arbor.Persistence.EventLog.Ecto, as: EventLog
  alias Arbor.Persistence.Repo
  alias Arbor.Persistence.Schemas.Event, as: EventRow
  alias Arbor.Persistence.Schemas.EventLogOperation

  @moduletag :database
  @moduletag :integration

  setup do
    # Schema deletes follow the repo adapter. `public.events` is Postgres-only;
    # SQLite stores the same rows in `events`.
    Repo.delete_all(EventLogOperation)
    Repo.delete_all(EventRow)
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
