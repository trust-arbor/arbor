defmodule Arbor.LLM.ResponseBudget do
  @moduledoc false

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
    limits = %{
      max_bytes: Keyword.fetch!(opts, :max_bytes),
      max_nodes: Keyword.get(opts, :max_nodes, 100_000),
      max_depth: Keyword.get(opts, :max_depth, 32),
      max_map_keys: Keyword.get(opts, :max_map_keys, 10_000),
      max_list_items: Keyword.get(opts, :max_list_items, 100_000)
    }

    with :ok <- validate_limits(limits),
         :ok <- validate_external_size(term, limits.max_bytes),
         {:ok, _nodes} <- walk(term, 0, 0, limits) do
      :ok
    end
  end

  @spec bounded_req_into(pos_integer()) :: function()
  def bounded_req_into(maximum) when is_integer(maximum) and maximum > 0 do
    fn {:data, data}, {request, response} when is_binary(data) ->
      retained = if is_binary(response.body), do: response.body, else: ""
      remaining = maximum - byte_size(retained)

      if byte_size(data) > remaining do
        prefix = if remaining > 0, do: binary_part(data, 0, remaining), else: ""

        response = %{
          response
          | body: retained <> prefix,
            private: Map.put(response.private, :arbor_response_overflow, maximum)
        }

        {:halt, {%{request | halted: true}, response}}
      else
        {:cont, {request, %{response | body: retained <> data}}}
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
    maximum = Keyword.fetch!(opts, :max_bytes)

    cond do
      byte_size(body) > maximum ->
        {:error, {:decoded_term_limit_exceeded, :bytes, maximum}}

      not String.valid?(body) ->
        {:error, {:invalid_json, :valid_utf8_required}}

      true ->
        with {:ok, decoded} <- Jason.decode(body),
             :ok <- validate(decoded, opts) do
          {:ok, decoded}
        else
          {:error, %Jason.DecodeError{}} -> {:error, {:invalid_json, :malformed}}
          {:error, _reason} = error -> error
        end
    end
  end

  @spec finite_number?(term()) :: boolean()
  def finite_number?(value) when is_integer(value),
    do: value >= @signed_64_min and value <= @signed_64_max

  def finite_number?(value) when is_float(value), do: value == value and value - value == 0.0
  def finite_number?(_value), do: false

  defp validate_limits(limits) do
    if Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
      do: :ok,
      else: {:error, {:invalid_budget, :positive_limits_required}}
  end

  defp decode_bounded_body(
         {request, %Req.Response{private: %{arbor_response_overflow: _maximum}} = response}
       ),
       do: {request, response}

  defp decode_bounded_body({request, %Req.Response{body: body} = response})
       when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> validate_decoded_response(request, response, decoded)
      {:error, _reason} -> halt_response(request, response, {:invalid_json, :malformed})
    end
  end

  defp decode_bounded_body(request_response), do: request_response

  defp validate_decoded_response(request, response, decoded) do
    maximum = Map.fetch!(request.private, :arbor_response_maximum)

    case validate(decoded,
           max_bytes: maximum,
           max_nodes: 100_000,
           max_depth: 32,
           max_map_keys: 10_000,
           max_list_items: 100_000
         ) do
      :ok -> {request, %{response | body: decoded}}
      {:error, reason} -> halt_response(request, response, reason)
    end
  end

  defp halt_response(request, response, reason) do
    response = %{
      response
      | private: Map.put(response.private, :arbor_response_error, reason)
    }

    {%{request | halted: true}, response}
  end

  defp validate_external_size(term, maximum) do
    if :erlang.external_size(term) <= maximum,
      do: :ok,
      else: {:error, {:decoded_term_limit_exceeded, :bytes, maximum}}
  end

  defp walk(_term, depth, _nodes, %{max_depth: maximum}) when depth > maximum,
    do: {:error, {:decoded_term_limit_exceeded, :depth, maximum}}

  defp walk(_term, _depth, nodes, %{max_nodes: maximum}) when nodes >= maximum,
    do: {:error, {:decoded_term_limit_exceeded, :nodes, maximum}}

  defp walk(term, depth, nodes, limits) when is_map(term) do
    if map_size(term) > limits.max_map_keys do
      {:error, {:decoded_term_limit_exceeded, :map_keys, limits.max_map_keys}}
    else
      walk_map(:maps.iterator(term), depth + 1, nodes + 1, limits)
    end
  end

  defp walk(term, depth, nodes, limits) when is_list(term),
    do: walk_list(term, depth + 1, nodes + 1, 0, limits)

  defp walk(term, depth, nodes, limits) when is_tuple(term),
    do: walk_tuple(term, 0, depth + 1, nodes + 1, limits)

  defp walk(term, _depth, nodes, _limits) when is_integer(term) do
    if term >= @signed_64_min and term <= @signed_64_max,
      do: {:ok, nodes + 1},
      else: {:error, {:decoded_term_invalid, :signed_64_required}}
  end

  defp walk(term, _depth, nodes, _limits) when is_float(term) do
    if finite_number?(term),
      do: {:ok, nodes + 1},
      else: {:error, {:decoded_term_invalid, :finite_float_required}}
  end

  defp walk(term, _depth, nodes, _limits) when is_binary(term) do
    if String.valid?(term),
      do: {:ok, nodes + 1},
      else: {:error, {:decoded_term_invalid, :valid_utf8_required}}
  end

  defp walk(term, _depth, nodes, _limits)
       when is_atom(term) or is_boolean(term) or is_nil(term),
       do: {:ok, nodes + 1}

  defp walk(_term, _depth, _nodes, _limits),
    do: {:error, {:decoded_term_invalid, :json_compatible_term_required}}

  defp walk_map(iterator, depth, nodes, limits) do
    case :maps.next(iterator) do
      :none ->
        {:ok, nodes}

      {key, value, next} ->
        with {:ok, nodes} <- walk(key, depth, nodes, limits),
             {:ok, nodes} <- walk(value, depth, nodes, limits) do
          walk_map(next, depth, nodes, limits)
        end
    end
  end

  defp walk_list([], _depth, nodes, _count, _limits), do: {:ok, nodes}

  defp walk_list(_list, _depth, _nodes, count, %{max_list_items: maximum})
       when count >= maximum,
       do: {:error, {:decoded_term_limit_exceeded, :list_items, maximum}}

  defp walk_list([head | tail], depth, nodes, count, limits) do
    with {:ok, nodes} <- walk(head, depth, nodes, limits) do
      walk_list(tail, depth, nodes, count + 1, limits)
    end
  end

  defp walk_list(_tail, _depth, _nodes, _count, _limits),
    do: {:error, {:decoded_term_invalid, :proper_list_required}}

  defp walk_tuple(tuple, index, _depth, nodes, _limits) when index == tuple_size(tuple),
    do: {:ok, nodes}

  defp walk_tuple(tuple, index, depth, nodes, limits) do
    with {:ok, nodes} <- walk(elem(tuple, index), depth, nodes, limits) do
      walk_tuple(tuple, index + 1, depth, nodes, limits)
    end
  end
end
