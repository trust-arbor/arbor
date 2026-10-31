defmodule Arbor.LLM.JSONPreflight do
  @moduledoc false

  @signed_64_max "9223372036854775807"
  @signed_64_min_magnitude "9223372036854775808"

  @spec scan(binary(), keyword(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def scan(body, opts, capture_keys \\ [])
      when is_binary(body) and is_list(opts) and is_list(capture_keys) do
    limits = %{
      max_bytes: Keyword.fetch!(opts, :max_bytes),
      max_nodes: Keyword.get(opts, :max_nodes, 100_000),
      max_depth: Keyword.get(opts, :max_depth, 32),
      max_map_keys: Keyword.get(opts, :max_map_keys, 10_000),
      max_list_items: Keyword.get(opts, :max_list_items, 100_000),
      max_string_bytes: Keyword.get(opts, :max_string_bytes, Keyword.fetch!(opts, :max_bytes)),
      max_number_bytes: Keyword.get(opts, :max_number_bytes, 128)
    }

    with :ok <- validate_limits(limits),
         :ok <- validate_body(body, limits.max_bytes),
         {:ok, capture} <- capture_set(capture_keys),
         state = %{
           limits: limits,
           nodes: 0,
           bytes: 0,
           map_keys: 0,
           list_items: 0,
           string_bytes: 0,
           capture: capture,
           seen_capture: MapSet.new(),
           numbers: %{}
         },
         {:ok, rest, state} <- parse_value(skip_ws(body), 0, state, nil),
         true <- skip_ws(rest) == "" or {:error, {:invalid_json, :malformed}} do
      {:ok,
       %{
         nodes: state.nodes,
         bytes: state.bytes,
         map_keys: state.map_keys,
         list_items: state.list_items,
         string_bytes: state.string_bytes,
         number_lexemes: state.numbers
       }}
    end
  end

  defp validate_limits(limits) do
    if Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
      do: :ok,
      else: {:error, {:invalid_budget, :positive_limits_required}}
  end

  defp validate_body(body, maximum) do
    cond do
      byte_size(body) > maximum ->
        {:error, {:decoded_term_limit_exceeded, :bytes, maximum}}

      not String.valid?(body) ->
        {:error, {:invalid_json, :valid_utf8_required}}

      true ->
        :ok
    end
  end

  defp capture_set(keys) do
    if Enum.all?(keys, &(is_binary(&1) and byte_size(&1) <= 256 and String.valid?(&1))),
      do: {:ok, MapSet.new(keys)},
      else: {:error, {:invalid_budget, :capture_keys}}
  end

  defp parse_value("", _depth, _state, _key), do: malformed()

  defp parse_value("{" <> rest, depth, state, key) do
    with {:ok, state} <- add_node(state),
         {:ok, state} <- add_retained_bytes(state, 1),
         {:ok, next_depth} <- add_depth(depth, state),
         {:ok, state} <- mark_non_number_capture(key, state) do
      parse_object(skip_ws(rest), next_depth, state)
    end
  end

  defp parse_value("[" <> rest, depth, state, key) do
    with {:ok, state} <- add_node(state),
         {:ok, state} <- add_retained_bytes(state, 1),
         {:ok, next_depth} <- add_depth(depth, state),
         {:ok, state} <- mark_non_number_capture(key, state) do
      parse_array(skip_ws(rest), next_depth, state)
    end
  end

  defp parse_value("\"" <> rest, _depth, state, key) do
    with {:ok, rest, decoded_bytes, _raw, _escaped?} <- parse_string(rest),
         {:ok, state} <- add_node(state),
         {:ok, state} <- add_string_bytes(state, decoded_bytes),
         {:ok, state} <- add_retained_bytes(state, decoded_bytes),
         {:ok, state} <- mark_non_number_capture(key, state) do
      {:ok, rest, state}
    end
  end

  defp parse_value("true" <> rest, _depth, state, key),
    do: finish_literal(rest, state, key, 4)

  defp parse_value("false" <> rest, _depth, state, key),
    do: finish_literal(rest, state, key, 5)

  defp parse_value("null" <> rest, _depth, state, key),
    do: finish_literal(rest, state, key, 4)

  defp parse_value(<<char, _::binary>> = body, _depth, state, key)
       when char == ?- or char in ?0..?9 do
    with {:ok, token, rest} <- take_number(body, state.limits.max_number_bytes),
         :ok <- validate_number(token),
         {:ok, state} <- add_node(state),
         {:ok, state} <- add_retained_bytes(state, 8),
         {:ok, state} <- capture_number(key, token, state) do
      {:ok, rest, state}
    end
  end

  defp parse_value(_body, _depth, _state, _key), do: malformed()

  defp finish_literal(rest, state, key, retained_bytes) do
    with :ok <- delimiter(rest),
         {:ok, state} <- add_node(state),
         {:ok, state} <- add_retained_bytes(state, retained_bytes),
         {:ok, state} <- mark_non_number_capture(key, state) do
      {:ok, rest, state}
    end
  end

  defp parse_object("}" <> rest, _depth, state), do: {:ok, rest, state}

  defp parse_object("\"" <> rest, depth, state) do
    with {:ok, rest, decoded_bytes, raw_key, escaped?} <- parse_string(rest),
         :ok <- reject_escaped_capture_key(escaped?, state),
         {:ok, state} <- add_node(state),
         {:ok, state} <- add_string_bytes(state, decoded_bytes),
         {:ok, state} <- add_retained_bytes(state, decoded_bytes),
         {:ok, state} <- add_map_key(state),
         key = if(escaped?, do: nil, else: raw_key),
         {:ok, state} <- reserve_capture(key, state),
         ":" <> rest <- skip_ws(rest),
         {:ok, rest, state} <- parse_value(skip_ws(rest), depth, state, key) do
      continue_object(skip_ws(rest), depth, state)
    else
      {:error, _reason} = error -> error
      _pattern_mismatch -> malformed()
    end
  end

  defp parse_object(_body, _depth, _state), do: malformed()

  defp continue_object("," <> rest, depth, state), do: parse_object(skip_ws(rest), depth, state)
  defp continue_object("}" <> rest, _depth, state), do: {:ok, rest, state}
  defp continue_object(_body, _depth, _state), do: malformed()

  defp parse_array("]" <> rest, _depth, state), do: {:ok, rest, state}

  defp parse_array(body, depth, state) do
    with {:ok, state} <- add_list_item(state),
         {:ok, rest, state} <- parse_value(body, depth, state, nil) do
      continue_array(skip_ws(rest), depth, state)
    end
  end

  defp continue_array("," <> rest, depth, state), do: parse_array(skip_ws(rest), depth, state)
  defp continue_array("]" <> rest, _depth, state), do: {:ok, rest, state}
  defp continue_array(_body, _depth, _state), do: malformed()

  defp parse_string(source), do: scan_string(source, source, 0, 0, false)

  defp scan_string("", _source, _consumed, _decoded, _escaped?), do: malformed()

  defp scan_string("\"" <> rest, source, consumed, decoded, escaped?) do
    raw = binary_part(source, 0, consumed)
    {:ok, rest, decoded, raw, escaped?}
  end

  defp scan_string(<<char, _::binary>>, _source, _consumed, _decoded, _escaped?)
       when char < 0x20,
       do: malformed()

  defp scan_string("\\" <> rest, source, consumed, decoded, _escaped?) do
    case rest do
      <<escape, tail::binary>> when escape in [?\", ?\\, ?/, ?b, ?f, ?n, ?r, ?t] ->
        scan_string(tail, source, consumed + 2, decoded + 1, true)

      "u" <> tail ->
        parse_unicode_escape(tail, source, consumed, decoded)

      _ ->
        malformed()
    end
  end

  defp scan_string(<<_char, rest::binary>>, source, consumed, decoded, escaped?),
    do: scan_string(rest, source, consumed + 1, decoded + 1, escaped?)

  defp parse_unicode_escape(<<hex::binary-size(4), rest::binary>>, source, consumed, decoded) do
    with {:ok, codepoint} <- hex4(hex) do
      cond do
        codepoint in 0xD800..0xDBFF ->
          case rest do
            <<"\\u", low_hex::binary-size(4), tail::binary>> ->
              with {:ok, low} <- hex4(low_hex),
                   true <- low in 0xDC00..0xDFFF or {:error, {:invalid_json, :malformed}} do
                scan_string(tail, source, consumed + 12, decoded + 4, true)
              end

            _ ->
              malformed()
          end

        codepoint in 0xDC00..0xDFFF ->
          malformed()

        true ->
          scan_string(rest, source, consumed + 6, decoded + utf8_bytes(codepoint), true)
      end
    end
  end

  defp parse_unicode_escape(_rest, _source, _consumed, _decoded), do: malformed()

  defp hex4(hex) do
    if Regex.match?(~r/\A[0-9A-Fa-f]{4}\z/, hex) do
      case Integer.parse(hex, 16) do
        {value, ""} -> {:ok, value}
        _ -> malformed()
      end
    else
      malformed()
    end
  end

  defp utf8_bytes(value) when value <= 0x7F, do: 1
  defp utf8_bytes(value) when value <= 0x7FF, do: 2
  defp utf8_bytes(_value), do: 3

  defp take_number(body, maximum), do: take_number(body, body, 0, maximum)

  defp take_number(<<char, rest::binary>>, source, count, maximum)
       when (char in ?0..?9 or char in [?+, ?-, ?., ?e, ?E]) and count < maximum,
       do: take_number(rest, source, count + 1, maximum)

  defp take_number(<<char, _::binary>>, _source, count, maximum)
       when (char in ?0..?9 or char in [?+, ?-, ?., ?e, ?E]) and count >= maximum,
       do: {:error, {:decoded_term_limit_exceeded, :number_bytes, maximum}}

  defp take_number(rest, source, count, _maximum) do
    token = binary_part(source, 0, count)

    with :ok <- delimiter(rest) do
      {:ok, token, rest}
    end
  end

  defp validate_number(token) do
    if Regex.match?(~r/\A-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/, token) do
      if String.contains?(token, [".", "e", "E"]),
        do: validate_float(token),
        else: validate_integer(token)
    else
      malformed()
    end
  end

  defp validate_integer("-" <> digits),
    do: bounded_integer_digits(digits, @signed_64_min_magnitude)

  defp validate_integer(digits), do: bounded_integer_digits(digits, @signed_64_max)

  defp bounded_integer_digits(digits, maximum) do
    cond do
      byte_size(digits) < byte_size(maximum) ->
        :ok

      byte_size(digits) > byte_size(maximum) ->
        {:error, {:decoded_term_invalid, :signed_64_required}}

      digits <= maximum ->
        :ok

      true ->
        {:error, {:decoded_term_invalid, :signed_64_required}}
    end
  end

  defp validate_float(token) do
    case Float.parse(token) do
      {value, ""} when value == value and value - value == 0.0 -> :ok
      _ -> {:error, {:decoded_term_invalid, :finite_float_required}}
    end
  end

  defp delimiter(""), do: :ok
  defp delimiter(<<char, _::binary>>) when char in [32, 9, 10, 13, ?,, ?], ?}], do: :ok
  defp delimiter(_rest), do: malformed()

  defp add_node(%{nodes: nodes, limits: %{max_nodes: maximum}} = state) do
    if nodes < maximum,
      do: {:ok, %{state | nodes: nodes + 1}},
      else: {:error, {:decoded_term_limit_exceeded, :nodes, maximum}}
  end

  defp add_depth(depth, %{limits: %{max_depth: maximum}}) do
    if depth < maximum,
      do: {:ok, depth + 1},
      else: {:error, {:decoded_term_limit_exceeded, :depth, maximum}}
  end

  defp add_map_key(%{map_keys: count, limits: %{max_map_keys: maximum}} = state) do
    if count < maximum,
      do: {:ok, %{state | map_keys: count + 1}},
      else: {:error, {:decoded_term_limit_exceeded, :map_keys, maximum}}
  end

  defp add_list_item(%{list_items: count, limits: %{max_list_items: maximum}} = state) do
    if count < maximum,
      do: {:ok, %{state | list_items: count + 1}},
      else: {:error, {:decoded_term_limit_exceeded, :list_items, maximum}}
  end

  defp add_string_bytes(%{string_bytes: count, limits: limits} = state, amount) do
    cond do
      amount > limits.max_string_bytes ->
        {:error, {:decoded_term_limit_exceeded, :string_bytes, limits.max_string_bytes}}

      count > limits.max_bytes - amount ->
        {:error, {:decoded_term_limit_exceeded, :string_bytes, limits.max_bytes}}

      true ->
        {:ok, %{state | string_bytes: count + amount}}
    end
  end

  defp add_retained_bytes(%{bytes: count, limits: %{max_bytes: maximum}} = state, amount) do
    if count <= maximum - amount,
      do: {:ok, %{state | bytes: count + amount}},
      else: {:error, {:decoded_term_limit_exceeded, :bytes, maximum}}
  end

  defp reserve_capture(nil, state), do: {:ok, state}

  defp reserve_capture(key, state) do
    if MapSet.member?(state.capture, key) do
      if MapSet.member?(state.seen_capture, key),
        do: {:error, {:invalid_json, {:duplicate_tracked_key, key}}},
        else: {:ok, %{state | seen_capture: MapSet.put(state.seen_capture, key)}}
    else
      {:ok, state}
    end
  end

  defp capture_number(nil, _token, state), do: {:ok, state}

  defp capture_number(key, token, state) do
    if MapSet.member?(state.capture, key),
      do: {:ok, %{state | numbers: Map.put(state.numbers, key, token)}},
      else: {:ok, state}
  end

  defp mark_non_number_capture(nil, state), do: {:ok, state}
  defp mark_non_number_capture(_key, state), do: {:ok, state}

  defp reject_escaped_capture_key(true, %{capture: capture}) do
    if MapSet.size(capture) > 0,
      do: {:error, {:invalid_json, :escaped_tracked_key_forbidden}},
      else: :ok
  end

  defp reject_escaped_capture_key(false, _state), do: :ok

  defp skip_ws(<<char, rest::binary>>) when char in [32, 9, 10, 13], do: skip_ws(rest)
  defp skip_ws(rest), do: rest

  defp malformed, do: {:error, {:invalid_json, :malformed}}
end
