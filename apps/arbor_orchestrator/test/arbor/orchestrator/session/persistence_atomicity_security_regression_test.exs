defmodule Arbor.Orchestrator.Session.PersistenceAtomicitySecurityRegressionTest do
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Session.AssistantMessage
  alias Arbor.Orchestrator.Session.Persistence

  test "security regression: a simulated second-row failure cannot persist a half-turn" do
    parent = self()

    {:ok, probe} =
      Agent.start_link(fn ->
        %{batch_calls: 0, single_calls: 0, persisted: [], ensure_args: nil}
      end)

    ensure_session = fn session_id, agent_id, opts ->
      Agent.update(probe, &%{&1 | ensure_args: {session_id, agent_id, opts}})
      {:ok, %{id: "session-uuid", session_id: session_id, agent_id: agent_id}}
    end

    append_session_entries = fn session_uuid, entries ->
      Agent.update(probe, fn state ->
        %{state | batch_calls: state.batch_calls + 1}
      end)

      send(parent, {:persistence_effect, :batch, session_uuid, entries})

      # Simulates a transaction rejecting its second row. An atomic adapter
      # leaves no durable effect.
      {:error, :simulated_second_row_failure}
    end

    persist_entry = fn entry ->
      call_number =
        Agent.get_and_update(probe, fn state ->
          next = state.single_calls + 1

          persisted =
            if next == 1 do
              state.persisted ++ [entry]
            else
              state.persisted
            end

          {next, %{state | single_calls: next, persisted: persisted}}
        end)

      send(parent, {:persistence_effect, :single, call_number})

      if call_number == 1,
        do: :ok,
        else: {:error, :simulated_second_row_failure}
    end

    state = %{
      session_id: "tenant-session-c6a",
      agent_id: "agent_owner_c6a",
      current_engagement_id: "eng-c6a",
      turn_count: 0,
      messages: [],
      adapters: %{
        ensure_session: ensure_session,
        append_session_entries: append_session_entries,
        persist_entry: persist_entry
      }
    }

    now = ~U[2026-08-05 12:00:00.000000Z]

    assert {:ok, _task} =
             Persistence.persist_turn_entries(
               state,
               %{"role" => "user", "content" => "first row"},
               %AssistantMessage{
                 content: "second row",
                 started_at: now,
                 completed_at: now
               },
               %{},
               user_sent_at: now,
               assistant_completed_at: now
             )

    await_persistence_effect()
    snapshot = Agent.get(probe, & &1)

    assert snapshot.persisted == []
    assert snapshot.batch_calls == 1
    assert snapshot.single_calls == 0
    assert snapshot.ensure_args == {"tenant-session-c6a", "agent_owner_c6a", []}
  end

  defp await_persistence_effect do
    receive do
      {:persistence_effect, :batch, "session-uuid", [user, assistant]} ->
        assert user.entry_type == "user"
        assert assistant.entry_type == "assistant"

      {:persistence_effect, :single, 1} ->
        await_persistence_effect()

      {:persistence_effect, :single, 2} ->
        :ok
    after
      1_000 -> flunk("timed out waiting for the persistence effect")
    end
  end
end
