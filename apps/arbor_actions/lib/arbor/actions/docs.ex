defmodule Arbor.Actions.Docs do
  @moduledoc """
  Documentation lookup operations as Jido actions.

  This module provides Jido-compatible actions for querying module and
  function documentation via `Code.fetch_docs/1`. Useful for research
  agents that need to understand API surfaces without reading source files.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Lookup` | Look up module or function documentation |

  ## Examples

      # Get module docs
      {:ok, result} = Arbor.Actions.Docs.Lookup.run(
        %{module: "Enum"},
        %{}
      )

      # Get function docs
      {:ok, result} = Arbor.Actions.Docs.Lookup.run(
        %{module: "Enum", function: "map", arity: 2},
        %{}
      )

  ## Authorization

  - Lookup: `arbor://actions/execute/docs.lookup`
  """

  defmodule Lookup do
    @moduledoc """
    Look up module or function documentation.

    Uses `Code.fetch_docs/1` to retrieve embedded documentation from compiled
    modules. Module names are converted via `String.to_existing_atom/1` which
    is safe — it only succeeds for atoms that already exist in the VM.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `module` | string | yes | Module name (e.g. "Enum", "Arbor.Security") |
    | `function` | string | no | Function name to filter to |
    | `arity` | non_neg_integer | no | Function arity to filter to |

    ## Returns

    - `module` - The module name
    - `module_doc` - Module-level documentation text
    - `functions` - List of function docs (filtered if function/arity specified)
    """

    use Jido.Action,
      name: "docs_lookup",
      description: "Look up module or function documentation",
      category: "docs",
      tags: ["docs", "documentation", "lookup", "research"],
      schema: [
        module: [
          type: :string,
          required: true,
          doc: "Module name (e.g. \"Enum\", \"Arbor.Security\")"
        ],
        function: [
          type: :string,
          doc: "Function name to look up"
        ],
        arity: [
          type: :non_neg_integer,
          doc: "Function arity to filter to"
        ]
      ]

    alias Arbor.Actions

    def taint_roles do
      %{
        module: :control,
        function: :control,
        arity: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
    def run(params, _context) do
      module_name = params[:module]

      Actions.emit_started(__MODULE__, %{module: module_name})

      with {:ok, module_atom} <- resolve_module(module_name),
           {:ok, docs} <- fetch_docs(module_atom) do
        module_doc = extract_module_doc(docs)
        functions = extract_function_docs(docs, params[:function], params[:arity])

        result = %{
          module: module_name,
          module_doc: module_doc,
          functions: functions,
          function_count: length(functions)
        }

        Actions.emit_completed(__MODULE__, %{
          module: module_name,
          function_count: length(functions)
        })

        {:ok, result}
      else
        {:error, reason} = error ->
          Actions.emit_failed(__MODULE__, %{
            module: module_name,
            reason: inspect(reason)
          })

          error
      end
    end

    defp resolve_module(name) when is_binary(name) do
      # Prefix with Elixir. if not already prefixed for module atom lookup
      prefixed =
        if String.starts_with?(name, "Elixir.") do
          name
        else
          "Elixir." <> name
        end

      try do
        {:ok, String.to_existing_atom(prefixed)}
      rescue
        ArgumentError ->
          {:error, {:unknown_module, name}}
      end
    end

    defp fetch_docs(module_atom) do
      case Code.fetch_docs(module_atom) do
        {:docs_v1, _annotation, _beam_language, _format, _module_doc, _metadata, _docs} =
            docs ->
          {:ok, docs}

        {:error, reason} ->
          {:error, {:docs_unavailable, reason}}
      end
    end

    defp extract_module_doc({:docs_v1, _, _, _, module_doc, _, _}) do
      case module_doc do
        %{"en" => text} -> text
        :hidden -> "(hidden)"
        :none -> "(no documentation)"
        _ -> "(no documentation)"
      end
    end

    defp extract_function_docs({:docs_v1, _, _, _, _, _, docs}, fn_name, arity) do
      docs
      |> Enum.filter(fn
        {{kind, name, a}, _, _, _, _} when kind in [:function, :macro] ->
          name_match =
            if fn_name do
              to_string(name) == fn_name
            else
              true
            end

          arity_match =
            if arity do
              a == arity
            else
              true
            end

          name_match and arity_match

        _ ->
          false
      end)
      |> Enum.map(fn {{kind, name, a}, _, signatures, doc, metadata} ->
        %{
          kind: kind,
          name: to_string(name),
          arity: a,
          signatures: signatures || [],
          doc: format_doc(doc),
          deprecated: Map.get(metadata, :deprecated, nil)
        }
      end)
    end

    defp format_doc(%{"en" => text}), do: text
    defp format_doc(:hidden), do: "(hidden)"
    defp format_doc(:none), do: "(no documentation)"
    defp format_doc(_), do: "(no documentation)"
  end
end
