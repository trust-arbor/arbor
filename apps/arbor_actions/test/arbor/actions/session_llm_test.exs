defmodule Arbor.Actions.SessionLlmTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.SessionLlm

  @moduletag :fast

  # ============================================================================
  # BuildPrompt
  # ============================================================================

  describe "BuildPrompt — schema" do
    test "action metadata" do
      assert SessionLlm.BuildPrompt.name() == "session_llm_build_prompt"
    end

    test "requires mode" do
      assert {:error, _} = SessionLlm.BuildPrompt.validate_params(%{})
    end

    test "accepts valid params" do
      assert {:ok, _} = SessionLlm.BuildPrompt.validate_params(%{mode: "heartbeat"})
    end
  end

  describe "BuildPrompt — heartbeat mode" do
    test "builds prompt with mode instructions" do
      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{
                   mode: "heartbeat",
                   cognitive_mode: "goal_pursuit",
                   turn_count: 3,
                   goals: [%{"id" => "g1", "description" => "Build feature", "progress" => 0.2}]
                 },
                 %{}
               )

      assert is_binary(result.heartbeat_prompt)
      assert result.heartbeat_prompt =~ "GOAL PURSUIT"
      assert result.heartbeat_prompt =~ "turn 3"
      assert result.heartbeat_prompt =~ "Build feature"
    end

    test "includes all context sections when present" do
      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{
                   mode: "heartbeat",
                   goals: [%{"id" => "g1", "description" => "test", "progress" => 0}],
                   working_memory: %{"key" => "value"},
                   knowledge_graph: [%{"type" => "trait", "content" => "curious", "confidence" => 0.8}],
                   pending_proposals: [%{"id" => "p1", "type" => "insight", "content" => "test"}],
                   active_intents: [
                     %{
                       "id" => "i1",
                       "action" => "file.read",
                       "description" => "read config",
                       "goal_id" => "g1",
                       "status" => "pending"
                     }
                   ],
                   recent_thinking: [%{"text" => "I should try...", "significant" => true}],
                   recent_percepts: [%{"data" => %{"action_type" => "file.read"}, "outcome" => "success"}]
                 },
                 %{}
               )

      prompt = result.heartbeat_prompt
      assert prompt =~ "## Goals"
      assert prompt =~ "## Working Memory"
      assert prompt =~ "## Knowledge Graph"
      assert prompt =~ "## Pending Proposals"
      assert prompt =~ "## Active Intents"
      assert prompt =~ "## Recent Thinking"
      assert prompt =~ "## Recent Action Results"
    end

    test "empty sections are omitted" do
      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(%{mode: "heartbeat"}, %{})

      prompt = result.heartbeat_prompt
      assert prompt =~ "No active goals"
      refute prompt =~ "## Working Memory"
      refute prompt =~ "## Knowledge Graph"
    end

    test "mode instructions vary by cognitive mode" do
      for {mode, keyword} <- [
            {"consolidation", "CONSOLIDATION"},
            {"plan_execution", "PLAN EXECUTION"},
            {"reflection", "REFLECTION"}
          ] do
        assert {:ok, result} =
                 SessionLlm.BuildPrompt.run(
                   %{mode: "heartbeat", cognitive_mode: mode},
                   %{}
                 )

        assert result.heartbeat_prompt =~ keyword
      end
    end

    test "includes JSON response format instructions" do
      assert {:ok, result} = SessionLlm.BuildPrompt.run(%{mode: "heartbeat"}, %{})
      assert result.heartbeat_prompt =~ "Respond with valid JSON"
      assert result.heartbeat_prompt =~ "memory_notes"
      assert result.heartbeat_prompt =~ "proposal_decisions"
    end
  end

  describe "BuildPrompt — followup mode" do
    test "formats percepts as user message" do
      percepts = [
        %{
          "data" => %{"action_type" => "file.read", "result" => "file contents here"},
          "outcome" => "success"
        }
      ]

      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{
                   mode: "followup",
                   percepts: percepts,
                   messages: [%{"role" => "user", "content" => "hello"}]
                 },
                 %{}
               )

      assert is_binary(result.followup_prompt)
      assert result.followup_prompt =~ "Action Results"
      assert result.followup_prompt =~ "file.read"
      assert is_list(result.messages)
      assert length(result.messages) == 2
      assert List.last(result.messages)["role"] == "user"
    end

    test "handles empty percepts" do
      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{mode: "followup", percepts: [], messages: []},
                 %{}
               )

      assert result.followup_prompt =~ "No action results"
    end

    test "formats blocked and failed percepts" do
      percepts = [
        %{"data" => %{"action_type" => "shell.execute"}, "outcome" => "blocked", "error" => "unauthorized"},
        %{"data" => %{"action_type" => "file.write"}, "outcome" => "failure", "error" => "permission denied"}
      ]

      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{mode: "followup", percepts: percepts, messages: []},
                 %{}
               )

      assert result.followup_prompt =~ "BLOCKED"
      assert result.followup_prompt =~ "FAILED"
    end
  end

  describe "BuildPrompt — turn mode" do
    test "injects timestamps into user messages" do
      messages = [
        %{
          "role" => "user",
          "content" => "hello",
          "timestamp" => "2026-02-22T14:30:05Z"
        }
      ]

      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{mode: "turn", messages: messages},
                 %{}
               )

      assert is_list(result.messages)
      assert hd(result.messages)["content"] =~ "[14:30:05]"
    end

    test "skips timestamp injection for assistant messages" do
      messages = [
        %{
          "role" => "assistant",
          "content" => "response",
          "timestamp" => "2026-02-22T14:30:05Z"
        }
      ]

      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{mode: "turn", messages: messages},
                 %{}
               )

      # Assistant messages should NOT have timestamp injected (prevents chaining)
      refute hd(result.messages)["content"] =~ "[14:30:05]"
    end

    test "removes timestamp field from messages without content" do
      messages = [
        %{"role" => "user", "timestamp" => "2026-02-22T14:30:05Z"}
      ]

      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{mode: "turn", messages: messages},
                 %{}
               )

      refute Map.has_key?(hd(result.messages), "timestamp")
    end
  end

  describe "BuildPrompt — error handling" do
    test "returns error for unknown mode" do
      assert {:error, _} = SessionLlm.BuildPrompt.run(%{mode: "unknown"}, %{})
    end
  end
end
