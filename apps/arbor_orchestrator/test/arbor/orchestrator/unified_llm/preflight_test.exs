defmodule Arbor.Orchestrator.UnifiedLLM.PreflightTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.Preflight

  describe "strip_quant/1" do
    test "strips an LM Studio @quant suffix" do
      assert Preflight.strip_quant("gemma-4-e4b-it@q4_k_xl") == "gemma-4-e4b-it"
    end

    test "leaves an Ollama name:tag id untouched (no @)" do
      assert Preflight.strip_quant("granite4.1:3b") == "granite4.1:3b"
    end

    test "leaves a bare id untouched" do
      assert Preflight.strip_quant("gemma-4-e4b-it") == "gemma-4-e4b-it"
    end
  end

  describe "classify/3 — LM Studio (@quant)" do
    test "exact match → :ok" do
      loaded = ["gemma-4-e4b-it@q4_k_xl", "gemma-4-e4b-it@q8_k_xl"]
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", loaded) == :ok
    end

    test "base loaded under a different quant → {:wrong_quant, served}" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", ["gemma-4-e4b-it@q8_k_xl"]) ==
               {:wrong_quant, "gemma-4-e4b-it@q8_k_xl"}
    end

    test "base loaded as a bare id (one quant) → :unverified_quant" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", ["gemma-4-e4b-it"]) ==
               :unverified_quant
    end

    test "base not loaded at all → :missing" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", ["granite-4.1-3b"]) ==
               :missing
    end

    test "empty loaded list → :missing" do
      assert Preflight.classify(:lm_studio, "gemma-4-e4b-it@q4_k_xl", []) == :missing
    end
  end

  describe "classify/3 — Ollama (name:tag, implicit :latest)" do
    test "exact tag match → :ok" do
      assert Preflight.classify(:ollama, "granite4.1:3b", ["granite4.1:3b", "granite4:1b"]) == :ok
    end

    test "bare name matches the loaded :latest tag → :ok (Ollama's default tag)" do
      assert Preflight.classify(:ollama, "mxbai-embed-large", ["mxbai-embed-large:latest"]) == :ok
    end

    test "explicit tag that isn't loaded → :missing (even if another tag is)" do
      assert Preflight.classify(:ollama, "granite4.1:3b", ["granite4:1b"]) == :missing
    end

    test "bare name with no matching :latest → :missing" do
      assert Preflight.classify(:ollama, "mxbai-embed-large", ["nomic-embed-text:latest"]) ==
               :missing
    end
  end

  describe "configured_models/0" do
    test "returns only local-provider entries, incl. the needs_tools gate and the retrieval embed" do
      entries = Preflight.configured_models()

      assert Enum.all?(entries, &(&1.provider in [:lm_studio, :ollama]))

      assert Enum.any?(entries, &(&1.stage == :needs_tools and &1.provider == :lm_studio))
      assert Enum.any?(entries, &(&1.stage == :retrieval and &1.kind == :embed))
    end
  end

  describe "check/1 (injected fetcher)" do
    test "classifies each configured model and tags :unreachable when a provider errors" do
      # Everything 'loaded' → all :ok
      all_ok = fn _provider, _base -> {:ok, all_configured_ids()} end
      assert Enum.all?(Preflight.check(all_ok), &(&1.status == :ok))

      # Provider unreachable → :unreachable for those entries
      down = fn _provider, _base -> {:error, :econnrefused} end
      assert Enum.all?(Preflight.check(down), &(&1.status == :unreachable))

      # Nothing loaded → :missing
      empty = fn _provider, _base -> {:ok, []} end
      assert Enum.all?(Preflight.check(empty), &(&1.status == :missing))
    end

    test "queries each {provider, base_url} at most once (caches within a run)" do
      counter = :counters.new(1, [:atomics])

      fetch = fn _provider, _base ->
        :counters.add(counter, 1, 1)
        {:ok, all_configured_ids()}
      end

      _ = Preflight.check(fetch)

      # Default config: needs_tools on lm_studio:1234, the rest on ollama:11434 →
      # two distinct provider/base_url pairs regardless of how many stages there are.
      distinct =
        Preflight.configured_models() |> Enum.map(&{&1.provider, &1.base_url}) |> Enum.uniq()

      assert :counters.get(counter, 1) == length(distinct)
    end
  end

  defp all_configured_ids do
    Preflight.configured_models() |> Enum.map(& &1.model) |> Enum.uniq()
  end
end
