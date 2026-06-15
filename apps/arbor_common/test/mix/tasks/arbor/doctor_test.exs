defmodule Mix.Tasks.Arbor.DoctorTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Mix.Tasks.Arbor.Doctor

  # `fallback_model/2` is the LLMDB-unavailable fallback path. It must NEVER return
  # a hard-coded model id (those go stale — cf. the retired trinity-large-preview)
  # and must respect local-first setups. The layering is: configured default (for
  # the default provider) → live local discovery → honest nil.
  describe "fallback_model/2 — no hard-coded models, local-first" do
    test "uses the configured default model for the configured default provider" do
      deps = %{
        default_provider: :openrouter,
        default_model: "openai/gpt-oss-120b:free",
        discover: fn _ -> [] end
      }

      assert Doctor.fallback_model(:openrouter, deps) == "openai/gpt-oss-120b:free"
    end

    test "discovers a live local model for a non-default provider (Ollama/LM Studio)" do
      deps = %{
        default_provider: :openrouter,
        default_model: "openai/gpt-oss-120b:free",
        discover: fn
          :ollama -> ["llama3.1:8b", "qwen2.5:7b"]
          _ -> []
        end
      }

      assert Doctor.fallback_model(:ollama, deps) == "llama3.1:8b"
    end

    test "returns nil (honest) when nothing is configured or discoverable — not a guess" do
      # The old behavior here was a hard-coded `claude-sonnet-...`. The regression
      # guard: an undiscoverable provider must NOT yield a fabricated model string.
      deps = %{default_provider: :ollama, default_model: nil, discover: fn _ -> [] end}

      assert Doctor.fallback_model(:anthropic, deps) == nil
    end

    test "prefers the configured default over discovery when this is the default provider" do
      deps = %{
        default_provider: :ollama,
        default_model: "granite4.1:3b",
        discover: fn _ -> ["something-else:latest"] end
      }

      assert Doctor.fallback_model(:ollama, deps) == "granite4.1:3b"
    end

    test "falls through to discovery when the configured default model is missing" do
      deps = %{
        default_provider: :ollama,
        default_model: nil,
        discover: fn :ollama -> ["qwen2.5:7b"] end
      }

      assert Doctor.fallback_model(:ollama, deps) == "qwen2.5:7b"
    end
  end
end
