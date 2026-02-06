defmodule Arbor.Agent.ToolBridge do
  @moduledoc """
  Bridge between SDK tools and Arbor.Actions.

  Exposes Arbor.Actions as SDK tools while preserving:
  - Capability checks via `authorize_and_execute/4`
  - Taint enforcement
  - Signal emission
  - Full observability

  ## Usage

      # Configure tools for an agent
      {:ok, server} = Arbor.AI.AgentSDK.ToolServer.start_link(name: nil)
      ToolBridge.register_actions(server, agent_id, context)

      # Now Claude can call actions as tools
      ToolServer.call_tool("file_read", %{path: "/tmp/test.txt"}, server)

  ## Architecture

  This module lives in arbor_agent (Level 2) because it needs access to:
  - `Arbor.Actions` (Level 2) for action execution
  - `Arbor.AI.AgentSDK.ToolServer` (Standalone) for tool registration

  The ToolServer in arbor_ai is kept generic — it doesn't know about actions.
  This bridge provides the integration layer.
  """

  alias Arbor.AI.AgentSDK.ToolServer

  @doc """
  Register all Arbor.Actions as tools on a ToolServer.

  Each action becomes a tool that routes through `authorize_and_execute/4`,
  preserving capability checks and taint enforcement.

  ## Parameters

  - `server` - ToolServer pid or name
  - `agent_id` - Agent ID for capability checks
  - `context` - Execution context (workspace, taint policy, etc.)
  - `opts` - Options:
    - `:categories` - List of action categories to register (default: all)
    - `:exclude` - List of action names to exclude

  ## Examples

      # Register all actions
      ToolBridge.register_actions(server, "agent_001", %{workspace: "/tmp"})

      # Register only file and git actions
      ToolBridge.register_actions(server, "agent_001", %{},
        categories: [:file, :git]
      )

      # Exclude dangerous actions
      ToolBridge.register_actions(server, "agent_001", %{},
        exclude: ["shell_execute", "code_hot_load"]
      )
  """
  @spec register_actions(GenServer.server(), String.t(), map(), keyword()) :: :ok
  def register_actions(server, agent_id, context, opts \\ []) do
    categories = Keyword.get(opts, :categories, :all)
    exclude = Keyword.get(opts, :exclude, [])

    actions = get_actions(categories)

    for action <- actions do
      raw_schema = action.to_tool()
      schema = convert_schema(raw_schema)
      name = schema["name"]

      unless name in exclude do
        handler = build_handler(agent_id, action, context)
        ToolServer.register_handler(name, schema, handler, server)
      end
    end

    :ok
  end

  @doc """
  Unregister all action-based tools from a ToolServer.
  """
  @spec unregister_actions(GenServer.server(), keyword()) :: :ok
  def unregister_actions(server, opts \\ []) do
    categories = Keyword.get(opts, :categories, :all)

    actions = get_actions(categories)

    for action <- actions do
      raw_schema = action.to_tool()
      name = raw_schema[:name] || raw_schema.name
      ToolServer.unregister_handler(name, server)
    end

    :ok
  end

  @doc """
  Register a single action as a tool.
  """
  @spec register_action(GenServer.server(), module(), String.t(), map()) :: :ok
  def register_action(server, action_module, agent_id, context) do
    raw_schema = action_module.to_tool()
    schema = convert_schema(raw_schema)
    handler = build_handler(agent_id, action_module, context)
    ToolServer.register_handler(schema["name"], schema, handler, server)
  end

  # Get actions, optionally filtered by category
  defp get_actions(:all) do
    Arbor.Actions.all_actions()
  end

  defp get_actions(categories) when is_list(categories) do
    all = Arbor.Actions.list_actions()

    categories
    |> Enum.flat_map(fn cat -> Map.get(all, cat, []) end)
  end

  # Convert Jido action tool schema to SDK tool schema format
  # Jido: %{name: "x", description: "y", parameters_schema: %{...}}
  # SDK:  %{"name" => "x", "description" => "y", "input_schema" => %{...}}
  defp convert_schema(action_schema) do
    %{
      "name" => action_schema[:name] || action_schema.name,
      "description" => action_schema[:description] || action_schema.description,
      "input_schema" => action_schema[:parameters_schema] || action_schema.parameters_schema || %{}
    }
  end

  # Build a handler function that routes through authorize_and_execute
  defp build_handler(agent_id, action_module, context) do
    fn args ->
      case Arbor.Actions.authorize_and_execute(agent_id, action_module, args, context) do
        {:ok, result} ->
          {:ok, result}

        {:ok, :pending_approval, proposal_id} ->
          {:error, "Action requires approval. Proposal ID: #{proposal_id}"}

        {:error, :unauthorized} ->
          {:error, "Unauthorized: agent lacks capability for this action"}

        {:error, {:taint_blocked, param, level, _role}} ->
          {:error, "Taint blocked: #{param} has taint level #{level}"}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end
end
