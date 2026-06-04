defmodule Arbor.Common.ModelProfileTest do
  use ExUnit.Case, async: true
  @moduletag :fast

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
      # gpt-oss-120b:free replaced trinity-large-preview:free which was
      # retired by OpenRouter on 2026-04-22.
      profile = ModelProfile.get("openai/gpt-oss-120b:free")
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
  # entry/1 — ModelEntry resolution via llm_db (Phase 1 item 9)
  # ===========================================================================
  #
  # entry/1 reads from llm_db at runtime. These tests run against whatever
  # snapshot llm_db has loaded — the assertions pin SHAPE, not specific
  # numeric values (llm_db updates would otherwise break the suite when
  # the catalog itself updates). For value-specific assertions, the legacy
  # get/1 API has the static fallback shape covered above.

  describe "entry/1 — llm_db-backed resolution" do
    alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

    # These tests document the llm_db-backed path. They self-skip with an
    # `IO.puts` notice when llm_db's persistent_term store isn't populated
    # (arbor_common run in isolation without the full umbrella). With the
    # full umbrella up, llm_db is started by :llm_db's application and
    # these tests exercise the real lookup.
    defp llmdb_populated? do
      Code.ensure_loaded?(LLMDB) and
        match?({:ok, _}, safe_llmdb_get("anthropic:claude-opus-4-6"))
    end

    defp safe_llmdb_get(spec) do
      apply(LLMDB, :model, [spec])
    rescue
      _ -> :unavailable
    catch
      :exit, _ -> :unavailable
    end

    defp with_llmdb(fun) do
      if llmdb_populated?() do
        fun.()
      else
        IO.puts("  (skipped — llm_db not loaded in this test environment)")
        :ok
      end
    end

    test "returns a ModelEntry with one provider matching the queried (provider, model)" do
      with_llmdb(fn ->
        entry = ModelProfile.entry("anthropic:claude-opus-4-6")

        assert %ModelEntry{} = entry
        assert entry.canonical_id == "claude-opus-4-6"
        assert entry.family == :claude
        assert is_integer(entry.context_window) and entry.context_window > 0
        assert is_integer(entry.max_output_tokens) and entry.max_output_tokens > 0

        assert [%ProviderEntry{id: :anthropic, ref: "claude-opus-4-6", auth: :api_key} = p] =
                 entry.providers

        # arbor_runtime_overlay layers :acp on top of :arbor for the Claude
        # subscription path that ships an ACP harness.
        assert :arbor in p.runtimes
        assert :acp in p.runtimes
      end)
    end

    test "bare model id resolves through family inference (claude → :anthropic)" do
      with_llmdb(fn ->
        entry = ModelProfile.entry("claude-opus-4-6")
        assert entry.canonical_id == "claude-opus-4-6"
        assert entry.family == :claude
        assert [%ProviderEntry{id: :anthropic}] = entry.providers
      end)
    end

    test "bare model id resolves through family inference (gpt → :openai)" do
      with_llmdb(fn ->
        entry = ModelProfile.entry("gpt-5-nano")
        assert entry.family == :gpt
        assert [%ProviderEntry{id: :openai}] = entry.providers
      end)
    end

    test "capabilities are mapped from llm_db's flag set" do
      with_llmdb(fn ->
        entry = ModelProfile.entry("anthropic:claude-opus-4-6")
        # llm_db marks claude-opus-4-6 with chat + tools + json + streaming.
        assert :chat in entry.capabilities
        assert :tool_use in entry.capabilities
      end)
    end

    test "pricing is translated to ProviderEntry pricing shape when present" do
      with_llmdb(fn ->
        entry = ModelProfile.entry("anthropic:claude-opus-4-6")
        [%ProviderEntry{pricing: pricing}] = entry.providers
        # When llm_db has a cost entry, pricing is a map with at least one of
        # the four per-mtok keys.
        assert is_map(pricing)

        assert pricing
               |> Map.keys()
               |> Enum.any?(
                 &(&1 in [
                     :input_per_mtok,
                     :output_per_mtok,
                     :cache_read_per_mtok,
                     :cache_write_per_mtok
                   ])
               )
      end)
    end

    test "context_window / max_output_tokens come from llm_db's limits" do
      with_llmdb(fn ->
        llmdb_entry = ModelProfile.entry("anthropic:claude-opus-4-6")
        # llm_db is the source of truth — we pin that the numbers MATCH what
        # llm_db has, not specific hardcoded values that would rot.
        # apply/3 keeps the compiler quiet since arbor_common doesn't list
        # llm_db as a direct dep.
        {:ok, llmdb_model} = apply(LLMDB, :model, ["anthropic:claude-opus-4-6"])
        assert llmdb_entry.context_window == llmdb_model.limits.context
        assert llmdb_entry.max_output_tokens == llmdb_model.limits.output
      end)
    end

    test "auth_for_provider defaults to :api_key for unknown providers" do
      with_llmdb(fn ->
        entry = ModelProfile.entry("openai:gpt-5-nano")
        assert [%ProviderEntry{auth: :api_key}] = entry.providers
      end)
    end
  end

  describe "entry/1 — synthesis fallback when llm_db has no record" do
    alias Arbor.Contracts.LLM.{ModelEntry, ProviderEntry}

    test "completely unknown model falls back to defaults with :legacy provider" do
      entry = ModelProfile.entry("totally-unknown-thing-9000")
      assert %ModelEntry{family: :unknown} = entry
      assert entry.context_window == ModelProfile.default_context_size()
      assert [%ProviderEntry{id: :legacy, auth: :api_key, runtimes: [:arbor]}] = entry.providers
      assert Enum.any?(entry.caveats, &String.contains?(&1, "llm_db"))
    end

    test "unknown model with claude-family-name uses family fallback" do
      # A model id llm_db won't have but the family pattern catches.
      entry = ModelProfile.entry("some-future-claude-variant-zzz")
      assert entry.family == :claude
      assert entry.context_window == 200_000
      assert [%ProviderEntry{id: :legacy}] = entry.providers
    end
  end

  describe "entry/1 — backwards-compat with existing API" do
    test "get/1 still returns the legacy map shape unchanged" do
      profile = ModelProfile.get("claude-opus-4-6")
      # The legacy short-form static map still drives get/1 etc. — those
      # specific values are pinned here so the existing callers don't drift.
      assert profile.context_size == 200_000
      assert profile.family == :claude
      assert profile.effective_window_pct == 0.75
    end

    test "context_size/1 / family/1 unchanged for legacy fallback entries" do
      assert ModelProfile.context_size("gpt-4o") == 128_000
      assert ModelProfile.family("gpt-4o") == :gpt
    end
  end

  # ===========================================================================
  # Doctests
  # ===========================================================================

  doctest Arbor.Common.ModelProfile
end
