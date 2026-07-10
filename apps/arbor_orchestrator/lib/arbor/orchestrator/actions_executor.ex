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

  For LLM tool integration, see `Arbor.LLM.ArborActionsExecutor`
  which adds OpenAI format conversion.
  """

  require Logger

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
    task_id = Keyword.get(opts, :task_id)
    workdir = normalize_workdir(workdir)

    run_action(fn ->
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
            |> maybe_resolve_file_paths(action_module, workdir)
            |> maybe_inject_workdir(workdir)

          # Sign with the canonical module-derived resource URI.
          signed_request = signed_request || sign_for_module(signer, action_module, params)

          # Build AuthContext — single struct with everything auth needs.
          # The signed_request and signer are included so downstream code
          # (authorize_and_execute, facade auth) can access them.
          # Arbor.Contracts.Security.AuthContext lives in arbor_contracts (a dep).
          auth_context =
            Arbor.Contracts.Security.AuthContext.new(agent_id,
              signer: signer,
              signed_request: signed_request,
              session_id: Keyword.get(opts, :session_id)
            )

          Logger.debug(
            "[ActionsExecutor] #{name}: signed=#{signed_request != nil}, " <>
              "agent=#{agent_id}, module=#{action_module}"
          )

          # Context passed to the action's run/2 — includes signed_request
          # so facade auth can see it, and auth_context for the new flow.
          # auth_context is always built (AuthContext lives in arbor_contracts).
          #
          # Taint bridge (taint-tracking-rebuild Phase 2): the orchestrator
          # threads the provenance taint of the data interpolated into this
          # action's params via the :taint opt. Putting it on context[:taint]
          # is what finally feeds TaintEnforcement.check — without it the
          # chokepoint reads no taint and every action passes (F1).
          context =
            %{auth_context: auth_context}
            |> maybe_put_context(:task_id, task_id)
            |> maybe_put_file_workspace(action_module, workdir)
            |> then(fn c ->
              if signed_request, do: Map.put(c, :signed_request, signed_request), else: c
            end)
            |> then(fn c ->
              case Keyword.get(opts, :taint) do
                nil -> c
                level -> Map.put(c, :taint, level)
              end
            end)

          case Arbor.Actions.authorize_and_execute(
                 agent_id,
                 action_module,
                 params,
                 context
               ) do
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
              msg =
                case reason do
                  :unauthorized ->
                    "Action #{name} unauthorized. You may need additional permissions."

                  {:unauthorized, detail} ->
                    "Action #{name} unauthorized: #{detail}"

                  reason when is_binary(reason) ->
                    reason

                  reason ->
                    "Action #{name} failed: #{inspect(reason)}"
                end

              {:error, msg}
          end
      end
    end)
  end

  @doc """
  Build a name -> module mapping from all registered actions.

  Keys on canonical dot-format names derived from module paths
  (e.g., `"file.read"` for `Arbor.Actions.File.Read`).
  """
  @spec build_action_map() :: %{String.t() => module()}
  def build_action_map do
    Arbor.Actions.all_actions()
    |> Enum.flat_map(fn module ->
      tool = module.to_tool()
      canonical = Arbor.Actions.action_module_to_name(module)
      # Include both canonical (dot) and Jido (underscore) names
      if canonical == tool.name do
        [{canonical, module}]
      else
        [{canonical, module}, {tool.name, module}]
      end
    end)
    |> Map.new()
  rescue
    # The action SYSTEM may not be fully initialized in every context. The
    # module is a guaranteed compile dep now, but defend against runtime
    # enumeration failures by returning an empty map (callers treat this as
    # "no actions resolvable").
    e ->
      Logger.warning("ActionsExecutor.build_action_map failed: #{Exception.message(e)}")
      %{}
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
    if interaction_request?(proposal_id) do
      await_interaction_and_retry(proposal_id, agent_id, action_module, params, context, name)
    else
      await_consensus_and_retry(proposal_id, agent_id, action_module, params, context, name)
    end
  end

  # `Escalation.submit_via_router` routes :ask approvals through
  # `Arbor.Comms.InteractionRouter`, returning an "irq_…" request id whose
  # decision arrives on the agent's interaction RESPONSE topic — NOT via
  # Consensus. The DOT-turn path used to await `Consensus.await(irq_…)` and got
  # `:not_found` for every router-routed approval (so no operator could approve
  # an agent's tool call from the dashboard or TUI). Mirror the ACP handler's
  # `await_human_approval` and wait on the response topic instead.
  defp interaction_request?(id) when is_binary(id), do: String.starts_with?(id, "irq")
  defp interaction_request?(_), do: false

  defp await_interaction_and_retry(request_id, agent_id, action_module, params, context, name) do
    topic = Arbor.Contracts.Comms.Interaction.response_topic_for_agent(agent_id)
    timeout = approval_timeout()

    Logger.info(
      "[ActionsExecutor] Awaiting operator approval for #{name} via InteractionRouter " <>
        "(request: #{request_id}, timeout: #{timeout}ms)"
    )

    task =
      Task.async(fn ->
        # Subscribe inside the Task so the subscription dies with it and stale
        # responses can't leak into the caller's mailbox (per the ACP handler).
        Phoenix.PubSub.subscribe(Arbor.Comms.PubSub, topic)

        receive do
          {:interaction_response, %{request_id: ^request_id, response: response}} ->
            {:response, response}
        after
          timeout -> :timeout
        end
      end)

    case Task.yield(task, timeout + 1_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:response, r}} when r in [:approved, :approve, "approved", "approve"] ->
        track_approval(agent_id, action_module)
        retry_execution(agent_id, action_module, params, context, name, request_id)

      {:ok, {:response, r}}
      when r in [:rejected, :reject, :denied, "rejected", "deny", "denied"] ->
        {:error, "Action #{name} was denied by the operator. Request ID: #{request_id}."}

      {:ok, {:response, other}} ->
        {:error,
         "Action #{name}: unexpected approval response #{inspect(other)}. " <>
           "Request ID: #{request_id}."}

      {:ok, :timeout} ->
        {:error,
         "Action #{name} requires approval but timed out after #{div(timeout, 1000)}s. " <>
           "Request ID: #{request_id}. Ask the user to approve it and try again."}

      _ ->
        {:error, "Action #{name} approval wait failed. Request ID: #{request_id}."}
    end
  rescue
    e ->
      Logger.warning("[ActionsExecutor] await_interaction_and_retry crashed: #{inspect(e)}")
      {:error, "Action #{name} requires approval. Request ID: #{request_id}"}
  end

  defp await_consensus_and_retry(proposal_id, agent_id, action_module, params, context, name) do
    consensus_mod = Module.concat([:Arbor, :Consensus])

    if Code.ensure_loaded?(consensus_mod) and
         function_exported?(consensus_mod, :await, 2) do
      timeout = approval_timeout()

      Logger.info(
        "[ActionsExecutor] Awaiting approval for #{name} (proposal: #{proposal_id}, timeout: #{timeout}ms)"
      )

      case apply(consensus_mod, :await, [proposal_id, [timeout: timeout]]) do
        {:ok, decision} when is_map(decision) ->
          handle_approval_decision(
            decision,
            agent_id,
            action_module,
            params,
            context,
            name,
            proposal_id
          )

        {:ok, :approved} ->
          # Simple approval atom (some paths return this)
          track_approval(agent_id, action_module)
          retry_execution(agent_id, action_module, params, context, name, proposal_id)

        {:error, :timeout} ->
          Logger.info(
            "[ActionsExecutor] Approval timed out for #{name} (proposal: #{proposal_id})"
          )

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

  defp handle_approval_decision(
         decision,
         agent_id,
         action_module,
         params,
         context,
         name,
         proposal_id
       ) do
    status = Map.get(decision, :decision) || Map.get(decision, :status)

    case status do
      :approved ->
        Logger.info("[ActionsExecutor] Approval granted for #{name}, executing")
        track_approval(agent_id, action_module)
        retry_execution(agent_id, action_module, params, context, name, proposal_id)

      :rejected ->
        track_rejection(agent_id, action_module)

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

  # Re-execute only the exact invocation that was approved. The one-shot marker
  # satisfies ApprovalGuard for this retry without minting durable authority.
  defp retry_execution(agent_id, action_module, params, context, name, request_id) do
    resource = Arbor.Actions.canonical_uri_for(action_module, params)

    context =
      Map.put(context, :approved_invocation, %{
        request_id: request_id,
        principal_id: agent_id,
        resource_uri: resource,
        decision: :approved
      })

    # Re-sign for the retry. The signed request that drove the original
    # (escalated) authorize is SINGLE-USE — its nonce was consumed by
    # `Identity.Verifier.check_nonce_uniqueness`. Replaying it here makes the
    # post-approval authorize fail `:unauthorized` (nonce replay), so an
    # approved tool could never actually run. The executor holds the agent's
    # signer in the AuthContext, so mint a fresh signed request (new nonce)
    # bound to this resource. (Masked until the InteractionRouter await began
    # succeeding — see the 2026-06-22 HITL routing fix.)
    context = resign_for_retry(context, action_module, params)

    case Arbor.Actions.authorize_and_execute(
           agent_id,
           action_module,
           params,
           context
         ) do
      {:ok, result} ->
        {:ok, format_result(result)}

      {:ok, :pending_approval, _proposal_id} ->
        # Shouldn't happen after approval, but handle gracefully
        {:error,
         "Action #{name} still requires approval after consensus granted it. This is a bug."}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

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

  # Mint a fresh signed request for the post-approval retry so identity
  # verification doesn't fail on a replayed (already-consumed) nonce. Uses the
  # signer carried on the AuthContext. If there's no signer (unsigned flow),
  # leave the context as-is — the original behavior.
  defp resign_for_retry(context, action_module, params) do
    case context[:auth_context] do
      %{signer: signer} when is_function(signer, 1) ->
        resource = Arbor.Actions.canonical_uri_for(action_module, params)

        case signer.(resource) do
          {:ok, fresh} ->
            auth_context = %{context.auth_context | signed_request: fresh}

            context
            |> Map.put(:signed_request, fresh)
            |> Map.put(:auth_context, auth_context)

          _ ->
            context
        end

      _ ->
        context
    end
  rescue
    _ -> context
  catch
    :exit, _ -> context
  end

  # Record approval/rejection with ConfirmationTracker for graduation tracking.
  # arbor_trust is a hard dep; the Process.whereis liveness check stays (the
  # tracker process may not be running in standalone/test slices).
  defp track_approval(agent_id, action_module) do
    if Process.whereis(Arbor.Trust.ConfirmationTracker) do
      resource = Arbor.Actions.canonical_uri_for(action_module, %{})
      Arbor.Trust.ConfirmationTracker.record_approval(agent_id, resource)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp track_rejection(agent_id, action_module) do
    if Process.whereis(Arbor.Trust.ConfirmationTracker) do
      resource = Arbor.Actions.canonical_uri_for(action_module, %{})
      Arbor.Trust.ConfirmationTracker.record_rejection(agent_id, resource)
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Resolve the provenance taint an action declares for its own output.

  Used by ingress handlers (taint-tracking-rebuild Phase 1) to label a node's
  output context keys with the source's provenance (e.g. web fetch ->
  `:untrusted`). Returns the declared level or `nil` when the action declares
  no provenance or the actions library is unavailable (standalone orchestrator).
  """
  @spec output_taint(String.t(), map()) :: atom() | nil
  def output_taint(name, params \\ %{}) do
    normalized = normalize_name(name)

    module =
      resolve_via_registry(normalized) ||
        resolve_via_registry(name) ||
        resolve_via_action_map(normalized, name)

    # arbor_actions is a hard dep — Arbor.Actions.Taint is called directly.
    if module do
      Arbor.Actions.Taint.output_taint_for(module, params)
    end
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

  defp normalize_workdir(nil), do: File.cwd!()
  defp normalize_workdir(""), do: File.cwd!()
  defp normalize_workdir(workdir) when is_binary(workdir), do: Path.expand(workdir)
  defp normalize_workdir(_workdir), do: File.cwd!()

  defp maybe_resolve_file_paths(params, Arbor.Actions.File.Glob, workdir) do
    params
    |> put_new_either(:base_path, "base_path", workdir)
    |> resolve_path_param(:base_path, workdir)
  end

  defp maybe_resolve_file_paths(params, action_module, workdir)
       when action_module in [
              Arbor.Actions.File.Read,
              Arbor.Actions.File.Write,
              Arbor.Actions.File.List,
              Arbor.Actions.File.Exists,
              Arbor.Actions.File.Edit,
              Arbor.Actions.File.Search
            ] do
    resolve_path_param(params, :path, workdir)
  end

  defp maybe_resolve_file_paths(params, _action_module, _workdir), do: params

  defp resolve_path_param(params, key, workdir) do
    case Map.get(params, key) do
      path when is_binary(path) and path != "" ->
        resolved_path =
          if Path.type(path) == :absolute do
            Path.expand(path)
          else
            Path.expand(path, workdir)
          end

        Map.put(params, key, resolved_path)

      _ ->
        params
    end
  end

  defp maybe_put_file_workspace(context, action_module, workdir)
       when action_module in [
              Arbor.Actions.File.Read,
              Arbor.Actions.File.Write,
              Arbor.Actions.File.List,
              Arbor.Actions.File.Glob,
              Arbor.Actions.File.Exists,
              Arbor.Actions.File.Edit,
              Arbor.Actions.File.Search
            ] do
    Map.put(context, :workspace, workdir)
  end

  defp maybe_put_file_workspace(context, _action_module, _workdir), do: context

  defp maybe_put_context(context, _key, nil), do: context
  defp maybe_put_context(context, _key, ""), do: context
  defp maybe_put_context(context, key, value), do: Map.put(context, key, value)

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
  # Params are included so self-scoped URIs (arbor://agent/profile/{id})
  # match the URI that authorize_and_execute will verify against.
  defp sign_for_module(nil, _action_module, _params), do: nil

  defp sign_for_module(signer, action_module, params) when is_function(signer, 1) do
    resource = Arbor.Actions.canonical_uri_for(action_module, params)

    case signer.(resource) do
      {:ok, signed_request} ->
        Logger.debug("[ActionsExecutor] Signed for #{resource}")
        signed_request

      {:error, reason} ->
        Logger.warning("[ActionsExecutor] Signing failed for #{resource}: #{inspect(reason)}")
        nil
    end
  end

  defp sign_for_module(_, _, _), do: nil

  # Execute an action thunk. arbor_actions is a guaranteed compile dep, so the
  # module is always loaded — this no longer guards module availability. It
  # only converts an unexpected crash inside action execution into a clear
  # error result instead of letting it propagate as a raw exception (e.g. when
  # the action SYSTEM, like ActionRegistry, is not running in some context).
  @doc false
  def run_action(fun) do
    fun.()
  rescue
    e ->
      Logger.warning(
        "ActionsExecutor: #{Exception.message(e)}\n  #{Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0..500)}"
      )

      {:error, "Action execution failed: #{Exception.message(e)}"}
  end

  # Public runtime bridge for callers that have NO compile-time dep on
  # arbor_actions and reach the orchestrator only via runtime apply/3
  # (e.g. Arbor.LLM.ArborActionsExecutor, a Level-1 lib that can't depend on
  # the Level-2 arbor_actions). For those callers the "is the actions module
  # loaded?" guard is still meaningful, so this preserves the original
  # nil-on-unavailable contract. Orchestrator-internal code calls the actions
  # module directly and does NOT use this.
  @doc false
  def with_actions_module(fun) do
    if Code.ensure_loaded?(Arbor.Actions) do
      fun.()
    else
      nil
    end
  rescue
    e ->
      Logger.warning(
        "ActionsExecutor: #{Exception.message(e)}\n  #{Exception.format_stacktrace(__STACKTRACE__) |> String.slice(0..500)}"
      )

      nil
  end
end
