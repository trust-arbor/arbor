defmodule Arbor.Contracts.Session.AssistantMessageTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.LLM.TokenUsage
  alias Arbor.Contracts.Pipeline.Response
  alias Arbor.Contracts.Session.AssistantMessage

  doctest AssistantMessage

  @started ~U[2026-06-15 09:00:00.000Z]
  @completed ~U[2026-06-15 09:00:02.250Z]

  describe "from_result_ctx/3" do
    test "reads the magic-string keys into typed fields" do
      ctx = %{
        "session.response" => "the answer",
        "session.tool_calls" => [%{"name" => "file.read"}],
        "session.tool_history" => [%{"round" => 1}],
        "session.usage" => %{"input_tokens" => 10, "output_tokens" => 5, "duration_ms" => 1200},
        "llm.model" => "openai/gpt-oss-120b:free",
        "llm.provider" => :openrouter,
        "llm.stop_reason" => "stop"
      }

      am = AssistantMessage.from_result_ctx(ctx, @started, @completed)

      assert am.content == "the answer"
      assert am.tool_calls == [%{"name" => "file.read"}]
      assert am.tool_history == [%{"round" => 1}]
      assert am.model == "openai/gpt-oss-120b:free"
      assert am.provider == :openrouter
      assert am.finish_reason == "stop"
      assert am.status == :complete
      assert am.started_at == @started
      assert am.completed_at == @completed
      assert am.first_token_at == nil
      assert %TokenUsage{input_tokens: 10, output_tokens: 5} = am.usage
    end

    test "missing keys default loudly (nil / empty), never crash" do
      am = AssistantMessage.from_result_ctx(%{}, @started)

      assert am.content == ""
      assert am.tool_calls == []
      assert am.tool_history == []
      assert am.model == nil
      assert am.finish_reason == nil
      assert am.completed_at == nil
      # usage normalizes a missing map to an empty TokenUsage, not nil
      assert %TokenUsage{} = am.usage
    end
  end

  describe "to_persistence/1" do
    test "emits the typed fields a SessionEntry assistant row needs" do
      ctx = %{
        "session.response" => "hello",
        "session.tool_calls" => [%{"name" => "x"}],
        "session.usage" => %{"input_tokens" => 3},
        "llm.model" => "m",
        "llm.stop_reason" => "stop"
      }

      p =
        ctx
        |> AssistantMessage.from_result_ctx(@started, @completed)
        |> AssistantMessage.to_persistence()

      assert p.content == "hello"
      assert p.tool_calls == [%{"name" => "x"}]
      assert p.model == "m"
      assert p.stop_reason == "stop"
      assert p.timestamp == @completed
      assert is_map(p.token_usage)
    end

    test "timestamp falls back to started_at when not completed" do
      p = %{} |> AssistantMessage.from_result_ctx(@started) |> AssistantMessage.to_persistence()
      assert p.timestamp == @started
    end
  end

  describe "to_message_map/1" do
    test "produces the loose role/content/timestamp map for the messages list" do
      am =
        AssistantMessage.from_result_ctx(%{"session.response" => "  hi  "}, @started, @completed)

      msg = AssistantMessage.to_message_map(am)

      assert msg["role"] == "assistant"
      assert msg["content"] == "hi"
      assert msg["timestamp"] == DateTime.to_iso8601(@completed)
    end

    test "returns nil for empty/blank content (mirrors old build_assistant_message)" do
      am = AssistantMessage.from_result_ctx(%{"session.response" => "   "}, @started, @completed)
      assert AssistantMessage.to_message_map(am) == nil
    end
  end

  describe "from_pipeline_response/3" do
    test "builds from a normalized Response" do
      resp = %Response{
        content: "ok",
        finish_reason: :stop,
        tool_history: [%{"r" => 1}],
        usage: %{"input_tokens" => 2}
      }

      am = AssistantMessage.from_pipeline_response(resp, @started, @completed)

      assert am.content == "ok"
      assert am.finish_reason == :stop
      assert am.tool_history == [%{"r" => 1}]
      assert %TokenUsage{input_tokens: 2} = am.usage
    end
  end

  describe "failed/3" do
    test "carries the failure reason and :failed status" do
      am = AssistantMessage.failed({:llm_error, :timeout}, @started, @completed)
      assert am.status == :failed
      assert am.interrupted_reason == {:llm_error, :timeout}
      assert am.content == ""
    end
  end

  describe "interrupted/4 + cancelled/3 (streaming partial preservation)" do
    test "interrupted/4 preserves the partial content + system-failure reason" do
      am =
        AssistantMessage.interrupted("half a thoug", :task_crashed, @started,
          completed_at: @completed,
          first_token_at: ~U[2026-06-15 09:00:00.300Z]
        )

      assert am.status == :interrupted
      assert am.content == "half a thoug"
      assert am.interrupted_reason == :task_crashed
      assert am.started_at == @started
      assert am.completed_at == @completed
      assert am.first_token_at == ~U[2026-06-15 09:00:00.300Z]
      # providers don't return usage until the stream completes
      assert am.usage == nil
    end

    test "cancelled/3 defaults the reason to :user_cancelled and uses :cancelled status" do
      am = AssistantMessage.cancelled("partial answer", @started, completed_at: @completed)
      assert am.status == :cancelled
      assert am.interrupted_reason == :user_cancelled
      assert am.content == "partial answer"
    end

    test "cancelled/3 accepts an explicit reason override" do
      am = AssistantMessage.cancelled("x", @started, reason: :navigated_away)
      assert am.status == :cancelled
      assert am.interrupted_reason == :navigated_away
    end

    test "an interrupted partial still converts to persistence with its partial content" do
      p =
        "partial"
        |> AssistantMessage.interrupted(:timeout, @started, completed_at: @completed)
        |> AssistantMessage.to_persistence()

      assert p.content == "partial"
      assert p.timestamp == @completed
      assert p.token_usage == nil
    end
  end
end
