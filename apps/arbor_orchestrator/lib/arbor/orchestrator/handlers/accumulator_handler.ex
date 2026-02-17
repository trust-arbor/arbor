defmodule Arbor.Orchestrator.Handlers.AccumulatorHandler do
  @moduledoc """
  Handler that performs stateful reduction across pipeline nodes.

  Accumulates values, counts, and aggregates collections by reading from context,
  applying an operation, and writing the result back.

  ## Node Attributes

    - `input_key` - context key to read the input value from (required)
    - `accumulator_key` - context key to store/read the accumulator
      (default: `"accumulator.{node_id}"`)
    - `init_value` - initial value when the accumulator doesn't exist yet
      (default depends on operation)
    - `operation` - which accumulation operation to perform (required).
      One of: `"sum"`, `"count"`, `"min"`, `"max"`, `"product"`, `"avg"`,
      `"append"`, `"prepend"`, `"merge"`, `"concat"`
    - `limit` - optional max value (numeric ops) or max length (collection ops)
    - `limit_action` - what to do when limit is exceeded:
      `"fail"`, `"warn"` (default), or `"cap"`

  ## Context Updates

    - `{accumulator_key}` - the accumulated value (JSON-encoded if complex)
    - `accumulator.{node_id}.operation` - the operation name
    - `accumulator.{node_id}.input` - the input value used
    - `accumulator.{node_id}.previous` - value before this operation
    - `accumulator.{node_id}.limit_exceeded` - `"true"` if limit was hit

  For `"avg"`, also sets:
    - `accumulator.{node_id}.avg` - the computed average as a string
  """

  @behaviour Arbor.Orchestrator.Handlers.Handler

  alias Arbor.Orchestrator.Engine.{Context, Outcome}

  @numeric_ops ~w(sum count min max product avg)
  @collection_ops ~w(append prepend merge concat)
  @all_ops @numeric_ops ++ @collection_ops

  @impl true
  def execute(node, context, _graph, _opts) do
    operation = Map.get(node.attrs, "operation")
    input_key = Map.get(node.attrs, "input_key")

    unless operation do
      raise "accumulator requires 'operation' attribute"
    end

    unless operation in @all_ops do
      raise "unknown accumulator operation '#{operation}'. " <>
              "Must be one of: #{Enum.join(@all_ops, ", ")}"
    end

    unless input_key do
      raise "accumulator requires 'input_key' attribute"
    end

    acc_key = Map.get(node.attrs, "accumulator_key", "accumulator.#{node.id}")
    limit = parse_limit(Map.get(node.attrs, "limit"))
    limit_action = Map.get(node.attrs, "limit_action", "warn")
    meta_prefix = "accumulator.#{node.id}"

    input_value = Context.get(context, input_key)
    previous = Context.get(context, acc_key)

    init_value = resolve_init(Map.get(node.attrs, "init_value"), operation)
    current = if is_nil(previous), do: init_value, else: decode_accumulator(previous, operation)

    {result, display_value, extra_updates} = apply_operation(operation, current, input_value)

    {final_result, final_display, limit_exceeded, limit_note} =
      check_limit(result, display_value, limit, limit_action, operation)

    case limit_note do
      {:fail, reason} ->
        %Outcome{
          status: :fail,
          failure_reason: reason
        }

      _ ->
        encoded = encode_accumulator(final_result, operation)

        updates =
          %{
            acc_key => encoded,
            "#{meta_prefix}.operation" => operation,
            "#{meta_prefix}.input" => to_context_string(input_value),
            "#{meta_prefix}.previous" => to_context_string(previous),
            "#{meta_prefix}.limit_exceeded" => to_string(limit_exceeded)
          }
          |> Map.merge(extra_updates)
          |> maybe_add_avg(meta_prefix, final_display, operation)

        notes = build_notes(operation, input_value, final_display, limit_exceeded, limit_note)

        %Outcome{
          status: :success,
          notes: notes,
          context_updates: updates
        }
    end
  rescue
    e ->
      %Outcome{
        status: :fail,
        failure_reason: "accumulator error: #{Exception.message(e)}"
      }
  end

  @impl true
  def idempotency, do: :idempotent

  # --- Operations ---

  defp apply_operation("sum", current, input) do
    a = ensure_number(current)
    b = ensure_number(input)
    result = a + b
    {result, result, %{}}
  end

  defp apply_operation("count", current, _input) do
    a = ensure_number(current)
    result = a + 1
    {result, result, %{}}
  end

  defp apply_operation("min", current, input) do
    a = ensure_number(current)
    b = ensure_number(input)
    result = min(a, b)
    {result, result, %{}}
  end

  defp apply_operation("max", current, input) do
    a = ensure_number(current)
    b = ensure_number(input)
    result = max(a, b)
    {result, result, %{}}
  end

  defp apply_operation("product", current, input) do
    a = ensure_number(current)
    b = ensure_number(input)
    result = a * b
    {result, result, %{}}
  end

  defp apply_operation("avg", current, input) do
    {sum, count} = ensure_avg_state(current)
    b = ensure_number(input)
    new_sum = sum + b
    new_count = count + 1
    avg = new_sum / new_count
    {{new_sum, new_count}, avg, %{}}
  end

  defp apply_operation("append", current, input) do
    list = ensure_list(current)
    result = list ++ [input]
    {result, result, %{}}
  end

  defp apply_operation("prepend", current, input) do
    list = ensure_list(current)
    result = [input | list]
    {result, result, %{}}
  end

  defp apply_operation("merge", current, input) do
    base = ensure_map(current)
    overlay = ensure_map(input)
    result = deep_merge(base, overlay)
    {result, result, %{}}
  end

  defp apply_operation("concat", current, input) do
    a = to_string(current)
    b = to_string(input)
    result = a <> b
    {result, result, %{}}
  end

  # --- Type Coercion ---

  defp ensure_number(nil), do: 0

  defp ensure_number(n) when is_number(n), do: n

  defp ensure_number(s) when is_binary(s) do
    s = String.trim(s)

    case Float.parse(s) do
      {f, ""} ->
        if trunc(f) == f and not String.contains?(s, "."), do: trunc(f), else: f

      _ ->
        raise "cannot convert '#{s}' to number"
    end
  end

  defp ensure_number(other) do
    raise "cannot convert #{inspect(other)} to number"
  end

  defp ensure_list(nil), do: []
  defp ensure_list(list) when is_list(list), do: list

  defp ensure_list(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, list} when is_list(list) -> list
      _ -> [s]
    end
  end

  defp ensure_list(other), do: [other]

  defp ensure_map(nil), do: %{}
  defp ensure_map(map) when is_map(map), do: map

  defp ensure_map(s) when is_binary(s) do
    case Jason.decode(s) do
      {:ok, map} when is_map(map) -> map
      _ -> raise "cannot convert '#{s}' to map"
    end
  end

  defp ensure_map(other) do
    raise "cannot convert #{inspect(other)} to map"
  end

  defp ensure_avg_state({sum, count}) when is_number(sum) and is_number(count), do: {sum, count}
  defp ensure_avg_state(%{"sum" => s, "count" => c}), do: {ensure_number(s), ensure_number(c)}
  defp ensure_avg_state(nil), do: {0, 0}

  defp ensure_avg_state(other) when is_number(other), do: {other, 1}

  defp ensure_avg_state(other) do
    raise "invalid avg state: #{inspect(other)}"
  end

  # --- Init Values ---

  defp resolve_init(nil, "sum"), do: 0
  defp resolve_init(nil, "count"), do: 0
  defp resolve_init(nil, "min"), do: 1.0e308
  defp resolve_init(nil, "max"), do: -1.0e308
  defp resolve_init(nil, "product"), do: 1
  defp resolve_init(nil, "avg"), do: {0, 0}
  defp resolve_init(nil, "append"), do: []
  defp resolve_init(nil, "prepend"), do: []
  defp resolve_init(nil, "merge"), do: %{}
  defp resolve_init(nil, "concat"), do: ""

  defp resolve_init(value, op) when op in @numeric_ops, do: ensure_number(value)
  defp resolve_init(value, "append"), do: ensure_list(value)
  defp resolve_init(value, "prepend"), do: ensure_list(value)
  defp resolve_init(value, "merge"), do: ensure_map(value)
  defp resolve_init(value, "concat"), do: to_string(value)

  # --- Accumulator Encoding/Decoding ---

  defp encode_accumulator({sum, count}, "avg") do
    Jason.encode!(%{"sum" => sum, "count" => count})
  end

  defp encode_accumulator(value, _op) when is_list(value) or is_map(value) do
    Jason.encode!(value)
  end

  defp encode_accumulator(value, _op), do: to_string(value)

  defp decode_accumulator(value, "avg") when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"sum" => s, "count" => c}} -> {ensure_number(s), ensure_number(c)}
      _ -> ensure_avg_state(value)
    end
  end

  defp decode_accumulator(value, op) when op in ~w(append prepend) and is_binary(value) do
    ensure_list(value)
  end

  defp decode_accumulator(value, "merge") when is_binary(value), do: ensure_map(value)

  defp decode_accumulator(value, op) when op in @numeric_ops and is_binary(value) do
    ensure_number(value)
  end

  defp decode_accumulator(value, _op), do: value

  # --- Limit Checking ---

  defp check_limit(result, display, nil, _action, _op), do: {result, display, false, nil}

  defp check_limit(result, display, limit, action, op) when op in @numeric_ops do
    check_value = if op == "avg", do: display, else: result
    exceeded = is_number(check_value) and check_value > limit

    if exceeded do
      apply_limit_action(result, display, limit, action, op)
    else
      {result, display, false, nil}
    end
  end

  defp check_limit(result, display, limit, action, op) when op in ~w(append prepend) do
    exceeded = is_list(result) and length(result) > limit

    if exceeded do
      apply_limit_action(result, display, limit, action, op)
    else
      {result, display, false, nil}
    end
  end

  defp check_limit(result, display, limit, action, "concat") do
    exceeded = is_binary(result) and String.length(result) > limit

    if exceeded do
      apply_limit_action(result, display, limit, action, "concat")
    else
      {result, display, false, nil}
    end
  end

  defp check_limit(result, display, limit, action, "merge") do
    exceeded = is_map(result) and map_size(result) > limit

    if exceeded do
      apply_limit_action(result, display, limit, action, "merge")
    else
      {result, display, false, nil}
    end
  end

  defp apply_limit_action(result, display, limit, "fail", _op) do
    {result, display, true, {:fail, "accumulator exceeded limit of #{limit}"}}
  end

  defp apply_limit_action(result, display, limit, "cap", op) when op in @numeric_ops do
    capped =
      case op do
        "avg" -> result
        _ -> min(result, limit)
      end

    capped_display = if op == "avg", do: min(display, limit), else: capped
    {capped, capped_display, true, "capped at limit #{limit}"}
  end

  defp apply_limit_action(result, _display, limit, "cap", op) when op in ~w(append prepend) do
    capped = Enum.take(result, limit)
    {capped, capped, true, "capped at limit #{limit}"}
  end

  defp apply_limit_action(result, _display, limit, "cap", "concat") do
    capped = String.slice(result, 0, limit)
    {capped, capped, true, "capped at limit #{limit}"}
  end

  defp apply_limit_action(result, _display, limit, "cap", "merge") do
    capped = result |> Enum.take(limit) |> Map.new()
    {capped, capped, true, "capped at limit #{limit}"}
  end

  defp apply_limit_action(result, display, limit, _warn, _op) do
    {result, display, true, "warning: accumulator exceeded limit of #{limit}"}
  end

  # --- Helpers ---

  defp parse_limit(nil), do: nil

  defp parse_limit(value) when is_number(value), do: value

  defp parse_limit(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {f, ""} -> if trunc(f) == f, do: trunc(f), else: f
      _ -> nil
    end
  end

  defp parse_limit(_), do: nil

  defp deep_merge(base, overlay) when is_map(base) and is_map(overlay) do
    Map.merge(base, overlay, fn
      _key, v1, v2 when is_map(v1) and is_map(v2) -> deep_merge(v1, v2)
      _key, _v1, v2 -> v2
    end)
  end

  defp deep_merge(_base, overlay), do: overlay

  defp to_context_string(nil), do: ""
  defp to_context_string(value) when is_binary(value), do: value
  defp to_context_string(value) when is_number(value), do: to_string(value)
  defp to_context_string(value) when is_list(value) or is_map(value), do: Jason.encode!(value)
  defp to_context_string({sum, count}), do: Jason.encode!(%{"sum" => sum, "count" => count})
  defp to_context_string(value), do: inspect(value)

  defp maybe_add_avg(updates, meta_prefix, display_value, "avg") do
    Map.put(updates, "#{meta_prefix}.avg", to_string(display_value))
  end

  defp maybe_add_avg(updates, _meta_prefix, _display_value, _op), do: updates

  defp build_notes(operation, input, display, limit_exceeded, limit_note) do
    base = "#{operation}: input=#{to_context_string(input)}, result=#{to_context_string(display)}"

    if limit_exceeded and is_binary(limit_note) do
      "#{base} (#{limit_note})"
    else
      base
    end
  end
end
