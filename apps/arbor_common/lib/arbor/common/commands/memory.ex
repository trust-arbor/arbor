defmodule Arbor.Common.Commands.Memory do
  @moduledoc "Show working memory summary."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "memory"

  @impl true
  def aliases, do: ["mem"]

  @impl true
  def description, do: "Show working memory summary"

  @impl true
  def usage, do: "/memory"

  @impl true
  def available?(_context), do: true

  @impl true
  def execute(_args, context) do
    case context[:memory_fn] do
      fun when is_function(fun, 0) ->
        case fun.() do
          {:ok, summary} when is_binary(summary) -> {:ok, summary}
          {:ok, data} when is_map(data) -> {:ok, format_memory(data)}
          _ -> {:ok, "No working memory available."}
        end

      _ ->
        {:ok, "Working memory not available in this context."}
    end
  end

  defp format_memory(data) do
    lines = ["Working Memory:"]

    lines =
      case data[:thoughts] do
        thoughts when is_list(thoughts) and length(thoughts) > 0 ->
          lines ++ ["  Thoughts: #{length(thoughts)}"]

        _ ->
          lines
      end

    lines =
      case data[:concerns] do
        concerns when is_list(concerns) and length(concerns) > 0 ->
          lines ++ ["  Concerns: #{length(concerns)}"]

        _ ->
          lines
      end

    lines =
      case data[:curiosities] do
        curiosities when is_list(curiosities) and length(curiosities) > 0 ->
          lines ++ ["  Curiosities: #{length(curiosities)}"]

        _ ->
          lines
      end

    Enum.join(lines, "\n")
  end
end
