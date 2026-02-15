defmodule Arbor.Consensus.LLMBridge do
  @moduledoc """
  Thin runtime bridge from arbor_consensus to UnifiedLLM.

  Bridges the hierarchy gap: arbor_consensus (Level 1) cannot compile-time
  depend on arbor_orchestrator (Standalone). Uses `Code.ensure_loaded?/1` +
  `apply/3` for dynamic module loading.

  When UnifiedLLM modules are available, constructs proper Request/Message
  structs with system/user prompt separation and delegates to
  `Client.complete/3`.

  When UnifiedLLM is not loaded, falls back to `Arbor.AI.generate_text/2`
  with `backend: :cli`.

  ## Usage

      case LLMBridge.complete(system_prompt, user_prompt, provider: "anthropic", model: "claude-sonnet-4-5-20250929") do
        {:ok, text} -> # process response text
        {:error, reason} -> # handle error
      end
  """

  require Logger

  @client_mod Arbor.Orchestrator.UnifiedLLM.Client
  @request_mod Arbor.Orchestrator.UnifiedLLM.Request
  @message_mod Arbor.Orchestrator.UnifiedLLM.Message
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

  Returns `{:ok, response_text}` or `{:error, reason}`.

  ## Options

  - `:provider` — provider string (e.g., `"anthropic"`, `"openai"`)
  - `:model` — model identifier (e.g., `"claude-sonnet-4-5-20250929"`)
  - `:max_tokens` — max response tokens (default: 4096)
  - `:temperature` — sampling temperature (default: 0.7)
  - `:timeout` — call timeout in ms (not used directly, caller manages)
  - `:backend` — `:cli` to force CLI backend (agents can read source code),
    `:api` to force UnifiedLLM API path. Default: auto-detect.
  """
  @spec complete(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def complete(system_prompt, user_prompt, opts \\ []) do
    backend = Keyword.get(opts, :backend)

    cond do
      backend == :cli ->
        complete_via_fallback(system_prompt, user_prompt, opts)

      backend == :api and available?() ->
        complete_via_unified(system_prompt, user_prompt, opts)

      available?() ->
        complete_via_unified(system_prompt, user_prompt, opts)

      true ->
        complete_via_fallback(system_prompt, user_prompt, opts)
    end
  catch
    :exit, reason ->
      Logger.warning("LLMBridge.complete exit: #{inspect(reason)}")
      {:error, {:exit, reason}}

    kind, reason ->
      Logger.warning("LLMBridge.complete #{kind}: #{inspect(reason)}")
      {:error, {kind, reason}}
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
    request = struct!(@request_mod, %{
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
        {:ok, response.text}

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
        backend: :cli
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
