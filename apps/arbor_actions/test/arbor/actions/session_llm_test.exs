defmodule Arbor.Actions.SessionLlmTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.SessionLlm

  @moduletag :fast

  # ============================================================================
  # BuildPrompt
  # ============================================================================

  describe "pipeline_internal classification" do
    test "session_llm_build_prompt is a graph syscall, not an ordinary tool" do
      assert "pipeline_internal" in Enum.map(SessionLlm.BuildPrompt.tags(), &to_string/1)
      assert Arbor.Actions.pipeline_internal_action?(SessionLlm.BuildPrompt)
      refute SessionLlm.BuildPrompt in Arbor.Actions.exposed_actions()
    end
  end

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

  describe "BuildPrompt — turn mode (regression: recalled memory reaches the turn)" do
    # Regression for the 2026-07-04 memory-system audit + the migration that dropped memory from the
    # turn path: the DOT-pipeline rewrite kept recalled memory only in heartbeat mode, so agents
    # remembered during autonomous heartbeats but forgot during conversation. build_turn now injects
    # query-relevant recall into the user turn. This fails on the pre-fix build_turn.
    test "injects recalled memories as a system-context section" do
      {:ok, result} =
        SessionLlm.BuildPrompt.run(
          %{
            mode: "turn",
            messages: [%{"role" => "user", "content" => "what did we decide?"}],
            recalled_memories: [
              %{"content" => "Hysun prefers verify-before-fix"},
              %{"content" => "the eval judge is gpt-5.4-mini"}
            ]
          },
          %{}
        )

      # Same guard as before — recalled memory must REACH the turn. It now rides
      # the user message rather than a system one: recall changes every turn, so
      # in the system prompt it would invalidate the cacheable prefix each
      # request (see the stable/volatile split in APIAgent).
      assert Enum.any?(result.messages, fn m ->
               m["role"] == "user" and String.contains?(m["content"] || "", "Retrieved memories") and
                 String.contains?(m["content"] || "", "Hysun prefers verify-before-fix")
             end)

      assert result.user_prompt =~ "what did we decide?"
    end

    test "no recalled memories → no stray system-context message" do
      {:ok, result} =
        SessionLlm.BuildPrompt.run(
          %{
            mode: "turn",
            messages: [%{"role" => "user", "content" => "hi"}],
            recalled_memories: []
          },
          %{}
        )

      refute Enum.any?(result.messages, fn m ->
               m["role"] == "system" and
                 String.contains?(m["content"] || "", "Retrieved memories")
             end)
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
                   knowledge_graph: [
                     %{"type" => "trait", "content" => "curious", "confidence" => 0.8}
                   ],
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
                   recent_percepts: [
                     %{"data" => %{"action_type" => "file.read"}, "outcome" => "success"}
                   ]
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
      assert result.heartbeat_prompt =~ "\"proposals\""
      assert result.heartbeat_prompt =~ "must execute this beat"
      refute result.heartbeat_prompt =~ "do not invent"
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
        %{
          "data" => %{"action_type" => "shell.execute"},
          "outcome" => "blocked",
          "error" => "unauthorized"
        },
        %{
          "data" => %{"action_type" => "file.write"},
          "outcome" => "failure",
          "error" => "permission denied"
        }
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

  describe "BuildPrompt — followup conversation (regression: tool loop lost the beat)" do
    # Every heartbeat starts with session.messages = []. Before 2026-09-27 the
    # followup call received only the action results — not the heartbeat prompt
    # llm_call answered, and not its own prior reply.

    @success [
      %{"data" => %{"action_type" => "file.read", "result" => "ok"}, "outcome" => "success"}
    ]

    defp followup(params) do
      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(Map.merge(%{mode: "followup"}, params), %{})

      result
    end

    defp turns(messages), do: Enum.map(messages, &{&1["role"], &1["content"]})

    test "first followup opens with the heartbeat prompt and the reply it produced" do
      result =
        followup(%{
          percepts: @success,
          messages: [],
          heartbeat_prompt: "HEARTBEAT: pursue goal G-1",
          last_response: ~s({"actions": [{"type": "file.read"}]})
        })

      assert turns(result.messages) == [
               {"user", "HEARTBEAT: pursue goal G-1"},
               {"assistant", ~s({"actions": [{"type": "file.read"}]})},
               {"user", result.followup_prompt}
             ]
    end

    test "later followups accumulate each reply between result messages" do
      first =
        followup(%{
          percepts: @success,
          messages: [],
          heartbeat_prompt: "HEARTBEAT",
          last_response: "reply-1"
        })

      second =
        followup(%{
          percepts: @success,
          messages: first.messages,
          heartbeat_prompt: "HEARTBEAT",
          last_response: "reply-2"
        })

      # The heartbeat prompt is seeded once, not re-added per iteration.
      assert turns(second.messages) == [
               {"user", "HEARTBEAT"},
               {"assistant", "reply-1"},
               {"user", first.followup_prompt},
               {"assistant", "reply-2"},
               {"user", second.followup_prompt}
             ]
    end

    test "full context-key names are accepted, like the other followup params" do
      result =
        followup(%{
          "session.percepts" => @success,
          "session.messages" => [],
          "session.heartbeat_prompt" => "HEARTBEAT",
          "last_response" => "reply-1"
        })

      assert Enum.map(result.messages, & &1["role"]) == ["user", "assistant", "user"]
    end

    test "a reply with no user turn before it is dropped, never opening the history" do
      # Consolidation beats reach the loop without llm_call or a heartbeat prompt.
      result = followup(%{percepts: @success, messages: [], last_response: "stray"})

      assert turns(result.messages) == [{"user", result.followup_prompt}]
    end

    test "empty prompt and reply add no turns" do
      result =
        followup(%{percepts: @success, messages: [], heartbeat_prompt: "", last_response: ""})

      assert turns(result.messages) == [{"user", result.followup_prompt}]
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

  describe "recalled memories placement (prompt caching)" do
    test "recall introduces no system message, keeping the cacheable prefix stable" do
      assert {:ok, result} =
               SessionLlm.BuildPrompt.run(
                 %{
                   mode: "turn",
                   messages: [%{"role" => "user", "content" => "what is my lucky number?"}],
                   recalled_memories: [%{"content" => "User's lucky number is 7734"}]
                 },
                 %{}
               )

      # A second system message is also rejected outright by OpenAI-compatible
      # providers ("Context should have at most one system message, found 2").
      refute Enum.any?(result.messages, &(&1["role"] == "system")),
             "recall must not introduce a system message: #{inspect(result.messages)}"

      assert [%{"role" => "user", "content" => content}] = result.messages
      assert content =~ "7734"
      assert content =~ "what is my lucky number?"
    end
  end
end
