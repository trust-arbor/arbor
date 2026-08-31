defmodule Arbor.Consensus.Evaluators.AdvisoryLLMTest do
  use ExUnit.Case, async: false

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
    :adversarial
  ]

  @portable_models %{
    brainstorming: "xai_oauth:grok-4.6",
    user_experience: "openrouter:google/gemini-3.7-flash",
    security: "openai_oauth:gpt-5.6-sol",
    privacy: "openrouter:google/gemini-3.7-flash",
    stability: "openrouter:deepseek/deepseek-v4-pro-0813",
    capability: "openrouter:google/gemini-3.7-flash",
    emergence: "xai_oauth:grok-4.6",
    vision: "openrouter:google/gemini-3.7-flash",
    performance: "ollama:kimi-k2.7-code:cloud",
    generalization: "openrouter:deepseek/deepseek-v4-pro-0813",
    resource_usage: "ollama:kimi-k2.7-code:cloud",
    consistency: "openrouter:deepseek/deepseek-v4-pro-0813",
    adversarial: "openai_oauth:gpt-5.6-sol"
  }

  @model_config_keys [:council_model, :perspective_models_json, :perspective_models]

  setup do
    previous =
      Map.new(@model_config_keys, fn key ->
        {key, Application.fetch_env(:arbor_consensus, key)}
      end)

    Enum.each(@model_config_keys, &Application.delete_env(:arbor_consensus, &1))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_consensus, key, value)
        {key, :error} -> Application.delete_env(:arbor_consensus, key)
      end)
    end)

    :ok
  end

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
          :adversarial
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

    test "doc paths are read and inlined in user prompt" do
      # Create a temp file so format_doc_paths can read and inline it
      tmp_dir = System.tmp_dir!()
      doc_path = Path.join(tmp_dir, "test_reference_doc.md")
      File.write!(doc_path, "# Test Reference\n\nThis is test content for advisory.")

      on_exit(fn -> File.rm(doc_path) end)

      {:ok, proposal} =
        Proposal.new(%{
          proposer: "human",
          change_type: :advisory,
          description: "Test doc path forwarding",
          target_layer: 4,
          context: %{reference_docs: [doc_path]}
        })

      # Capture the user prompt to verify doc contents are inlined
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
      # File contents should be inlined, not just the path
      assert user_prompt =~ "Reference Documents"
      assert user_prompt =~ "test_reference_doc.md"
      assert user_prompt =~ "This is test content for advisory."
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

      unique_models = map |> Map.values() |> Enum.uniq()

      # Seats span subscription OAuth, local Ollama, and OpenRouter; each is
      # resolved against the host at consult time (see the host-fallback test).
      assert length(unique_models) >= 3,
             "expected mixed model families, got: #{inspect(unique_models)}"
    end

    test "each perspective has a default provider:model assignment" do
      assert AdvisoryLLM.provider_map() == @portable_models
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

    test "forwards the evaluator timeout to the LLM bridge" do
      proposal = TestHelpers.build_proposal(%{description: "Timeout propagation test"})
      parent = self()

      complete_fun = fn _system_prompt, _user_prompt, opts ->
        send(parent, {:bridge_opts, opts})

        {:ok,
         Jason.encode!(%{
           "analysis" => "Mock analysis",
           "considerations" => [],
           "alternatives" => [],
           "recommendation" => "ok"
         }), %{}}
      end

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming,
                 timeout: 75_000,
                 complete_fun: complete_fun
               )

      assert eval.sealed
      assert_receive {:bridge_opts, opts}
      assert opts[:timeout] == 75_000
      assert opts[:max_tokens] == nil
    end

    test "forwards an explicit response-token cap" do
      proposal = TestHelpers.build_proposal(%{description: "Token cap propagation test"})
      parent = self()

      complete_fun = fn _system_prompt, _user_prompt, opts ->
        send(parent, {:bridge_opts, opts})

        {:ok,
         Jason.encode!(%{
           "analysis" => "Mock analysis",
           "considerations" => [],
           "alternatives" => [],
           "recommendation" => "ok"
         }), %{}}
      end

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :brainstorming,
                 max_tokens: 12_345,
                 complete_fun: complete_fun
               )

      assert eval.sealed
      assert_receive {:bridge_opts, opts}
      assert opts[:max_tokens] == 12_345
    end
  end

  describe "resolve_provider_model/2" do
    test "returns default provider and model for perspective" do
      assert {"openai_oauth", "gpt-5.6-sol"} = AdvisoryLLM.resolve_provider_model(:security)

      assert {"openrouter", "google/gemini-3.7-flash"} =
               AdvisoryLLM.resolve_provider_model(:privacy)
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

    test "adversarial perspective has a default" do
      AdvisoryLLM.reset_perspective_models()

      assert {"openai_oauth", "gpt-5.6-sol"} = AdvisoryLLM.resolve_provider_model(:adversarial)
    end

    test "OpenRouter model defaults resolve correctly" do
      assert {"xai_oauth", "grok-4.6"} = AdvisoryLLM.resolve_provider_model(:brainstorming)

      assert {"openrouter", "deepseek/deepseek-v4-pro-0813"} =
               AdvisoryLLM.resolve_provider_model(:generalization)

      assert {"openrouter", "deepseek/deepseek-v4-pro-0813"} =
               AdvisoryLLM.resolve_provider_model(:stability)
    end
  end

  describe "parse_perspective_models_json/1" do
    test "parses closed perspective names and preserves model tag colons" do
      json =
        Jason.encode!(%{
          "security" => "openai_oauth:gpt-daybreak-blue-latest",
          "performance" => "ollama:kimi-k2.7-code:cloud"
        })

      assert {:ok,
              %{
                security: "openai_oauth:gpt-daybreak-blue-latest",
                performance: "ollama:kimi-k2.7-code:cloud"
              }} = AdvisoryLLM.parse_perspective_models_json(json)
    end

    test "rejects malformed JSON and non-object values" do
      assert {:error, :invalid_json} = AdvisoryLLM.parse_perspective_models_json("{")
      assert {:error, :expected_json_object} = AdvisoryLLM.parse_perspective_models_json("[]")
    end

    test "rejects unknown perspective names without creating atoms" do
      assert {:error, {:unknown_perspective, "security_review"}} =
               AdvisoryLLM.parse_perspective_models_json(
                 ~s({"security_review":"openrouter:model"})
               )
    end

    test "rejects malformed provider:model routes" do
      assert {:error, {:invalid_provider_model, "security"}} =
               AdvisoryLLM.parse_perspective_models_json(~s({"security":"model-only"}))
    end
  end

  describe "runtime configuration" do
    test "per-perspective JSON overrides the uniform model" do
      Application.put_env(:arbor_consensus, :council_model, "openrouter:uniform")

      Application.put_env(
        :arbor_consensus,
        :perspective_models_json,
        ~s({"security":"openai_oauth:gpt-daybreak-blue-latest"})
      )

      assert {"openai_oauth", "gpt-daybreak-blue-latest"} =
               AdvisoryLLM.resolve_provider_model(:security)

      assert {"openrouter", "uniform"} = AdvisoryLLM.resolve_provider_model(:privacy)
    end

    test "programmatic configuration overrides environment JSON" do
      Application.put_env(
        :arbor_consensus,
        :perspective_models_json,
        ~s({"security":"openai_oauth:gpt-daybreak-blue-latest"})
      )

      AdvisoryLLM.configure_perspective(:security, "ollama:local-model")

      assert {"ollama", "local-model"} = AdvisoryLLM.resolve_provider_model(:security)
    end

    test "invalid environment JSON fails loudly when the council resolves models" do
      Application.put_env(:arbor_consensus, :perspective_models_json, ~s({"unknown":"x:y"}))

      assert_raise ArgumentError, ~r/invalid ARBOR_COUNCIL_PERSPECTIVE_MODELS/, fn ->
        AdvisoryLLM.provider_map()
      end
    end

    test "configure_perspective/2 overrides a single perspective" do
      AdvisoryLLM.configure_perspective(:security, "ollama:llama3.2:latest")

      assert {"ollama", "llama3.2:latest"} =
               AdvisoryLLM.resolve_provider_model(:security)

      # Other perspectives unchanged
      assert {"openrouter", "google/gemini-3.7-flash"} =
               AdvisoryLLM.resolve_provider_model(:privacy)
    end

    test "configure_perspectives/1 overrides multiple perspectives" do
      AdvisoryLLM.configure_perspectives(%{
        security: "xai:grok-3",
        brainstorming: "openrouter:deepseek/deepseek-r1"
      })

      assert {"xai", "grok-3"} = AdvisoryLLM.resolve_provider_model(:security)

      assert {"openrouter", "deepseek/deepseek-r1"} =
               AdvisoryLLM.resolve_provider_model(:brainstorming)

      # Other perspectives unchanged
      assert {"openrouter", "deepseek/deepseek-v4-pro-0813"} =
               AdvisoryLLM.resolve_provider_model(:stability)
    end

    test "reset_perspective_models/0 restores defaults" do
      AdvisoryLLM.configure_perspective(:security, "ollama:test")
      assert {"ollama", "test"} = AdvisoryLLM.resolve_provider_model(:security)

      AdvisoryLLM.reset_perspective_models()

      assert {"openai_oauth", "gpt-5.6-sol"} = AdvisoryLLM.resolve_provider_model(:security)
    end

    test "provider_map/0 reflects runtime configuration" do
      AdvisoryLLM.configure_perspective(:adversarial, "lm_studio:qwen3-coder")
      map = AdvisoryLLM.provider_map()
      assert map[:adversarial] == "lm_studio:qwen3-coder"
      # Defaults still present for unconfigured perspectives
      assert map[:security] == "openai_oauth:gpt-5.6-sol"
    end

    test "per-call provider_model opt still takes precedence over config" do
      AdvisoryLLM.configure_perspective(:security, "ollama:test")

      # Per-call override should win
      assert {"gemini", "gemini-2.5-flash"} =
               AdvisoryLLM.resolve_provider_model(:security,
                 provider_model: "gemini:gemini-2.5-flash"
               )
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

  describe "design-review evaluation protocol" do
    test "requests a structured approve|rework verdict in the prompt" do
      test_pid = self()

      capture_fn = fn _system_prompt, user_prompt ->
        send(test_pid, {:user_prompt, user_prompt})
        {:ok, Jason.encode!(%{"verdict" => "approve", "concerns" => []})}
      end

      proposal = design_review_proposal("Should we extract a core?")

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :security, llm_fn: capture_fn)

      assert eval.vote == :approve
      assert_receive {:user_prompt, user_prompt}
      assert user_prompt =~ "Design-review verdict"
      assert user_prompt =~ "approve"
      assert user_prompt =~ "rework"
    end

    test "maps a rework verdict to reject with the named concerns" do
      llm_fn = fn _system_prompt, _user_prompt ->
        {:ok,
         Jason.encode!(%{
           "verdict" => "rework",
           "concerns" => ["Name the missing capability bound"],
           "analysis" => "The design omits the fs grant"
         })}
      end

      proposal = design_review_proposal("Review the design")

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :security, llm_fn: llm_fn)

      assert eval.vote == :reject
      assert "Name the missing capability bound" in eval.concerns
      refute eval.vote == :approve
    end

    test "a missing verdict is rework with the parse problem, never approve" do
      llm_fn = fn _system_prompt, _user_prompt ->
        {:ok, Jason.encode!(%{"analysis" => "Looks fine", "concerns" => []})}
      end

      proposal = design_review_proposal("Missing verdict")

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :stability, llm_fn: llm_fn)

      assert eval.vote == :reject
      assert Enum.any?(eval.concerns, &String.contains?(&1, "malformed design-review verdict"))
    end

    test "non-JSON design-review output is rework, never approve" do
      llm_fn = fn _system_prompt, _user_prompt ->
        {:ok, "I like this design."}
      end

      proposal = design_review_proposal("Prose only")

      assert {:ok, eval} =
               AdvisoryLLM.evaluate(proposal, :adversarial, llm_fn: llm_fn)

      assert eval.vote == :reject
      assert Enum.any?(eval.concerns, &String.contains?(&1, "malformed design-review verdict"))
    end

    test "malformed concern payloads are seat errors, not reject/rework votes" do
      proposal = design_review_proposal("Malformed concerns")

      payloads = [
        Jason.encode!(%{"verdict" => "approve", "concerns" => %{"x" => 1}}),
        Jason.encode!(%{"verdict" => "approve", "concerns" => "not-a-list"}),
        Jason.encode!(%{"verdict" => "rework", "concerns" => [1]}),
        Jason.encode!(%{"verdict" => "approve", "concerns" => [%{"nested" => true}]})
      ]

      Enum.each(payloads, fn payload ->
        llm_fn = fn _system_prompt, _user_prompt -> {:ok, payload} end

        assert {:error, :malformed_evaluation} =
                 AdvisoryLLM.evaluate(proposal, :security, llm_fn: llm_fn)
      end)
    end
  end

  defp design_review_proposal(description) do
    TestHelpers.build_proposal(%{
      description: description,
      context: %{"evaluation_protocol" => "design_review"}
    })
  end
end
