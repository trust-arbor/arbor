defmodule Arbor.Agent.PerceptFormatter do
  @moduledoc """
  Formats action execution results into structured Percepts.

  Converts raw `{:ok, result}` / `{:error, reason}` tuples from action
  execution into `Percept` structs with human-readable summaries and
  truncated data suitable for Mind context.

  ## Percept Categories

  - **SUCCESS** — Intent completed, data available
  - **BLOCKED** — Authorization denied (capability or reflex)
  - **FAILED** — Execution error (action crashed, invalid params, etc.)

  ## Data Truncation

  Large result data is truncated to `@max_data_chars` (4000 characters)
  with a truncation marker. This keeps percepts lean for the Mind's
  context window while preserving the most useful information.
  """

  alias Arbor.Contracts.Memory.Percept

  @max_data_chars 4000

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Create a Percept from an action execution result.

  ## Parameters

  - `intent` — the Intent that was executed (needs `id`, `capability`, `op`, `target`)
  - `result` — `{:ok, data}` or `{:error, reason}` from action execution
  - `duration_ms` — execution time in milliseconds

  ## Examples

      percept = PerceptFormatter.from_result(intent, {:ok, %{content: "..."}}, 42)
      percept.outcome
      # => :success
      percept.summary
      # => "fs.read /etc/hosts — succeeded"
  """
  @spec from_result(map(), {:ok, any()} | {:error, any()}, non_neg_integer()) :: Percept.t()
  def from_result(intent, {:ok, result}, duration_ms) do
    data = truncate_data(normalize_data(result))

    Percept.success(intent_id(intent), data,
      summary: success_summary(intent, result),
      duration_ms: duration_ms
    )
  end

  def from_result(intent, {:error, :unauthorized}, duration_ms) do
    Percept.blocked(intent_id(intent), "unauthorized",
      summary: blocked_summary(intent, :unauthorized),
      duration_ms: duration_ms
    )
  end

  def from_result(intent, {:error, {:taint_blocked, param, level, role}}, duration_ms) do
    Percept.blocked(intent_id(intent), "taint_blocked",
      summary: blocked_summary(intent, {:taint_blocked, param, level, role}),
      duration_ms: duration_ms,
      data: %{param: param, taint_level: level, role: role}
    )
  end

  def from_result(intent, {:error, reason}, duration_ms) do
    Percept.failure(intent_id(intent), sanitize_error(reason),
      summary: failure_summary(intent, reason),
      duration_ms: duration_ms
    )
  end

  @doc """
  Create a timeout Percept.
  """
  @spec timeout(map(), non_neg_integer()) :: Percept.t()
  def timeout(intent, duration_ms) do
    Percept.timeout(intent_id(intent), duration_ms,
      summary: "#{cap_op(intent)} — timed out after #{duration_ms}ms"
    )
  end

  @doc """
  Create a Percept for a mental action result (store-backed operations).
  """
  @spec from_mental_result(map(), {:ok, any()} | {:error, any()} | any()) :: Percept.t()
  def from_mental_result(intent, {:ok, result}) do
    data = truncate_data(normalize_data(result))

    Percept.success(intent_id(intent), data, summary: success_summary(intent, result))
  end

  def from_mental_result(intent, {:error, reason}) do
    Percept.failure(intent_id(intent), sanitize_error(reason),
      summary: failure_summary(intent, reason)
    )
  end

  # Catch-all for bare results (not wrapped in {:ok, _} or {:error, _})
  def from_mental_result(intent, result) do
    data = truncate_data(normalize_data(result))

    Percept.success(intent_id(intent), data, summary: success_summary(intent, result))
  end

  # ── Summaries ──────────────────────────────────────────────────────

  defp success_summary(intent, result) do
    detail = result_detail(intent, result)

    if detail do
      "#{cap_op(intent)}#{target_suffix(intent)} — #{detail}"
    else
      "#{cap_op(intent)}#{target_suffix(intent)} — succeeded"
    end
  end

  defp blocked_summary(intent, :unauthorized) do
    "BLOCKED: #{cap_op(intent)}#{target_suffix(intent)} — unauthorized"
  end

  defp blocked_summary(intent, {:taint_blocked, param, level, _role}) do
    "BLOCKED: #{cap_op(intent)}#{target_suffix(intent)} — taint #{level} on #{param}"
  end

  defp failure_summary(intent, reason) do
    msg = error_message(reason)
    "FAILED: #{cap_op(intent)}#{target_suffix(intent)} — #{msg}"
  end

  # ── Result Detail Extraction ───────────────────────────────────────

  defp result_detail(%{capability: "fs", op: :read}, result) when is_map(result) do
    content = Map.get(result, :content) || Map.get(result, "content")

    if is_binary(content) do
      lines = content |> String.split("\n") |> length()
      "read #{lines} lines"
    end
  end

  defp result_detail(%{capability: "fs", op: :write}, result) when is_map(result) do
    bytes = Map.get(result, :bytes_written) || Map.get(result, "bytes_written")
    if bytes, do: "wrote #{bytes} bytes"
  end

  defp result_detail(%{capability: "fs", op: :list}, result) when is_map(result) do
    entries = Map.get(result, :entries) || Map.get(result, "entries") || []
    "#{length(List.wrap(entries))} entries"
  end

  defp result_detail(%{capability: "fs", op: :glob}, result) when is_map(result) do
    matches = Map.get(result, :matches) || Map.get(result, "matches") || []
    "#{length(List.wrap(matches))} matches"
  end

  defp result_detail(%{capability: "fs", op: :search}, result) when is_map(result) do
    matches = Map.get(result, :matches) || Map.get(result, "matches") || []
    "#{length(List.wrap(matches))} matches"
  end

  defp result_detail(%{capability: "shell"}, result) when is_map(result) do
    code = Map.get(result, :exit_code) || Map.get(result, "exit_code")
    if code, do: "exit #{code}"
  end

  defp result_detail(%{capability: "code", op: op}, result)
       when op in [:compile, :test] and is_map(result) do
    status = Map.get(result, :status) || Map.get(result, "status")
    if status, do: "#{status}"
  end

  defp result_detail(%{capability: "git", op: :log}, result) when is_map(result) do
    commits = Map.get(result, :commits) || Map.get(result, "commits") || []
    "#{length(List.wrap(commits))} commits"
  end

  defp result_detail(%{capability: "memory", op: :recall}, result) when is_map(result) do
    results = Map.get(result, :results) || Map.get(result, "results") || []
    "#{length(List.wrap(results))} results"
  end

  defp result_detail(_intent, _result), do: nil

  # ── Data Processing ────────────────────────────────────────────────

  defp normalize_data(%_{} = data), do: Map.from_struct(data)
  defp normalize_data(data) when is_map(data), do: data
  defp normalize_data(data) when is_binary(data), do: %{text: data}
  defp normalize_data(data) when is_list(data), do: %{items: data}
  defp normalize_data(data), do: %{value: inspect(data)}

  defp truncate_data(data) when is_map(data) do
    # Always apply per-value truncation (large strings, long lists)
    truncated = Map.new(data, fn {k, v} -> {k, truncate_value(v)} end)

    if truncated != data do
      Map.put(truncated, :_truncated, true)
    else
      truncated
    end
  end

  defp truncate_value(v) when is_binary(v) and byte_size(v) > @max_data_chars do
    String.slice(v, 0, @max_data_chars) <> "\n... (truncated)"
  end

  defp truncate_value(v) when is_list(v) and length(v) > 50 do
    Enum.take(v, 50) ++ ["... (#{length(v) - 50} more)"]
  end

  defp truncate_value(v), do: v

  # ── Error Sanitization ─────────────────────────────────────────────

  defp sanitize_error(reason) when is_atom(reason), do: reason

  defp sanitize_error(reason) when is_binary(reason) do
    # Strip internal module paths and stack traces
    reason
    |> String.replace(~r/\(.*?\.ex:\d+\)/, "(internal)")
    |> String.slice(0, 500)
  end

  defp sanitize_error({type, detail}) when is_atom(type) do
    {type, sanitize_error(detail)}
  end

  defp sanitize_error(reason), do: inspect(reason) |> String.slice(0, 500)

  defp error_message(reason) when is_atom(reason), do: to_string(reason)
  defp error_message(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp error_message({type, _}), do: to_string(type)
  defp error_message(reason), do: inspect(reason) |> String.slice(0, 200)

  # ── Helpers ────────────────────────────────────────────────────────

  defp cap_op(%{capability: cap, op: op}) when is_binary(cap) and not is_nil(op) do
    "#{cap}.#{op}"
  end

  defp cap_op(%{action: action}) when not is_nil(action), do: to_string(action)
  defp cap_op(_), do: "unknown"

  defp target_suffix(%{target: target}) when is_binary(target) and target != "" do
    short =
      if String.length(target) > 60, do: "..." <> String.slice(target, -57, 57), else: target

    " #{short}"
  end

  defp target_suffix(_), do: ""

  defp intent_id(%{id: id}) when is_binary(id), do: id
  defp intent_id(_), do: nil
end
