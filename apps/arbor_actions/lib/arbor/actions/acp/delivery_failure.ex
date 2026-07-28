defmodule Arbor.Actions.Acp.DeliveryFailure do
  @moduledoc false

  @max_message_bytes 4096
  @credit_phrase "used all available credits"
  @spending_limit_phrase "reached its monthly spending limit"

  @type classification :: {:provider_account_exhausted, 402 | 403 | 429} | :other
  @type response_classification ::
          classification()
          | {:acp_protocol_failure,
             %{provider: String.t(), reason: :unattested_provider_account_exhaustion}}

  @spec classify(term()) :: classification()
  def classify(
        {:provider_account_exhausted,
         %{
           provider: "claude",
           http_status: 429,
           provider_session_id: session_id
         }}
      )
      when is_binary(session_id) and session_id != "" and byte_size(session_id) <= 256 do
    if String.valid?(session_id), do: {:provider_account_exhausted, 429}, else: :other
  end

  def classify(reason) when is_map(reason) do
    with {:ok, -32_603} <- value_at(reason, :code),
         {:ok, data} when is_map(data) <- value_at(reason, :data),
         {:ok, http_status} when http_status in [402, 403] <-
           value_at(data, :http_status),
         {:ok, message} <- value_at(data, :message),
         {:ok, message} <- sanitized_message(message),
         true <- account_exhaustion_message?(message) do
      {:provider_account_exhausted, http_status}
    else
      _ -> :other
    end
  end

  def classify(_reason), do: :other

  @doc false
  @spec classify_response(term()) :: response_classification()
  def classify_response(response) do
    case Arbor.AI.classify_acp_prompt_failure(response) do
      {:provider_account_exhausted, _evidence} = reason -> classify(reason)
      {:acp_protocol_failure, _evidence} = reason -> reason
      :none -> :other
    end
  end

  @doc false
  @spec provider_session_id(term()) :: String.t()
  def provider_session_id({:provider_account_exhausted, %{provider_session_id: session_id}})
      when is_binary(session_id) and session_id != "" and byte_size(session_id) <= 256 do
    if String.valid?(session_id), do: session_id, else: ""
  end

  def provider_session_id(_reason), do: ""

  @doc false
  @spec response_provider_session_id(term()) :: String.t()
  def response_provider_session_id(response) do
    response
    |> Arbor.AI.classify_acp_prompt_failure()
    |> provider_session_id()
  end

  defp value_at(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  defp sanitized_message(message) when is_binary(message) do
    if byte_size(message) <= @max_message_bytes and String.valid?(message) do
      {:ok, message}
    else
      :error
    end
  end

  defp sanitized_message({:truncated_binary, prefix, original_size})
       when is_binary(prefix) and is_integer(original_size) and original_size >= 0 and
              byte_size(prefix) <= @max_message_bytes and original_size >= byte_size(prefix) do
    if String.valid?(prefix), do: {:ok, prefix}, else: :error
  end

  defp sanitized_message(_message), do: :error

  defp account_exhaustion_message?(message) when is_binary(message) do
    downcased = String.downcase(message)

    :binary.match(downcased, @credit_phrase) != :nomatch or
      :binary.match(downcased, @spending_limit_phrase) != :nomatch
  end
end
