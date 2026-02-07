defmodule Arbor.AI.AgentSDK.ToolServer do
  @moduledoc """
  In-process tool server for SDK-defined tools.

  Manages tool registrations and executes tool calls without subprocess overhead.
  Tools are registered from modules that `use Arbor.AI.AgentSDK.Tool`.

  ## Usage

      # Register a tools module
      ToolServer.register_tools(MyTools)

      # Call a tool
      {:ok, result} = ToolServer.call_tool("greet", %{"name" => "World"})

      # List available tools
      tools = ToolServer.list_tools()
  """

  use GenServer

  require Logger

  alias Arbor.AI.AgentSDK.Error
  alias Arbor.AI.AgentSDK.Tool

  @type tool_entry ::
          %{module: module(), schema: Tool.tool_schema()}
          | %{handler: (map() -> {:ok, term()} | {:error, term()}), schema: map()}

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Start the tool server.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register all tools from a module that uses `Arbor.AI.AgentSDK.Tool`.
  """
  @spec register_tools(module(), GenServer.server()) :: :ok | {:error, term()}
  def register_tools(module, server \\ __MODULE__) do
    GenServer.call(server, {:register, module})
  end

  @doc """
  Unregister all tools from a module.
  """
  @spec unregister_tools(module(), GenServer.server()) :: :ok
  def unregister_tools(module, server \\ __MODULE__) do
    GenServer.call(server, {:unregister, module})
  end

  @doc """
  Register a tool with a custom handler function.

  This allows registering tools that don't use the `Arbor.AI.AgentSDK.Tool` macro,
  such as wrappers around `Arbor.Actions` modules.

  ## Parameters

  - `name` - Tool name (string)
  - `schema` - JSON schema map with "name", "description", "input_schema"
  - `handler` - Function that takes args map and returns `{:ok, result}` or `{:error, reason}`
  - `server` - GenServer reference (default: __MODULE__)

  ## Example

      schema = %{
        "name" => "file_read",
        "description" => "Read a file",
        "input_schema" => %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      }

      handler = fn args ->
        Arbor.Actions.authorize_and_execute(agent_id, Arbor.Actions.File.Read, args, context)
      end

      ToolServer.register_handler("file_read", schema, handler)
  """
  @spec register_handler(
          String.t(),
          map(),
          (map() -> {:ok, term()} | {:error, term()}),
          GenServer.server()
        ) :: :ok
  def register_handler(name, schema, handler, server \\ __MODULE__)
      when is_function(handler, 1) do
    GenServer.call(server, {:register_handler, name, schema, handler})
  end

  @doc """
  Unregister a handler-based tool by name.
  """
  @spec unregister_handler(String.t(), GenServer.server()) :: :ok
  def unregister_handler(name, server \\ __MODULE__) do
    GenServer.call(server, {:unregister_handler, name})
  end

  @doc """
  Call a tool by name with the given arguments.

  Arguments can use string or atom keys — they will be normalized to atom keys
  for the tool function.
  """
  @spec call_tool(String.t(), map(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def call_tool(name, args, server \\ __MODULE__) do
    GenServer.call(server, {:call, name, args})
  end

  @doc """
  Check if a tool is registered.
  """
  @spec has_tool?(String.t(), GenServer.server()) :: boolean()
  def has_tool?(name, server \\ __MODULE__) do
    GenServer.call(server, {:has_tool?, name})
  end

  @doc """
  List all registered tools as JSON schema definitions.
  """
  @spec list_tools(GenServer.server()) :: [map()]
  def list_tools(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  @doc """
  List all registered tool names.
  """
  @spec tool_names(GenServer.server()) :: [String.t()]
  def tool_names(server \\ __MODULE__) do
    GenServer.call(server, :names)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    state = %{
      tools: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    if function_exported?(module, :__tools__, 0) do
      schemas = module.__tools__()

      new_tools =
        Enum.reduce(schemas, state.tools, fn schema, acc ->
          Map.put(acc, schema.name, %{module: module, schema: schema})
        end)

      {:reply, :ok, %{state | tools: new_tools}}
    else
      {:reply, {:error, {:not_a_tool_module, module}}, state}
    end
  end

  def handle_call({:unregister, module}, _from, state) do
    new_tools =
      state.tools
      |> Enum.reject(fn {_name, entry} -> Map.get(entry, :module) == module end)
      |> Map.new()

    {:reply, :ok, %{state | tools: new_tools}}
  end

  def handle_call({:register_handler, name, schema, handler}, _from, state) do
    new_tools = Map.put(state.tools, name, %{handler: handler, schema: schema})
    {:reply, :ok, %{state | tools: new_tools}}
  end

  def handle_call({:unregister_handler, name}, _from, state) do
    new_tools = Map.delete(state.tools, name)
    {:reply, :ok, %{state | tools: new_tools}}
  end

  def handle_call({:call, name, args}, _from, state) do
    case Map.get(state.tools, name) do
      nil ->
        {:reply, {:error, Error.tool_error(name, :unknown_tool)}, state}

      %{module: module} ->
        # Module-based tool (from deftool macro)
        normalized_args = normalize_args(args)

        result =
          try do
            module.__call_tool__(name, normalized_args)
          rescue
            e -> {:error, Error.tool_error(name, Exception.message(e))}
          end

        {:reply, result, state}

      %{handler: handler} ->
        # Handler-based tool (from register_handler)
        normalized_args = normalize_args(args)

        result =
          try do
            case handler.(normalized_args) do
              {:ok, value} -> {:ok, to_string_result(value)}
              {:error, _} = error -> error
              other -> {:ok, to_string_result(other)}
            end
          rescue
            e -> {:error, Error.tool_error(name, Exception.message(e))}
          end

        {:reply, result, state}
    end
  end

  def handle_call({:has_tool?, name}, _from, state) do
    {:reply, Map.has_key?(state.tools, name), state}
  end

  def handle_call(:list, _from, state) do
    schemas =
      state.tools
      |> Map.values()
      |> Enum.map(fn
        %{module: _module, schema: schema} ->
          # Module-based tool — convert internal schema to JSON
          Tool.to_json_schema(schema)

        %{handler: _handler, schema: schema} ->
          # Handler-based tool — schema is already JSON format
          schema
      end)

    {:reply, schemas, state}
  end

  def handle_call(:names, _from, state) do
    {:reply, Map.keys(state.tools), state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  # Normalize string-keyed args to atom-keyed for tool functions.
  # Only converts keys that exist as atoms (safe).
  defp normalize_args(args) when is_map(args) do
    Map.new(args, fn
      {key, val} when is_binary(key) ->
        try do
          {String.to_existing_atom(key), val}
        rescue
          ArgumentError -> {key, val}
        end

      {key, val} ->
        {key, val}
    end)
  end

  # Convert result to string for Claude
  defp to_string_result(value) when is_binary(value), do: value
  defp to_string_result(value) when is_map(value), do: Jason.encode!(value)
  defp to_string_result(value), do: inspect(value)
end
