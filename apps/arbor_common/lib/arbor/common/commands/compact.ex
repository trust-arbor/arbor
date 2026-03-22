defmodule Arbor.Common.Commands.Compact do
  @moduledoc "Trigger context compaction for the current session."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "compact"

  @impl true
  def description, do: "Compact session context to free token space"

  @impl true
  def usage, do: "/compact"

  @impl true
  def available?(context), do: context[:session_pid] != nil

  @impl true
  def execute(_args, context) do
    case context[:compact_fn] do
      fun when is_function(fun, 0) ->
        case fun.() do
          :ok -> {:ok, "Context compacted."}
          {:ok, stats} -> {:ok, "Context compacted. #{format_stats(stats)}"}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, "Compaction not available — no active session."}
    end
  end

  defp format_stats(stats) when is_map(stats) do
    parts = []

    parts =
      if before = stats[:messages_before],
        do: parts ++ ["#{before} → #{stats[:messages_after] || "?"} messages"],
        else: parts

    parts =
      if ratio = stats[:compression_ratio],
        do: parts ++ ["#{Float.round(ratio * 100, 1)}% reduction"],
        else: parts

    Enum.join(parts, ", ")
  end

  defp format_stats(_), do: ""
end
