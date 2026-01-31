defmodule Arbor.AI.CliImpl do
  @moduledoc """
  CLI-based LLM implementation with automatic fallback chain.

  Uses CLI tools (Claude Code, Codex, Gemini CLI, etc.) for "free" LLM access
  via existing subscriptions. Falls back through configured providers until
  one succeeds.

  ## Provider Chain

  The fallback chain is configurable via `Arbor.AI.Config.cli_fallback_chain/0`:

  1. anthropic - Claude Code CLI (`claude`)
  2. openai - Codex CLI (`codex`)
  3. gemini - Gemini CLI (`gemini`)
  4. qwen - Qwen CLI (`qwen`)
  5. opencode - Opencode CLI (`opencode`)
  6. lmstudio - Local LMStudio HTTP (always available fallback)

  ## Configuration

  Configure the fallback chain order:

      config :arbor_ai,
        cli_fallback_chain: [:anthropic, :openai, :gemini, :lmstudio]

  Override per-call:

      Arbor.AI.generate_text(prompt, backend: :cli, fallback_chain: [:gemini, :lmstudio])

  ## Usage

      # Use default fallback chain
      {:ok, result} = CliImpl.generate_text("Hello")

      # Request specific provider
      {:ok, result} = CliImpl.generate_text("Hello", provider: :gemini)

      # Override fallback chain for this call
      {:ok, result} = CliImpl.generate_text("Hello", fallback_chain: [:lmstudio])
  """

  alias Arbor.AI.BudgetTracker
  alias Arbor.AI.Config
  alias Arbor.AI.QuotaTracker
  alias Arbor.AI.Response
  alias Arbor.AI.SessionRegistry
  alias Arbor.Signals

  alias Arbor.AI.Backends.{
    ClaudeCli,
    CodexCli,
    GeminiCli,
    LMStudio,
    OpencodeCli,
    QwenCli
  }

  require Logger

  # Provider -> Backend module mapping
  @backends %{
    anthropic: ClaudeCli,
    openai: CodexCli,
    gemini: GeminiCli,
    qwen: QwenCli,
    opencode: OpencodeCli,
    lmstudio: LMStudio
  }

  # Default fallback chain - can be overridden via config
  @default_fallback_chain [:anthropic, :openai, :gemini, :lmstudio]

  @doc """
  Generate text using CLI backends with automatic fallback.

  ## Options

  - `:provider` - Specific provider to use (skips fallback chain)
  - `:fallback_chain` - Override the fallback chain for this call
  - `:model` - Model selection (provider-specific)
  - `:system_prompt` - System prompt for context
  - `:max_tokens` - Maximum tokens to generate
  - `:temperature` - Sampling temperature
  - `:timeout` - Timeout in milliseconds (default: 300_000)
  - `:new_session` - Force new session (default: false)
  - `:session_context` - Context key for multi-turn sessions (e.g., "deliberation_123")
  - `:session_id` - Explicit session ID to resume (overrides session_context lookup)

  ## Session Management

  When `session_context` is provided, the system automatically:
  1. Looks up existing session_id for this {provider, context} pair
  2. Passes session_id to the backend for continuation
  3. Stores the resulting session_id after successful response

  This enables multi-turn conversations without manual session tracking.

  ## Returns

  - `{:ok, %Response{}}` - Success with response data
  - `{:error, :all_providers_failed}` - All providers failed
  - `{:error, reason}` - Specific error
  """
  @spec generate_text(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def generate_text(prompt, opts \\ []) do
    Logger.debug("CliImpl generating text",
      prompt_length: String.length(prompt),
      provider: opts[:provider]
    )

    provider = opts[:provider]
    emit_request_started(provider, String.length(prompt))
    start_time = System.monotonic_time(:millisecond)

    result =
      case provider do
        nil ->
          # No provider specified - use fallback chain
          chain = Keyword.get(opts, :fallback_chain, Config.cli_fallback_chain())
          generate_with_fallback(prompt, opts, chain)

        provider when is_atom(provider) ->
          # Specific provider requested
          call_provider(provider, prompt, opts)

        provider when is_binary(provider) ->
          call_provider(String.to_existing_atom(provider), prompt, opts)
      end

    duration_ms = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, response} ->
        emit_request_completed(provider, duration_ms, response)
        result

      {:error, reason} ->
        emit_request_failed(provider, reason)
        result
    end
  end

  @doc """
  Generate text with a specific provider, no fallback.
  """
  @spec generate_with_provider(atom(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, term()}
  def generate_with_provider(provider, prompt, opts \\ []) do
    call_provider(provider, prompt, opts)
  end

  @doc """
  Returns the configured fallback chain.
  """
  @spec fallback_chain() :: [atom()]
  def fallback_chain do
    Config.cli_fallback_chain()
  end

  @doc """
  Returns the default fallback chain (ignoring config).
  """
  @spec default_fallback_chain() :: [atom()]
  def default_fallback_chain do
    @default_fallback_chain
  end

  @doc """
  Returns the backend module for a provider.
  """
  @spec backend_module(atom()) :: module() | nil
  def backend_module(provider) do
    Map.get(@backends, provider)
  end

  @doc """
  Returns all available provider atoms.
  """
  @spec available_providers() :: [atom()]
  def available_providers do
    Map.keys(@backends)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_with_fallback(_prompt, _opts, []) do
    Logger.error("All LLM providers failed")
    {:error, :all_providers_failed}
  end

  defp generate_with_fallback(prompt, opts, [provider | rest]) do
    # Check quota before trying
    if QuotaTracker.available?(provider) do
      case call_provider(provider, prompt, opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          Logger.warning("LLM provider failed, trying next",
            provider: provider,
            reason: inspect(reason, limit: 100),
            remaining: rest
          )

          if rest != [] do
            emit_provider_fallback(provider, hd(rest), reason)
          end

          generate_with_fallback(prompt, opts, rest)
      end
    else
      Logger.info("Skipping quota-exhausted provider", provider: provider)
      emit_quota_exhausted(provider)
      generate_with_fallback(prompt, opts, rest)
    end
  end

  defp call_provider(provider, prompt, opts) do
    case Map.get(@backends, provider) do
      nil ->
        {:error, {:unsupported_provider, provider}}

      module ->
        # Session management: look up existing session if context provided
        opts = inject_session_id(provider, module, opts)

        try do
          case module.generate_text(prompt, opts) do
            {:ok, response} = success ->
              # Store session_id for future calls
              store_session_id(provider, module, opts, response)

              # Record usage for budget tracking
              record_budget_usage(provider, opts, response)

              success

            error ->
              error
          end
        rescue
          e ->
            Logger.warning("Provider raised exception",
              provider: provider,
              error: inspect(e)
            )

            {:error, {:provider_error, provider, e}}
        end
    end
  end

  # Look up and inject session_id if session_context is provided
  defp inject_session_id(provider, module, opts) do
    session_context = Keyword.get(opts, :session_context)

    cond do
      # No session context - nothing to inject
      is_nil(session_context) ->
        opts

      # Already has session_id - don't override
      Keyword.has_key?(opts, :session_id) ->
        opts

      # Backend doesn't support sessions
      not module.supports_sessions?() ->
        opts

      # Look up existing session
      true ->
        case SessionRegistry.get_session_id(provider, session_context) do
          nil ->
            # No existing session - force new to avoid resuming a random session.
            # The returned session_id will be stored by store_session_id/4
            # and used for subsequent calls via this context.
            Logger.debug("Creating new session for context",
              provider: provider,
              context: session_context
            )

            Keyword.put(opts, :new_session, true)

          session_id ->
            Logger.debug("Resuming session",
              provider: provider,
              context: session_context,
              session_id: String.slice(session_id, 0, 12) <> "..."
            )

            Keyword.put(opts, :session_id, session_id)
        end
    end
  end

  # Store session_id after successful response
  defp store_session_id(provider, module, opts, response) do
    session_context = Keyword.get(opts, :session_context)

    with true <- session_context != nil,
         true <- module.supports_sessions?(),
         session_id when is_binary(session_id) <- module.extract_session_id(response) do
      do_store_session(provider, session_context, session_id)
    else
      _ -> :ok
    end
  end

  defp do_store_session(provider, session_context, session_id) do
    case SessionRegistry.get_session_id(provider, session_context) do
      ^session_id ->
        # Same session - just update last_used_at
        SessionRegistry.touch(provider, session_context)

      _ ->
        # New or different session - store it
        SessionRegistry.store(provider, session_context, session_id)
    end
  end

  # Record usage for budget tracking (only if BudgetTracker is running)
  defp record_budget_usage(provider, opts, response) do
    if BudgetTracker.started?() do
      model = Keyword.get(opts, :model, "unknown")
      usage = Map.get(response, :usage, %{})

      BudgetTracker.record_usage(provider, %{
        model: to_string(model),
        input_tokens: Map.get(usage, :input_tokens, 0),
        output_tokens: Map.get(usage, :output_tokens, 0)
      })
    end
  end

  # ============================================================================
  # Signal Emissions
  # ============================================================================

  defp emit_request_started(provider, prompt_length) do
    Signals.emit(:ai, :request_started, %{
      provider: provider_string(provider),
      prompt_length: prompt_length
    })
  end

  defp emit_request_completed(provider, duration_ms, response) do
    Signals.emit(:ai, :request_completed, %{
      provider: provider_string(provider),
      duration_ms: duration_ms,
      response_length: response_length(response)
    })
  end

  defp emit_request_failed(provider, reason) do
    Signals.emit(:ai, :request_failed, %{
      provider: provider_string(provider),
      reason: inspect(reason, limit: 200)
    })
  end

  defp emit_provider_fallback(from_provider, to_provider, reason) do
    Signals.emit(:ai, :provider_fallback, %{
      from_provider: to_string(from_provider),
      to_provider: to_string(to_provider),
      reason: inspect(reason, limit: 200)
    })
  end

  defp emit_quota_exhausted(provider) do
    Signals.emit(:ai, :quota_exhausted, %{
      provider: to_string(provider)
    })
  end

  defp provider_string(nil), do: "auto"
  defp provider_string(provider), do: to_string(provider)

  defp response_length(%{text: text}) when is_binary(text), do: String.length(text)
  defp response_length(_), do: 0
end
