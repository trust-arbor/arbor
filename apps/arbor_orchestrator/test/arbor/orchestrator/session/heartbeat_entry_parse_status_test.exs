defmodule Arbor.Orchestrator.Session.HeartbeatEntryParseStatusTest do
  @moduledoc """
  Regression (Imp review 2026-09-27, D1): the persisted heartbeat entry records
  whether the beat's reply parsed, so a journal of all-empty beats can be told
  apart into idle beats and unreadable replies.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Session.Persistence

  @moduletag :fast

  defp persist(result_ctx) do
    test_pid = self()

    state = %{
      adapters: %{
        persist_entry: fn entry ->
          send(test_pid, {:heartbeat_entry, entry})
          :ok
        end
      }
    }

    Persistence.persist_heartbeat_entry(state, result_ctx)
    assert_receive {:heartbeat_entry, entry}, 1_000
    entry
  end

  test "a parse failure is recorded in the heartbeat entry metadata" do
    entry =
      persist(%{
        "session.cognitive_mode" => "reflection",
        "session.actions" => [],
        "session.parse_status" => "parse_failed",
        "session.parse_error" => "not_json"
      })

    assert entry.entry_type == "heartbeat"
    assert entry.metadata["actions_count"] == 0
    assert entry.metadata["parse_status"] == "parse_failed"
    assert entry.metadata["parse_error"] == "not_json"
  end

  test "an idle, parsed beat records parsed with no error" do
    entry =
      persist(%{
        "session.actions" => [],
        "session.parse_status" => "parsed",
        "session.parse_error" => nil
      })

    assert entry.metadata["parse_status"] == "parsed"
    assert entry.metadata["parse_error"] == nil
  end

  test "a beat that never reached the parser records no parse status" do
    entry = persist(%{"session.cognitive_mode" => "idle"})

    assert entry.metadata["parse_status"] == nil
    assert entry.metadata["parse_error"] == nil
  end
end
