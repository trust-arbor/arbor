defmodule Arbor.Common.Commands.Tools do
  @moduledoc "List or search available tools."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "tools"

  @impl true
  def description, do: "List or search available tools"

  @impl true
  def usage, do: "/tools [find <query>]"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_agent?(ctx)

  @impl true
  def execute("", %Context{tools: []}) do
    {:ok, Result.ok("No tools available in current context.")}
  end

  def execute("", %Context{tools: tools}) when is_list(tools) do
    lines = Enum.map(tools, &"  #{&1}")
    {:ok, Result.ok("Available tools (#{length(tools)}):\n" <> Enum.join(lines, "\n"))}
  end

  def execute("find " <> query, %Context{} = ctx) do
    do_find(String.trim(query), ctx)
  end

  def execute(other, %Context{} = ctx) do
    do_find(String.trim(other), ctx)
  end

  defp do_find(_query, %Context{tools: []}) do
    {:ok, Result.ok("No tools available in current context.")}
  end

  defp do_find(query, %Context{tools: tools}) when is_list(tools) do
    q = String.downcase(query)
    matches = Enum.filter(tools, &String.contains?(String.downcase(&1), q))

    case matches do
      [] ->
        {:ok, Result.ok("No tools matching \"#{query}\".")}

      _ ->
        lines = Enum.map(matches, &"  #{&1}")
        {:ok, Result.ok("Tools matching \"#{query}\":\n" <> Enum.join(lines, "\n"))}
    end
  end
end
