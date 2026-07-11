defmodule Arbor.LLM.ResponseBudget do
  @moduledoc false

  alias Arbor.LLM.JSONPreflight

  @signed_64_min -9_223_372_036_854_775_808
  @signed_64_max 9_223_372_036_854_775_807

  @type limits :: %{
          required(:max_bytes) => pos_integer(),
          required(:max_nodes) => pos_integer(),
          required(:max_depth) => pos_integer(),
          required(:max_map_keys) => pos_integer(),
          required(:max_list_items) => pos_integer()
        }

  @spec validate(term(), keyword()) :: :ok | {:error, term()}
  def validate(term, opts) when is_list(opts) do
    case measure(term, opts) do
      {:ok, _measurements} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec measure(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def measure(term, opts) when is_list(opts) do
    limits = limits(opts)

    with :ok <- validate_limits(limits) do
      walk([{:value, term, 0}], %{nodes: 0, bytes: 0, map_keys: 0, list_items: 0}, limits)
    end
  end

  @spec bounded_req_into(pos_integer()) :: function()
  def bounded_req_into(maximum) when is_integer(maximum) and maximum > 0 do
    fn {:data, data}, {request, response} when is_binary(data) ->
      retained = Map.get(response.private, :arbor_response_bytes, 0)
      remaining = maximum - retained

      if byte_size(data) > remaining do
        prefix = if remaining > 0, do: binary_part(data, 0, remaining), else: ""

        private =
          response.private
          |> append_response_chunk(prefix)
          |> Map.put(:arbor_response_overflow, maximum)

        response = %{response | body: "", private: private}
        {:halt, {%{request | halted: true}, response}}
      else
        private = append_response_chunk(response.private, data)
        {:cont, {request, %{response | body: "", private: private}}}
      end
    end
  end

  @spec apply_req_receipt(Req.Request.t(), pos_integer()) :: Req.Request.t()
  def apply_req_receipt(%Req.Request{} = request, maximum)
      when is_integer(maximum) and maximum > 0 do
    request
    |> Req.Request.put_private(:arbor_response_maximum, maximum)
    |> then(&%{&1 | into: bounded_req_into(maximum)})
    |> Req.Request.merge_options(compressed: false, decode_body: false, redirect: false)
    |> Req.Request.prepend_response_steps(arbor_decode_bounded_body: &decode_bounded_body/1)
  end

  @spec decode_json(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode_json(body, opts) when is_binary(body) and is_list(opts) do
    with {:ok, _measurements} <- JSONPreflight.scan(body, opts),
         {:ok, decoded} <- decode_after_preflight(body),
         :ok <- validate(decoded, opts),
         :ok <- validate_embedded_json(decoded, opts) do
      {:ok, decoded}
    end
  end

  @spec decode_json_numbers(binary(), keyword(), [String.t()]) ::
          {:ok, term(), %{String.t() => String.t()}} | {:error, term()}
  def decode_json_numbers(body, opts, keys)
      when is_binary(body) and is_list(opts) and is_list(keys) do
    with {:ok, %{number_lexemes: numbers}} <- JSONPreflight.scan(body, opts, keys),
         true <-
           Enum.all?(keys, &Map.has_key?(numbers, &1)) or
             {:error, {:invalid_json, :tracked_number_required}},
         {:ok, decoded} <- decode_after_preflight(body),
         :ok <- validate(decoded, opts),
         :ok <- validate_embedded_json(decoded, opts) do
      {:ok, decoded, numbers}
    end
  end

  @spec validate_json(binary(), keyword()) :: :ok | {:error, term()}
  def validate_json(body, opts) when is_binary(body) and is_list(opts) do
    case JSONPreflight.scan(body, opts) do
      {:ok, _measurements} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec exact_unit_number?(binary()) :: boolean()
  def exact_unit_number?(token) when is_binary(token) do
    with false <- String.starts_with?(token, "-"),
         [mantissa, exponent] <- split_exponent(token),
         {:ok, exponent} <- bounded_exponent(exponent),
         [integer, fraction] <- split_fraction(mantissa),
         true <- integer != "" and fraction != "",
         true <- all_digits?(integer) and all_digits?(fraction) do
      digits = integer <> fraction
      significant = String.trim_leading(digits, "0")

      if significant == "" do
        true
      else
        leading_zeroes = byte_size(digits) - byte_size(significant)
        decimal_position = byte_size(integer) + exponent - leading_zeroes

        cond do
          decimal_position <= 0 -> true
          decimal_position > 1 -> false
          true -> significant == "1" <> String.duplicate("0", byte_size(significant) - 1)
        end
      end
    else
      _ -> false
    end
  end

  def exact_unit_number?(_token), do: false

  @spec finite_number?(term()) :: boolean()
  def finite_number?(value) when is_integer(value),
    do: value >= @signed_64_min and value <= @signed_64_max

  def finite_number?(value) when is_float(value), do: value == value and value - value == 0.0
  def finite_number?(_value), do: false

  defp limits(opts) do
    %{
      max_bytes: Keyword.fetch!(opts, :max_bytes),
      max_nodes: Keyword.get(opts, :max_nodes, 100_000),
      max_depth: Keyword.get(opts, :max_depth, 32),
      max_map_keys: Keyword.get(opts, :max_map_keys, 10_000),
      max_list_items: Keyword.get(opts, :max_list_items, 100_000)
    }
  end

  defp validate_limits(limits) do
    if Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
      do: :ok,
      else: {:error, {:invalid_budget, :positive_limits_required}}
  end

  defp append_response_chunk(private, ""), do: private

  defp append_response_chunk(private, data) do
    private
    |> Map.update(:arbor_response_chunks, [data], &[data | &1])
    |> Map.update(:arbor_response_bytes, byte_size(data), &(&1 + byte_size(data)))
  end

  defp decode_bounded_body(
         {request, %Req.Response{private: %{arbor_response_overflow: _maximum}} = response}
       ),
       do: {request, response}

  defp decode_bounded_body({request, %Req.Response{} = response}) do
    with :ok <- identity_content_encoding(response),
         :ok <- json_content_type(response),
         {:ok, body} <- response_binary(response),
         maximum = Map.fetch!(request.private, :arbor_response_maximum),
         {:ok, decoded} <-
           decode_json(body,
             max_bytes: maximum,
             max_nodes: 100_000,
             max_depth: 32,
             max_map_keys: 10_000,
             max_list_items: 100_000
           ) do
      {request, %{response | body: decoded}}
    else
      {:error, reason} -> halt_response(request, response, reason)
    end
  end

  defp identity_content_encoding(response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] ->
        :ok

      values ->
        if Enum.all?(values, &(String.downcase(String.trim(&1)) in ["", "identity"])),
          do: :ok,
          else: {:error, {:invalid_content_encoding, :identity_required}}
    end
  end

  defp json_content_type(response) do
    case Req.Response.get_header(response, "content-type") do
      [] ->
        {:error, {:invalid_content_type, :application_json_required}}

      [value] ->
        if json_content_type?(value),
          do: :ok,
          else: {:error, {:invalid_content_type, :application_json_required}}

      _conflicting_or_malformed ->
        {:error, {:invalid_content_type, :application_json_required}}
    end
  end

  defp json_content_type?(value) when is_binary(value) do
    media_type =
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    media_type == "application/json" or String.ends_with?(media_type, "+json")
  end

  defp response_binary(%Req.Response{private: %{arbor_response_chunks: chunks}})
       when is_list(chunks) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp response_binary(%Req.Response{body: body}) when is_binary(body), do: {:ok, body}
  defp response_binary(_response), do: {:error, {:invalid_json, :binary_body_required}}

  defp decode_after_preflight(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{}} -> {:error, {:invalid_json, :decoder_disagreement}}
    end
  end

  defp validate_embedded_json(term, opts) do
    walk_embedded([{:value, term}], opts)
  end

  defp walk_embedded([], _opts), do: :ok

  defp walk_embedded([{:value, map} | rest], opts) when is_map(map) do
    with :ok <- validate_function_arguments(map, opts) do
      walk_embedded([{:map, :maps.iterator(map)} | rest], opts)
    end
  end

  defp walk_embedded([{:value, list} | rest], opts) when is_list(list),
    do: walk_embedded([{:list, list} | rest], opts)

  defp walk_embedded([{:value, tuple} | rest], opts) when is_tuple(tuple),
    do: walk_embedded([{:tuple, tuple, 0} | rest], opts)

  defp walk_embedded([{:value, _scalar} | rest], opts), do: walk_embedded(rest, opts)

  defp walk_embedded([{:map, iterator} | rest], opts) do
    case :maps.next(iterator) do
      :none ->
        walk_embedded(rest, opts)

      {_key, value, next} ->
        walk_embedded([{:value, value}, {:map, next} | rest], opts)
    end
  end

  defp walk_embedded([{:list, []} | rest], opts), do: walk_embedded(rest, opts)

  defp walk_embedded([{:list, [head | tail]} | rest], opts),
    do: walk_embedded([{:value, head}, {:list, tail} | rest], opts)

  defp walk_embedded([{:list, _improper} | _rest], _opts),
    do: {:error, {:decoded_term_invalid, :proper_list_required}}

  defp walk_embedded([{:tuple, tuple, index} | rest], opts) when index == tuple_size(tuple),
    do: walk_embedded(rest, opts)

  defp walk_embedded([{:tuple, tuple, index} | rest], opts),
    do: walk_embedded([{:value, elem(tuple, index)}, {:tuple, tuple, index + 1} | rest], opts)

  defp scan_result({:ok, _measurements}), do: :ok
  defp scan_result({:error, _reason} = error), do: error

  defp validate_function_arguments(map, opts) do
    name = Map.get(map, "name", Map.get(map, :name))
    arguments = Map.get(map, "arguments", Map.get(map, :arguments))

    if is_binary(name) and is_binary(arguments),
      do: JSONPreflight.scan(arguments, opts) |> scan_result(),
      else: :ok
  end

  defp halt_response(request, response, reason) do
    response = %{response | private: Map.put(response.private, :arbor_response_error, reason)}
    {%{request | halted: true}, response}
  end

  defp walk([], stats, _limits), do: {:ok, stats}

  defp walk([{:value, _term, depth} | _rest], _stats, %{max_depth: maximum})
       when depth > maximum,
       do: {:error, {:decoded_term_limit_exceeded, :depth, maximum}}

  defp walk([{:value, term, depth} | rest], stats, limits) when is_map(term) do
    with {:ok, stats} <- add_term_node(stats, 1, limits),
         {:ok, stats} <- add_bytes(stats, 1, limits),
         {:ok, stats} <- add_map_keys(stats, map_size(term), limits) do
      walk([{:map, :maps.iterator(term), depth + 1} | rest], stats, limits)
    end
  end

  defp walk([{:map, iterator, depth} | rest], stats, limits) do
    case :maps.next(iterator) do
      :none ->
        walk(rest, stats, limits)

      {key, value, next} when is_binary(key) or is_atom(key) ->
        walk(
          [{:value, key, depth}, {:value, value, depth}, {:map, next, depth} | rest],
          stats,
          limits
        )

      {_key, _value, _next} ->
        {:error, {:decoded_term_invalid, :string_or_atom_map_keys_required}}
    end
  end

  defp walk([{:value, term, depth} | rest], stats, limits) when is_list(term) do
    with {:ok, stats} <- add_term_node(stats, 1, limits),
         {:ok, stats} <- add_bytes(stats, 1, limits) do
      walk([{:list, term, depth + 1, 0} | rest], stats, limits)
    end
  end

  defp walk([{:list, [], _depth, _count} | rest], stats, limits), do: walk(rest, stats, limits)

  defp walk([{:list, _list, _depth, count} | _rest], _stats, %{max_list_items: maximum})
       when count >= maximum,
       do: {:error, {:decoded_term_limit_exceeded, :list_items, maximum}}

  defp walk([{:list, [head | tail], depth, count} | rest], stats, limits) do
    with {:ok, stats} <- add_list_items(stats, 1, limits) do
      walk([{:value, head, depth}, {:list, tail, depth, count + 1} | rest], stats, limits)
    end
  end

  defp walk([{:list, _tail, _depth, _count} | _rest], _stats, _limits),
    do: {:error, {:decoded_term_invalid, :proper_list_required}}

  defp walk([{:value, term, depth} | rest], stats, limits) when is_tuple(term) do
    size = tuple_size(term)

    with {:ok, stats} <- add_term_node(stats, 1, limits),
         {:ok, stats} <- add_bytes(stats, 1, limits),
         {:ok, stats} <- add_list_items(stats, size, limits) do
      walk([{:tuple, term, 0, depth + 1} | rest], stats, limits)
    end
  end

  defp walk([{:tuple, tuple, index, _depth} | rest], stats, limits)
       when index == tuple_size(tuple),
       do: walk(rest, stats, limits)

  defp walk([{:tuple, tuple, index, depth} | rest], stats, limits),
    do:
      walk(
        [{:value, elem(tuple, index), depth}, {:tuple, tuple, index + 1, depth} | rest],
        stats,
        limits
      )

  defp walk([{:value, term, _depth} | rest], stats, limits) when is_integer(term) do
    if finite_number?(term),
      do: add_scalar_and_continue(rest, stats, 8, limits),
      else: {:error, {:decoded_term_invalid, :signed_64_required}}
  end

  defp walk([{:value, term, _depth} | rest], stats, limits) when is_float(term) do
    if finite_number?(term),
      do: add_scalar_and_continue(rest, stats, 8, limits),
      else: {:error, {:decoded_term_invalid, :finite_float_required}}
  end

  defp walk([{:value, term, _depth} | rest], stats, limits) when is_binary(term) do
    if String.valid?(term),
      do: add_scalar_and_continue(rest, stats, byte_size(term), limits),
      else: {:error, {:decoded_term_invalid, :valid_utf8_required}}
  end

  defp walk([{:value, term, _depth} | rest], stats, limits)
       when is_atom(term) or is_boolean(term) or is_nil(term),
       do: add_scalar_and_continue(rest, stats, atom_bytes(term), limits)

  defp walk([{:value, _term, _depth} | _rest], _stats, _limits),
    do: {:error, {:decoded_term_invalid, :json_compatible_term_required}}

  defp add_scalar_and_continue(rest, stats, bytes, limits) do
    with {:ok, stats} <- add_term_node(stats, 1, limits),
         {:ok, stats} <- add_bytes(stats, bytes, limits) do
      walk(rest, stats, limits)
    end
  end

  defp add_term_node(stats, amount, limits) do
    if stats.nodes <= limits.max_nodes - amount,
      do: {:ok, %{stats | nodes: stats.nodes + amount}},
      else: {:error, {:decoded_term_limit_exceeded, :nodes, limits.max_nodes}}
  end

  defp add_bytes(stats, amount, limits) do
    if stats.bytes <= limits.max_bytes - amount,
      do: {:ok, %{stats | bytes: stats.bytes + amount}},
      else: {:error, {:decoded_term_limit_exceeded, :bytes, limits.max_bytes}}
  end

  defp add_map_keys(stats, amount, limits) do
    if stats.map_keys <= limits.max_map_keys - amount,
      do: {:ok, %{stats | map_keys: stats.map_keys + amount}},
      else: {:error, {:decoded_term_limit_exceeded, :map_keys, limits.max_map_keys}}
  end

  defp add_list_items(stats, amount, limits) do
    if stats.list_items <= limits.max_list_items - amount,
      do: {:ok, %{stats | list_items: stats.list_items + amount}},
      else: {:error, {:decoded_term_limit_exceeded, :list_items, limits.max_list_items}}
  end

  defp atom_bytes(nil), do: 4
  defp atom_bytes(true), do: 4
  defp atom_bytes(false), do: 5
  defp atom_bytes(atom), do: atom |> Atom.to_string() |> byte_size()

  defp split_exponent(token) do
    case Regex.split(~r/[eE]/, token, parts: 2) do
      [mantissa] -> [mantissa, "0"]
      [mantissa, exponent] -> [mantissa, exponent]
    end
  end

  defp bounded_exponent(exponent) when byte_size(exponent) <= 6 do
    case Integer.parse(exponent) do
      {value, ""} when value in -9_999..9_999 -> {:ok, value}
      _ -> :error
    end
  end

  defp bounded_exponent(_exponent), do: :error

  defp split_fraction(mantissa) do
    case String.split(mantissa, ".", parts: 2) do
      [integer] -> [integer, "0"]
      [integer, fraction] -> [integer, fraction]
    end
  end

  defp all_digits?(value), do: value != "" and Regex.match?(~r/\A[0-9]+\z/, value)
end
