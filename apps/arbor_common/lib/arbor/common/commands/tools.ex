defmodule Arbor.Common.Commands.Tools do
  @moduledoc "List or search available tools."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "tools"

  @impl true
  def description, do: "List or search available tools"

  @impl true
  def usage, do: "/tools [find <query>]"

  @impl true
  def available?(_context), do: true

  @impl true
  def execute("", context) do
    case context[:tools] do
      tools when is_list(tools) and length(tools) > 0 ->
        lines = Enum.map(tools, fn
          %{name: name, description: desc} -> "  #{name} — #{desc}"
          {name, desc} -> "  #{name} — #{desc}"
          name when is_binary(name) -> "  #{name}"
        end)

        {:ok, "Available tools (#{length(tools)}):\n" <> Enum.join(lines, "\n")}

      _ ->
        {:ok, "No tools available in current context."}
    end
  end

  def execute("find " <> query, context) do
    query = String.trim(query)

    case context[:find_tools_fn] do
      fun when is_function(fun, 1) ->
        case fun.(query) do
          {:ok, results} when is_list(results) ->
            if results == [] do
              {:ok, "No tools matching \"#{query}\"."}
            else
              lines = Enum.map(results, fn
                %{name: name, description: desc} -> "  #{name} — #{desc}"
                {name, desc} -> "  #{name} — #{desc}"
              end)

              {:ok, "Tools matching \"#{query}\":\n" <> Enum.join(lines, "\n")}
            end

          _ ->
            {:ok, "Tool search not available."}
        end

      _ ->
        # Fall back to filtering context tools
        case context[:tools] do
          tools when is_list(tools) ->
            q = String.downcase(query)

            matches =
              Enum.filter(tools, fn
                %{name: name, description: desc} ->
                  String.contains?(String.downcase(name), q) or
                    String.contains?(String.downcase(desc || ""), q)

                {name, desc} ->
                  String.contains?(String.downcase(to_string(name)), q) or
                    String.contains?(String.downcase(to_string(desc)), q)

                name when is_binary(name) ->
                  String.contains?(String.downcase(name), q)
              end)

            if matches == [] do
              {:ok, "No tools matching \"#{query}\"."}
            else
              lines = Enum.map(matches, fn
                %{name: name, description: desc} -> "  #{name} — #{desc}"
                {name, desc} -> "  #{name} — #{desc}"
                name -> "  #{name}"
              end)

              {:ok, "Tools matching \"#{query}\":\n" <> Enum.join(lines, "\n")}
            end

          _ ->
            {:ok, "Tool search not available."}
        end
    end
  end

  def execute(other, context), do: execute("find " <> other, context)
end
