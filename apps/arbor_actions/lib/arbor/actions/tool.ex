defmodule Arbor.Actions.Tool do
  @moduledoc """
  Tool discovery actions for progressive tool disclosure.

  Agents use `FindTools` to discover additional tools on demand rather than
  having all ~149 tools loaded into context at once. Results are full OpenAI-format
  tool schemas so the agent can use discovered tools immediately.

  ## Authorization

  - FindTools: `arbor://actions/find_tools`
  """

  defmodule FindTools do
    @moduledoc """
    Search for available tools by query and return their full schemas.

    Backed by `CapabilityResolver.search/2` for trust-gated discovery across
    all registries (actions, skills, pipelines). Returns OpenAI-format tool
    definitions so the agent can call discovered tools in the same turn.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `query` | string | yes | Natural language query describing what tools you need |
    | `limit` | integer | no | Max tools to return (default: 10) |
    """

    use Jido.Action,
      name: "tool_find_tools",
      description:
        "Search for additional tools by query. Returns full tool schemas you can use immediately. " <>
          "Use when you need a capability not in your current tool set.",
      category: "tool",
      tags: ["tool", "discovery", "search", "progressive"],
      schema: [
        query: [type: :string, required: true, doc: "What tools do you need? Describe the task."],
        limit: [type: :integer, default: 10, doc: "Max tools to return"]
      ]

    alias Arbor.Actions

    require Logger

    def taint_roles, do: %{query: :control, limit: :data}

    @impl true
    def run(params, context) do
      query = params[:query]
      limit = params[:limit] || 10
      trust_tier = context[:trust_tier] || :new

      Actions.emit_started(__MODULE__, %{query: query, limit: limit})

      resolver = Arbor.Common.CapabilityResolver
      executor_mod = executor_module()

      tools =
        if Code.ensure_loaded?(resolver) and function_exported?(resolver, :search, 2) do
          try do
            matches =
              resolver.search(query, trust_tier: trust_tier, limit: limit, kind: :action)

            matches
            |> Enum.flat_map(&match_to_tool_schema(&1, executor_mod))
            |> Enum.uniq_by(fn tool -> get_in(tool, ["function", "name"]) end)
          rescue
            _ -> fallback_search(query, limit, executor_mod)
          end
        else
          # Fallback: search action names directly
          fallback_search(query, limit, executor_mod)
        end

      tool_names = Enum.map(tools, fn t -> get_in(t, ["function", "name"]) end)

      Actions.emit_completed(__MODULE__, %{count: length(tools), tool_names: tool_names})

      {:ok,
       %{
         tools: tools,
         count: length(tools),
         discovered_tool_names: tool_names
       }}
    end

    # Convert a CapabilityMatch to OpenAI tool schema(s)
    defp match_to_tool_schema(match, executor_mod) do
      descriptor = match.descriptor
      metadata = descriptor.metadata || %{}

      # Actions have a :module in metadata — convert to tool schema
      module = metadata[:module] || metadata["module"]

      cond do
        module != nil and is_atom(module) and function_exported?(module, :to_tool, 0) ->
          tool = module.to_tool()
          [apply(executor_mod, :to_openai_format, [tool])]

        descriptor.kind == :action and descriptor.source_ref != nil ->
          # Try resolving by source_ref (action name)
          case resolve_by_name(descriptor.source_ref, executor_mod) do
            {:ok, defs} -> defs
            :error -> []
          end

        true ->
          []
      end
    rescue
      _ -> []
    end

    defp resolve_by_name(name, executor_mod) do
      defs = apply(executor_mod, :definitions, [[name]])

      if defs != [] do
        {:ok, defs}
      else
        :error
      end
    rescue
      _ -> :error
    end

    # Fallback when CapabilityResolver is unavailable: substring match on action names
    defp fallback_search(query, limit, executor_mod) do
      actions_mod = Module.concat([:Arbor, :Actions])

      if Code.ensure_loaded?(actions_mod) and function_exported?(actions_mod, :all_actions, 0) do
        query_lower = String.downcase(query)
        query_words = String.split(query_lower, ~r/\s+/)

        apply(actions_mod, :all_actions, [])
        |> Enum.filter(fn module ->
          tool = module.to_tool()
          name = String.downcase(tool.name || "")
          desc = String.downcase(tool.description || "")
          text = name <> " " <> desc

          Enum.any?(query_words, &String.contains?(text, &1))
        end)
        |> Enum.take(limit)
        |> Enum.map(fn module ->
          apply(executor_mod, :to_openai_format, [module.to_tool()])
        end)
      else
        []
      end
    rescue
      _ -> []
    end

    defp executor_module do
      Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutor
    end
  end
end
