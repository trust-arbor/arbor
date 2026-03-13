defmodule Arbor.Gateway.IntentExtractor do
  @moduledoc """
  Extracts structured intent from natural language prompts using a small LLM.

  Phase 2 of the Prompt Pre-Processor pipeline. Runs AFTER data classification
  (Phase 1) so that routing decisions can force local-only model selection when
  sensitive data is detected.

  ## Usage

      classification = PromptClassifier.classify(prompt)
      {:ok, intent} = IntentExtractor.extract(prompt, classification: classification)

  ## Intent Structure

  Returns a map with:
  - `goal` — what the user is trying to accomplish (one sentence)
  - `success_criteria` — concrete, testable assertions for verification
  - `constraints` — what should NOT happen (boundaries, restrictions)
  - `resources` — files, systems, or data involved
  - `risk_level` — low/medium/high based on reversibility and blast radius

  ## Model Selection

  Uses a fast, cheap model (Haiku-class) by default. When the classification
  indicates sensitive data (`:local_only` or `:local_preferred` routing), only
  local models are considered.
  """

  require Logger

  alias Arbor.Gateway.PromptClassifier

  @type intent :: %{
          goal: String.t(),
          success_criteria: [String.t()],
          constraints: [String.t()],
          resources: [String.t()],
          risk_level: :low | :medium | :high
        }

  @fallback_extraction_prompt """
  Analyze this user request and extract structured intent. Respond with valid JSON only.

  {
    "goal": "What the user is trying to accomplish (one sentence)",
    "success_criteria": ["Concrete, testable assertion 1", "Assertion 2"],
    "constraints": ["What should NOT happen"],
    "resources": ["Files, systems, or data involved"],
    "risk_level": "low|medium|high (based on reversibility and blast radius)"
  }

  Rules:
  - goal: Single clear sentence. If ambiguous, state the most likely interpretation.
  - success_criteria: Must be verifiable. "It works" is not a criterion. "HTTP 200 at /health" is.
  - constraints: Infer reasonable constraints even if not stated (e.g. "don't delete data").
  - resources: List specific files, services, or data the task touches.
  - risk_level: low = easily reversible, no shared state. medium = reversible with effort. high = destructive or affects others.

  User request:
  """

  defp extraction_prompt do
    lib = Arbor.Common.SkillLibrary

    if Code.ensure_loaded?(lib) and Process.whereis(lib) != nil do
      case lib.get("intent-extraction") do
        {:ok, skill} when skill.body != "" -> skill.body
        _ -> @fallback_extraction_prompt
      end
    else
      @fallback_extraction_prompt
    end
  rescue
    _ -> @fallback_extraction_prompt
  catch
    :exit, _ -> @fallback_extraction_prompt
  end

  @doc """
  Extract structured intent from a prompt.

  ## Options

  - `:classification` — result from `PromptClassifier.classify/1`. If provided,
    uses the routing recommendation for model selection. If omitted, classifies automatically.
  - `:provider` — override LLM provider (default: auto-selected)
  - `:model` — override LLM model (default: auto-selected)
  - `:timeout` — LLM call timeout in ms (default: 10_000)
  """
  @spec extract(String.t(), keyword()) :: {:ok, intent()} | {:error, term()}
  def extract(prompt, opts \\ []) when is_binary(prompt) do
    classification =
      Keyword.get_lazy(opts, :classification, fn -> PromptClassifier.classify(prompt) end)

    # Use sanitized prompt if sensitive data was found
    effective_prompt =
      if classification.element_count > 0,
        do: classification.sanitized_prompt,
        else: prompt

    llm_prompt = extraction_prompt() <> effective_prompt

    llm_opts = build_llm_opts(classification, opts)

    case call_llm(llm_prompt, llm_opts) do
      {:ok, text} -> parse_intent(text)
      {:error, _} = err -> err
    end
  end

  @doc """
  Extract intent, returning a default/empty intent on failure instead of an error.
  """
  @spec extract_or_default(String.t(), keyword()) :: intent()
  def extract_or_default(prompt, opts \\ []) do
    case extract(prompt, opts) do
      {:ok, intent} ->
        intent

      {:error, reason} ->
        Logger.warning("[IntentExtractor] Falling back to default intent: #{inspect(reason)}")
        default_intent(prompt)
    end
  end

  # -- LLM call via runtime bridge --

  defp call_llm(prompt, opts) do
    ai_mod = Arbor.AI

    if Code.ensure_loaded?(ai_mod) and function_exported?(ai_mod, :generate_text, 2) do
      ai_mod.generate_text(prompt, opts)
      |> normalize_response()
    else
      {:error, :arbor_ai_unavailable}
    end
  rescue
    e -> {:error, {:llm_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:llm_exit, reason}}
  end

  defp normalize_response({:ok, %{text: text}}) when is_binary(text), do: {:ok, text}
  defp normalize_response({:ok, text}) when is_binary(text), do: {:ok, text}
  defp normalize_response({:ok, %{} = result}), do: {:ok, Map.get(result, :text, inspect(result))}
  defp normalize_response({:error, _} = err), do: err

  # -- Model selection --

  defp build_llm_opts(classification, opts) do
    base = [
      max_tokens: 1024,
      temperature: 0.3,
      system_prompt: "You are a precise intent extraction system. Output valid JSON only."
    ]

    # Apply user overrides
    base = if opts[:provider], do: Keyword.put(base, :provider, opts[:provider]), else: base
    base = if opts[:model], do: Keyword.put(base, :model, opts[:model]), else: base
    base = if opts[:timeout], do: Keyword.put(base, :timeout, opts[:timeout]), else: base

    # If no explicit provider/model, select based on routing recommendation
    if not Keyword.has_key?(base, :provider) do
      select_model(classification.routing_recommendation, base)
    else
      base
    end
  end

  defp select_model(:local_only, opts) do
    # Must use local model — try configured local provider
    local = Application.get_env(:arbor_gateway, :local_llm, provider: :ollama, model: "llama3.2")
    opts |> Keyword.put(:provider, local[:provider]) |> Keyword.put(:model, local[:model])
  end

  defp select_model(:local_preferred, opts) do
    # Prefer local but fall back to cloud haiku
    local = Application.get_env(:arbor_gateway, :local_llm, nil)

    if local do
      opts |> Keyword.put(:provider, local[:provider]) |> Keyword.put(:model, local[:model])
    else
      select_model(:any, opts)
    end
  end

  defp select_model(:any, opts) do
    # Use cheap fast model — haiku class
    fast =
      Application.get_env(:arbor_gateway, :intent_llm,
        provider: :anthropic,
        model: "claude-haiku-4-5-20251001"
      )

    opts |> Keyword.put(:provider, fast[:provider]) |> Keyword.put(:model, fast[:model])
  end

  # -- JSON parsing --

  defp parse_intent(text) when is_binary(text) do
    # Extract JSON from potential markdown fences
    json_text = extract_json(text)

    case Jason.decode(json_text) do
      {:ok, map} when is_map(map) ->
        {:ok, normalize_intent(map)}

      {:error, _} ->
        {:error, {:parse_error, "Failed to parse intent JSON from LLM response"}}
    end
  end

  defp extract_json(text) do
    # Strip markdown code fences if present
    case Regex.run(~r/```(?:json)?\s*\n?(.*?)\n?\s*```/s, text) do
      [_, json] -> String.trim(json)
      _ -> String.trim(text)
    end
  end

  defp normalize_intent(map) do
    %{
      goal: Map.get(map, "goal", ""),
      success_criteria: normalize_list(Map.get(map, "success_criteria", [])),
      constraints: normalize_list(Map.get(map, "constraints", [])),
      resources: normalize_list(Map.get(map, "resources", [])),
      risk_level: normalize_risk(Map.get(map, "risk_level", "low"))
    }
  end

  defp normalize_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp normalize_list(str) when is_binary(str), do: [str]
  defp normalize_list(_), do: []

  defp normalize_risk("high"), do: :high
  defp normalize_risk("medium"), do: :medium
  defp normalize_risk(_), do: :low

  defp default_intent(prompt) do
    %{
      goal: String.slice(prompt, 0, 200),
      success_criteria: [],
      constraints: [],
      resources: [],
      risk_level: :low
    }
  end
end
