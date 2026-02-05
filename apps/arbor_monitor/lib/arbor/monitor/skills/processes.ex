defmodule Arbor.Monitor.Skills.Processes do
  @moduledoc """
  Process metrics: top processes by memory, reductions, message queue length.
  """

  @behaviour Arbor.Monitor.Skill

  alias Arbor.Monitor.Config

  @impl true
  def name, do: :processes

  @impl true
  def collect do
    top_by_memory = safe_proc_count(:memory, 10)
    top_by_reductions = safe_proc_count(:reductions, 10)
    top_by_message_queue = safe_proc_count(:message_queue_len, 10)

    max_message_queue =
      case top_by_message_queue do
        [{_, count, _} | _] -> count
        _ -> 0
      end

    metrics = %{
      top_by_memory: format_proc_list(top_by_memory),
      top_by_reductions: format_proc_list(top_by_reductions),
      top_by_message_queue: format_proc_list(top_by_message_queue),
      max_message_queue_len: max_message_queue
    }

    {:ok, metrics}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @impl true
  def check(metrics) do
    config = Config.anomaly_config()
    mq_threshold = get_in(config, [:message_queue_len, :threshold]) || 10_000

    if metrics[:max_message_queue_len] > mq_threshold do
      {:anomaly, :warning,
       %{
         metric: :message_queue_len,
         value: metrics[:max_message_queue_len],
         threshold: mq_threshold
       }}
    else
      :normal
    end
  end

  defp safe_proc_count(attribute, count) do
    :recon.proc_count(attribute, count)
  rescue
    _ -> []
  end

  defp format_proc_list(procs) do
    Enum.map(procs, fn {pid, value, info} ->
      %{
        pid: inspect(pid),
        value: value,
        info: sanitize_info(info)
      }
    end)
  end

  defp sanitize_info(info) when is_list(info) do
    info
    |> Enum.flat_map(fn
      {:current_function, mfa} -> [{:current_function, inspect(mfa)}]
      {:initial_call, mfa} -> [{:initial_call, inspect(mfa)}]
      {:registered_name, name} -> [{:registered_name, name}]
      {key, val} when is_atom(key) -> [{key, inspect(val)}]
      _ -> []
    end)
    |> Map.new()
  end

  defp sanitize_info(info), do: %{raw: inspect(info)}
end
