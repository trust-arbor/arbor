defmodule Arbor.Common.ModelProfileTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.ModelProfile

  # ===========================================================================
  # Exact match lookups
  # ===========================================================================

  describe "exact match" do
    test "claude-sonnet-4-6" do
      profile = ModelProfile.get("claude-sonnet-4-6")
      assert profile.context_size == 200_000
      assert profile.max_output_tokens == 64_000
      assert profile.family == :claude
      assert profile.effective_window_pct == 0.75
    end

    test "claude-opus-4-6" do
      assert ModelProfile.context_size("claude-opus-4-6") == 200_000
      assert ModelProfile.max_output_tokens("claude-opus-4-6") == 32_000
    end

    test "gpt-4o" do
      profile = ModelProfile.get("gpt-4o")
      assert profile.context_size == 128_000
      assert profile.max_output_tokens == 16_384
      assert profile.family == :gpt
    end

    test "gemini-2.0-flash" do
      assert ModelProfile.context_size("gemini-2.0-flash") == 1_000_000
      assert ModelProfile.family("gemini-2.0-flash") == :gemini
    end

    test "openrouter free model" do
      profile = ModelProfile.get("arcee-ai/trinity-large-preview:free")
      assert profile.context_size == 131_072
      assert profile.family == :openrouter_free
    end

    test "deepseek-chat" do
      assert ModelProfile.context_size("deepseek-chat") == 128_000
      assert ModelProfile.family("deepseek-chat") == :deepseek
    end

    test "local models" do
      assert ModelProfile.context_size("llama3.2") == 128_000
      assert ModelProfile.context_size("qwen3-coder-next") == 32_768
      assert ModelProfile.context_size("mistral") == 32_000
    end
  end

  # ===========================================================================
  # Provider-prefixed lookups (strip prefix)
  # ===========================================================================

  describe "provider prefix stripping" do
    test "anthropic:model" do
      profile = ModelProfile.get("anthropic:claude-3-5-sonnet-20241022")
      assert profile.context_size == 200_000
      assert profile.max_output_tokens == 8_192
      assert profile.family == :claude
    end

    test "openai:model" do
      assert ModelProfile.context_size("openai:gpt-4o") == 128_000
      assert ModelProfile.family("openai:gpt-4o") == :gpt
    end

    test "google:model" do
      assert ModelProfile.context_size("google:gemini-2.0-flash") == 1_000_000
    end
  end

  # ===========================================================================
  # Family pattern matching (unknown model, known family)
  # ===========================================================================

  describe "family pattern matching" do
    test "unknown claude model matches claude family" do
      profile = ModelProfile.get("anthropic/claude-sonnet-4")
      assert profile.context_size == 200_000
      assert profile.family == :claude
    end

    test "unknown gpt model matches gpt family" do
      profile = ModelProfile.get("openai/gpt-4o-2025-future")
      assert profile.context_size == 128_000
      assert profile.family == :gpt
    end

    test "unknown gemini model matches gemini family" do
      profile = ModelProfile.get("google/gemini-3.0-ultra")
      assert profile.context_size == 1_000_000
      assert profile.family == :gemini
    end

    test "unknown deepseek model" do
      profile = ModelProfile.get("deepseek-v4-turbo")
      assert profile.context_size == 128_000
      assert profile.family == :deepseek
    end

    test "unknown llama model" do
      profile = ModelProfile.get("meta-llama/llama-4-70b")
      assert profile.context_size == 128_000
      assert profile.family == :llama
    end

    test "case insensitive matching" do
      profile = ModelProfile.get("CLAUDE-FUTURE-MODEL")
      assert profile.family == :claude
    end

    test "trinity pattern matches openrouter_free" do
      profile = ModelProfile.get("some/trinity-variant:free")
      assert profile.family == :openrouter_free
    end
  end

  # ===========================================================================
  # Unknown models (no family match)
  # ===========================================================================

  describe "unknown models" do
    test "returns defaults for completely unknown model" do
      profile = ModelProfile.get("totally-unknown-model-xyz")
      assert profile.context_size == 100_000
      assert profile.max_output_tokens == 4_096
      assert profile.effective_window_pct == 0.75
      assert profile.family == :unknown
    end

    test "default_context_size/0" do
      assert ModelProfile.default_context_size() == 100_000
    end

    test "default_effective_window_pct/0" do
      assert ModelProfile.default_effective_window_pct() == 0.75
    end
  end

  # ===========================================================================
  # Effective window calculation
  # ===========================================================================

  describe "effective_window/1" do
    test "claude: 200k * 0.75 = 150k" do
      assert ModelProfile.effective_window("claude-sonnet-4-6") == 150_000
    end

    test "gpt-4o: 128k * 0.75 = 96k" do
      assert ModelProfile.effective_window("gpt-4o") == 96_000
    end

    test "gemini: 1M * 0.75 = 750k" do
      assert ModelProfile.effective_window("gemini-1.5-pro") == 1_500_000
    end

    test "unknown model: 100k * 0.75 = 75k" do
      assert ModelProfile.effective_window("unknown-model") == 75_000
    end
  end

  # ===========================================================================
  # Convenience accessors
  # ===========================================================================

  describe "accessor functions" do
    test "context_size/1" do
      assert ModelProfile.context_size("gpt-4") == 8_192
    end

    test "effective_window_pct/1" do
      assert ModelProfile.effective_window_pct("gpt-4") == 0.75
    end

    test "max_output_tokens/1" do
      assert ModelProfile.max_output_tokens("gpt-4") == 4_096
    end

    test "family/1" do
      assert ModelProfile.family("gpt-4") == :gpt
    end
  end

  # ===========================================================================
  # known_models/0
  # ===========================================================================

  describe "known_models/0" do
    test "returns non-empty list" do
      models = ModelProfile.known_models()
      assert models != []
    end

    test "sorted by context_size descending" do
      models = ModelProfile.known_models()
      sizes = Enum.map(models, fn {_id, p} -> p.context_size end)
      assert sizes == Enum.sort(sizes, :desc)
    end

    test "all profiles have required fields" do
      for {_id, profile} <- ModelProfile.known_models() do
        assert is_integer(profile.context_size)
        assert is_float(profile.effective_window_pct)
        assert is_integer(profile.max_output_tokens)
        assert is_atom(profile.family)
      end
    end

    test "gemini models appear first (largest context)" do
      [{first_id, _} | _] = ModelProfile.known_models()
      assert String.contains?(first_id, "gemini")
    end
  end

  # ===========================================================================
  # Doctests
  # ===========================================================================

  doctest Arbor.Common.ModelProfile
end
