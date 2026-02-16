defmodule Arbor.Consensus.Evaluators.AdvisoryLLMTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Consensus.TestHelpers
  alias Arbor.Contracts.Consensus.Proposal

  @moduletag :fast

  @all_perspectives [
    :brainstorming,
    :user_experience,
    :security,
    :privacy,
    :stability,
    :capability,
    :emergence,
    :vision,
    :performance,
    :generalization,
    :resource_usage,
    :consistency,
    :general
  ]

  # LLM function that returns a mock JSON response (replaces ai_module: MockAI)
  defp mock_llm_fn do
    fn _system_prompt, _user_prompt ->
      {:ok,
       Jason.encode!(%{
         "analysis" => "Mock analysis of the design question",
         "considerations" => ["Consider simplicity", "Consider composability"],
         "alternatives" => ["Alternative approach A", "Alternative approach B"],
         "recommendation" => "Start with the simplest approach"
       })}
    end
  end

  # LLM function that returns an error (replaces ai_module: ErrorAI)
  defp error_llm_fn do
    fn _system_prompt, _user_prompt ->
      {:error, :api_error}
    end
  end

  describe "behaviour implementation" do
    test "name/0 returns :advisory_llm" do
      assert AdvisoryLLM.name() == :advisory_llm
    end

    test "perspectives/0 returns all 13 perspectives" do
      perspectives = AdvisoryLLM.perspectives()
      assert length(perspectives) == 13

      for p <- @all_perspectives do
        assert p in perspectives, "missing perspective: #{p}"
      end
    end

    test "strategy/0 returns :llm" do
      assert AdvisoryLLM.strategy() == :llm
    end
  end

  describe "evaluate/3 — all perspectives" do
    for perspective <- [
          :brainstorming,
          :user_experience,
          :security,
          :privacy,
          :stability,
          :capability,
          :emergence,
          :vision,
          :performance,
          :generalization,
          :resource_usage,
          :consistency,
          :general
        ] do
      test "evaluates from #{perspective} perspective" do
        proposal = TestHelpers.build_proposal(%{description: "Test #{unquote(perspective)}"})

        assert {:ok, eval} =
                 AdvisoryLLM.evaluate(proposal, unquote(perspective), llm_fn: mock_llm_fn())

        assert eval.perspective == unquote(perspective)
        assert eval.vote == :approve
        assert eval.sealed == true
        assert eval.reasoning =~ "Mock analysis"
      end
    end

    test "rejects unsupported perspective" do
      proposal = TestHelpers.build_proposal()

      assert {:error, {:unsupported_perspective, :nonexistent, _}} =
               AdvisoryLLM.evaluate(proposal, :nonexistent, llm_fn: mock_llm_fn())
    end
  end

  describe "evaluate/3 — error handling" do
    test "handles LLM error gracefully" do
      proposal = TestHelpers.build_proposal(%{description: "Test error handling"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, llm_fn: error_llm_fn())

      assert eval.vote == :abstain
      assert eval.confidence == 0.0
      assert eval.reasoning =~ "LLM error"
    end

    test "includes context in evaluation" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Should we use Redis?",
          target_layer: 4,
          context: %{constraints: "must survive restarts", budget: "low"}
        })

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :stability, llm_fn: mock_llm_fn())

      assert eval.vote == :approve
      assert eval.sealed == true
    end
  end

  describe "reference documents" do
    test "vision includes VISION.md path automatically" do
      proposal = TestHelpers.build_proposal(%{description: "Does this align with the vision?"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :vision, llm_fn: mock_llm_fn())

      assert eval.perspective == :vision
      assert eval.sealed == true
    end

    test "reference_docs paths included for any perspective" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Brainstorm with reference doc",
          target_layer: 4,
          context: %{reference_docs: [".arbor/roadmap/consensus-redesign.md"]}
        })

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, llm_fn: mock_llm_fn())

      assert eval.perspective == :brainstorming
      assert eval.sealed == true
    end

    test "vision includes both VISION.md and reference_docs paths" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Check vision alignment",
          target_layer: 4,
          context: %{reference_docs: ["docs/design.md"]}
        })

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :vision, llm_fn: mock_llm_fn())

      assert eval.perspective == :vision
      assert eval.sealed == true
    end

    test "nonexistent doc paths are listed without error" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Check with nonexistent doc path",
          target_layer: 4,
          context: %{reference_docs: ["/nonexistent/path/to/doc.md"]}
        })

      # Paths are just listed in the prompt — no file I/O, no crash
      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, llm_fn: mock_llm_fn())

      assert eval.perspective == :brainstorming
    end

    test "doc paths are passed in user prompt to llm_fn" do
      doc_path = ".arbor/roadmap/consensus-redesign.md"

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Test doc path forwarding",
          target_layer: 4,
          context: %{reference_docs: [doc_path]}
        })

      # Capture the user prompt to verify doc paths are included
      test_pid = self()

      capture_fn = fn _system_prompt, user_prompt ->
        send(test_pid, {:user_prompt, user_prompt})

        {:ok,
         Jason.encode!(%{
           "analysis" => "Mock analysis",
           "considerations" => [],
           "alternatives" => [],
           "recommendation" => "ok"
         })}
      end

      assert {:ok, _eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, llm_fn: capture_fn)

      assert_receive {:user_prompt, user_prompt}
      assert user_prompt =~ doc_path
    end
  end

  describe "context formatting" do
    test "reference_docs are excluded from context section in prompt" do
      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Test context filtering",
          target_layer: 4,
          context: %{
            important_info: "this should appear",
            reference_docs: ["/some/path.md"]
          }
        })

      # Evaluate from a non-vision perspective to verify reference_docs
      # don't appear in the context section
      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, llm_fn: mock_llm_fn())

      assert eval.sealed == true
    end
  end

  describe "model diversity" do
    test "provider_map/0 returns provider:model for each perspective" do
      map = AdvisoryLLM.provider_map()
      assert map_size(map) == 13

      # Each perspective has a provider:model string
      for p <- @all_perspectives do
        assert Map.has_key?(map, p), "missing provider:model for: #{p}"
        assert is_binary(Map.get(map, p)), "provider:model for #{p} should be a string"
      end

      # Multiple distinct models are represented for viewpoint diversity
      unique_models = map |> Map.values() |> Enum.uniq()

      assert length(unique_models) >= 3,
             "expected at least 3 different models, got: #{inspect(unique_models)}"
    end

    test "each perspective has a default provider:model assignment" do
      map = AdvisoryLLM.provider_map()

      # Verify specific assignments — distributed across 4 OpenRouter models
      assert map[:security] == "openrouter:openai/gpt-5-nano"
      assert map[:vision] == "openrouter:moonshotai/kimi-k2.5"
      assert map[:consistency] == "openrouter:openai/gpt-5-nano"
      assert map[:performance] == "openrouter:openai/gpt-5-nano"
      assert map[:privacy] == "openrouter:openai/gpt-5-nano"
      assert map[:brainstorming] == "openrouter:moonshotai/kimi-k2.5"
      assert map[:emergence] == "openrouter:moonshotai/kimi-k2.5"
      assert map[:capability] == "openrouter:moonshotai/kimi-k2.5"
      assert map[:stability] == "openrouter:x-ai/grok-4.1-fast"
      assert map[:resource_usage] == "openrouter:x-ai/grok-4.1-fast"
      assert map[:user_experience] == "openrouter:minimax/minimax-m2.5"
      assert map[:generalization] == "openrouter:minimax/minimax-m2.5"
      assert map[:general] == "openrouter:minimax/minimax-m2.5"
    end

    test "caller can override provider_model via opts" do
      proposal = TestHelpers.build_proposal(%{description: "Override test"})

      # Capture the call to verify the right provider/model was resolved
      test_pid = self()

      capture_fn = fn system_prompt, _user_prompt ->
        send(test_pid, {:system_prompt, system_prompt})

        {:ok,
         Jason.encode!(%{
           "analysis" => "Mock analysis",
           "considerations" => [],
           "alternatives" => [],
           "recommendation" => "ok"
         })}
      end

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :security,
                 llm_fn: capture_fn,
                 provider_model: "gemini:gemini-2.5-flash"
               )

      assert eval.sealed == true
    end
  end

  describe "resolve_provider_model/2" do
    test "returns default provider and model for perspective" do
      assert {"openrouter", "openai/gpt-5-nano"} =
               AdvisoryLLM.resolve_provider_model(:security)

      assert {"openrouter", "openai/gpt-5-nano"} = AdvisoryLLM.resolve_provider_model(:privacy)
    end

    test "per-call override via provider_model opt" do
      assert {"gemini", "gemini-2.5-flash"} =
               AdvisoryLLM.resolve_provider_model(:security,
                 provider_model: "gemini:gemini-2.5-flash"
               )
    end

    test "handles provider-only string" do
      # When override has no colon, provider and model are the same string
      assert {"anthropic", "anthropic"} =
               AdvisoryLLM.resolve_provider_model(:security, provider_model: "anthropic")
    end

    test "handles openrouter paths with slashes via override" do
      assert {"openrouter", "deepseek/deepseek-r1"} =
               AdvisoryLLM.resolve_provider_model(:brainstorming,
                 provider_model: "openrouter:deepseek/deepseek-r1"
               )
    end

    test "handles model names with colons (ollama tags) via override" do
      assert {"ollama", "deepseek-v3.2:cloud"} =
               AdvisoryLLM.resolve_provider_model(:generalization,
                 provider_model: "ollama:deepseek-v3.2:cloud"
               )
    end

    test "general perspective has a default" do
      AdvisoryLLM.reset_perspective_models()
      assert {"openrouter", "minimax/minimax-m2.5"} =
               AdvisoryLLM.resolve_provider_model(:general)
    end

    test "OpenRouter model defaults resolve correctly" do
      assert {"openrouter", "moonshotai/kimi-k2.5"} =
               AdvisoryLLM.resolve_provider_model(:brainstorming)

      assert {"openrouter", "minimax/minimax-m2.5"} =
               AdvisoryLLM.resolve_provider_model(:generalization)

      assert {"openrouter", "x-ai/grok-4.1-fast"} =
               AdvisoryLLM.resolve_provider_model(:stability)
    end
  end

  describe "runtime configuration" do
    setup do
      # Reset to defaults after each test
      on_exit(fn -> AdvisoryLLM.reset_perspective_models() end)
    end

    test "configure_perspective/2 overrides a single perspective" do
      AdvisoryLLM.configure_perspective(:security, "ollama:llama3.2:latest")

      assert {"ollama", "llama3.2:latest"} =
               AdvisoryLLM.resolve_provider_model(:security)

      # Other perspectives unchanged
      assert {"openrouter", "openai/gpt-5-nano"} =
               AdvisoryLLM.resolve_provider_model(:privacy)
    end

    test "configure_perspectives/1 overrides multiple perspectives" do
      AdvisoryLLM.configure_perspectives(%{
        security: "xai:grok-3",
        brainstorming: "openrouter:deepseek/deepseek-r1"
      })

      assert {"xai", "grok-3"} = AdvisoryLLM.resolve_provider_model(:security)
      assert {"openrouter", "deepseek/deepseek-r1"} = AdvisoryLLM.resolve_provider_model(:brainstorming)

      # Other perspectives unchanged
      assert {"openrouter", "x-ai/grok-4.1-fast"} =
               AdvisoryLLM.resolve_provider_model(:stability)
    end

    test "reset_perspective_models/0 restores defaults" do
      AdvisoryLLM.configure_perspective(:security, "ollama:test")
      assert {"ollama", "test"} = AdvisoryLLM.resolve_provider_model(:security)

      AdvisoryLLM.reset_perspective_models()
      assert {"openrouter", "openai/gpt-5-nano"} =
               AdvisoryLLM.resolve_provider_model(:security)
    end

    test "provider_map/0 reflects runtime configuration" do
      AdvisoryLLM.configure_perspective(:general, "lm_studio:qwen3-coder")
      map = AdvisoryLLM.provider_map()
      assert map[:general] == "lm_studio:qwen3-coder"
      # Defaults still present for unconfigured perspectives
      assert map[:security] == "openrouter:openai/gpt-5-nano"
    end

    test "per-call provider_model opt still takes precedence over config" do
      AdvisoryLLM.configure_perspective(:security, "ollama:test")

      # Per-call override should win
      assert {"gemini", "gemini-2.5-flash"} =
               AdvisoryLLM.resolve_provider_model(:security, provider_model: "gemini:gemini-2.5-flash")
    end
  end

  describe "system prompt loading" do
    test "llm_fn receives a system prompt with perspective content" do
      proposal = TestHelpers.build_proposal(%{description: "Prompt check"})
      test_pid = self()

      capture_fn = fn system_prompt, _user_prompt ->
        send(test_pid, {:system_prompt, system_prompt})

        {:ok,
         Jason.encode!(%{
           "analysis" => "Mock",
           "considerations" => [],
           "alternatives" => [],
           "recommendation" => "ok"
         })}
      end

      assert {:ok, _eval} =
               AdvisoryLLM.evaluate(proposal, :security, llm_fn: capture_fn)

      assert_receive {:system_prompt, system_prompt}
      # Should contain security-related content (from fallback or skill)
      assert system_prompt =~ "SECURITY"
      assert system_prompt =~ "attack surface"
    end

    test "each fallback prompt includes response format" do
      proposal = TestHelpers.build_proposal(%{description: "Format check"})
      test_pid = self()

      for perspective <- @all_perspectives do
        capture_fn = fn system_prompt, _user_prompt ->
          send(test_pid, {:system_prompt, perspective, system_prompt})

          {:ok,
           Jason.encode!(%{
             "analysis" => "Mock",
             "considerations" => [],
             "alternatives" => [],
             "recommendation" => "ok"
           })}
        end

        assert {:ok, _eval} =
                 AdvisoryLLM.evaluate(proposal, perspective, llm_fn: capture_fn)

        assert_receive {:system_prompt, ^perspective, system_prompt}
        assert system_prompt =~ "Respond with valid JSON only"
      end
    end
  end

  describe "response parsing" do
    test "parses valid JSON response into structured reasoning" do
      proposal = TestHelpers.build_proposal(%{description: "Test parsing"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming, llm_fn: mock_llm_fn())

      assert eval.reasoning =~ "Considerations"
      assert eval.reasoning =~ "Alternatives"
      assert eval.reasoning =~ "Recommendation"
    end

    test "handles non-JSON response as raw text" do
      raw_text_fn = fn _system_prompt, _user_prompt ->
        {:ok, "This is just plain text analysis without JSON."}
      end

      proposal = TestHelpers.build_proposal(%{description: "Test raw text"})

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :security, llm_fn: raw_text_fn)

      assert eval.reasoning == "This is just plain text analysis without JSON."
    end
  end
end
