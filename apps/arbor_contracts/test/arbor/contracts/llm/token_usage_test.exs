defmodule Arbor.Contracts.LLM.TokenUsageTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.LLM.TokenUsage

  @moduletag :fast

  describe "from_provider/2 — anthropic" do
    test "extracts standard fields from anthropic-shaped body" do
      body = %{
        "usage" => %{
          "input_tokens" => 1234,
          "output_tokens" => 567,
          "cache_read_input_tokens" => 100,
          "cache_creation_input_tokens" => 50
        }
      }

      assert %TokenUsage{
               input_tokens: 1234,
               output_tokens: 567,
               total_tokens: 1801,
               cache_read_tokens: 100,
               cache_write_tokens: 50,
               provider: :anthropic
             } = TokenUsage.from_provider(:anthropic, body)
    end

    test "missing usage block produces empty struct" do
      assert %TokenUsage{input_tokens: nil, output_tokens: nil} =
               TokenUsage.from_provider(:anthropic, %{})
    end
  end

  describe "from_provider/2 — openai-shape" do
    test "extracts prompt/completion tokens for openrouter" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 800,
          "completion_tokens" => 200,
          "total_tokens" => 1000,
          "cost" => 0.0042
        }
      }

      assert %TokenUsage{
               input_tokens: 800,
               output_tokens: 200,
               total_tokens: 1000,
               cost: 0.0042,
               provider: :openrouter
             } = TokenUsage.from_provider(:openrouter, body)
    end

    test "computes total_tokens when missing" do
      body = %{"usage" => %{"prompt_tokens" => 50, "completion_tokens" => 25}}
      usage = TokenUsage.from_provider(:openai, body)
      assert usage.total_tokens == 75
    end

    test "extracts reasoning_tokens from completion_tokens_details" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 100,
          "completion_tokens" => 200,
          "completion_tokens_details" => %{"reasoning_tokens" => 150}
        }
      }

      assert %TokenUsage{reasoning_tokens: 150} = TokenUsage.from_provider(:openai, body)
    end

    test "extracts cached_tokens from prompt_tokens_details" do
      body = %{
        "usage" => %{
          "prompt_tokens" => 1000,
          "completion_tokens" => 50,
          "prompt_tokens_details" => %{"cached_tokens" => 800}
        }
      }

      assert %TokenUsage{cache_read_tokens: 800} = TokenUsage.from_provider(:openai, body)
    end
  end

  describe "from_provider/2 — edge cases" do
    test "nil body returns empty struct" do
      assert TokenUsage.empty?(TokenUsage.from_provider(:anthropic, nil))
    end

    test "non-map body returns empty struct" do
      assert TokenUsage.empty?(TokenUsage.from_provider(:openai, "garbage"))
    end

    test "unknown provider falls back to openai shape" do
      body = %{"usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5}}
      assert %TokenUsage{input_tokens: 10, output_tokens: 5} = TokenUsage.from_provider(:weird, body)
    end
  end

  describe "from_map/1" do
    test "round-trips via to_signal_data" do
      original = %TokenUsage{
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        provider: :openai,
        model: "gpt-5"
      }

      assert original == original |> TokenUsage.to_signal_data() |> TokenUsage.from_map()
    end

    test "accepts both atom and string keys" do
      from_atoms = TokenUsage.from_map(%{input_tokens: 10, output_tokens: 5})
      from_strings = TokenUsage.from_map(%{"input_tokens" => 10, "output_tokens" => 5})
      assert from_atoms == from_strings
    end

    test "passes through an existing TokenUsage struct unchanged" do
      u = %TokenUsage{input_tokens: 1}
      assert TokenUsage.from_map(u) == u
    end

    test "nil returns empty struct" do
      assert TokenUsage.empty?(TokenUsage.from_map(nil))
    end
  end

  describe "with_meta/2" do
    test "stamps duration/provider/model without clobbering token counts" do
      base = %TokenUsage{input_tokens: 100, output_tokens: 50}

      stamped =
        TokenUsage.with_meta(base, duration_ms: 1234, provider: :openrouter, model: "trinity")

      assert stamped.input_tokens == 100
      assert stamped.output_tokens == 50
      assert stamped.duration_ms == 1234
      assert stamped.provider == :openrouter
      assert stamped.model == "trinity"
    end
  end

  describe "add/2" do
    test "sums token counts" do
      a = %TokenUsage{input_tokens: 10, output_tokens: 5, cost: 0.01}
      b = %TokenUsage{input_tokens: 20, output_tokens: 15, cost: 0.02}

      sum = TokenUsage.add(a, b)
      assert sum.input_tokens == 30
      assert sum.output_tokens == 20
      assert_in_delta sum.cost, 0.03, 0.0001
    end

    test "right-hand provider/model wins" do
      a = %TokenUsage{provider: :openai, model: "old"}
      b = %TokenUsage{provider: :anthropic, model: "new"}
      sum = TokenUsage.add(a, b)
      assert sum.provider == :anthropic
      assert sum.model == "new"
    end
  end

  describe "to_telemetry/1" do
    test "produces non-nil integer fields suitable for :telemetry" do
      u = %TokenUsage{input_tokens: 100, output_tokens: 50, total_tokens: 150}
      tel = TokenUsage.to_telemetry(u)
      assert tel.input_tokens == 100
      assert tel.output_tokens == 50
      assert tel.total_tokens == 150
      assert tel.cached_tokens == 0
    end

    test "nil token fields become 0 for telemetry" do
      tel = TokenUsage.to_telemetry(%TokenUsage{})
      assert tel.input_tokens == 0
      assert tel.output_tokens == 0
    end
  end

  describe "empty?/1" do
    test "true when no token data" do
      assert TokenUsage.empty?(%TokenUsage{})
      assert TokenUsage.empty?(%TokenUsage{provider: :openai, duration_ms: 100})
    end

    test "false when any token field is set" do
      refute TokenUsage.empty?(%TokenUsage{input_tokens: 1})
      refute TokenUsage.empty?(%TokenUsage{output_tokens: 1})
      refute TokenUsage.empty?(%TokenUsage{total_tokens: 1})
    end
  end
end
