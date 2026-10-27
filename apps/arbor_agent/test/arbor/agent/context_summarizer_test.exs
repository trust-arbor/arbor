defmodule Arbor.Agent.ContextSummarizerTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Agent.ContextSummarizer
  alias Arbor.LLM.Client

  defmodule OfflineAdapter do
    @moduledoc false
    @behaviour Arbor.LLM.ProviderAdapter

    def provider, do: "context_summarizer_test_offline"
    def complete(_request, _opts), do: {:error, :context_summarizer_test_llm_unavailable}
  end

  setup do
    # Store original values
    original_enabled = Application.get_env(:arbor_agent, :context_summarization_enabled)
    original_max = Application.get_env(:arbor_agent, :context_max_tokens)
    original_ratio = Application.get_env(:arbor_agent, :context_recent_ratio)
    original_cache = Application.get_env(:arbor_agent, :summary_cache_enabled)
    original_client = :persistent_term.get({Client, :default_client}, :missing)
    original_bridge = :persistent_term.get({Arbor.AI.UnifiedBridge, :client}, :missing)

    # These tests exercise summary fallback, so shared provider credentials
    # must not turn their synthetic prose into a live model request. Replace
    # only the transport; keep the production scanner and policy enabled.
    providers = Arbor.LLM.known_providers() ++ ~w(acp openai_oauth xai_oauth)

    client =
      Client.new(
        adapters: Map.new(providers, &{&1, OfflineAdapter}),
        default_provider: "openai"
      )

    Client.set_default_client(client)
    :persistent_term.put({Arbor.AI.UnifiedBridge, :client}, client)

    on_exit(fn ->
      for {key, original} <- [
            {{Client, :default_client}, original_client},
            {{Arbor.AI.UnifiedBridge, :client}, original_bridge}
          ] do
        if original == :missing,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, original)
      end

      if original_enabled do
        Application.put_env(:arbor_agent, :context_summarization_enabled, original_enabled)
      else
        Application.delete_env(:arbor_agent, :context_summarization_enabled)
      end

      if original_max do
        Application.put_env(:arbor_agent, :context_max_tokens, original_max)
      else
        Application.delete_env(:arbor_agent, :context_max_tokens)
      end

      if original_ratio do
        Application.put_env(:arbor_agent, :context_recent_ratio, original_ratio)
      else
        Application.delete_env(:arbor_agent, :context_recent_ratio)
      end

      if original_cache do
        Application.put_env(:arbor_agent, :summary_cache_enabled, original_cache)
      else
        Application.delete_env(:arbor_agent, :summary_cache_enabled)
      end
    end)

    # Disable cache for most tests to isolate behavior
    Application.put_env(:arbor_agent, :summary_cache_enabled, false)

    :ok
  end

  describe "new_context_window/0" do
    test "creates empty context window with correct structure" do
      window = ContextSummarizer.new_context_window()

      assert window.recent == []
      assert window.tier_1_summary == nil
      assert window.tier_2_summary == nil
      assert window.total_tokens == 0
      assert window.last_summarized_at == nil
    end
  end

  describe "needs_summarization?/1" do
    test "returns false when total_tokens is under threshold" do
      window = %{total_tokens: 50_000}
      Application.put_env(:arbor_agent, :context_max_tokens, 100_000)

      refute ContextSummarizer.needs_summarization?(window)
    end

    test "returns true when total_tokens exceeds threshold" do
      window = %{total_tokens: 150_000}
      Application.put_env(:arbor_agent, :context_max_tokens, 100_000)
      Application.put_env(:arbor_agent, :context_summarization_enabled, true)

      assert ContextSummarizer.needs_summarization?(window)
    end

    test "returns false when summarization is disabled" do
      window = %{total_tokens: 150_000}
      Application.put_env(:arbor_agent, :context_summarization_enabled, false)

      refute ContextSummarizer.needs_summarization?(window)
    end

    test "returns false when total_tokens key is missing" do
      window = %{}
      Application.put_env(:arbor_agent, :context_summarization_enabled, true)
      Application.put_env(:arbor_agent, :context_max_tokens, 100_000)

      refute ContextSummarizer.needs_summarization?(window)
    end
  end

  describe "maybe_summarize/1" do
    test "returns context unchanged when under threshold" do
      window = ContextSummarizer.new_context_window()
      window = %{window | total_tokens: 50_000}
      Application.put_env(:arbor_agent, :context_max_tokens, 100_000)

      assert {:ok, ^window} = ContextSummarizer.maybe_summarize(window)
    end

    test "returns context unchanged when summarization disabled" do
      window = ContextSummarizer.new_context_window()
      window = %{window | total_tokens: 150_000}
      Application.put_env(:arbor_agent, :context_summarization_enabled, false)

      assert {:ok, ^window} = ContextSummarizer.maybe_summarize(window)
    end
  end

  describe "summarize/1" do
    test "preserves recent messages based on ratio" do
      messages =
        for i <- 1..20 do
          %{role: "user", content: "Message #{i}"}
        end

      window = %{
        recent: messages,
        tier_1_summary: nil,
        tier_2_summary: nil,
        total_tokens: 150_000,
        last_summarized_at: nil
      }

      Application.put_env(:arbor_agent, :context_recent_ratio, 0.7)

      # The explicit offline adapter makes the AI call fail, but should
      # gracefully degrade and keep existing nil summary
      {:ok, result} = ContextSummarizer.summarize(window)

      # Should keep ~14 recent messages (70% of 20)
      assert length(result.recent) == 14
      assert result.last_summarized_at != nil
    end

    test "handles empty message list" do
      window = ContextSummarizer.new_context_window()

      {:ok, result} = ContextSummarizer.summarize(window)

      assert result.recent == []
      assert result.last_summarized_at != nil
    end

    test "preserves at least min_recent_count messages" do
      messages =
        for i <- 1..5 do
          %{role: "user", content: "Message #{i}"}
        end

      window = %{
        recent: messages,
        tier_1_summary: nil,
        tier_2_summary: nil,
        total_tokens: 150_000,
        last_summarized_at: nil
      }

      Application.put_env(:arbor_agent, :context_recent_ratio, 0.1)

      {:ok, result} = ContextSummarizer.summarize(window)

      # With only 5 messages and min_recent_count=10, keeps all 5
      assert length(result.recent) == 5
    end
  end

  describe "build_prompt_context/1" do
    test "returns empty string when no summaries exist" do
      window = ContextSummarizer.new_context_window()
      assert ContextSummarizer.build_prompt_context(window) == ""
    end

    test "includes tier_1 summary when present" do
      window = %{
        ContextSummarizer.new_context_window()
        | tier_1_summary: "Recent summary of discussion"
      }

      result = ContextSummarizer.build_prompt_context(window)
      assert result =~ "## Recent Context (summarized)"
      assert result =~ "Recent summary of discussion"
    end

    test "includes tier_2 summary when present" do
      window = %{
        ContextSummarizer.new_context_window()
        | tier_2_summary: "Earlier discussion about architecture"
      }

      result = ContextSummarizer.build_prompt_context(window)
      assert result =~ "## Earlier Context (summarized)"
      assert result =~ "Earlier discussion about architecture"
    end

    test "orders tiers chronologically (tier_2 before tier_1)" do
      window = %{
        ContextSummarizer.new_context_window()
        | tier_1_summary: "Recent summary",
          tier_2_summary: "Earlier summary"
      }

      result = ContextSummarizer.build_prompt_context(window)

      tier_2_pos = :binary.match(result, "Earlier Context")
      tier_1_pos = :binary.match(result, "Recent Context")

      assert elem(tier_2_pos, 0) < elem(tier_1_pos, 0)
    end

    test "handles only tier_1 without tier_2" do
      window = %{
        ContextSummarizer.new_context_window()
        | tier_1_summary: "Just tier 1"
      }

      result = ContextSummarizer.build_prompt_context(window)
      assert result =~ "Just tier 1"
      refute result =~ "Earlier Context"
    end
  end
end
