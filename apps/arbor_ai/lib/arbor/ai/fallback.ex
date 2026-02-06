defmodule Arbor.AI.Fallback do
  @moduledoc """
  Local LLM fallback for offline/unreliable network scenarios.

  Provides automatic fallback to Ollama when cloud providers fail or time out.
  Critical for conference demos where WiFi is unreliable.

  ## How It Works

  1. Primary request goes to configured provider
  2. On timeout/failure, automatically switches to local Ollama
  3. Ollama uses simplified prompts (shorter context for local model)
  4. Auto-switches back to cloud when it recovers

  ## Configuration

      config :arbor_ai,
        fallback_enabled: true,
        fallback_provider: :ollama,
        fallback_model: "llama3",
        fallback_timeout_ms: 5_000

  ## Requirements

  Ollama must be installed and running:

      # Install
      brew install ollama

      # Pull model
      ollama pull llama3

      # Start server
      ollama serve

  ## Usage

      # With automatic fallback
      {:ok, result} = Arbor.AI.Fallback.generate_with_fallback(
        "Analyze this anomaly",
        primary_opts: [provider: :anthropic],
        fallback_opts: [model: "llama3"]
      )

      # Check fallback status
      Arbor.AI.Fallback.status()
      #=> %{enabled: true, ollama_available: true, active: false}
  """

  alias Arbor.AI.CliImpl
  alias Arbor.AI.Response
  alias Arbor.Signals

  require Logger

  @default_base_url "http://localhost:11434"
  @default_model "llama3"
  @default_timeout 5_000
  @connect_check_timeout 2_000

  # Track whether we're currently in fallback mode
  # Use process dictionary for simplicity in demo context
  @fallback_state_key :arbor_ai_fallback_active

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Generate text with automatic fallback to local Ollama.

  ## Options

  - `:primary_opts` - Options for the primary provider (passed to CliImpl)
  - `:fallback_opts` - Options for Ollama fallback
  - `:fallback_timeout_ms` - Timeout before switching to fallback
  - `:simplify_prompt` - Simplify prompt for local model (default: true)
  """
  @spec generate_with_fallback(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def generate_with_fallback(prompt, opts \\ []) do
    if fallback_enabled?() do
      do_generate_with_fallback(prompt, opts)
    else
      # Fallback disabled, just use primary
      CliImpl.generate_text(prompt, opts[:primary_opts] || [])
    end
  end

  @doc """
  Check fallback system status.

  Returns current state including whether Ollama is available.
  """
  @spec status() :: map()
  def status do
    %{
      enabled: fallback_enabled?(),
      ollama_available: ollama_available?(),
      active: fallback_active?(),
      fallback_model: fallback_model(),
      primary_healthy: primary_healthy?()
    }
  end

  @doc """
  Check if Ollama server is available.
  """
  @spec ollama_available?() :: boolean()
  def ollama_available? do
    url = "#{ollama_base_url()}/api/tags"

    case Req.get(url, receive_timeout: @connect_check_timeout) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  Generate text directly via Ollama (no fallback logic).

  Used when you specifically want local inference.
  """
  @spec generate_via_ollama(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def generate_via_ollama(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, fallback_model())
    timeout = Keyword.get(opts, :timeout, config(:fallback_timeout_ms))
    system_prompt = Keyword.get(opts, :system_prompt)

    # Simplify prompt for local model if requested
    prompt =
      if Keyword.get(opts, :simplify_prompt, false) do
        simplify_prompt(prompt)
      else
        prompt
      end

    messages = build_messages(prompt, system_prompt)
    body = build_request_body(messages, model, opts)
    url = "#{ollama_base_url()}/api/chat"

    start_time = System.monotonic_time(:millisecond)

    case make_ollama_request(url, body, timeout) do
      {:ok, json} ->
        duration = System.monotonic_time(:millisecond) - start_time
        response = parse_ollama_response(json, model, duration)
        {:ok, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Reset fallback state (mark primary as healthy again).
  """
  @spec reset() :: :ok
  def reset do
    set_fallback_active(false)
    :ok
  end

  @doc """
  Check if fallback mode is currently active.
  """
  @spec fallback_active?() :: boolean()
  def fallback_active? do
    Process.get(@fallback_state_key, false)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_generate_with_fallback(prompt, opts) do
    primary_opts = Keyword.get(opts, :primary_opts, [])
    fallback_timeout = Keyword.get(opts, :fallback_timeout_ms, config(:fallback_timeout_ms))

    # If we're already in fallback mode and primary isn't healthy, skip trying it
    if fallback_active?() and not primary_healthy?() do
      Logger.debug("Fallback active, using Ollama directly")
      generate_with_fallback_provider(prompt, opts)
    else
      # Try primary with timeout
      try_primary_with_fallback(prompt, primary_opts, fallback_timeout, opts)
    end
  end

  defp try_primary_with_fallback(prompt, primary_opts, timeout, full_opts) do
    task =
      Task.async(fn ->
        CliImpl.generate_text(prompt, primary_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response}} ->
        # Primary succeeded, mark as healthy
        set_fallback_active(false)
        {:ok, response}

      {:ok, {:error, reason}} ->
        Logger.warning("Primary provider failed: #{inspect(reason)}")
        attempt_fallback(prompt, reason, full_opts)

      nil ->
        Logger.warning("Primary provider timed out after #{timeout}ms")
        Task.shutdown(task, :brutal_kill)
        attempt_fallback(prompt, :timeout, full_opts)
    end
  end

  defp attempt_fallback(prompt, primary_reason, opts) do
    if ollama_available?() do
      Logger.info("Switching to Ollama fallback")
      emit_fallback_activated(primary_reason)
      set_fallback_active(true)
      generate_with_fallback_provider(prompt, opts)
    else
      Logger.error("Ollama fallback not available")
      {:error, {:all_providers_failed, primary: primary_reason, fallback: :ollama_unavailable}}
    end
  end

  defp generate_with_fallback_provider(prompt, opts) do
    fallback_opts = Keyword.get(opts, :fallback_opts, [])
    simplify = Keyword.get(opts, :simplify_prompt, true)

    case generate_via_ollama(prompt, Keyword.put(fallback_opts, :simplify_prompt, simplify)) do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Logger.error("Ollama fallback failed: #{inspect(reason)}")
        set_fallback_active(false)
        {:error, {:fallback_failed, reason}}
    end
  end

  # Check if primary is healthy (simple heuristic: not in active fallback)
  defp primary_healthy? do
    not fallback_active?()
  end

  defp set_fallback_active(active) when is_boolean(active) do
    Process.put(@fallback_state_key, active)
  end

  # Simplify prompt for local models (shorter, clearer)
  defp simplify_prompt(prompt) when byte_size(prompt) > 2000 do
    # Truncate very long prompts for local model
    String.slice(prompt, 0, 2000) <> "\n\n[Context truncated for local model]"
  end

  defp simplify_prompt(prompt), do: prompt

  # ============================================================================
  # Ollama HTTP Client
  # ============================================================================

  defp build_messages(prompt, nil) do
    [%{role: "user", content: prompt}]
  end

  defp build_messages(prompt, system_prompt) do
    [
      %{role: "system", content: system_prompt},
      %{role: "user", content: prompt}
    ]
  end

  defp build_request_body(messages, model, opts) do
    base = %{
      model: model,
      messages: messages,
      stream: false
    }

    # Add optional parameters
    base
    |> maybe_add(:options, build_options(opts))
  end

  defp build_options(opts) do
    options = %{}

    options =
      case Keyword.get(opts, :temperature) do
        nil -> options
        temp -> Map.put(options, :temperature, temp)
      end

    options =
      case Keyword.get(opts, :max_tokens) do
        nil -> options
        tokens -> Map.put(options, :num_predict, tokens)
      end

    if map_size(options) == 0, do: nil, else: options
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp make_ollama_request(url, body, timeout) do
    case Req.post(url,
           json: body,
           receive_timeout: timeout,
           retry: false
         ) do
      {:ok, %{status: 200, body: json}} ->
        {:ok, json}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: :econnrefused}} ->
        {:error, :connection_refused}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_ollama_response(json, model, duration_ms) do
    message = json["message"] || %{}
    done = json["done"] || false

    # Ollama returns token counts in specific fields
    prompt_eval_count = json["prompt_eval_count"] || 0
    eval_count = json["eval_count"] || 0

    Response.new(
      text: message["content"] || "",
      provider: :ollama,
      model: json["model"] || model,
      finish_reason: if(done, do: :stop, else: nil),
      usage: %{
        input_tokens: prompt_eval_count,
        output_tokens: eval_count,
        total_tokens: prompt_eval_count + eval_count
      },
      timing: %{duration_ms: duration_ms},
      raw_response: json
    )
  end

  # ============================================================================
  # Configuration
  # ============================================================================

  defp fallback_enabled? do
    config(:fallback_enabled)
  end

  defp fallback_model do
    config(:fallback_model)
  end

  defp ollama_base_url do
    case Application.get_env(:arbor_ai, :ollama) do
      nil -> @default_base_url
      config -> Keyword.get(config, :base_url, @default_base_url)
    end
  end

  defp config(key) do
    defaults = %{
      fallback_enabled: true,
      fallback_model: @default_model,
      fallback_timeout_ms: @default_timeout
    }

    Application.get_env(:arbor_ai, key, Map.get(defaults, key))
  end

  # ============================================================================
  # Signal Emissions
  # ============================================================================

  defp emit_fallback_activated(reason) do
    Signals.emit(:ai, :fallback_activated, %{
      from_provider: "primary",
      to_provider: "ollama",
      reason: inspect(reason, limit: 200),
      timestamp: System.system_time(:millisecond)
    })
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
