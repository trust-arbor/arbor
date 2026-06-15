defmodule Arbor.Orchestrator.TurnCommitCoreTest do
  @moduledoc """
  PROTOTYPE / SPIKE (2026-06-15) — the "I-direction" counterpart to
  `turn_lifecycle_spike_test.exs`.

  Where the graphed spike lifts `apply_turn_result` into a DOT node, this proves
  the *functional-core / imperative-shell* alternative: the whole turn-commit
  DECISION is a single pure function (`SessionCore.commit_turn/1`), and the
  GenServer shell (`Session.Builders.apply_turn_result/4`) just executes the side
  effects (compactor, persist, telemetry) and adopts the result.

  No orchestrator opcodes added, no graph involved, no JSON serialization
  boundary (F7) — the typed `%AssistantMessage{}` lives in the commit as a real
  Elixir struct because nothing serializes it. Compare head-to-head with the
  spike; findings in
  `.arbor/roadmap/1-brainstorming/turn-lifecycle-prototype-friction-log.md`.
  """
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Session.AssistantMessage
  alias Arbor.Orchestrator.SessionCore
  alias Arbor.Orchestrator.SessionCore.TurnCommit

  @moduletag :fast

  @now ~U[2026-06-15 12:00:00Z]

  defp commit(overrides) do
    base = %{
      message: "hello, what can you do?",
      result_ctx: %{"session.response" => "I can orchestrate DOT pipelines."},
      current_messages: [%{"role" => "system", "content" => "you are arbor"}],
      current_working_memory: %{},
      current_turn_count: 2,
      now: @now,
      user_sent_at: @now,
      envelope_builder: &AssistantMessage.from_result_ctx/3
    }

    SessionCore.commit_turn(Map.merge(base, Map.new(overrides)))
  end

  describe "the turn-commit decision is pure and complete" do
    test "appends this turn's user+assistant messages and bumps the turn count" do
      %TurnCommit{} = c = commit([])

      # Fallback branch: result_ctx had no "session.messages", so the core
      # appends user + assistant to the current history.
      assert length(c.messages) == 3
      assert Enum.at(c.messages, 0) == %{"role" => "system", "content" => "you are arbor"}
      assert Enum.at(c.messages, 1)["role"] == "user"
      assert Enum.at(c.messages, 1)["content"] == "hello, what can you do?"
      assert List.last(c.messages)["role"] == "assistant"
      assert List.last(c.messages)["content"] == "I can orchestrate DOT pipelines."

      assert c.turn_count == 3
    end

    test "prefers the result context's session.messages when present" do
      pre_built = [%{"role" => "user", "content" => "x"}]

      c =
        commit(
          result_ctx: %{
            "session.response" => "ok",
            "session.messages" => pre_built
          }
        )

      # When the graph already produced the message list, the core appends only
      # the assistant display msg to it (no double user append).
      assert length(c.messages) == 2
      assert hd(c.messages) == %{"role" => "user", "content" => "x"}
      assert List.last(c.messages)["content"] == "ok"
    end

    test "carries a real typed %AssistantMessage{} envelope (no serialization boundary)" do
      c =
        commit(
          result_ctx: %{
            "session.response" => "hello there",
            "llm.model" => "spike-model",
            "llm.provider" => "spike-provider"
          }
        )

      assert %AssistantMessage{} = c.assistant_message
      assert c.assistant_message.content == "hello there"
      assert c.assistant_message.status == :complete
      assert c.assistant_message.model == "spike-model"
      assert c.assistant_message.provider == "spike-provider"
    end

    test "an empty response yields no assistant display msg but still commits the turn" do
      c = commit(result_ctx: %{"session.response" => ""})

      assert c.assistant_msg == nil
      # Only the user msg is appended to history (no empty assistant bubble).
      assert length(c.messages) == 2
      assert List.last(c.messages)["role"] == "user"
      assert c.turn_count == 3
    end

    test "exposes the persistence timestamps the shell needs" do
      c = commit([])
      assert c.user_sent_at == @now
      assert c.assistant_completed_at == @now
    end
  end

  describe "assistant_started_at/3 clamps to the user's send time" do
    test "subtracts the call duration from completion time" do
      ctx = %{"session.usage" => %{"duration_ms" => 5_000}}
      started = SessionCore.assistant_started_at(ctx, @now, ~U[2026-06-15 11:00:00Z])
      assert started == ~U[2026-06-15 11:59:55.000Z]
    end

    test "never precedes the user's send time" do
      ctx = %{"session.usage" => %{"duration_ms" => 10_000}}
      user_sent_at = ~U[2026-06-15 11:59:58Z]
      started = SessionCore.assistant_started_at(ctx, @now, user_sent_at)
      assert started == user_sent_at
    end
  end
end
