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

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.CodingPlan.ExecutionManifest
  alias Arbor.Orchestrator.Engine.RunAuthorization
  alias Arbor.Orchestrator.Graph

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
    execute_with_result_mode(name, args, workdir, opts, :formatted)
  end

  @doc """
  Execute an action and preserve its successful result as the original Elixir term.

  Resolution, execution binding, signing, caller-authority intersection,
  authorization, approval, and retry behavior are identical to `execute/4`.
  Errors retain the same bounded string format used by `execute/4`.
  """
  @spec execute_structured(String.t(), map(), String.t(), keyword()) ::
          {:ok, term()} | {:error, String.t()}
  def execute_structured(name, args, workdir, opts \\ []) do
    execute_with_result_mode(name, args, workdir, opts, :structured)
  end

  defp execute_with_result_mode(name, args, workdir, opts, result_mode)
       when result_mode in [:formatted, :structured] do
    agent_id = Keyword.get(opts, :agent_id, "system")
    signed_request = Keyword.get(opts, :signed_request)
    signer = Keyword.get(opts, :signer)
    task_id = Keyword.get(opts, :task_id)
    session_id = Keyword.get(opts, :session_id)
    caller_id = Keyword.get(opts, :caller_id)
    author_id = Keyword.get(opts, :author_id)
    workdir = normalize_workdir(workdir)

    run_action(fn ->
      with :ok <- reject_mixed_signing_credentials(opts, args) do
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
            execute_resolved_action(
              name,
              args,
              workdir,
              opts,
              action_module,
              agent_id,
              caller_id,
              author_id,
              task_id,
              session_id,
              signed_request,
              signer,
              result_mode
            )
        end
      else
        {:error, reason} ->
          {:error, "Action #{name} execution binding rejected: #{inspect(reason)}"}
      end
    end)
  end

  defp execute_with_result_mode(_name, _args, _workdir, _opts, result_mode) do
    raise ArgumentError, "unsupported action result mode: #{inspect(result_mode)}"
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

  # These values remain action-local. They are never params or Engine context,
  # and executable delegate/middleware overrides are intentionally excluded.
  @nested_engine_opt_keys [
    :authorization,
    :authorizer,
    :signer,
    :auth_context,
    :identity_private_key,
    :on_event,
    :logs_root,
    :resumable,
    :max_depth
  ]

  @nested_engine_action_modules [
    Arbor.Actions.Council.ReviewChange,
    Arbor.Actions.Coding.ReviewedCommit
  ]

  @credential_key_names MapSet.new([
                          "signer",
                          "signedrequest",
                          "signingauthority",
                          "identityprivatekey",
                          "authorizer",
                          "authcontext",
                          "privatekey",
                          "credential",
                          "credentials",
                          "bearertoken",
                          "accesstoken",
                          "secretkey"
                        ])

  @signing_boundary_timeout_ms 5_000

  # ============================================================================
  # Private
  # ============================================================================

  defp execute_resolved_action(
         name,
         args,
         workdir,
         opts,
         action_module,
         agent_id,
         caller_id,
         author_id,
         task_id,
         session_id,
         signed_request,
         signer,
         result_mode
       ) do
    with {:ok, pinned_binding} <- verify_pinned_action(action_module, name, opts),
         {:ok, execution_binding_context} <- execution_binding_context(opts),
         {:ok, retry_workdir_guard} <- capture_retry_workdir_guard(workdir, agent_id) do
      params =
        args
        |> atomize_known_keys(action_module)
        |> maybe_resolve_file_paths(action_module, workdir)
        |> maybe_inject_workdir(action_module, workdir)

      case verify_caller_authority(action_module, params, agent_id, caller_id, opts) do
        :ok ->
          with_signing_boundary(opts, fn boundary_ref ->
            with {:ok, nested_engine_opts} <-
                   nested_engine_opts(opts, action_module, boundary_ref),
                 {:ok, signed_request} <-
                   sign_for_action(opts, signed_request, signer, action_module, params) do
              # An authority is process-local input only. The action receives the
              # signed request, never the opaque authority or a closure capturing it.
              legacy_signer =
                if Keyword.has_key?(opts, :signing_authority), do: nil, else: signer

              auth_context =
                Arbor.Contracts.Security.AuthContext.new(agent_id,
                  signer: legacy_signer,
                  signed_request: signed_request,
                  session_id: session_id
                )

              Logger.debug(
                "[ActionsExecutor] #{name}: signed=#{signed_request != nil}, " <>
                  "agent=#{agent_id}, caller=#{caller_id || agent_id}, module=#{action_module}"
              )

              context =
                %{auth_context: auth_context, workdir: workdir}
                |> Map.merge(execution_binding_context)
                |> maybe_put_approval_timeout(opts, execution_binding_context)
                |> Map.put(:retry_workdir_guard, retry_workdir_guard)
                |> maybe_put_context(:task_id, task_id)
                |> maybe_put_context(:session_id, session_id)
                |> maybe_put_context(:caller_id, caller_id || agent_id)
                |> maybe_put_context(:author_id, author_id)
                |> maybe_put_context(:run_authorization, Keyword.get(opts, :run_authorization))
                |> maybe_put_context(:nested_engine_opts, nested_engine_opts)
                |> maybe_put_context(:pinned_action_binding, pinned_binding)
                |> maybe_put_context(:pinned_action_name, name)
                # Owner-issued effect execution ID from Engine/ExecHandler opts only.
                # Never derived here; omit when the owner did not supply one.
                |> maybe_put_context(:execution_id, Keyword.get(opts, :execution_id))
                |> maybe_put_acp_transcript_capture(action_module, opts)
                # Engine-pinned graph execution may resolve pipeline_internal actions.
                |> Map.put(:allow_pipeline_internal, true)
                |> maybe_put_file_workspace(action_module, workdir)
                |> then(fn context ->
                  if signed_request,
                    do: Map.put(context, :signed_request, signed_request),
                    else: context
                end)
                |> then(fn context ->
                  case Keyword.get(opts, :taint) do
                    nil -> context
                    level -> Map.put(context, :taint, level)
                  end
                end)
                |> maybe_put_context(:param_taint, Keyword.get(opts, :param_taint))

              execute_authorized_action(
                agent_id,
                action_module,
                params,
                context,
                name,
                boundary_ref,
                result_mode
              )
            else
              {:error, reason} ->
                {:error, "Action #{name} signing failed: #{inspect(reason)}"}
            end
          end)

        {:error, reason} ->
          {:error,
           "Caller #{caller_id || "unknown"} lacks authority for action #{name}: " <>
             inspect(reason)}
      end
    else
      {:error, reason} ->
        {:error, "Action #{name} execution binding rejected: #{inspect(reason)}"}
    end
  end

  defp execute_authorized_action(
         agent_id,
         action_module,
         params,
         context,
         name,
         boundary,
         result_mode
       ) do
    result = Arbor.Actions.authorize_and_execute(agent_id, action_module, params, context)

    case result do
      {:ok, :pending_approval, proposal_id} ->
        await_approval_and_retry(
          proposal_id,
          agent_id,
          action_module,
          params,
          context,
          name,
          boundary,
          result_mode
        )

      {:ok, result} ->
        successful_result(result, result_mode)

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

  defp verify_pinned_action(action_module, action_name, opts) do
    bindings = Keyword.get(opts, :pinned_action_bindings)
    digest = Keyword.get(opts, :execution_manifest_digest)

    cond do
      not is_nil(digest) and not is_map(bindings) ->
        {:error, :missing_action_bindings}

      is_nil(bindings) ->
        {:ok, nil}

      true ->
        ExecutionManifest.verify_action_module(action_name, action_module, bindings)
    end
  end

  defp execution_binding_context(opts) do
    manifest = Keyword.get(opts, :execution_manifest)
    manifest_digest = Keyword.get(opts, :execution_manifest_digest)
    bindings = Keyword.get(opts, :pinned_action_bindings)
    authority = Keyword.get(opts, :run_authorization)

    cond do
      not is_nil(authority) and not match?(%RunAuthorization{}, authority) ->
        {:error, :invalid_run_authorization}

      Enum.all?([manifest, manifest_digest, bindings], &is_nil/1) and
          authority_has_execution_binding?(authority) ->
        {:error, :incomplete_execution_binding}

      Enum.all?([manifest, manifest_digest, bindings], &is_nil/1) ->
        {:ok, %{}}

      not is_map(manifest) or not is_binary(manifest_digest) or not is_map(bindings) ->
        {:error, :incomplete_execution_binding}

      true ->
        with {:ok, bindings_digest} <- Arbor.Actions.execution_binding_digest(bindings),
             {:ok, lineage} <-
               execution_binding_lineage(authority, manifest, manifest_digest, bindings) do
          {:ok,
           Map.merge(
             %{
               execution_manifest: manifest,
               execution_manifest_digest: manifest_digest,
               pinned_action_bindings: bindings,
               pinned_action_bindings_digest: bindings_digest
             },
             lineage
           )}
        else
          {:error, :run_authorization_execution_binding_mismatch} = error -> error
          {:error, _reason} -> {:error, :invalid_action_bindings}
        end
    end
  end

  defp authority_has_execution_binding?(%RunAuthorization{} = authority) do
    not Enum.all?(
      [
        authority.execution_manifest,
        authority.execution_manifest_digest,
        authority.pinned_action_bindings
      ],
      &is_nil/1
    )
  end

  defp authority_has_execution_binding?(_authority), do: false

  defp execution_binding_lineage(nil, _manifest, _manifest_digest, _bindings),
    do: {:ok, %{}}

  defp execution_binding_lineage(
         %RunAuthorization{} = authority,
         manifest,
         manifest_digest,
         bindings
       ) do
    if authority.execution_manifest == manifest and
         authority.execution_manifest_digest == manifest_digest and
         authority.pinned_action_bindings == bindings do
      {:ok,
       %{
         execution_authority_binding_digest: authority.binding_digest,
         execution_authority_parent_binding_digest: authority.parent_binding_digest
       }}
    else
      {:error, :run_authorization_execution_binding_mismatch}
    end
  end

  defp nested_engine_opts(opts, action_module, boundary_ref) do
    forwarded =
      opts
      |> Keyword.take(@nested_engine_opt_keys)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> maybe_put_nested_authority_boundary(action_module, boundary_ref)

    project? =
      forwarded != [] or match?(%RunAuthorization{}, Keyword.get(opts, :run_authorization))

    if project? do
      case Keyword.get(opts, :max_depth, 3) do
        max_depth when is_integer(max_depth) ->
          {:ok, Keyword.put(forwarded, :max_depth, max_depth - 1)}

        _invalid ->
          {:error, :invalid_nested_engine_max_depth}
      end
    else
      {:ok, nil}
    end
  end

  defp maybe_put_nested_authority_boundary(opts, action_module, {pid, token} = boundary)
       when action_module in @nested_engine_action_modules and is_pid(pid) and is_reference(token) do
    opts
    |> Keyword.put(:authorizer, fn principal_id, type ->
      authorize_at_signing_boundary(boundary, principal_id, type)
    end)
    |> Keyword.put(:signer, fn resource -> sign_at_signing_boundary(boundary, resource) end)
  end

  defp maybe_put_nested_authority_boundary(opts, _action_module, _boundary_ref), do: opts

  defp verify_caller_authority(_action_module, _params, agent_id, caller_id, _opts)
       when caller_id in [nil, ""] or caller_id == agent_id,
       do: :ok

  defp verify_caller_authority(action_module, params, _agent_id, caller_id, opts) do
    security = Arbor.Orchestrator.Config.security_module()
    scope_opts = scope_opts(opts)

    case action_authorization_resource(action_module, params) do
      {:ok, resource} ->
        resource_opts = maybe_put_file_path(scope_opts, resource, params)

        with true <- function_exported?(security, :list_capabilities, 2),
             true <- function_exported?(security, :capability_authorizes?, 3),
             {:ok, effective_resource} <- effective_resource(security, resource, resource_opts),
             {:ok, capabilities} <- security.list_capabilities(caller_id, scope_opts),
             true <-
               Enum.any?(capabilities, fn capability ->
                 security.capability_authorizes?(capability, effective_resource, scope_opts)
               end) do
          :ok
        else
          _ -> {:error, {:caller_authority_missing, resource}}
        end

      {:error, reason} ->
        {:error, {:caller_authority_resource_invalid, reason}}
    end
  end

  defp effective_resource(security, resource, opts) do
    cond do
      function_exported?(security, :normalize_authorization_resource_uri, 2) ->
        security.normalize_authorization_resource_uri(resource, opts)

      function_exported?(security, :authorization_resource_uri, 2) ->
        {:ok, security.authorization_resource_uri(resource, opts)}

      true ->
        {:ok, resource}
    end
  end

  defp scope_opts(opts) do
    []
    |> maybe_put_opt(:task_id, Keyword.get(opts, :task_id))
    |> maybe_put_opt(:session_id, Keyword.get(opts, :session_id))
  end

  defp maybe_put_file_path(opts, resource, params) do
    if resource in ["arbor://fs/read", "arbor://fs/write"] do
      case params[:path] || params[:file_path] || params[:base_path] do
        path when is_binary(path) and path != "" -> Keyword.put(opts, :file_path, path)
        _ -> opts
      end
    else
      opts
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Wait synchronously for approval, then retry execution on success.
  # On denial or timeout, return an error message to the LLM.
  defp await_approval_and_retry(
         proposal_id,
         agent_id,
         action_module,
         params,
         context,
         name,
         boundary,
         result_mode
       ) do
    if interaction_request?(proposal_id) do
      await_interaction_and_retry(
        proposal_id,
        agent_id,
        action_module,
        params,
        context,
        name,
        boundary,
        result_mode
      )
    else
      await_consensus_and_retry(
        proposal_id,
        agent_id,
        action_module,
        params,
        context,
        name,
        boundary,
        result_mode
      )
    end
  end

  # `Escalation.submit_via_router` routes :ask approvals through
  # `Arbor.Comms.InteractionRouter`, returning an "irq_…" request id whose
  # decision arrives on the agent's interaction RESPONSE topic — NOT via
  # Consensus. Wait via the public InteractionRouter.await_response/3 facade
  # (subscribe-before-lookup + durable get_response) — never via undeclared
  # Arbor.Comms.PubSub and never with sleep-based races.
  defp interaction_request?(id) when is_binary(id), do: String.starts_with?(id, "irq")
  defp interaction_request?(_), do: false

  defp await_interaction_and_retry(
         request_id,
         agent_id,
         action_module,
         params,
         context,
         name,
         boundary,
         result_mode
       ) do
    alias Arbor.Contracts.Comms.ApprovalAnswer

    with {:ok, request_id} <- ApprovalAnswer.validate_request_id(request_id) do
      timeout = approval_timeout(context)
      router = interaction_router()

      Logger.info(
        "[ActionsExecutor] Awaiting operator approval for #{name} via InteractionRouter " <>
          "(request: #{request_id}, timeout: #{timeout}ms)"
      )

      if Code.ensure_loaded?(router) and function_exported?(router, :await_response, 3) do
        case apply(router, :await_response, [request_id, agent_id, [timeout: timeout]]) do
          {:ok, response, metadata} ->
            handle_normalized_decision(
              ApprovalAnswer.normalize(response, metadata),
              agent_id,
              action_module,
              params,
              context,
              name,
              request_id,
              :operator,
              boundary,
              result_mode
            )

          {:error, :timeout} ->
            {:error,
             "Action #{name} requires approval but timed out after #{div(timeout, 1000)}s. " <>
               "Request ID: #{request_id}. Ask the user to approve it and try again."}

          {:error, reason} ->
            {:error,
             "Action #{name} approval wait failed (#{inspect(reason)}). Request ID: #{request_id}."}
        end
      else
        {:error,
         "Action #{name} requires approval. Request ID: #{request_id}. " <>
           "InteractionRouter is not available to wait synchronously."}
      end
    else
      {:error, reason} ->
        {:error, "Action #{name}: invalid approval request id (#{inspect(reason)})."}
    end
  rescue
    e ->
      Logger.warning("[ActionsExecutor] await_interaction_and_retry crashed: #{inspect(e)}")
      {:error, "Action #{name} requires approval. Request ID: #{request_id}"}
  end

  defp interaction_router, do: Module.concat([:Arbor, :Comms, :InteractionRouter])

  defp await_consensus_and_retry(
         proposal_id,
         agent_id,
         action_module,
         params,
         context,
         name,
         boundary,
         result_mode
       ) do
    alias Arbor.Contracts.Comms.ApprovalAnswer

    consensus_mod = Module.concat([:Arbor, :Consensus])

    with {:ok, proposal_id} <- ApprovalAnswer.validate_request_id(proposal_id) do
      if Code.ensure_loaded?(consensus_mod) and
           function_exported?(consensus_mod, :await, 2) do
        timeout = approval_timeout(context)

        Logger.info(
          "[ActionsExecutor] Awaiting approval for #{name} (proposal: #{proposal_id}, timeout: #{timeout}ms)"
        )

        case apply(consensus_mod, :await, [proposal_id, [timeout: timeout]]) do
          {:ok, decision} when is_map(decision) ->
            handle_normalized_decision(
              ApprovalAnswer.normalize_consensus_decision(decision),
              agent_id,
              action_module,
              params,
              context,
              name,
              proposal_id,
              :consensus,
              boundary,
              result_mode
            )

          {:ok, :approved} ->
            track_approval(agent_id, action_module)

            retry_execution(
              agent_id,
              action_module,
              params,
              context,
              name,
              proposal_id,
              boundary,
              result_mode
            )

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
        {:error,
         "Action #{name} requires approval. Proposal ID: #{proposal_id}. " <>
           "The approval system is not available to wait synchronously."}
      end
    else
      {:error, reason} ->
        {:error, "Action #{name}: invalid approval proposal id (#{inspect(reason)})."}
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

  # Generic LLM/tool path: approve retries once; deny/rework never execute and
  # surface as honest errors (not success). Coding graphs use
  # coding_reviewed_commit for branchable outcomes instead of a control protocol.
  defp handle_normalized_decision(
         normalized,
         agent_id,
         action_module,
         params,
         context,
         name,
         request_id,
         backend,
         boundary,
         result_mode
       ) do
    case normalized do
      {:ok, :approve} ->
        Logger.info("[ActionsExecutor] Approval granted for #{name}, executing")
        track_approval(agent_id, action_module)

        retry_execution(
          agent_id,
          action_module,
          params,
          context,
          name,
          request_id,
          boundary,
          result_mode
        )

      {:ok, :rework, note} ->
        track_rejection(agent_id, action_module)
        note_suffix = if note != "", do: " Note: #{note}", else: ""

        {:error,
         "Action #{name} was sent for rework by the #{backend_label(backend)}." <>
           " Request ID: #{request_id}.#{note_suffix}"}

      {:ok, :deny, note} ->
        track_rejection(agent_id, action_module)
        note_suffix = if note != "", do: " Note: #{note}", else: ""

        {:error,
         "Action #{name} was denied by the #{backend_label(backend)}." <>
           " Request ID: #{request_id}.#{note_suffix}"}

      {:error, reason} ->
        {:error,
         "Action #{name}: approval response rejected (#{inspect(reason)}). Request ID: #{request_id}."}
    end
  end

  defp backend_label(:operator), do: "operator"
  defp backend_label(:consensus), do: "consensus"
  defp backend_label(_), do: "approval backend"

  # Re-execute only the exact invocation that was approved. The one-shot marker
  # satisfies ApprovalGuard for this retry without minting durable authority.
  defp retry_execution(
         agent_id,
         action_module,
         params,
         context,
         name,
         request_id,
         boundary,
         result_mode
       ) do
    with :ok <- verify_retry_resolution(name, action_module),
         :ok <- verify_retry_binding(name, action_module, context),
         :ok <- verify_retry_caller_authority(action_module, params, agent_id, context),
         {:ok, resource} <- action_authorization_resource(action_module, params),
         retry_context =
           Map.put(context, :approved_invocation, %{
             request_id: request_id,
             principal_id: agent_id,
             resource_uri: resource,
             decision: :approved
           }),
         # The signed request that drove the escalated authorize is single-use.
         {:ok, retry_context} <- resign_for_retry(retry_context, resource, boundary),
         :ok <- verify_retry_workdir(retry_context) do
      result =
        Arbor.Actions.authorize_and_execute(agent_id, action_module, params, retry_context)

      case result do
        {:ok, result} ->
          successful_result(result, result_mode)

        {:ok, :pending_approval, _proposal_id} ->
          {:error,
           "Action #{name} still requires approval after consensus granted it. This is a bug."}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, "Action #{name} was approved but execution failed: #{inspect(reason)}"}
      end
    else
      {:error, reason} ->
        {:error, "Action #{name} approval retry binding rejected: #{inspect(reason)}"}
    end
  end

  defp verify_retry_resolution(name, action_module) do
    normalized = normalize_name(name)

    resolved =
      resolve_via_registry(normalized) ||
        resolve_via_registry(name) ||
        resolve_via_action_map(normalized, name)

    if resolved == action_module,
      do: :ok,
      else: {:error, {:action_registry_drift, name}}
  end

  defp verify_retry_binding(name, action_module, context) do
    bindings = Map.get(context, :pinned_action_bindings)
    digest = Map.get(context, :execution_manifest_digest)

    cond do
      not is_nil(digest) and not is_map(bindings) ->
        {:error, :missing_action_bindings}

      is_map(bindings) ->
        case ExecutionManifest.verify_action_module(name, action_module, bindings) do
          {:ok, _binding} -> :ok
          {:error, _reason} = error -> error
        end

      is_nil(bindings) ->
        :ok

      true ->
        {:error, :invalid_action_bindings}
    end
  end

  defp verify_retry_caller_authority(action_module, params, agent_id, context) do
    caller_id = Map.get(context, :caller_id)

    opts =
      []
      |> maybe_put_opt(:task_id, Map.get(context, :task_id))
      |> maybe_put_opt(:session_id, Map.get(context, :session_id))

    verify_caller_authority(action_module, params, agent_id, caller_id, opts)
  end

  defp capture_retry_workdir_guard(workdir, agent_id) do
    with {:ok, canonical_workdir} <- SafePath.resolve_real(workdir),
         {:ok, authority} <-
           RunAuthorization.new(
             %Graph{id: "ActionsExecutorRetryWorkdir", compiled: true},
             agent_id: agent_id,
             workdir: canonical_workdir
           ) do
      # Retain the same digest-bound workdir identity used by Engine runs
      # from the first attempt through the otherwise unbounded approval wait.
      {:ok, %{authority: authority, supplied_workdir: workdir}}
    else
      _other -> {:error, :retry_workdir_binding_unavailable}
    end
  end

  defp verify_retry_workdir(%{
         retry_workdir_guard: %{
           authority: %RunAuthorization{} = authority,
           supplied_workdir: supplied_workdir
         }
       }) do
    with {:ok, resolved_workdir} <- SafePath.resolve_real(supplied_workdir),
         true <- resolved_workdir == authority.workdir,
         :ok <- RunAuthorization.verify_workdir(authority) do
      :ok
    else
      _other -> {:error, :run_authorization_workdir_changed}
    end
  end

  defp verify_retry_workdir(_context), do: {:error, :missing_retry_workdir_binding}

  # Extended approval waits are trusted Engine/control data. Only accept them
  # when an execution binding is present (coding task / run authority path).
  # Direct unbound callers cannot extend the global timeout — the old
  # ExecHandler-source opt-in is gone (coding bounds live in CodingTaskExecutor).
  defp maybe_put_approval_timeout(context, opts, execution_binding_context) do
    timeout_ms = Keyword.get(opts, :approval_timeout_ms)

    if map_size(execution_binding_context) > 0 and is_integer(timeout_ms) and timeout_ms > 0 do
      Map.put(context, :approval_timeout_ms, timeout_ms)
    else
      context
    end
  end

  defp approval_timeout(context) do
    case Map.get(context, :approval_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      _ ->
        global_approval_timeout()
    end
  end

  defp global_approval_timeout do
    case Application.get_env(:arbor_orchestrator, :approval_timeout_ms, @approval_timeout_ms) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _ -> @approval_timeout_ms
    end
  end

  # The first proof is consumed by identity verification. Mint a fresh proof
  # for the exact approved resource through the process-local boundary. Legacy
  # callers may use their signer, but a signed request without either source
  # fails closed instead of replaying its nonce.
  defp resign_for_retry(context, resource, boundary) do
    signer =
      case boundary do
        {pid, token} when is_pid(pid) and is_reference(token) ->
          fn exact_resource -> sign_at_signing_boundary(boundary, exact_resource) end

        nil ->
          get_in(context, [:auth_context, Access.key(:signer)])
      end

    cond do
      is_function(signer, 1) ->
        with {:ok, fresh} <- signer.(resource) do
          auth_context = %{context.auth_context | signed_request: fresh}

          {:ok,
           context
           |> Map.put(:signed_request, fresh)
           |> Map.put(:auth_context, auth_context)}
        end

      Map.has_key?(context, :signed_request) ->
        {:error, :approval_retry_signer_unavailable}

      true ->
        {:ok, context}
    end
  rescue
    _ -> {:error, :approval_retry_signing_failed}
  catch
    :exit, _ -> {:error, :approval_retry_signing_failed}
  end

  # Record approval/rejection through the public trust facade. The tracker may
  # not be running in standalone/test slices, so tracking remains best-effort.
  defp track_approval(agent_id, action_module) do
    resource = Arbor.Actions.canonical_uri_for(action_module, %{})
    Arbor.Trust.record_approval(agent_id, resource)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp track_rejection(agent_id, action_module) do
    resource = Arbor.Actions.canonical_uri_for(action_module, %{})
    Arbor.Trust.record_rejection(agent_id, resource)
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

  # Inject directory context only for schema-declared keys.
  # Strict schema-bounded actions (e.g. CrossApp.Validate) reject unknown
  # parameters; injecting both :workdir and :cwd unconditionally fails them
  # before any business logic runs.
  defp maybe_inject_workdir(args, action_module, workdir) do
    schema = action_module.to_tool().parameters_schema
    known_keys = extract_schema_keys(schema)

    args
    |> maybe_put_schema_key(known_keys, :workdir, "workdir", workdir)
    |> maybe_put_schema_key(known_keys, :cwd, "cwd", workdir)
  end

  defp maybe_put_schema_key(args, known_keys, atom_key, string_key, value) do
    if MapSet.member?(known_keys, atom_key) do
      put_new_either(args, atom_key, string_key, value)
    else
      args
    end
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

  defp maybe_put_acp_transcript_capture(
         context,
         Arbor.Actions.Acp.SendMessage,
         opts
       ) do
    case {
      Keyword.get(opts, :transcript_capture_error),
      Keyword.get(opts, :transcript_sink),
      Keyword.get(opts, :execution_id)
    } do
      {error, _sink, _execution_id} when not is_nil(error) ->
        Map.put(context, :transcript_capture_error, :invalid_trusted_transcript_capture)

      {nil, nil, _execution_id} ->
        context

      {nil, {module, function, fixed_args} = sink, execution_id}
      when is_atom(module) and is_atom(function) and is_list(fixed_args) and
             is_binary(execution_id) and execution_id != "" ->
        context
        |> Map.put(:transcript_sink, sink)
        |> Map.put(:transcript_execution_id, execution_id)

      {nil, _sink, _execution_id} ->
        Map.put(context, :transcript_capture_error, :invalid_trusted_transcript_capture)
    end
  end

  defp maybe_put_acp_transcript_capture(context, _action_module, _opts), do: context

  defp maybe_put_context(context, _key, nil), do: context
  defp maybe_put_context(context, _key, ""), do: context
  defp maybe_put_context(context, key, value), do: Map.put(context, key, value)

  defp successful_result(result, :formatted), do: {:ok, format_result(result)}
  defp successful_result(result, :structured), do: {:ok, result}

  defp successful_result(_result, result_mode) do
    raise ArgumentError, "unsupported action result mode: #{inspect(result_mode)}"
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

  defp reject_mixed_signing_credentials(opts, args) do
    authority? = Keyword.has_key?(opts, :signing_authority)
    legacy? = Keyword.has_key?(opts, :signer) or Keyword.has_key?(opts, :signed_request)

    cond do
      authority? and legacy? ->
        {:error, :mixed_signing_credentials}

      authority? and
          (credential_bearing_term?(args) or
             credential_bearing_term?(Keyword.delete(opts, :signing_authority))) ->
        {:error, :caller_supplied_signing_credentials}

      true ->
        :ok
    end
  end

  defp credential_bearing_term?(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.any?(fn {key, value} ->
      credential_bearing_key?(key) or credential_bearing_term?(value)
    end)
  end

  defp credential_bearing_term?(term) when is_list(term) do
    Enum.any?(term, fn
      {key, value} -> credential_bearing_key?(key) or credential_bearing_term?(value)
      value -> credential_bearing_term?(value)
    end)
  end

  defp credential_bearing_term?({key, value}) do
    credential_bearing_key?(key) or credential_bearing_term?(value)
  end

  defp credential_bearing_term?(term) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.any?(&credential_bearing_term?/1)
  end

  defp credential_bearing_term?(_term), do: false

  defp credential_bearing_key?(key) when is_atom(key) or is_binary(key),
    do: credential_key?(key)

  defp credential_bearing_key?(key) when is_map(key) do
    Enum.any?(Map.to_list(key), fn {nested_key, nested_value} ->
      credential_bearing_key?(nested_key) or credential_bearing_key?(nested_value)
    end)
  end

  defp credential_bearing_key?(key) when is_list(key),
    do: Enum.any?(key, &credential_bearing_key?/1)

  defp credential_bearing_key?(key) when is_tuple(key) do
    key
    |> Tuple.to_list()
    |> Enum.any?(&credential_bearing_key?/1)
  end

  defp credential_bearing_key?(_key), do: false

  defp credential_key?(key) when is_atom(key) or is_binary(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "")

    MapSet.member?(@credential_key_names, normalized)
  end

  defp credential_key?(_key), do: false

  defp with_signing_boundary(opts, fun) when is_function(fun, 1) do
    case Keyword.fetch(opts, :signing_authority) do
      :error ->
        fun.(nil)

      {:ok, authority} ->
        owner = self()
        token = make_ref()

        {boundary_pid, boundary_monitor} =
          spawn_monitor(fn -> signing_boundary_loop(authority, owner, token) end)

        boundary = {boundary_pid, token}

        result =
          try do
            {:return, fun.(boundary)}
          catch
            kind, reason -> {:raise, kind, reason, __STACKTRACE__}
          end

        close_result = close_signing_boundary(boundary_pid, token, boundary_monitor)

        case {result, close_result} do
          {{:return, value}, :ok} ->
            value

          {{:return, _value}, {:error, reason}} ->
            {:error, "Signing boundary close failed: #{inspect(reason)}"}

          {{:raise, kind, reason, stacktrace}, _close_result} ->
            :erlang.raise(kind, reason, stacktrace)
        end
    end
  end

  defp signing_boundary_loop(authority, owner, token) do
    owner_monitor = Process.monitor(owner)
    signing_boundary_receive(authority, token, owner_monitor)
  end

  defp signing_boundary_receive(authority, token, owner_monitor) do
    receive do
      {:call, caller, call_ref, ^token, {:sign, resource}}
      when is_pid(caller) and is_reference(call_ref) ->
        send(caller, {call_ref, Arbor.Security.sign_with_authority(authority, resource)})
        signing_boundary_receive(authority, token, owner_monitor)

      {:call, caller, call_ref, ^token, {:authorize, principal_id, _type}}
      when is_pid(caller) and is_reference(call_ref) ->
        result =
          case authority do
            %{principal_id: ^principal_id} ->
              Arbor.Orchestrator.Authorization.check_orchestrator_access(
                principal_id,
                authority
              )

            _other ->
              {:error, :principal_mismatch}
          end

        send(caller, {call_ref, result})
        signing_boundary_receive(authority, token, owner_monitor)

      {:close, closer, close_ref, ^token}
      when is_pid(closer) and is_reference(close_ref) ->
        send(closer, {:signing_boundary_closed, close_ref})
        :ok

      {:DOWN, ^owner_monitor, :process, _pid, _reason} ->
        :ok

      _other ->
        signing_boundary_receive(authority, token, owner_monitor)
    end
  end

  defp close_signing_boundary(pid, token, monitor) do
    close_ref = make_ref()
    send(pid, {:close, self(), close_ref, token})

    receive do
      {:signing_boundary_closed, ^close_ref} ->
        await_signing_boundary_down(pid, monitor)

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :signing_boundary_closed_without_acknowledgement}
    after
      @signing_boundary_timeout_ms ->
        Process.exit(pid, :kill)
        await_forced_signing_boundary_down(pid, monitor)
        {:error, :signing_boundary_close_timeout}
    end
  end

  defp await_signing_boundary_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, :normal} -> :ok
      {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :signing_boundary_close_failed}
    after
      @signing_boundary_timeout_ms ->
        Process.exit(pid, :kill)
        await_forced_signing_boundary_down(pid, monitor)
        {:error, :signing_boundary_close_timeout}
    end
  end

  defp await_forced_signing_boundary_down(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @signing_boundary_timeout_ms -> Process.demonitor(monitor, [:flush])
    end
  end

  defp sign_at_signing_boundary({pid, token}, resource)
       when is_pid(pid) and is_reference(token) and is_binary(resource) and resource != "" do
    signing_boundary_call(pid, token, {:sign, resource})
  end

  defp sign_at_signing_boundary(_boundary, _resource),
    do: {:error, :invalid_signing_boundary_request}

  defp authorize_at_signing_boundary({pid, token}, principal_id, type)
       when is_pid(pid) and is_reference(token) and is_binary(principal_id) do
    signing_boundary_call(pid, token, {:authorize, principal_id, type})
  end

  defp authorize_at_signing_boundary(_boundary, _principal_id, _type),
    do: {:error, :invalid_signing_boundary_request}

  defp signing_boundary_call(pid, token, request) do
    call_ref = make_ref()
    monitor = Process.monitor(pid)
    send(pid, {:call, self(), call_ref, token, request})

    receive do
      {^call_ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, :signing_boundary_unavailable}
    after
      5_000 ->
        Process.demonitor(monitor, [:flush])
        {:error, :signing_boundary_timeout}
    end
  end

  # Sign a tool call using the canonical module-derived resource URI. Authority
  # key presence selects the authority path, including when its value is nil.
  # Params are included so self-scoped URIs match authorize_and_execute.
  defp sign_for_action(opts, signed_request, signer, action_module, params) do
    case Keyword.fetch(opts, :signing_authority) do
      {:ok, authority} ->
        sign_with_authority_for_module(authority, action_module, params)

      :error ->
        {:ok, signed_request || sign_for_module(signer, action_module, params)}
    end
  end

  defp sign_with_authority_for_module(authority, action_module, params) do
    with {:ok, resource} <- action_authorization_resource(action_module, params),
         {:ok, signed_request} <- Arbor.Security.sign_with_authority(authority, resource) do
      Logger.debug("[ActionsExecutor] Authority-signed for #{resource}")
      {:ok, signed_request}
    else
      {:error, reason} ->
        Logger.warning(
          "[ActionsExecutor] Authority signing failed for #{inspect(action_module)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp sign_for_module(nil, _action_module, _params), do: nil

  defp sign_for_module(signer, action_module, params) when is_function(signer, 1) do
    with {:ok, resource} <- action_authorization_resource(action_module, params),
         {:ok, signed_request} <- signer.(resource) do
      Logger.debug("[ActionsExecutor] Signed for #{resource}")
      signed_request
    else
      {:error, reason} ->
        Logger.warning(
          "[ActionsExecutor] Signing failed for #{inspect(action_module)}: #{inspect(reason)}"
        )

        nil
    end
  end

  defp sign_for_module(_, _, _), do: nil

  defp action_authorization_resource(action_module, params) do
    result =
      if Code.ensure_loaded?(action_module) and
           function_exported?(action_module, :authorization_resource, 1) do
        action_module.authorization_resource(params)
      else
        {:ok, Arbor.Actions.canonical_uri_for(action_module, params)}
      end

    case result do
      {:ok, "arbor://" <> _rest = resource} -> {:ok, resource}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_action_authorization_resource}
    end
  end

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
