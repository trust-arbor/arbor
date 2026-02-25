defmodule Arbor.Orchestrator.ActionsExecutor do
  @moduledoc """
  Core action execution engine for the orchestrator.

  Resolves action names to modules, atomizes keys via schema allowlists,
  signs requests for identity verification, and executes via
  `Arbor.Actions.authorize_and_execute/4`.

  ## Name Resolution

  Action names are resolved via `build_action_map/0` which keys on canonical
  dot-format names derived from module paths (e.g., `"file.read"` for
  `Arbor.Actions.File.Read`). Underscore-format names from LLM tool calls
  are also supported via normalization.

  ## Usage

      ActionsExecutor.execute("file.read", %{"path" => "/tmp/x"}, ".", agent_id: "agent_001")

  For LLM tool integration, see `Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutor`
  which adds OpenAI format conversion.
  """

  require Logger

  @actions_mod Module.concat([:Arbor, :Actions])

  @doc """
  Execute an action by name with optional agent identity for authorization.

  Accepts a 4th `opts` keyword list with:
    * `:agent_id` - The agent identity for authorization (default: `"system"`)
    * `:signed_request` - Pre-signed request for identity verification
    * `:signer` - Signer function `(resource -> {:ok, signed} | {:error, reason})`

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
      normalized = normalize_name(name)

      case Map.get(action_map, normalized) || Map.get(action_map, name) do
        nil ->
          {:error, "Unknown action: #{name}"}

        action_module ->
          params =
            args
            |> atomize_known_keys(action_module)
            |> maybe_inject_workdir(workdir)

          # Sign with the canonical module-derived resource URI.
          signed_request = signed_request || sign_for_module(signer, action_module)

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

  @doc """
  Build a name -> module mapping from all registered actions.

  Keys on canonical dot-format names derived from module paths
  (e.g., `"file.read"` for `Arbor.Actions.File.Read`).
  """
  @spec build_action_map() :: %{String.t() => module()}
  def build_action_map do
    with_actions_module(fn ->
      apply(@actions_mod, :all_actions, [])
      |> Enum.flat_map(fn module ->
        tool = module.to_tool()
        canonical = apply(@actions_mod, :action_module_to_name, [module])
        # Include both canonical (dot) and Jido (underscore) names
        if canonical == tool.name do
          [{canonical, module}]
        else
          [{canonical, module}, {tool.name, module}]
        end
      end)
      |> Map.new()
    end) || %{}
  end

  # ============================================================================
  # Private
  # ============================================================================

  # Normalize underscore-format names to dot-format when no dots present.
  # E.g., "file_read" -> "file.read", but "file.read" stays unchanged.
  defp normalize_name(name) do
    if String.contains?(name, ".") do
      name
    else
      # Only replace the FIRST underscore with a dot to handle multi-word
      # module segments (e.g., "eval_pipeline_load_dataset" -> "eval_pipeline.load_dataset")
      # This is a best-effort heuristic; the exact match via build_action_map handles all cases.
      case String.split(name, "_", parts: 2) do
        [prefix, rest] -> "#{prefix}.#{rest}"
        [single] -> single
      end
    end
  end

  # Atomize string keys using the action's schema as an allowlist.
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

  @doc false
  def format_result(result) when is_binary(result), do: result

  def format_result(result) when is_map(result) do
    case Jason.encode(result, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(result, pretty: true)
    end
  end

  def format_result(result) when is_list(result) do
    case Jason.encode(result, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(result, pretty: true)
    end
  end

  def format_result(result), do: inspect(result, pretty: true)

  # Sign a tool call using the canonical module-derived resource URI.
  defp sign_for_module(nil, _action_module), do: nil

  defp sign_for_module(signer, action_module) when is_function(signer, 1) do
    canonical_name = apply(@actions_mod, :action_module_to_name, [action_module])
    resource = "arbor://actions/execute/#{canonical_name}"

    case signer.(resource) do
      {:ok, signed_request} -> signed_request
      {:error, _} -> nil
    end
  end

  defp sign_for_module(_, _), do: nil

  # Runtime bridge — don't crash if arbor_actions isn't loaded
  @doc false
  def with_actions_module(fun) do
    if Code.ensure_loaded?(@actions_mod) do
      fun.()
    else
      nil
    end
  rescue
    e ->
      Logger.warning("ActionsExecutor: #{inspect(e)}")
      nil
  end
end
