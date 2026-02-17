defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.ErrorMapper do
  @moduledoc false

  alias Arbor.Orchestrator.UnifiedLLM.ProviderError

  @spec from_http(String.t(), integer(), term(), [{String.t(), String.t()}] | map()) ::
          ProviderError.t()
  def from_http(provider, status, body, headers \\ []) do
    {message, code} = extract_message_and_code(body)

    ProviderError.exception(
      message: message || "HTTP #{status}",
      provider: provider,
      status: status,
      retryable: retryable_status?(status),
      retry_after_ms: parse_retry_after(headers),
      code: code,
      details: %{"body" => body}
    )
  end

  @spec from_transport(String.t(), term()) :: ProviderError.t()
  def from_transport(provider, reason) do
    ProviderError.exception(
      message: "transport error: #{inspect(reason)}",
      provider: provider,
      retryable: true,
      details: %{"reason" => inspect(reason)}
    )
  end

  @spec retryable_status?(integer()) :: boolean()
  def retryable_status?(status) when status in [408, 409, 425, 429], do: true
  def retryable_status?(status) when status >= 500 and status <= 599, do: true
  def retryable_status?(_), do: false

  @spec parse_retry_after([{String.t(), String.t()}] | map()) :: integer() | nil
  def parse_retry_after(headers) do
    value =
      cond do
        is_list(headers) ->
          headers
          |> Enum.find_value(fn {k, v} ->
            if String.downcase(to_string(k)) == "retry-after", do: v, else: nil
          end)

        is_map(headers) ->
          Map.get(headers, "retry-after") || Map.get(headers, "Retry-After")

        true ->
          nil
      end

    case value do
      nil ->
        nil

      v when is_integer(v) ->
        max(v, 0) * 1000

      v when is_binary(v) ->
        case Integer.parse(String.trim(v)) do
          {seconds, _} -> max(seconds, 0) * 1000
          :error -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_message_and_code(%{"error" => %{} = error}) do
    message = Map.get(error, "message") || Map.get(error, :message)
    code = Map.get(error, "code") || Map.get(error, :code)
    {maybe_string(message), maybe_string(code)}
  end

  defp extract_message_and_code(%{"error" => error}) when is_binary(error) do
    {error, nil}
  end

  defp extract_message_and_code(%{error: %{} = error}) do
    message = Map.get(error, :message) || Map.get(error, "message")
    code = Map.get(error, :code) || Map.get(error, "code")
    {maybe_string(message), maybe_string(code)}
  end

  defp extract_message_and_code(%{} = body) do
    message = Map.get(body, "message") || Map.get(body, :message)
    code = Map.get(body, "code") || Map.get(body, :code)
    {maybe_string(message), maybe_string(code)}
  end

  defp extract_message_and_code(body) when is_binary(body), do: {body, nil}
  defp extract_message_and_code(_), do: {nil, nil}

  defp maybe_string(nil), do: nil
  defp maybe_string(v), do: to_string(v)
end
