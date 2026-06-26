defmodule Arbor.LLM.ProviderRegistryTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.ProviderRegistry

  # Regression: the same physical LM Studio provider was historically
  # spelled FOUR ways across Arbor's layers —
  #
  #   arbor_ai            -> :lmstudio   (atom, no underscore)
  #   arbor_orchestrator  -> :lm_studio  (atom, underscore)
  #   mix arbor.agent     -> "lmstudio" / "lm_studio" (either string)
  #   arbor_llm registry  -> "lm_studio" (canonical)
  #
  # A dev wiring up a local-LLM stage had to know which spelling each
  # layer wanted, and a typo'd spelling silently routed nowhere. The
  # normalization seam in ProviderRegistry folds every spelling onto the
  # one canonical provider string so all four resolve to the SAME
  # provider identity / base_url. These tests pin that closed — if the
  # seam regresses, the spellings diverge again and these fail.
  describe "normalize/1 — LM Studio spelling footgun" do
    @lm_studio_spellings [:lmstudio, "lmstudio", :lm_studio, "lm_studio"]

    test "all four LM Studio spellings normalize to the same canonical string" do
      canonical = Enum.map(@lm_studio_spellings, &ProviderRegistry.normalize/1)

      assert canonical == ["lm_studio", "lm_studio", "lm_studio", "lm_studio"],
             "expected every LM Studio spelling to fold onto \"lm_studio\", got: #{inspect(canonical)}"
    end

    test "all four spellings resolve to the same provider identity (req_llm atom)" do
      atoms = Enum.map(@lm_studio_spellings, &ProviderRegistry.req_llm_atom/1)

      assert atoms == [:openai, :openai, :openai, :openai],
             "LM Studio routes through req_llm's :openai module; spellings diverged: #{inspect(atoms)}"
    end

    test "all four spellings resolve to the same base_url" do
      urls = Enum.map(@lm_studio_spellings, &ProviderRegistry.default_base_url/1)

      assert urls == [
               "http://localhost:1234/v1",
               "http://localhost:1234/v1",
               "http://localhost:1234/v1",
               "http://localhost:1234/v1"
             ],
             "spellings produced different base_urls: #{inspect(urls)}"
    end

    test "all four spellings are recognized as local + known providers" do
      for spelling <- @lm_studio_spellings do
        assert ProviderRegistry.local?(spelling),
               "#{inspect(spelling)} should be a local provider"

        assert ProviderRegistry.known?(spelling),
               "#{inspect(spelling)} should be a known provider"
      end
    end

    test "all four spellings produce the same display name" do
      names = Enum.map(@lm_studio_spellings, &ProviderRegistry.display_name/1)
      assert names == ["LM Studio", "LM Studio", "LM Studio", "LM Studio"]
    end

    test "all four spellings produce the same (identical) capabilities" do
      [first | rest] = Enum.map(@lm_studio_spellings, &ProviderRegistry.capabilities/1)
      assert Enum.all?(rest, &(&1 == first))
    end
  end

  describe "normalize/1 — pass-through for everything else" do
    test "canonical local + cloud names are unchanged" do
      assert ProviderRegistry.normalize("ollama") == "ollama"
      assert ProviderRegistry.normalize(:ollama) == "ollama"
      assert ProviderRegistry.normalize("openai") == "openai"
      assert ProviderRegistry.normalize("anthropic") == "anthropic"
    end

    test "unknown providers pass through as their string form" do
      assert ProviderRegistry.normalize("totally-made-up") == "totally-made-up"
      assert ProviderRegistry.normalize(:some_future_provider) == "some_future_provider"
    end
  end
end
