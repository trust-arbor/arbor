defmodule Arbor.Common.Commands.Memory do
  @moduledoc "Show working memory summary."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "memory"

  @impl true
  def aliases, do: ["mem"]

  @impl true
  def description, do: "Show working memory summary"

  @impl true
  def usage, do: "/memory"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute(_args, %Context{working_memory_summary: nil}) do
    {:ok, Result.ok("No working memory available.")}
  end

  def execute(_args, %Context{working_memory_summary: data}) when is_map(data) do
    {:ok, Result.ok(format_memory(data))}
  end

  defp format_memory(data) do
    counts = [
      maybe_count("Thoughts", data[:thoughts]),
      maybe_count("Concerns", data[:concerns]),
      maybe_count("Curiosities", data[:curiosities])
    ]

    lines = ["Working Memory:" | Enum.reject(counts, &is_nil/1)]
    Enum.join(lines, "\n")
  end

  defp maybe_count(_label, nil), do: nil
  defp maybe_count(_label, []), do: nil

  defp maybe_count(label, list) when is_list(list) do
    "  #{label}: #{length(list)}"
  end

  defp maybe_count(_label, _), do: nil
end
