defmodule Arbor.Contracts.Security.SigningAuthority.Validator do
  @moduledoc false

  @token_min_bytes 16

  @spec get_attr(keyword() | map(), atom()) :: term()
  def get_attr(attrs, key) when is_list(attrs) do
    case Enum.find(attrs, fn
           {candidate, _value} -> candidate == key
           _malformed -> false
         end) do
      {^key, value} -> value
      _missing -> nil
    end
  end

  def get_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
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
end
