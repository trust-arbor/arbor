defmodule Arbor.AI do
  @moduledoc """
  Unified LLM interface for Arbor.

  Provides a simple facade for text generation with automatic routing
  between API backends (ReqLLM, paid) and CLI backends (Claude Code, etc., "free").

  ## Quick Start

      # Generate text with default settings (uses routing strategy)
      {:ok, result} = Arbor.AI.generate_text("What is 2+2?")
      result.text
      #=> "2+2 equals 4."

      # Explicitly use CLI backend (free via subscriptions)
      {:ok, result} = Arbor.AI.generate_text("Hello", backend: :cli)

      # Explicitly use API backend (paid)
      {:ok, result} = Arbor.AI.generate_text("Hello", backend: :api)

      # With custom options
      {:ok, result} = Arbor.AI.generate_text(
        "Analyze this code for security issues.",
        system_prompt: "You are a security reviewer.",
        max_tokens: 2048,
        temperature: 0.3
      )

  ## Backend Options

  - `:backend` - Backend selection:
    - `:api` - Use ReqLLM (paid API calls)
    - `:cli` - Use CLI agents (Claude Code, Codex, Gemini CLI, etc.)
    - `:auto` - Use routing strategy to decide (default)

  ## Configuration

  Configure defaults in your config:

      config :arbor_ai,
        # API settings
        default_provider: :anthropic,
        default_model: "claude-sonnet-4-5-20250514",
        timeout: 60_000,

        # Routing
        default_backend: :auto,
        routing_strategy: :cost_optimized,  # Try CLI first

        # CLI fallback chain
        cli_fallback_chain: [:anthropic, :openai, :gemini, :lmstudio]

  API keys are loaded from environment variables:

      ANTHROPIC_API_KEY=sk-ant-...
      OPENAI_API_KEY=sk-...
  """

  @behaviour Arbor.Contracts.API.AI

  alias Arbor.AI.{BackendRegistry, BudgetTracker, CliImpl, Config, Response, Router, UsageStats}

  require Logger

  # ── Authorized API (for agent callers) ──

  @doc """
  Generate text with authorization check.

  Verifies the agent has the `arbor://ai/request/{provider}` capability before
  making the LLM request. Use this for agent-initiated AI requests where
  authorization should be enforced.

  This protects against unauthorized data exfiltration (prompts sent to external APIs)
  and cost overruns (paid API calls).

  ## Parameters

  - `agent_id` - The agent's ID for capability lookup
  - `prompt` - The prompt to send to the LLM
  - `opts` - Options passed to `generate_text/2`, plus:
    - `:trace_id` - Optional trace ID for correlation
    - `:provider` - Provider to use (determines capability URI), default: "auto"

  ## Returns

  - `{:ok, result}` on success (same as `generate_text/2`)
  - `{:error, {:unauthorized, reason}}` if agent lacks the required capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other errors
  """
  @spec authorize_generate(String.t(), String.t(), keyword()) ::
          {:ok, map()}
          | {:ok, :pending_approval, String.t()}
          | {:error, {:unauthorized, term()} | term()}
  def authorize_generate(agent_id, prompt, opts \\ []) do
    provider = extract_provider(opts)
    resource = "arbor://ai/request/#{provider}"
    {trace_id, opts} = Keyword.pop(opts, :trace_id)

    case Arbor.Security.authorize(agent_id, resource, :request, trace_id: trace_id) do
      {:ok, :authorized} ->
        generate_text(prompt, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, reason} ->
        {:error, {:unauthorized, reason}}
    end
  end

  # Extract provider from opts for capability URI
  defp extract_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> "auto"
      provider when is_atom(provider) -> Atom.to_string(provider)
      provider when is_binary(provider) -> provider
    end
  end

  # ── Unchecked API (for system callers) ──

  @impl true
  @spec generate_text(String.t(), keyword()) ::
          {:ok, Arbor.Contracts.API.AI.result()} | {:error, term()}
  def generate_text(prompt, opts \\ []) do
    backend = Router.select_backend(opts)

    Logger.debug("Arbor.AI routing to #{backend} backend")

    case backend do
      :cli ->
        generate_text_via_cli(prompt, opts)

      :api ->
        generate_text_via_api(prompt, opts)
    end
  end

  @doc """
  Generate text using the CLI backend directly.

  Bypasses routing and uses CLI agents (Claude Code, Codex, etc.).
  """
  @spec generate_text_via_cli(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_text_via_cli(prompt, opts \\ []) do
    case CliImpl.generate_text(prompt, opts) do
      {:ok, response} ->
        {:ok, normalize_response(response)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate text using the API backend directly.

  Bypasses routing and uses ReqLLM (paid API calls).
  """
  @spec generate_text_via_api(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def generate_text_via_api(prompt, opts \\ []) do
    provider = Keyword.get(opts, :provider, Config.default_provider())
    model = Keyword.get(opts, :model, Config.default_model())
    system_prompt = Keyword.get(opts, :system_prompt)
    max_tokens = Keyword.get(opts, :max_tokens, 1024)
    temperature = Keyword.get(opts, :temperature, 0.7)

    messages = build_messages(prompt, system_prompt)
    model_spec = build_model_spec(provider, model)

    req_opts =
      [
        max_tokens: max_tokens,
        temperature: temperature
      ]
      |> maybe_add_system_prompt(system_prompt)

    Logger.debug("Arbor.AI API generating with #{provider}:#{model}")

    case ReqLLM.generate_text(model_spec, messages, req_opts) do
      {:ok, response} ->
        {:ok, format_api_response(response, provider, model)}

      {:error, reason} ->
        Logger.warning("Arbor.AI API generation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Check available backends.

  Returns a list of available backends with their status.
  """
  @spec available_backends() :: [atom()]
  def available_backends do
    BackendRegistry.available_backends()
  end

  # ── Task-Aware Routing ──

  @doc """
  Route a task to an appropriate backend and model.

  Delegates to `Router.route_task/2`. Accepts either a prompt string
  (which gets classified) or a TaskMeta struct.

  ## Options

  - `:model` - Manual override `{backend, model}` - bypasses routing entirely
  - `:min_trust` - Override minimum trust level
  - `:exclude` - List of backends to exclude

  ## Returns

  - `{:ok, {backend, model}}` - Selected backend and model
  - `{:error, reason}` - Routing failed

  ## Examples

      {:ok, {:anthropic, "claude-opus-4-20250514"}} = Arbor.AI.route_task("Fix auth vulnerability")
  """
  @spec route_task(Arbor.AI.TaskMeta.t() | String.t(), keyword()) ::
          {:ok, {atom(), String.t()}} | {:error, term()}
  def route_task(task_or_prompt, opts \\ []) do
    Router.route_task(task_or_prompt, opts)
  end

  @doc """
  Route an embedding request to an appropriate provider.

  Delegates to `Router.route_embedding/1`.

  ## Options

  - `:prefer` - `:local`, `:cloud`, or `:auto` (default: configured preference)

  ## Returns

  - `{:ok, {backend, model}}` - Selected embedding provider and model
  - `{:error, :no_embedding_providers}` - No providers available

  ## Examples

      {:ok, {:ollama, "nomic-embed-text"}} = Arbor.AI.route_embedding()
      {:ok, {:openai, "text-embedding-3-small"}} = Arbor.AI.route_embedding(prefer: :cloud)
  """
  @spec route_embedding(keyword()) :: {:ok, {atom(), String.t()}} | {:error, term()}
  def route_embedding(opts \\ []) do
    Router.route_embedding(opts)
  end

  @doc """
  Classify a prompt into task metadata for routing decisions.

  Delegates to `TaskMeta.classify/2`.

  ## Examples

      meta = Arbor.AI.classify_task("Fix the security vulnerability in auth.ex")
      meta.risk_level  #=> :critical
      meta.domain      #=> :security
  """
  @spec classify_task(String.t(), keyword()) :: Arbor.AI.TaskMeta.t()
  def classify_task(prompt, opts \\ []) do
    Arbor.AI.TaskMeta.classify(prompt, opts)
  end

  # ── Stats & Observability ──

  @doc """
  Get all routing stats as a map keyed by {backend, model}.

  Delegates to `UsageStats.all_stats/0`.

  ## Examples

      stats = Arbor.AI.routing_stats()
      #=> %{
      #=>   {:anthropic, "claude-opus-4"} => %{requests: 47, successes: 46, ...},
      #=>   {:gemini, "gemini-pro"} => %{requests: 23, successes: 21, ...}
      #=> }
  """
  @spec routing_stats() :: map()
  def routing_stats do
    UsageStats.all_stats()
  end

  @doc """
  Get stats for a specific backend (aggregated across all models).

  Delegates to `UsageStats.get_stats/1`.

  ## Examples

      stats = Arbor.AI.backend_stats(:anthropic)
      stats.requests    #=> 47
      stats.successes   #=> 46
      stats.avg_latency_ms #=> 2340.5
  """
  @spec backend_stats(atom()) :: map()
  def backend_stats(backend) when is_atom(backend) do
    UsageStats.get_stats(backend)
  end

  @doc """
  Get all backends sorted by success rate (descending).

  Returns a list of `{backend, success_rate}` tuples.

  Delegates to `UsageStats.reliability_ranking/0`.

  ## Examples

      Arbor.AI.reliability_ranking()
      #=> [{:ollama, 0.991}, {:anthropic, 0.979}, {:gemini, 0.913}]
  """
  @spec reliability_ranking() :: [{atom(), float()}]
  def reliability_ranking do
    UsageStats.reliability_ranking()
  end

  @doc """
  Get current budget status.

  Delegates to `BudgetTracker.get_status/0`.

  ## Examples

      {:ok, status} = Arbor.AI.budget_status()
      status.daily_budget      #=> 10.0
      status.spent_today       #=> 2.35
      status.remaining         #=> 7.65
      status.percent_remaining #=> 0.765
  """
  @spec budget_status() :: {:ok, map()} | {:ok, map()}
  def budget_status do
    BudgetTracker.get_status()
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  # Normalize CLI response to contract format
  defp normalize_response(%Response{} = response) do
    %{
      text: response.text || "",
      usage: response.usage || %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
      model: response.model,
      provider: response.provider
    }
  end

  defp normalize_response(response) when is_map(response) do
    %{
      text: response[:text] || response["text"] || "",
      usage: response[:usage] || response["usage"] || %{},
      model: response[:model] || response["model"],
      provider: response[:provider] || response["provider"]
    }
  end

  defp build_messages(prompt, nil) do
    [%{role: "user", content: prompt}]
  end

  defp build_messages(prompt, _system_prompt) do
    # System prompt is passed via opts, not messages for ReqLLM
    [%{role: "user", content: prompt}]
  end

  defp maybe_add_system_prompt(opts, nil), do: opts
  defp maybe_add_system_prompt(opts, system), do: Keyword.put(opts, :system_prompt, system)

  defp build_model_spec(provider, model) do
    "#{provider}:#{model}"
  end

  defp format_api_response(response, provider, model) do
    %{
      text: extract_text(response),
      usage: extract_usage(response),
      model: model,
      provider: provider
    }
  end

  defp extract_text(response) when is_binary(response), do: response

  defp extract_text(response) when is_struct(response) do
    extract_text(Map.from_struct(response))
  end

  defp extract_text(response) when is_map(response) do
    extract_text_from_map(response)
  end

  defp extract_text(_response), do: ""

  defp extract_text_from_map(%{text: text}) when is_binary(text), do: text
  defp extract_text_from_map(%{content: content}) when is_binary(content), do: content

  defp extract_text_from_map(%{message: %{content: content}}) when is_binary(content),
    do: content

  defp extract_text_from_map(_), do: ""

  defp extract_usage(response) when is_map(response) do
    usage = Map.get(response, :usage) || %{}

    %{
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0),
      total_tokens:
        Map.get(usage, :total_tokens) ||
          Map.get(usage, :input_tokens, 0) + Map.get(usage, :output_tokens, 0)
    }
  end

  defp extract_usage(_), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
end
