defmodule Arbor.AI.Backends.LMStudio do
  @moduledoc """
  LMStudio backend for local LLM inference.

  Uses LMStudio's OpenAI-compatible API running on localhost.
  This is the "last-ditch" fallback for when all cloud/subscription
  backends are unavailable due to quota exhaustion.

  ## Configuration

  LMStudio must be running with a model loaded and the local server enabled.
  Default endpoint: http://localhost:1234/v1

  Configure via environment or application config:

      config :arbor_ai, Arbor.AI.Backends.LMStudio,
        base_url: "http://localhost:1234/v1",
        model: "gpt-oss-120b"

  ## Usage

      # Basic generation
      {:ok, response} = LMStudio.generate_text("Explain this code")

      # With specific model
      {:ok, response} = LMStudio.generate_text("Task", model: "gpt-oss-120b")
  """

  alias Arbor.AI.Response

  require Logger

  @provider :lmstudio
  @default_model "gpt-oss-120b-heretic-v2-hi-mlx"
  @default_base_url "http://localhost:1234/v1"
  @default_timeout 300_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Generate text using LMStudio's local server.
  """
  @spec generate_text(String.t(), keyword()) :: {:ok, Response.t()} | {:error, term()}
  def generate_text(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())
    base_url = Keyword.get(opts, :base_url, base_url())
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    system_prompt = Keyword.get(opts, :system_prompt)

    Logger.info("LMStudio generating text",
      model: model,
      prompt_length: String.length(prompt)
    )

    messages = build_messages(prompt, system_prompt)
    body = build_request_body(messages, model, opts)
    url = "#{base_url}/chat/completions"

    start_time = System.monotonic_time(:millisecond)

    case make_request(url, body, timeout) do
      {:ok, json} ->
        duration = System.monotonic_time(:millisecond) - start_time
        response = parse_response(json, duration)

        Logger.info("LMStudio response received",
          duration_ms: duration,
          model: response.model,
          response_length: String.length(response.text)
        )

        {:ok, response}

      {:error, :connection_refused} ->
        Logger.warning("LMStudio not available - is the server running?")
        {:error, :lmstudio_unavailable}

      {:error, reason} ->
        Logger.warning("LMStudio error", error: inspect(reason))
        {:error, reason}
    end
  end

  @doc """
  Check if LMStudio server is available.
  """
  @spec available?() :: boolean()
  def available? do
    url = "#{base_url()}/models"

    case Req.get(url, receive_timeout: 2_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc """
  List available models from LMStudio.
  """
  @spec list_models() :: {:ok, [String.t()]} | {:error, term()}
  def list_models do
    url = "#{base_url()}/models"

    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"data" => models}}} ->
        model_ids = Enum.map(models, & &1["id"])
        {:ok, model_ids}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Default model for this backend.
  """
  @spec default_model() :: String.t()
  def default_model do
    config()[:model] || @default_model
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp config do
    Application.get_env(:arbor_ai, __MODULE__, [])
  end

  defp base_url do
    config()[:base_url] || @default_base_url
  end

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
    |> maybe_add(:temperature, Keyword.get(opts, :temperature))
    |> maybe_add(:max_tokens, Keyword.get(opts, :max_tokens))
    |> maybe_add(:top_p, Keyword.get(opts, :top_p))
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  defp make_request(url, body, timeout) do
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

  defp parse_response(json, duration_ms) do
    choice = List.first(json["choices"] || [])
    message = choice["message"] || %{}
    usage = json["usage"] || %{}

    Response.new(
      text: message["content"] || "",
      provider: @provider,
      model: json["model"],
      finish_reason: normalize_finish_reason(choice["finish_reason"]),
      usage: %{
        input_tokens: usage["prompt_tokens"] || 0,
        output_tokens: usage["completion_tokens"] || 0,
        total_tokens: usage["total_tokens"] || 0
      },
      timing: %{duration_ms: duration_ms},
      raw_response: json
    )
  end

  defp normalize_finish_reason("stop"), do: :stop
  defp normalize_finish_reason("length"), do: :max_tokens
  defp normalize_finish_reason(_), do: nil
end
