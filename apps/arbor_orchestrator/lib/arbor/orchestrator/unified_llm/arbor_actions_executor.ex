defmodule Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutor do
  @moduledoc """
  Bridges ToolLoop's tool execution interface to Arbor.Actions.

  Converts Arbor Action schemas (Jido format) to OpenAI tool-calling format
  for the LLM, and routes execute calls to Arbor's action system.

  ## Usage in DOT nodes

  Set `tools` attribute to a comma-separated list of action names:

      node [type="codergen" use_tools="true" tools="file_read,file_search,shell_execute"]

  If `tools` is omitted, falls back to `CodingTools` (5 built-in tools).

  ## Tool Format

  Arbor Actions use Jido format (`to_tool/0`):

      %{name: "file_read", description: "...", parameters_schema: %{...}}

  This module converts them to OpenAI format for the LLM:

      %{"type" => "function", "function" => %{"name" => "file_read", ...}}
  """

  require Logger

  @actions_mod Module.concat([:Arbor, :Actions])

  @doc """
  Get OpenAI-format tool definitions for the specified action names.

  If `action_names` is nil, returns definitions for all available actions.
  """
  @spec definitions(list(String.t()) | nil) :: [map()]
  def definitions(action_names \\ nil)

  def definitions(nil) do
    with_actions_module(fn ->
      apply(@actions_mod, :all_tools, [])
      |> Enum.map(&to_openai_format/1)
    end) || []
  end

  def definitions(action_names) when is_list(action_names) do
    with_actions_module(fn ->
      action_map = build_action_map()

      Enum.flat_map(action_names, fn name ->
        name = String.trim(name)

        case Map.get(action_map, name) do
          nil ->
            Logger.warning("ArborActionsExecutor: unknown action '#{name}'")
            []

          module ->
            [to_openai_format(module.to_tool())]
        end
      end)
    end) || []
  end

  @doc """
  Execute an action by name with optional agent identity for authorization.

  Accepts a 4th `opts` keyword list with:
    * `:agent_id` - The agent identity for authorization (default: `"system"`)

  Maps tool names to Arbor Actions, atomizes string-keyed args using the
  action's schema as an allowlist, and executes via the action system.
  """
  @spec execute(String.t(), map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(name, args, workdir, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, "system")
    signed_request = Keyword.get(opts, :signed_request)
    signer = Keyword.get(opts, :signer)

    with_actions_module(fn ->
      action_map = build_action_map()

      case Map.get(action_map, name) do
        nil ->
          {:error, "Unknown action: #{name}"}

        action_module ->
          params =
            args
            |> atomize_known_keys(action_module)
            |> maybe_inject_workdir(workdir)

          # Sign with the canonical module-derived resource URI.
          # This ensures the signed resource matches what authorize_and_execute
          # derives from the module name (dots, not underscores).
          signed_request = signed_request || sign_for_module(signer, action_module)

          # Pass signed_request in context for identity verification.
          # authorize_and_execute extracts it and passes to Security.authorize.
          context =
            if signed_request do
              %{signed_request: signed_request}
            else
              %{}
            end

          case apply(@actions_mod, :authorize_and_execute, [
                 agent_id,
                 action_module,
                 params,
                 context
               ]) do
            {:ok, result} ->
              {:ok, format_result(result)}

            {:error, reason} ->
              {:error, "Action #{name} failed: #{inspect(reason)}"}
          end
      end
    end) || {:error, "Arbor.Actions not available"}
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Convert Jido tool format to OpenAI function-calling format
  defp to_openai_format(jido_tool) do
    %{
      "type" => "function",
      "function" => %{
        "name" => jido_tool.name,
        "description" => jido_tool.description,
        "parameters" => jido_tool.parameters_schema || %{"type" => "object", "properties" => %{}}
      }
    }
  end

  # Build a name -> module mapping from all registered actions
  defp build_action_map do
    apply(@actions_mod, :all_actions, [])
    |> Enum.map(fn module ->
      tool = module.to_tool()
      {tool.name, module}
    end)
    |> Map.new()
  end

  # Atomize string keys using the action's schema as an allowlist.
  # This prevents arbitrary atom creation (SafeAtom pattern) while
  # fixing the string-key/atom-key mismatch between LLM JSON output
  # and Arbor Action param access.
  defp atomize_known_keys(args, action_module) do
    schema = action_module.to_tool().parameters_schema
    known_atoms = extract_schema_keys(schema)

    Map.new(args, fn {k, v} ->
      case atomize_if_known(k, known_atoms) do
        {:ok, atom_key} -> {atom_key, v}
        :unknown -> {k, v}
      end
    end)
  end

  defp extract_schema_keys(nil), do: MapSet.new()

  defp extract_schema_keys(schema) do
    props = Map.get(schema, "properties") || Map.get(schema, :properties) || %{}

    props
    |> Map.keys()
    |> Enum.flat_map(fn key ->
      atom_key =
        if is_atom(key) do
          key
        else
          try do
            String.to_existing_atom(key)
          rescue
            ArgumentError -> nil
          end
        end

      if atom_key, do: [atom_key], else: []
    end)
    |> MapSet.new()
  end

  defp atomize_if_known(key, _known_atoms) when is_atom(key), do: {:ok, key}

  defp atomize_if_known(key, known_atoms) when is_binary(key) do
    atom = String.to_existing_atom(key)

    if MapSet.member?(known_atoms, atom) do
      {:ok, atom}
    else
      :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  # Inject workdir for actions that need directory context.
  # Injects both atom and string keys for compatibility.
  defp maybe_inject_workdir(args, workdir) do
    args
    |> put_new_either(:workdir, "workdir", workdir)
    |> put_new_either(:cwd, "cwd", workdir)
  end

  defp put_new_either(map, atom_key, string_key, value) do
    if Map.has_key?(map, atom_key) || Map.has_key?(map, string_key) do
      map
    else
      Map.put(map, atom_key, value)
    end
  end

  # Format action results for LLM consumption.
  # JSON for structured data, plain text for strings.
  defp format_result(result) when is_binary(result), do: result

  defp format_result(result) when is_map(result) do
    case Jason.encode(result, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(result, pretty: true)
    end
  end

  defp format_result(result) when is_list(result) do
    case Jason.encode(result, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(result, pretty: true)
    end
  end

  defp format_result(result), do: inspect(result, pretty: true)

  # Sign a tool call using the canonical module-derived resource URI.
  # This avoids the underscore/dot mismatch between Jido tool names
  # and module-derived names used by authorize_and_execute.
  defp sign_for_module(nil, _action_module), do: nil

  defp sign_for_module(signer, action_module) when is_function(signer, 1) do
    # Derive the canonical name from the module (e.g. Monitor.ReadDiagnostics -> "monitor.read_diagnostics")
    canonical_name = apply(@actions_mod, :action_module_to_name, [action_module])
    resource = "arbor://actions/execute/#{canonical_name}"

    case signer.(resource) do
      {:ok, signed_request} -> signed_request
      {:error, _} -> nil
    end
  end

  defp sign_for_module(_, _), do: nil

  # Runtime bridge — don't crash if arbor_actions isn't loaded
  defp with_actions_module(fun) do
    if Code.ensure_loaded?(@actions_mod) do
      fun.()
    else
      nil
    end
  rescue
    e ->
      Logger.warning("ArborActionsExecutor: #{inspect(e)}")
      nil
  end
end
