defmodule Arbor.Actions.Acp.DeliveryFailure do
  @moduledoc false

  @max_message_bytes 4096
  @credit_phrase "used all available credits"
  @spending_limit_phrase "reached its monthly spending limit"

  @spec classify(term()) :: {:provider_account_exhausted, 402 | 403} | :other
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
