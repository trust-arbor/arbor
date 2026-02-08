defmodule Arbor.AI.AgentSDK.Tool do
  @moduledoc ~S"""
  Define Elixir functions as Claude tools.

  Tools defined with this module can be called in-process without subprocess
  overhead, matching the `@tool` decorator pattern from the Python SDK and the
  tool definition pattern from the TypeScript SDK.

  ## Usage

      defmodule MyTools do
        use Arbor.AI.AgentSDK.Tool

        deftool :greet, "Greet a user by name" do
          param :name, :string, required: true, description: "Name to greet"

          def execute(%{name: name}) do
            {:ok, "Hello, #{name}!"}
          end
        end

        deftool :calculate, "Perform safe arithmetic" do
          param :expression, :string, required: true, description: "Math expression"

          def execute(%{expression: expr}) do
            case Code.eval_string(expr) do
              {result, _} -> {:ok, to_string(result)}
            end
          end
        end
      end

  ## Return Values

  Tool execute functions should return:
  - `{:ok, result}` — success, result converted to string
  - `{:error, reason}` — failure, shown to Claude as error
  - `result` (bare value) — treated as `{:ok, result}`
  """

  @type tool_schema :: %{
          name: String.t(),
          description: String.t(),
          function: atom(),
          params: [param_schema()]
        }

  @type param_schema :: %{
          name: atom(),
          type: param_type(),
          required: boolean(),
          description: String.t() | nil
        }

  @type param_type :: :string | :integer | :number | :boolean | :array | :object

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Arbor.AI.AgentSDK.Tool, only: [deftool: 3, param: 2, param: 3]

      Module.register_attribute(__MODULE__, :__sdk_tools__, accumulate: true)

      @before_compile Arbor.AI.AgentSDK.Tool
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    tools = Module.get_attribute(env.module, :__sdk_tools__) || []

    quote do
      @doc "List all tools defined in this module."
      def __tools__ do
        unquote(Macro.escape(Enum.reverse(tools)))
      end

      @doc "Get the schema for a specific tool by name."
      def __tool_schema__(name) when is_binary(name) do
        Enum.find(__tools__(), &(&1.name == name))
      end

      def __tool_schema__(name) when is_atom(name) do
        __tool_schema__(Atom.to_string(name))
      end

      @doc "Call a tool by name with the given arguments."
      def __call_tool__(name, args) when is_binary(name) do
        case __tool_schema__(name) do
          nil ->
            {:error, {:unknown_tool, name}}

          %{function: func} ->
            result = apply(__MODULE__, func, [args])
            unquote(__MODULE__).normalize_result(result)
        end
      end

      def __call_tool__(name, args) when is_atom(name) do
        __call_tool__(Atom.to_string(name), args)
      end
    end
  end

  @doc """
  Define a tool with a name, description, params, and execute function.

  ## Example

      deftool :search, "Search the codebase" do
        param :query, :string, required: true
        param :max_results, :integer, description: "Maximum results"

        def execute(%{query: query} = args) do
          max = Map.get(args, :max_results, 10)
          {:ok, do_search(query, max)}
        end
      end
  """
  defmacro deftool(name, description, do: block) do
    quote do
      # Collect params from the block
      @__current_params__ []

      unquote(rewrite_block(name, block))

      tool_schema = %{
        name: Atom.to_string(unquote(name)),
        description: unquote(description),
        function: unquote(tool_function_name(name)),
        params: Enum.reverse(@__current_params__)
      }

      @__sdk_tools__ tool_schema
    end
  end

  @doc false
  defmacro param(name, type, opts \\ []) do
    quote do
      @__current_params__ %{
                            name: unquote(name),
                            type: unquote(type),
                            required: unquote(Keyword.get(opts, :required, false)),
                            description: unquote(Keyword.get(opts, :description))
                          }
                          |> then(&[&1 | @__current_params__])
    end
  end

  # Rewrite the block to:
  # 1. Keep `param` calls as-is (they use module attribute accumulation)
  # 2. Rewrite `def execute(args)` to `def __tool_<name>__(args)`
  defp rewrite_block(name, {:__block__, meta, stmts}) do
    func_name = tool_function_name(name)

    rewritten =
      Enum.map(stmts, fn
        {:def, def_meta, [{:execute, exec_meta, args} | rest]} ->
          {:def, def_meta, [{func_name, exec_meta, args} | rest]}

        other ->
          other
      end)

    {:__block__, meta, rewritten}
  end

  defp rewrite_block(name, {:def, def_meta, [{:execute, exec_meta, args} | rest]}) do
    func_name = tool_function_name(name)
    {:def, def_meta, [{func_name, exec_meta, args} | rest]}
  end

  defp rewrite_block(_name, other), do: other

  # Compile-time only atom creation — bounded by developer-defined tool count.
  # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
  defp tool_function_name(name) when is_atom(name), do: :"__tool_#{name}__"

  # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
  defp tool_function_name({name, _, _}), do: :"__tool_#{name}__"

  @doc """
  Convert a tool schema to the JSON Schema format expected by Claude.
  """
  @spec to_json_schema(tool_schema()) :: map()
  def to_json_schema(%{name: name, description: description, params: params}) do
    properties =
      Map.new(params, fn param ->
        prop = %{"type" => type_to_json(param.type)}

        prop =
          if param.description do
            Map.put(prop, "description", param.description)
          else
            prop
          end

        {Atom.to_string(param.name), prop}
      end)

    required =
      params
      |> Enum.filter(& &1.required)
      |> Enum.map(&Atom.to_string(&1.name))

    schema = %{
      "type" => "object",
      "properties" => properties
    }

    schema = if required != [], do: Map.put(schema, "required", required), else: schema

    %{
      "name" => name,
      "description" => description,
      "input_schema" => schema
    }
  end

  @doc """
  Normalize a tool result into `{:ok, string}` or `{:error, string}` form.
  """
  @spec normalize_result(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_result({:ok, result}) when is_binary(result), do: {:ok, result}
  def normalize_result({:ok, result}), do: {:ok, inspect(result)}
  def normalize_result({:error, reason}) when is_binary(reason), do: {:error, reason}
  def normalize_result({:error, reason}), do: {:error, inspect(reason)}
  def normalize_result(result) when is_binary(result), do: {:ok, result}
  def normalize_result(result), do: {:ok, inspect(result)}

  defp type_to_json(:string), do: "string"
  defp type_to_json(:integer), do: "integer"
  defp type_to_json(:number), do: "number"
  defp type_to_json(:boolean), do: "boolean"
  defp type_to_json(:array), do: "array"
  defp type_to_json(:object), do: "object"
end
