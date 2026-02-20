defmodule Arbor.Actions.Monitor.ReadDiagnostics do
  @moduledoc """
  Read BEAM runtime diagnostics for investigating anomalies.

  Provides read-only inspection of processes, supervisors, and system state.
  Wraps `Arbor.Monitor.Diagnostics` via runtime bridge.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `query` | string | yes | What to inspect: "process", "supervisor", "top_processes", "system_info" |
  | `pid` | string | no | PID string for process/supervisor inspection |
  | `sort_by` | string | no | Sort key for top_processes: "memory", "reductions", "message_queue_len" |
  | `limit` | integer | no | Max results for top_processes (default: 10) |
  """

  use Jido.Action,
    name: "monitor_read_diagnostics",
    description: "Read BEAM runtime diagnostics for investigating anomalies",
    category: "monitor",
    tags: ["monitor", "diagnostics", "inspection"],
    schema: [
      query: [
        type: {:in, ["process", "supervisor", "top_processes", "system_info"]},
        required: true,
        doc: "What to inspect: process, supervisor, top_processes, system_info"
      ],
      pid: [
        type: :string,
        doc: "PID string for process/supervisor inspection"
      ],
      sort_by: [
        type: {:in, ["memory", "reductions", "message_queue_len"]},
        default: "memory",
        doc: "Sort key for top_processes"
      ],
      limit: [
        type: :non_neg_integer,
        default: 10,
        doc: "Max results for top_processes"
      ]
    ]

  @diagnostics_mod Arbor.Monitor.Diagnostics

  def taint_roles do
    %{query: :control, pid: :data, sort_by: :data, limit: :data}
  end

  @impl true
  def run(%{query: query} = params, _context) do
    if diagnostics_available?() do
      execute_query(query, params)
    else
      {:error, :diagnostics_unavailable}
    end
  end

  defp execute_query("process", %{pid: pid_str}) when is_binary(pid_str) do
    case parse_pid(pid_str) do
      {:ok, pid} ->
        case apply(@diagnostics_mod, :inspect_process, [pid]) do
          nil -> {:ok, %{query: "process", data: nil, message: "Process not found"}}
          data -> {:ok, %{query: "process", data: sanitize_data(data)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_query("process", _params) do
    {:error, :pid_required}
  end

  defp execute_query("supervisor", %{pid: pid_str}) when is_binary(pid_str) do
    case parse_pid(pid_str) do
      {:ok, pid} ->
        case apply(@diagnostics_mod, :inspect_supervisor, [pid]) do
          nil -> {:ok, %{query: "supervisor", data: nil, message: "Not a supervisor"}}
          data -> {:ok, %{query: "supervisor", data: sanitize_data(data)}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_query("supervisor", _params) do
    {:error, :pid_required}
  end

  defp execute_query("top_processes", params) do
    sort_by = sort_key(params[:sort_by] || "memory")
    limit = params[:limit] || 10

    data =
      if function_exported?(@diagnostics_mod, :top_processes, 2) do
        apply(@diagnostics_mod, :top_processes, [sort_by, limit])
      else
        # Fallback using recon if available
        try do
          :recon.proc_count(sort_by, limit)
          |> Enum.flat_map(fn
            {pid, value, info} when is_list(info) ->
              name =
                case List.keyfind(info, :registered_name, 0) do
                  {:registered_name, n} -> n
                  _ -> inspect(pid)
                end

              [%{pid: inspect(pid), name: inspect(name), value: value}]

            _ ->
              []
          end)
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end
      end

    {:ok, %{query: "top_processes", sort_by: params[:sort_by] || "memory", data: data}}
  end

  defp execute_query("system_info", _params) do
    data = %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      memory: :erlang.memory() |> Enum.into(%{}),
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      otp_release: :erlang.system_info(:otp_release) |> List.to_string(),
      uptime_ms: :erlang.statistics(:wall_clock) |> elem(0)
    }

    {:ok, %{query: "system_info", data: data}}
  end

  defp parse_pid(pid_string) when is_binary(pid_string) do
    case Regex.run(~r/<(\d+)\.(\d+)\.(\d+)>/, pid_string) do
      [_, a, b, c] ->
        {:ok, :erlang.list_to_pid(~c"<#{a}.#{b}.#{c}>")}

      nil ->
        {:error, :invalid_pid_format}
    end
  end

  defp sort_key("memory"), do: :memory
  defp sort_key("reductions"), do: :reductions
  defp sort_key("message_queue_len"), do: :message_queue_len
  defp sort_key(_), do: :memory

  defp diagnostics_available? do
    Code.ensure_loaded?(@diagnostics_mod)
  end

  defp sanitize_data(data) when is_map(data) do
    data
    |> Enum.map(fn
      {k, v} when is_pid(v) -> {k, inspect(v)}
      {k, v} when is_list(v) -> {k, Enum.map(v, &sanitize_value/1)}
      {k, v} -> {k, sanitize_value(v)}
    end)
    |> Enum.into(%{})
  end

  defp sanitize_data(data), do: data

  defp sanitize_value(v) when is_pid(v), do: inspect(v)
  defp sanitize_value(v) when is_port(v), do: inspect(v)
  defp sanitize_value(v) when is_reference(v), do: inspect(v)
  defp sanitize_value(v) when is_function(v), do: inspect(v)
  defp sanitize_value(v) when is_tuple(v), do: Tuple.to_list(v) |> Enum.map(&sanitize_value/1)
  defp sanitize_value(v), do: v
end
