defmodule Arbor.Consensus.LLMBridge do
  @moduledoc """
  Thin runtime bridge from arbor_consensus to LLM.

  Bridges the hierarchy gap: arbor_consensus (Level 1) cannot compile-time
  depend on arbor_orchestrator (Standalone). Uses `Code.ensure_loaded?/1` +
  `apply/3` for dynamic module loading.

  When UnifiedLLM modules are available, constructs proper Request/Message
  structs with system/user prompt separation and delegates to
  `Client.complete/3`.

  When UnifiedLLM is not loaded, falls back to `Arbor.AI.generate_text/2`
  with `runtime: :acp`.

  ## Usage

      case LLMBridge.complete(system_prompt, user_prompt, provider: "anthropic", model: "claude-sonnet-4-5-20250929") do
        {:ok, text} -> # process response text
        {:error, reason} -> # handle error
      end
  """

  require Logger

  # Client still lives in arbor_orchestrator (will move to arbor_llm in a
  # later session). Request and Message moved to arbor_llm in Session 1.
  @client_mod Arbor.LLM.Client
  @request_mod Arbor.LLM.Request
  @message_mod Arbor.LLM.Message
  @ai_mod Arbor.AI

  @doc """
  Returns true if UnifiedLLM modules are loaded and available.
  """
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(@client_mod) and
      Code.ensure_loaded?(@request_mod) and
      Code.ensure_loaded?(@message_mod)
  end

  @doc """
  Complete an LLM request with system and user prompt separation.

  Returns `{:ok, %{text: text, duration_ms: ms}}` or `{:error, reason}`.

  ## Options

  - `:provider` — provider string (e.g., `"anthropic"`, `"openai"`)
  - `:model` — model identifier (e.g., `"claude-sonnet-4-5-20250929"`)
  - `:max_tokens` — max response tokens (default: 4096)
  - `:temperature` — sampling temperature (default: 0.7)
  - `:timeout` — call timeout in ms (not used directly, caller manages)
  - `:runtime` — `:acp` to force CLI subprocess (agents can read source
    code), `:arbor` to force in-BEAM HTTP via arbor_llm. Default:
    auto-detect.
  - `:complete_fun` — internal arity-3 dependency-injection seam used by
    deterministic tests
  """
  @spec complete(String.t(), String.t(), keyword()) ::
          {:ok, %{text: String.t(), duration_ms: non_neg_integer(), usage: map()}}
          | {:error, term()}
  def complete(system_prompt, user_prompt, opts \\ []) do
    provider = Keyword.get(opts, :provider, "unknown")
    model = Keyword.get(opts, :model, "unknown")
    trace_id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    prompt_len = String.length(user_prompt)

    Logger.info(
      "[LLM] trace=#{trace_id} START llm_bridge " <>
        "provider=#{provider} model=#{model} prompt=#{prompt_len} chars"
    )

    start = System.monotonic_time(:millisecond)

    result = dispatch_complete(system_prompt, user_prompt, opts)
    duration_ms = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, text, usage} when is_map(usage) ->
        tokens = Map.get(usage, :total_tokens) || Map.get(usage, "total_tokens") || 0
        cost_str = format_cost_suffix(usage)

        Logger.info(
          "[LLM] trace=#{trace_id} OK    llm_bridge " <>
            "provider=#{provider} model=#{model} " <>
            "duration=#{duration_ms}ms tokens=#{tokens}#{cost_str}"
        )

        {:ok, %{text: text, duration_ms: duration_ms, usage: usage}}

      {:ok, text} ->
        Logger.info(
          "[LLM] trace=#{trace_id} OK    llm_bridge " <>
            "provider=#{provider} model=#{model} duration=#{duration_ms}ms"
        )

        {:ok, %{text: text, duration_ms: duration_ms, usage: %{}}}

      error ->
        Logger.warning(
          "[LLM] trace=#{trace_id} FAIL  llm_bridge " <>
            "provider=#{provider} model=#{model} " <>
            "duration=#{duration_ms}ms error=#{inspect(error)}"
        )

        error
    end
  catch
    :exit, reason ->
      Logger.warning("LLMBridge.complete exit: #{inspect(reason)}")
      {:error, {:exit, reason}}

    kind, reason ->
      Logger.warning("LLMBridge.complete #{kind}: #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  defp dispatch_complete(system_prompt, user_prompt, opts) do
    case Keyword.get(opts, :complete_fun) do
      fun when is_function(fun, 3) ->
        fun.(system_prompt, user_prompt, Keyword.delete(opts, :complete_fun))

      _other ->
        dispatch_runtime(system_prompt, user_prompt, opts)
    end
  end

  defp dispatch_runtime(system_prompt, user_prompt, opts) do
    runtime = Keyword.get(opts, :runtime)

    cond do
      runtime == :acp ->
        complete_via_fallback(system_prompt, user_prompt, opts)

      runtime == :arbor and available?() ->
        complete_via_unified(system_prompt, user_prompt, opts)

      available?() ->
        complete_via_unified(system_prompt, user_prompt, opts)

      true ->
        complete_via_fallback(system_prompt, user_prompt, opts)
    end
  end

  defp format_cost_suffix(usage) do
    with cost when is_number(cost) <- loggable_cost_total(usage),
         formatted when is_binary(formatted) <- format_cost(cost) do
      " cost=$#{formatted}"
    else
      _ -> ""
    end
  end

  defp format_cost(cost) when is_integer(cost), do: Integer.to_string(cost)

  defp format_cost(cost) when is_float(cost) do
    :erlang.float_to_binary(cost, decimals: 4)
  rescue
    ArgumentError -> nil
  end

  defp loggable_cost_total(usage) when is_map(usage) do
    case fetch_usage_value(usage, :cost) do
      cost when is_number(cost) -> cost
      cost when is_map(cost) -> recognized_numeric_total(cost) || top_level_total(usage)
      _other -> top_level_total(usage)
    end
  end

  defp loggable_cost_total(_usage), do: nil

  defp top_level_total(usage) do
    case fetch_usage_value(usage, :total_cost) do
      total when is_number(total) -> total
      _other -> nil
    end
  end

  defp recognized_numeric_total(cost) do
    [:total, "total", :total_cost, "total_cost"]
    |> Enum.find_value(fn key ->
      case Map.get(cost, key) do
        value when is_number(value) -> value
        _other -> nil
      end
    end)
  end

  defp fetch_usage_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  # ============================================================================
  # UnifiedLLM Path
  # ============================================================================

  defp complete_via_unified(system_prompt, user_prompt, opts) do
    provider = Keyword.get(opts, :provider)
    model = Keyword.get(opts, :model, "claude-sonnet-4-5-20250929")
    max_tokens = Keyword.get(opts, :max_tokens, 4096)
    temperature = Keyword.get(opts, :temperature, 0.7)

    # Build messages via apply/3
    system_msg = apply(@message_mod, :new, [:system, system_prompt])
    user_msg = apply(@message_mod, :new, [:user, user_prompt])

    # Build request struct
    request =
      struct!(@request_mod, %{
        provider: provider,
        model: model,
        messages: [system_msg, user_msg],
        max_tokens: max_tokens,
        temperature: temperature
      })

    # Get or create default client
    client = apply(@client_mod, :default_client, [])

    case apply(@client_mod, :complete, [client, request]) do
      {:ok, response} ->
        {:ok, response.text, response.usage}

      {:error, _reason} = error ->
        error
    end
  end

  # ============================================================================
  # Fallback Path (Arbor.AI)
  # ============================================================================

  # CLI backends available: :anthropic (claude), :openai (codex), :gemini, :lmstudio
  @cli_providers ~w(anthropic openai gemini lmstudio qwen opencode)a

  defp complete_via_fallback(system_prompt, user_prompt, opts) do
    if Code.ensure_loaded?(@ai_mod) do
      # Combine prompts since CLI backends silently drop system_prompt opt
      combined =
        """
        #{system_prompt}

        ---

        #{user_prompt}
        """

      cli_provider = resolve_cli_provider(Keyword.get(opts, :provider))

      ai_opts = [
        max_tokens: Keyword.get(opts, :max_tokens, 4096),
        temperature: Keyword.get(opts, :temperature, 0.7),
        runtime: :acp
      ]

      # Only pass provider if it maps to a real CLI backend;
      # otherwise let CliImpl use its fallback chain
      ai_opts = if cli_provider, do: Keyword.put(ai_opts, :provider, cli_provider), else: ai_opts

      case apply(@ai_mod, :generate_text, [combined, ai_opts]) do
        {:ok, response} ->
          {:ok, response.text}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :no_llm_backend_available}
    end
  end

  # Map API provider strings to CLI backend atoms.
  # Returns nil for providers without CLI backends (uses fallback chain).
  defp resolve_cli_provider(nil), do: nil

  defp resolve_cli_provider(provider) when is_atom(provider) do
    if provider in @cli_providers, do: provider, else: nil
  end

  defp resolve_cli_provider(provider) when is_binary(provider) do
    # Extract provider name (before colon in "provider:model" format)
    name =
      provider
      |> String.split(":")
      |> hd()

    try do
      atom = String.to_existing_atom(name)
      if atom in @cli_providers, do: atom, else: nil
    rescue
      ArgumentError -> nil
    end
  end
end
