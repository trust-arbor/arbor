defmodule Arbor.Contracts.Security.SigningAuthority.Validator do
  @moduledoc false

  @token_min_bytes 16

  @type principal_id :: String.t()
  @type attribute_error :: :invalid_attrs | :unknown_attribute | :duplicate_attribute

  @doc false
  @spec extract_attributes(keyword() | map(), [atom()]) ::
          {:ok, map()} | {:error, attribute_error()}
  def extract_attributes(attrs, allowed_keys) when is_list(allowed_keys) do
    with {:ok, pairs} <- attribute_pairs(attrs),
         :ok <- validate_attribute_keys(pairs, allowed_keys) do
      Enum.reduce_while(allowed_keys, {:ok, %{}}, fn key, {:ok, normalized} ->
        matches =
          Enum.filter(pairs, fn {candidate, _value} -> attribute_key?(candidate, key) end)

        case matches do
          [] -> {:cont, {:ok, normalized}}
          [{_source_key, value}] -> {:cont, {:ok, Map.put(normalized, key, value)}}
          _duplicates -> {:halt, {:error, :duplicate_attribute}}
        end
      end)
    end
  end

  @spec validate_token(term()) :: :ok | {:error, :invalid_token | :token_too_short | :zero_token}
  def validate_token(token) when is_binary(token) and byte_size(token) >= @token_min_bytes do
    if token == :binary.copy(<<0>>, byte_size(token)) do
      {:error, :zero_token}
    else
      :ok
    end
  end

  def validate_token(token) when is_binary(token), do: {:error, :token_too_short}
  def validate_token(_), do: {:error, :invalid_token}

  @spec validate_principal_id(term()) :: :ok | {:error, :invalid_principal_id}
  def validate_principal_id(id) when is_binary(id) and byte_size(id) > 0 do
    if String.starts_with?(id, "agent_") or String.starts_with?(id, "human_") do
      :ok
    else
      {:error, :invalid_principal_id}
    end
  end

  def validate_principal_id(_), do: {:error, :invalid_principal_id}

  @spec validate_purpose(term()) :: :ok | {:error, :invalid_purpose}
  def validate_purpose(purpose) when is_boolean(purpose), do: {:error, :invalid_purpose}
  def validate_purpose(purpose) when is_atom(purpose) and not is_nil(purpose), do: :ok

  def validate_purpose(purpose) when is_binary(purpose) do
    if String.trim(purpose) == "", do: {:error, :invalid_purpose}, else: :ok
  end

  def validate_purpose(_), do: {:error, :invalid_purpose}

  defp attribute_pairs(attrs) when is_map(attrs), do: {:ok, Map.to_list(attrs)}

  defp attribute_pairs(attrs) when is_list(attrs) do
    if Enum.all?(attrs, &match?({_key, _value}, &1)) do
      {:ok, attrs}
    else
      {:error, :invalid_attrs}
    end
  end

  defp attribute_pairs(_), do: {:error, :invalid_attrs}

  defp validate_attribute_keys(pairs, allowed_keys) do
    if Enum.all?(pairs, fn {candidate, _value} ->
         Enum.any?(allowed_keys, &attribute_key?(candidate, &1))
       end) do
      :ok
    else
      {:error, :unknown_attribute}
    end
  end

  defp attribute_key?(candidate, key) do
    candidate == key or candidate == Atom.to_string(key)
  end
end
