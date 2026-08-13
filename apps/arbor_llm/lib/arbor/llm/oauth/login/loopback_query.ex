defmodule Arbor.LLM.OAuth.Login.LoopbackQuery do
  @moduledoc false

  @max_query_bytes 4_096
  @max_pairs 8
  @max_key_bytes 32
  @field_limits %{
    "code" => 1_024,
    "state" => 1_024,
    "scope" => 1_024,
    "error" => 64,
    "error_description" => 1_024,
    "error_uri" => 2_048
  }
  @success_keys MapSet.new(~w(code state scope))
  @error_keys MapSet.new(~w(error state error_description error_uri))
  @closed_errors %{
    "access_denied" => :access_denied,
    "account_selection_required" => :account_selection_required,
    "consent_required" => :consent_required,
    "interaction_required" => :interaction_required,
    "invalid_request" => :invalid_request,
    "invalid_scope" => :invalid_scope,
    "login_required" => :login_required,
    "server_error" => :server_error,
    "temporarily_unavailable" => :temporarily_unavailable,
    "unauthorized_client" => :unauthorized_client,
    "unsupported_response_type" => :unsupported_response_type
  }
  @control_characters ~r/[\x00-\x1F\x7F]/

  @spec parse(term()) ::
          {:ok, {:success, String.t(), String.t()}}
          | {:ok, {:provider_error, atom(), String.t()}}
          | {:error, :invalid_callback}
  def parse(query) when is_binary(query) and byte_size(query) <= @max_query_bytes do
    with true <- query != "",
         parts when length(parts) <= @max_pairs <- String.split(query, "&", trim: false),
         {:ok, pairs} <- decode_pairs(parts, []),
         {:ok, values} <- unique_map(pairs) do
      classify(values)
    else
      _ -> {:error, :invalid_callback}
    end
  catch
    _, _ -> {:error, :invalid_callback}
  end

  def parse(_query), do: {:error, :invalid_callback}

  defp decode_pairs([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_pairs([part | rest], acc) do
    case :binary.split(part, "=") do
      [raw_key, raw_value] ->
        with {:ok, key} <- decode(raw_key),
             {:ok, value} <- decode(raw_value),
             :ok <- validate_pair(key, value) do
          decode_pairs(rest, [{key, value} | acc])
        end

      _ ->
        {:error, :invalid_callback}
    end
  end

  defp decode(value) do
    if valid_percent_encoding?(value) do
      decoded = URI.decode_www_form(value)

      if String.valid?(decoded) and not Regex.match?(@control_characters, decoded),
        do: {:ok, decoded},
        else: {:error, :invalid_callback}
    else
      {:error, :invalid_callback}
    end
  rescue
    ArgumentError -> {:error, :invalid_callback}
  end

  defp valid_percent_encoding?(<<>>), do: true

  defp valid_percent_encoding?(<<?%, a, b, rest::binary>>) do
    hex?(a) and hex?(b) and valid_percent_encoding?(rest)
  end

  defp valid_percent_encoding?(<<?%, _rest::binary>>), do: false
  defp valid_percent_encoding?(<<_byte, rest::binary>>), do: valid_percent_encoding?(rest)

  defp hex?(char), do: char in ?0..?9 or char in ?a..?f or char in ?A..?F

  defp validate_pair(key, value) do
    limit = Map.get(@field_limits, key)

    cond do
      not is_integer(limit) -> {:error, :invalid_callback}
      byte_size(key) == 0 or byte_size(key) > @max_key_bytes -> {:error, :invalid_callback}
      byte_size(value) == 0 or byte_size(value) > limit -> {:error, :invalid_callback}
      String.contains?(key, ["[", "]"]) -> {:error, :invalid_callback}
      true -> :ok
    end
  end

  defp unique_map(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      if Map.has_key?(acc, key),
        do: {:halt, {:error, :invalid_callback}},
        else: {:cont, {:ok, Map.put(acc, key, value)}}
    end)
  end

  defp classify(%{"code" => code, "state" => state} = values) do
    if subset?(values, @success_keys) and not Map.has_key?(values, "error"),
      do: {:ok, {:success, code, state}},
      else: {:error, :invalid_callback}
  end

  defp classify(%{"error" => error, "state" => state} = values) do
    with true <- subset?(values, @error_keys),
         {:ok, closed_error} <- Map.fetch(@closed_errors, error),
         :ok <- validate_error_uri(Map.get(values, "error_uri")) do
      {:ok, {:provider_error, closed_error, state}}
    else
      _ -> {:error, :invalid_callback}
    end
  end

  defp classify(_values), do: {:error, :invalid_callback}

  defp subset?(values, allowed),
    do: values |> Map.keys() |> Enum.all?(&MapSet.member?(allowed, &1))

  defp validate_error_uri(nil), do: :ok

  defp validate_error_uri(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil}
      when scheme in ["http", "https"] and is_binary(host) ->
        :ok

      _ ->
        {:error, :invalid_callback}
    end
  end
end
