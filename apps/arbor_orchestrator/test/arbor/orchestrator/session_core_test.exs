defmodule Arbor.Orchestrator.SessionCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.SessionCore

  # ===========================================================================
  # Construct
  # ===========================================================================

  describe "normalize_message/1" do
    test "passes through strings" do
      assert SessionCore.normalize_message("hello") == "hello"
    end

    test "extracts content from string-keyed map" do
      assert SessionCore.normalize_message(%{"content" => "hello"}) == "hello"
    end

    test "extracts content from atom-keyed map" do
      assert SessionCore.normalize_message(%{content: "hello"}) == "hello"
    end

    test "inspects other types" do
      assert SessionCore.normalize_message(42) == "42"
    end
  end

  describe "build_user_message/2" do
    test "builds a user message map" do
      ts = ~U[2026-04-06 12:00:00Z]
      msg = SessionCore.build_user_message("hello", ts)
      assert msg["role"] == "user"
      assert msg["content"] == "hello"
      assert msg["timestamp"] == "2026-04-06T12:00:00Z"
    end
  end

  describe "build_assistant_message/2" do
    test "builds assistant message" do
      msg = SessionCore.build_assistant_message("response", ~U[2026-04-06 12:00:00Z])
      assert msg["role"] == "assistant"
      assert msg["content"] == "response"
    end

    test "returns nil for empty response" do
      assert SessionCore.build_assistant_message("", ~U[2026-04-06 12:00:00Z]) == nil
      assert SessionCore.build_assistant_message("  ", ~U[2026-04-06 12:00:00Z]) == nil
      assert SessionCore.build_assistant_message(nil, ~U[2026-04-06 12:00:00Z]) == nil
    end
  end

  # ===========================================================================
  # Reduce
  # ===========================================================================

  describe "append_user_message/3" do
    test "appends user message to list" do
      messages = SessionCore.append_user_message([], "hello")
      assert length(messages) == 1
      msg = List.last(messages)
      assert msg["role"] == "user"
      assert msg["content"] == "hello"
    end

    test "preserves existing messages" do
      existing = [%{"role" => "system", "content" => "You are helpful."}]
      messages = SessionCore.append_user_message(existing, "hello")
      assert length(messages) == 2
      assert hd(messages)["role"] == "system"
    end

    test "is pipeable" do
      result =
        []
        |> SessionCore.append_user_message("hello")
        |> SessionCore.append_user_message("again")

      assert length(result) == 2
    end
  end

  describe "apply_llm_response/3" do
    test "appends assistant message" do
      messages = [%{"role" => "user", "content" => "hi"}]
      updated = SessionCore.apply_llm_response(messages, "hello back")
      assert length(updated) == 2
      assert List.last(updated)["role"] == "assistant"
    end

    test "skips empty response" do
      messages = [%{"role" => "user", "content" => "hi"}]
      updated = SessionCore.apply_llm_response(messages, "")
      assert length(updated) == 1
    end

    test "skips nil response" do
      messages = [%{"role" => "user", "content" => "hi"}]
      assert SessionCore.apply_llm_response(messages, nil) == messages
    end

    test "is pipeable end-to-end" do
      result =
        []
        |> SessionCore.append_user_message("hello")
        |> SessionCore.apply_llm_response("hi there")

      assert length(result) == 2
      assert hd(result)["role"] == "user"
      assert List.last(result)["role"] == "assistant"
    end
  end

  describe "compaction_decision/3" do
    test "no compact when under window" do
      assert :no_compact = SessionCore.compaction_decision([], 500, 1000)
    end

    test "compact when at window" do
      messages = [
        %{"role" => "user", "content" => String.duplicate("x", 400)},
        %{"role" => "assistant", "content" => String.duplicate("y", 400)},
        %{"role" => "user", "content" => String.duplicate("z", 400)}
      ]

      assert {:compact, _keep, _summarize} =
               SessionCore.compaction_decision(messages, 1000, 1000)
    end
  end

  describe "split_for_compression/2" do
    test "keeps recent messages within budget" do
      messages = [
        %{"content" => String.duplicate("a", 100)},
        %{"content" => String.duplicate("b", 100)},
        %{"content" => String.duplicate("c", 100)}
      ]

      {to_summarize, to_keep} = SessionCore.split_for_compression(messages, 50)
      assert length(to_keep) <= length(messages)
      assert length(to_summarize) + length(to_keep) == length(messages)
    end
  end

  describe "increment_turn/1" do
    test "increments" do
      assert SessionCore.increment_turn(0) == 1
      assert SessionCore.increment_turn(5) == 6
    end
  end

  # ===========================================================================
  # Convert
  # ===========================================================================

  describe "for_llm/1" do
    test "filters and formats messages" do
      messages = [
        %{"role" => "system", "content" => "Be helpful."},
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi there"},
        %{"role" => "user", "content" => ""},
        %{role: :user, content: "atom keys"}
      ]

      llm = SessionCore.for_llm(messages)
      # Empty content filtered out
      assert length(llm) == 4
      assert Enum.all?(llm, &is_binary(&1["role"]))
      assert Enum.all?(llm, &is_binary(&1["content"]))
    end
  end

  describe "for_cloud/2" do
    test "tokenizes PII in messages" do
      messages = [%{"role" => "user", "content" => "My email is john@example.com"}]
      token_map = %{"<EMAIL_1>" => %{original: "john@example.com"}}

      cloud = SessionCore.for_cloud(messages, token_map)
      assert hd(cloud)["content"] == "My email is <EMAIL_1>"
    end

    test "passes through with empty token map" do
      messages = [%{"role" => "user", "content" => "hello"}]
      cloud = SessionCore.for_cloud(messages, %{})
      assert hd(cloud)["content"] == "hello"
    end
  end

  describe "for_dashboard/1" do
    test "formats with atom roles and IDs" do
      messages = [
        %{"role" => "user", "content" => "hello", "timestamp" => "2026-04-06T12:00:00Z"},
        %{"role" => "assistant", "content" => "hi"}
      ]

      display = SessionCore.for_dashboard(messages)
      assert length(display) == 2
      assert hd(display).role == :user
      assert hd(display).id == "msg-0"
      assert List.last(display).role == :assistant
    end
  end

  describe "for_persistence/1" do
    test "wraps content in content blocks" do
      messages = [%{"role" => "user", "content" => "hello"}]
      entries = SessionCore.for_persistence(messages)

      assert length(entries) == 1
      entry = hd(entries)
      assert entry.entry_type == "user"
      assert entry.content == [%{"type" => "text", "text" => "hello"}]
    end
  end

  describe "for_prompt_context/1" do
    test "builds pipeline context dict" do
      state = %{agent_id: "agent_123", session_id: "sess_1", messages: [], turn_count: 5}
      ctx = SessionCore.for_prompt_context(state)

      assert ctx["session.agent_id"] == "agent_123"
      assert ctx["session.turn_count"] == 5
    end
  end

  describe "turn_summary/2" do
    test "summarizes turn metrics" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi"},
        %{"role" => "user", "content" => "bye"}
      ]

      usage = %{"input_tokens" => 100, "output_tokens" => 50}
      summary = SessionCore.turn_summary(messages, usage)

      assert summary.message_count == 3
      assert summary.user_messages == 2
      assert summary.assistant_messages == 1
      assert summary.input_tokens == 100
      assert summary.output_tokens == 50
    end
  end

  describe "estimate_message_tokens/1" do
    test "estimates based on content length" do
      msg = %{"content" => String.duplicate("x", 100)}
      tokens = SessionCore.estimate_message_tokens(msg)
      assert tokens > 0
      # 100/4 + 1
      assert tokens == 26
    end

    test "handles missing content" do
      assert SessionCore.estimate_message_tokens(%{}) == 1
    end
  end

  # ===========================================================================
  # Pipeline composability
  # ===========================================================================

  describe "pipeline" do
    test "compose reduce → convert" do
      messages =
        []
        |> SessionCore.append_user_message("hello")
        |> SessionCore.apply_llm_response("hi back")

      llm = SessionCore.for_llm(messages)
      assert length(llm) == 2
      assert hd(llm)["role"] == "user"
      assert List.last(llm)["role"] == "assistant"

      dashboard = SessionCore.for_dashboard(messages)
      assert hd(dashboard).role == :user

      persistence = SessionCore.for_persistence(messages)
      assert hd(persistence).content == [%{"type" => "text", "text" => "hello"}]
    end
  end

  # ===========================================================================
  # Slash command context — regression for 2026-04-09 Session Access crash
  # ===========================================================================
  #
  # Background: the previous version of `build_command_context/1` lived as a
  # `defp` in `Session` and used `state[:field]` bracket access on the Session
  # struct. Structs do NOT implement Access by default, so the very first slash
  # command typed in the dashboard crashed with `UndefinedFunctionError`. The
  # bug went unnoticed because no test exercised the function — `/help` was
  # the only command tested, and Help doesn't go through this code path.
  #
  # These tests construct a real `%Arbor.Orchestrator.Session{}` and call
  # `build_command_context/2` against it, asserting that:
  #   1. It does NOT crash (the original failure mode)
  #   2. It returns a plain map with the expected keys
  #   3. It pulls model/provider from `state.config` (which IS a regular map)
  #   4. It safely handles missing/nil discovered_tools
  #
  # If any future refactor reintroduces bracket access on the Session struct
  # or removes a key the slash commands depend on, these tests should fail.
  describe "build_command_context/2 — regression for Session Access crash" do
    alias Arbor.Orchestrator.Session

    test "does not crash on a real Session struct (the original bug)" do
      session = %Session{
        session_id: "test-session-1",
        agent_id: "agent_test",
        trust_tier: :veteran,
        turn_count: 5,
        config: %{model: "claude-opus-4-6", provider: :anthropic}
      }

      # The bug: this used to crash with UndefinedFunctionError because the
      # old defp was doing `state[:display_name]` on the struct. If this test
      # crashes (rather than failing an assertion), the regression is back.
      assert context = SessionCore.build_command_context(session, self())
      assert is_map(context)
    end

    test "pulls model and provider from state.config" do
      session = %Session{
        session_id: "test-session-2",
        agent_id: "agent_test",
        trust_tier: :veteran,
        turn_count: 0,
        config: %{model: "gpt-5", provider: :openai}
      }

      context = SessionCore.build_command_context(session, self())

      assert context.model == "gpt-5"
      assert context.provider == :openai
    end

    test "exposes core read-only fields used by /status, /session, /trust" do
      session = %Session{
        session_id: "test-session-3",
        agent_id: "agent_xyz",
        trust_tier: :partner,
        turn_count: 12,
        config: %{}
      }

      context = SessionCore.build_command_context(session, self())

      assert context.agent_id == "agent_xyz"
      assert context.session_id == "test-session-3"
      assert context.trust_tier == :partner
      assert context.turn_count == 12
      assert context.session_pid == self()
    end

    test "converts discovered_tools MapSet to a sorted list of strings" do
      session = %Session{
        session_id: "test-session-4",
        agent_id: "agent_test",
        trust_tier: :veteran,
        turn_count: 0,
        config: %{},
        discovered_tools: MapSet.new(["file_write", "shell_execute", "file_read"])
      }

      context = SessionCore.build_command_context(session, self())

      # Sorted alphabetically, plain strings (so /tools renders them with the
      # bare-name clause rather than "name — desc" with empty desc).
      assert context.tools == ["file_read", "file_write", "shell_execute"]
    end

    test "handles nil discovered_tools gracefully" do
      session = %Session{
        session_id: "test-session-5",
        agent_id: "agent_test",
        trust_tier: :veteran,
        turn_count: 0,
        config: %{},
        discovered_tools: nil
      }

      context = SessionCore.build_command_context(session, self())

      assert context.tools == []
    end

    test "handles nil config (defensive)" do
      # Should never happen in practice (struct default is %{}), but defensive
      # against a future refactor that initializes config to nil.
      session = %Session{
        session_id: "test-session-6",
        agent_id: "agent_test",
        trust_tier: :veteran,
        turn_count: 0,
        config: nil
      }

      context = SessionCore.build_command_context(session, self())

      assert context.model == nil
      assert context.provider == nil
    end

    test "session_pid defaults to nil if not provided" do
      session = %Session{
        session_id: "test-session-7",
        agent_id: "agent_test",
        trust_tier: :veteran,
        turn_count: 0,
        config: %{}
      }

      context = SessionCore.build_command_context(session)

      assert context.session_pid == nil
    end
  end
end
