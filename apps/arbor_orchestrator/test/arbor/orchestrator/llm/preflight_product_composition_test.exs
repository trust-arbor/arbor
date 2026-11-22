defmodule Arbor.Orchestrator.LLMPreflightProductCompositionTest do
  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.LLM.Preflight

  setup do
    assert Application.fetch_env(:arbor_llm, :preprocessor_provider) ==
             {:ok, Arbor.Orchestrator.Config}

    assert Preflight.configured_models() != []
    :ok
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
