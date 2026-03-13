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
      # Try ActionRegistry first (O(1) ETS lookup), fall back to build_action_map
      normalized = normalize_name(name)

      action_module =
        resolve_via_registry(normalized) ||
          resolve_via_registry(name) ||
          resolve_via_action_map(normalized, name)

      case action_module do
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
            {:ok, :pending_approval, proposal_id} ->
              await_approval_and_retry(
                proposal_id,
                agent_id,
                action_module,
                params,
                context,
                name
              )

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

  # Default timeout for synchronous approval waits (in milliseconds).
  # When a tool call requires approval, the executor blocks for up to this
  # duration waiting for consensus. Default: 60 seconds.
  @approval_timeout_ms 60_000

  # ============================================================================
  # Private
  # ============================================================================

  # Wait synchronously for approval, then retry execution on success.
  # On denial or timeout, return an error message to the LLM.
  defp await_approval_and_retry(proposal_id, agent_id, action_module, params, context, name) do
    consensus_mod = Module.concat([:Arbor, :Consensus])

    if Code.ensure_loaded?(consensus_mod) and
         function_exported?(consensus_mod, :await, 2) do
      timeout = approval_timeout()

      Logger.info(
        "[ActionsExecutor] Awaiting approval for #{name} (proposal: #{proposal_id}, timeout: #{timeout}ms)"
      )

      case apply(consensus_mod, :await, [proposal_id, [timeout: timeout]]) do
        {:ok, decision} when is_map(decision) ->
          handle_approval_decision(decision, agent_id, action_module, params, context, name)

        {:ok, :approved} ->
          # Simple approval atom (some paths return this)
          retry_execution(agent_id, action_module, params, context, name)

        {:error, :timeout} ->
          Logger.info("[ActionsExecutor] Approval timed out for #{name} (proposal: #{proposal_id})")

          {:error,
           "Action #{name} requires approval but timed out after #{div(timeout, 1000)}s. " <>
             "Proposal ID: #{proposal_id}. Ask the user to approve it and try again."}

        {:error, reason} ->
          Logger.info(
            "[ActionsExecutor] Approval failed for #{name}: #{inspect(reason)} (proposal: #{proposal_id})"
          )

          {:error,
           "Action #{name} requires approval. Proposal ID: #{proposal_id}. Status: #{inspect(reason)}"}
      end
    else
      # Consensus not available — return pending info to LLM
      {:error,
       "Action #{name} requires approval. Proposal ID: #{proposal_id}. " <>
         "The approval system is not available to wait synchronously."}
    end
  rescue
    e ->
      Logger.warning("[ActionsExecutor] await_approval_and_retry crashed: #{inspect(e)}")
      {:error, "Action #{name} requires approval. Proposal ID: #{proposal_id}"}
  catch
    :exit, reason ->
      Logger.warning("[ActionsExecutor] await_approval_and_retry exit: #{inspect(reason)}")
      {:error, "Action #{name} requires approval. Proposal ID: #{proposal_id}"}
  end

  defp handle_approval_decision(decision, agent_id, action_module, params, context, name) do
    status = Map.get(decision, :decision) || Map.get(decision, :status)

    case status do
      :approved ->
        Logger.info("[ActionsExecutor] Approval granted for #{name}, executing")
        retry_execution(agent_id, action_module, params, context, name)

      :rejected ->
        {:error,
         "Action #{name} was denied by consensus. " <>
           format_denial_reason(decision)}

      :deadlock ->
        {:error,
         "Action #{name} approval resulted in deadlock (no consensus reached). " <>
           "Ask the user to decide."}

      other ->
        {:error, "Action #{name} approval returned unexpected status: #{inspect(other)}"}
    end
  end

  # Re-execute the action after approval. Grant a clean capability (no
  # requires_approval constraint) so the retry doesn't trigger escalation again.
  defp retry_execution(agent_id, action_module, params, context, name) do
    # Grant a clean capability for this resource so retry succeeds
    grant_approved_capability(agent_id, action_module, context)

    case apply(@actions_mod, :authorize_and_execute, [
           agent_id,
           action_module,
           params,
           context
         ]) do
      {:ok, result} ->
        {:ok, format_result(result)}

      {:ok, :pending_approval, _proposal_id} ->
        # Shouldn't happen after approval, but handle gracefully
        {:error, "Action #{name} still requires approval after consensus granted it. This is a bug."}

      {:error, reason} ->
        {:error, "Action #{name} was approved but execution failed: #{inspect(reason)}"}
    end
  end

  defp format_denial_reason(decision) do
    concerns = Map.get(decision, :primary_concerns, [])

    if concerns != [] do
      "Concerns: #{Enum.join(concerns, "; ")}"
    else
      ""
    end
  end

  defp approval_timeout do
    Application.get_env(:arbor_orchestrator, :approval_timeout_ms, @approval_timeout_ms)
  end

  # Grant a clean capability (no requires_approval) after consensus approval.
  # This ensures the retry won't trigger escalation again.
  defp grant_approved_capability(agent_id, action_module, context) do
    security_mod = Module.concat([:Arbor, :Security])

    if Code.ensure_loaded?(security_mod) and function_exported?(security_mod, :grant, 1) do
      resource = apply(@actions_mod, :canonical_uri_for, [action_module, %{}])

      # Extract session_id from context if available
      session_id =
        Map.get(context, :session_id) ||
          Map.get(context, "session_id")

      grant_opts = [
        principal: agent_id,
        resource: resource,
        constraints: %{},
        metadata: %{source: :approval_granted}
      ]

      grant_opts =
        if session_id, do: Keyword.put(grant_opts, :session_id, session_id), else: grant_opts

      apply(security_mod, :grant, [grant_opts])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # Resolve an action name via ActionRegistry (O(1) ETS lookup).
  defp resolve_via_registry(name) do
    registry = Arbor.Common.ActionRegistry

    if Process.whereis(registry) do
      case registry.resolve(name) do
        {:ok, module} -> module
        {:error, _} -> nil
      end
    else
      nil
    end
  end

  # Fallback: resolve via build_action_map when registry unavailable.
  defp resolve_via_action_map(normalized, original) do
    action_map = build_action_map()
    Map.get(action_map, normalized) || Map.get(action_map, original)
  end

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
    resource = apply(@actions_mod, :canonical_uri_for, [action_module, %{}])

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
