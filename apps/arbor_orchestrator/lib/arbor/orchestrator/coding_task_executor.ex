defmodule Arbor.Orchestrator.CodingTaskExecutor do
  @moduledoc """
  `Arbor.Contracts.Agent.TaskExecutor` for the packaged coding-change pipeline.

  Accepts canonical JSON task maps with `kind: "coding_change"` in either the
  legacy flat shape or the versioned `Coding.Plan` shape. A reviewed compiler
  turns the normalized plan and trusted packaged template into immutable DOT;
  the exact plan, graph, and compile manifest are archived before execution.
  Engine opts come only from that compilation, allowlisted context fields, and
  trusted `run/3` identity — never from task-supplied authority or graph data.

  Authorization is mandatory (`authorization: true`) with a reload-stable
  `SigningAuthority` acquired from the target agent's signing key via the
  public Security facade. Missing identity/key/runtime graph fails closed (no
  system/unsigned fallback).

  This production executor always requires a live security runtime
  (`Config.security_available?/0`) before invoking any runner, regardless of
  the global standalone `security_required?` escape hatch. Repository and
  worktree paths must resolve inside explicitly configured workspace roots.
  These roots constrain task input only; they do not grant filesystem
  capabilities or replace authorization.

  ## JSON boundary

  Production TaskStore already canonicalizes. This module therefore accepts
  only non-struct, string-keyed JSON maps at `run/3`, `task_status/2`, and
  `cancel_task/2`, and `steer_task/3`. Atom keys, keywords, structs, PIDs,
  functions, and other non-JSON values are rejected (not stringified). Unknown
  context keys are rejected. Optional context fields are type-checked:
  `task_id` / `caller_id` nonblank strings, `timeout` a positive integer when
  present, `metadata` a JSON object when present. Each task receives an
  isolated, path-safe Engine logs directory. A supplied `timeout` is forwarded
  to Engine handlers and bounds the complete runner invocation.

  Steering never accepts a worker handle or principal override. It binds the
  persisted control's exact task id to the execution context, embeds the user
  correction as bounded JSON data in a same-session instruction, and resolves
  the active session only through the public managed ACP task/principal facade.
  """

  @behaviour Arbor.Contracts.Agent.TaskExecutor

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Coding.Plan
  alias Arbor.Contracts.Security.SigningAuthority
  alias Arbor.Orchestrator.Config

  alias Arbor.Orchestrator.CodingPlan.{
    ActionCatalog,
    Compilation,
    ExecutionManifest,
    Normalizer,
    Profiles,
    SemanticPreflight
  }

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

  @allowed_context_keys MapSet.new(~w(task_id timeout caller_id metadata))

  @allowed_control_keys MapSet.new(~w(
    control_id
    task_id
    sequence
    status
    sender_id
    message
    queued_at
    delivered_at
    target_stage
    delivery_mode
    error
  ))

  @forbidden_control_keys MapSet.new(~w(
    worker_session_id
    session_pid
    worker_pid
    owner_pid
    principal_id
    agent_id
    task_principal_id
    authorization
    signer
    capabilities
    identity
    private_key
    signing_key
  ))

  @max_control_id_bytes 256
  @max_control_task_id_bytes 512
  @max_control_message_bytes 4_000
  @max_target_stage_bytes 200
  @max_follow_up_instruction_bytes 16_384
  @max_metric_completed_nodes 500
  @max_metric_node_durations 500
  @max_metric_node_id_bytes 256
  @max_metric_usage_entries 32
  @max_metric_usage_list_items 32
  @max_metric_usage_depth 3
  @max_metric_usage_key_bytes 128
  @max_metric_usage_string_bytes 1_024
  @max_metric_usage_encoded_bytes 16_384

  @terminal_control_errors MapSet.new([
                             :unsupported,
                             :not_supported,
                             :task_control_unsupported,
                             :nonrecoverable,
                             :non_recoverable,
                             :ambiguous_task_control_session,
                             :invalid_task_control,
                             :invalid_control_id,
                             :invalid_control_message,
                             :invalid_task_id,
                             :blank_task_control
                           ])

  @forbidden_context_keys MapSet.new(~w(
    approval_timeout_ms
    authorization
    signer
    agent_id
    engine
    engine_module
    action_executor
    actions_executor
    graph
    graph_path
    capabilities
    identity
    authorizer
    private_key
    signing_key
    identity_private_key
  ))

  @forbidden_initial_value_keys MapSet.new(~w(
    action_executor
    actions_executor
    agent_id
    approval_timeout_ms
    artifacts
    authorization
    authorizer
    capabilities
    coding_pipeline_path
    compile_manifest_path
    coding_plan_path
    engine
    engine_module
    graph
    graph_path
    identity
    identity_private_key
    pipeline_path
    private_key
    session.agent_id
    session.caller_id
    session.metadata
    session.task_id
    signer
    signing_key
    task_id
  ))

  @artifact_descriptor_keys MapSet.new(~w(
    coding_plan_path
    coding_pipeline_path
    compile_manifest_path
    graph_hash
    compiler_version
  ))

  @artifact_path_keys ~w(coding_plan_path coding_pipeline_path compile_manifest_path)

  @success_statuses MapSet.new(~w(
    approval_denied
    change_committed
    declined
    human_review_required
    no_changes
    pr_created
    pr_failed
    review_failed
    review_rejected
    review_requires_rework
    rework_exhausted
    validation_failed
  ))

  @type json_map :: Arbor.Contracts.Agent.TaskExecutor.json_map()

  @doc """
  Run the coding-change pipeline for `agent_id`.

  `task` must be a JSON-clean string-keyed map with `kind: "coding_change"` and
  either legacy coding fields or a versioned `plan` object. `context` must
  include a nonblank `task_id`; optional `timeout` / `caller_id` / `metadata`
  are accepted as data only (not as control authority).
  """
  @impl true
  @spec run(String.t(), term(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(agent_id, task, context) when is_binary(agent_id) do
    started_at = System.monotonic_time(:millisecond)

    with :ok <- validate_agent_id(agent_id),
         {:ok, exec_ctx} <- validate_context(context),
         {:ok, plan} <- Normalizer.normalize_task(task),
         :ok <- require_security_available(),
         {:ok, plan} <- normalize_workspace_scope(plan),
         {:ok, template_path} <- resolve_template_path(),
         {:ok, security} <- security_facade(),
         {:ok, authority} <- acquire_signing_authority(security, agent_id) do
      try do
        with {:ok, compilation} <- compile_plan(plan, template_path),
             {:ok, logs_root} <- prepare_task_logs_root(exec_ctx.task_id),
             {:ok, artifacts} <- archive_compilation(logs_root, plan, compilation),
             {:ok, {pinned_action_bindings, pinned_handler_bindings}} <-
               verify_execution_boundary(
                 Map.fetch!(artifacts, "coding_pipeline_path"),
                 plan,
                 compilation
               ),
             {:ok, opts} <-
               build_engine_opts(
                 agent_id,
                 plan,
                 compilation,
                 exec_ctx,
                 authority,
                 logs_root,
                 pinned_action_bindings,
                 pinned_handler_bindings
               ),
             :ok <- validate_authority_signing(security, authority),
             # Startup URI registration is a snapshot; reconcile hot-loaded actions.
             :ok <- reconcile_action_uri_prefixes(),
             {:ok, engine_result} <-
               invoke_runner(Map.fetch!(artifacts, "coding_pipeline_path"), opts),
             {:ok, result} <-
               adapt_result(engine_result, started_at, Map.fetch!(plan.worker, "provider")) do
          {:ok,
           Map.put(result, "artifacts", attach_workspace_release_artifact(artifacts, result))}
        end
      after
        # The broker monitors this run process, but normal terminal outcomes
        # must release the authority before returning to TaskStore.
        _ = close_signing_authority(security, authority)
      end
    end
  end

  def run(_agent_id, _task, _context), do: {:error, :invalid_agent_id}

  @doc """
  Project JSON-clean progress for TaskStore from PipelineStatus.

  Returns only `current_step` and `waiting_on` (string or nil). Never returns
  PIDs or RunState structs.
  """
  @impl true
  @spec task_status(String.t(), map() | keyword()) ::
          {:ok, json_map()} | {:error, term()}
  def task_status(_agent_id, context) do
    with {:ok, exec_ctx} <- validate_context(context),
         task_id <- exec_ctx.task_id do
      case Config.pipeline_status_module().get(task_id) do
        nil ->
          {:error, :not_found}

        entry when is_map(entry) ->
          {:ok, progress_from_entry(entry)}

        _other ->
          {:error, :invalid_pipeline_status}
      end
    end
  rescue
    e -> {:error, {:pipeline_status_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_status_exit, reason}}
  end

  @doc """
  Cooperative cancel bookkeeping: mark the pipeline run abandoned.

  Idempotent and bounded. TaskStore still owns hard process termination and
  monitored resource cleanup.
  """
  @impl true
  @spec cancel_task(String.t(), map() | keyword()) :: :ok | {:error, term()}
  def cancel_task(_agent_id, context) do
    with {:ok, exec_ctx} <- validate_context(context),
         task_id <- exec_ctx.task_id do
      _ = Config.pipeline_status_module().mark_abandoned(task_id)
      :ok
    end
  rescue
    e -> {:error, {:pipeline_cancel_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_cancel_exit, reason}}
  end

  @doc """
  Deliver a persisted TaskStore control to the active managed ACP worker.

  The exact control/task ids are retained for managed-session dedupe. Delivery
  is resolved only by the context-bound task id and callback `agent_id`; worker
  handles, PIDs, and caller-provided principal overrides are rejected. Queued
  controls are durably accepted same-session follow-ups. Deferred or
  operational results remain retryable so TaskStore retains the same control
  id, while explicit unsupported/ambiguous outcomes are terminal.
  """
  @impl true
  @spec steer_task(String.t(), term(), map() | keyword()) ::
          Arbor.Contracts.Agent.TaskExecutor.steering_result()
  def steer_task(agent_id, control, context) do
    with :ok <- validate_steering_agent_id(agent_id),
         {:ok, control_data} <- validate_steering_control(control),
         {:ok, exec_ctx} <- validate_context(context),
         :ok <- ensure_same_task(control_data.task_id, exec_ctx.task_id),
         {:ok, managed_control} <- build_managed_control(control_data) do
      deliver_managed_control(control_data.task_id, agent_id, managed_control)
    end
  end

  # ===========================================================================
  # Validation
  # ===========================================================================

  defp validate_steering_agent_id(agent_id) when is_binary(agent_id) do
    if String.valid?(agent_id) and String.trim(agent_id) != "",
      do: :ok,
      else: {:error, :invalid_agent_id}
  end

  defp validate_steering_agent_id(_agent_id), do: {:error, :invalid_agent_id}

  defp validate_steering_control(control) when is_map(control) and not is_struct(control) do
    with :ok <- ensure_string_keyed_json_map(control, :non_json_control),
         :ok <- ensure_json_encodable(control, :non_json_control),
         :ok <-
           reject_forbidden_keys(control, @forbidden_control_keys, :forbidden_control_key),
         :ok <- reject_unknown_keys(control, @allowed_control_keys, :unknown_control_key),
         {:ok, control_id} <-
           require_bounded_control_field(control, "control_id", @max_control_id_bytes),
         {:ok, task_id} <-
           require_bounded_control_field(control, "task_id", @max_control_task_id_bytes),
         {:ok, message} <-
           require_bounded_control_field(control, "message", @max_control_message_bytes),
         {:ok, target_stage} <- normalize_control_target_stage(control) do
      {:ok,
       %{
         control_id: control_id,
         task_id: task_id,
         message: message,
         target_stage: target_stage
       }}
    end
  end

  defp validate_steering_control(_control), do: {:error, :invalid_control}

  defp require_bounded_control_field(control, field, max_bytes) do
    case Map.fetch(control, field) do
      :error ->
        {:error, {:missing_field, field}}

      {:ok, value} when is_binary(value) ->
        cond do
          byte_size(value) > max_bytes -> {:error, {:field_too_large, field}}
          not String.valid?(value) -> {:error, {:invalid_field_encoding, field}}
          String.trim(value) == "" -> {:error, {:blank_field, field}}
          true -> {:ok, value}
        end

      {:ok, _value} ->
        {:error, {:invalid_field_type, field}}
    end
  end

  defp normalize_control_target_stage(control) do
    case Map.fetch(control, "target_stage") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        cond do
          byte_size(value) > @max_target_stage_bytes ->
            {:error, {:field_too_large, "target_stage"}}

          not String.valid?(value) ->
            {:error, {:invalid_field_encoding, "target_stage"}}

          String.trim(value) == "" ->
            {:ok, nil}

          true ->
            {:ok, value}
        end

      {:ok, _value} ->
        {:error, {:invalid_field_type, "target_stage"}}
    end
  end

  defp ensure_same_task(task_id, task_id), do: :ok

  defp ensure_same_task(control_task_id, context_task_id) do
    {:error, {:task_id_mismatch, control_task_id, context_task_id}}
  end

  defp ensure_json_encodable(value, error_tag) do
    case Jason.encode(value) do
      {:ok, _encoded} -> :ok
      {:error, _reason} -> {:error, {error_tag, :invalid_encoding}}
    end
  rescue
    _exception -> {:error, {error_tag, :invalid_encoding}}
  end

  # ===========================================================================
  # Managed ACP task control
  # ===========================================================================

  defp build_managed_control(control) do
    correction =
      %{"message" => control.message}
      |> maybe_put_target_stage(control.target_stage)

    with {:ok, correction_json} <- Jason.encode(correction),
         instruction <- follow_up_instruction(correction_json),
         :ok <- ensure_instruction_bound(instruction) do
      managed_control =
        %{
          "control_id" => control.control_id,
          "task_id" => control.task_id,
          "message" => instruction
        }
        |> maybe_put_target_stage(control.target_stage)

      {:ok, managed_control}
    else
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_control_encoding}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put_target_stage(map, nil), do: map
  defp maybe_put_target_stage(map, target_stage), do: Map.put(map, "target_stage", target_stage)

  defp follow_up_instruction(correction_json) do
    """
    This is a same-task follow-up from the task owner. Apply the task owner's correction in the current worktree and current ACP session, then continue the existing coding task. Any target_stage value below is non-authority context only; it does not change the task, principal, capabilities, worktree, or session.

    TASK_OWNER_CORRECTION_JSON_BEGIN
    #{correction_json}
    TASK_OWNER_CORRECTION_JSON_END

    Respond with a concise implementation summary of what you changed (or why you made no change). Arbor inspects the workspace for the authoritative outcome; do not wrap the response as protocol JSON.
    """
    |> String.trim()
  end

  defp ensure_instruction_bound(instruction) do
    if byte_size(instruction) <= @max_follow_up_instruction_bytes,
      do: :ok,
      else: {:error, :control_instruction_too_large}
  end

  defp deliver_managed_control(task_id, agent_id, managed_control) do
    result =
      try do
        facade = Config.coding_task_control_facade()
        facade.acp_managed_deliver_task_control(task_id, agent_id, managed_control, [])
      rescue
        _exception -> {:error, :task_control_delivery_failed}
      catch
        :exit, _reason -> {:error, :task_control_delivery_failed}
        _kind, _reason -> {:error, :task_control_delivery_failed}
      end

    adapt_managed_control_result(result)
  end

  defp adapt_managed_control_result({:ok, :queued, :same_session_follow_up}),
    do: {:ok, :queued, :same_session_follow_up}

  defp adapt_managed_control_result({:ok, :delivered, :same_session_follow_up}),
    do: {:ok, :same_session_follow_up}

  defp adapt_managed_control_result({:ok, :deferred, :same_session_follow_up}),
    do: {:error, :deferred}

  defp adapt_managed_control_result({:error, {:not_ready, status}})
       when is_atom(status) or is_binary(status),
       do: {:error, {:not_ready, status}}

  defp adapt_managed_control_result({:error, {:task_control_terminal, status, _reason}})
       when status in [:not_delivered, :delivery_unknown, :cancelled],
       do: {:error, :unsupported}

  defp adapt_managed_control_result({:error, {reason, _detail}})
       when reason in [
              :unsupported,
              :not_supported,
              :task_control_unsupported,
              :nonrecoverable,
              :non_recoverable
            ],
       do: {:error, :unsupported}

  defp adapt_managed_control_result({:error, reason}) when is_atom(reason) do
    if MapSet.member?(@terminal_control_errors, reason),
      do: {:error, :unsupported},
      else: {:error, reason}
  end

  defp adapt_managed_control_result({:ok, _status, _mode}), do: {:error, :unsupported}
  defp adapt_managed_control_result(_result), do: {:error, :task_control_delivery_failed}

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    case String.trim(agent_id) do
      "" -> {:error, :invalid_agent_id}
      _ -> :ok
    end
  end

  defp validate_context(context) when is_map(context) and not is_struct(context) do
    with :ok <- ensure_string_keyed_json_map(context, :non_json_context),
         :ok <- reject_forbidden_keys(context, @forbidden_context_keys, :forbidden_context_key),
         :ok <- reject_unknown_keys(context, @allowed_context_keys, :unknown_context_key),
         {:ok, task_id} <- require_nonblank(context, "task_id"),
         {:ok, extras} <- extract_context_extras(context) do
      {:ok, Map.merge(%{task_id: task_id}, extras)}
    end
  end

  defp validate_context(_context), do: {:error, :invalid_context}

  defp require_nonblank(map, field) do
    case Map.get(map, field) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:blank_field, field}}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:error, {:missing_field, field}}

      _other ->
        {:error, {:invalid_field_type, field}}
    end
  end

  defp extract_context_extras(context) do
    Enum.reduce_while(["timeout", "caller_id", "metadata"], {:ok, %{}}, fn key, {:ok, acc} ->
      case Map.fetch(context, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize_context_extra(key, value) do
            {:ok, normalized} ->
              atom_key =
                case key do
                  "timeout" -> :timeout
                  "caller_id" -> :caller_id
                  "metadata" -> :metadata
                end

              {:cont, {:ok, Map.put(acc, atom_key, normalized)}}

            {:error, _} = err ->
              {:halt, err}
          end
      end
    end)
  end

  defp normalize_context_extra("timeout", value)
       when is_integer(value) and value > 0 and not is_boolean(value) do
    {:ok, value}
  end

  defp normalize_context_extra("timeout", _value), do: {:error, {:invalid_field_type, "timeout"}}

  defp normalize_context_extra("caller_id", value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, {:blank_field, "caller_id"}}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_context_extra("caller_id", _value),
    do: {:error, {:invalid_field_type, "caller_id"}}

  defp normalize_context_extra("metadata", value)
       when is_map(value) and not is_struct(value) do
    case ensure_string_keyed_json_map(value, :non_json_context) do
      :ok -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp normalize_context_extra("metadata", _value),
    do: {:error, {:invalid_field_type, "metadata"}}

  defp reject_forbidden_keys(map, forbidden, error_tag) do
    case Enum.find(Map.keys(map), &MapSet.member?(forbidden, &1)) do
      nil -> :ok
      key -> {:error, {error_tag, key}}
    end
  end

  defp reject_unknown_keys(map, allowed, error_tag) do
    case Enum.find(Map.keys(map), &(not MapSet.member?(allowed, &1))) do
      nil -> :ok
      key -> {:error, {error_tag, key}}
    end
  end

  # Strict JSON boundary: only string keys, no structs/keywords/coercion.
  # Rejects maps that would require stringifying atom keys or merging
  # conflicting coercible keys (e.g. :task and "task").
  defp ensure_string_keyed_json_map(map, error_tag) when is_map(map) and not is_struct(map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      cond do
        not is_binary(key) ->
          {:halt, {:error, {error_tag, :non_string_key}}}

        true ->
          case ensure_json_value(value) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {error_tag, reason}}}
          end
      end
    end)
  end

  defp ensure_json_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v),
    do: :ok

  defp ensure_json_value(list) when is_list(list) do
    if Keyword.keyword?(list) and list != [] do
      {:error, :keyword_not_json}
    else
      Enum.reduce_while(list, :ok, fn item, :ok ->
        case ensure_json_value(item) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp ensure_json_value(map) when is_map(map) and not is_struct(map) do
    ensure_string_keyed_json_map(map, :nested_non_json)
  end

  defp ensure_json_value(%_{}), do: {:error, :struct_not_json}
  defp ensure_json_value(v) when is_atom(v), do: {:error, :atom_not_json}
  defp ensure_json_value(v) when is_pid(v), do: {:error, :pid_not_json}
  defp ensure_json_value(v) when is_function(v), do: {:error, :function_not_json}
  defp ensure_json_value(v) when is_reference(v), do: {:error, :reference_not_json}
  defp ensure_json_value(v) when is_port(v), do: {:error, :port_not_json}
  defp ensure_json_value(v) when is_tuple(v), do: {:error, :tuple_not_json}
  defp ensure_json_value(_), do: {:error, :non_json_value}

  # ===========================================================================
  # Identity / graph / engine opts
  # ===========================================================================

  # Workspace roots are input scope, not authorization. Both configured roots
  # and caller-supplied paths must already exist so realpath can resolve every
  # symlink before the segment-aware containment check.
  defp normalize_workspace_scope(%Plan{} = plan) do
    with {:ok, configured_repo_roots} <- Config.coding_repo_roots(),
         {:ok, configured_worktree_roots} <- Config.coding_worktree_roots(),
         {:ok, repo_roots} <- canonicalize_configured_roots(configured_repo_roots, :repo),
         {:ok, worktree_roots} <-
           canonicalize_configured_roots(configured_worktree_roots, :worktree),
         {:ok, requested_repo_path} <-
           resolve_scoped_path(plan.repo_root, repo_roots, :repo_path),
         {:ok, repo_path} <- resolve_git_top_level(requested_repo_path, repo_roots),
         {:ok, worktree_base_dir} <-
           resolve_worktree_base(plan.workspace_policy["worktree_base_dir"], worktree_roots),
         plan_map = Plan.to_map(plan),
         workspace_policy =
           Map.put(plan_map["workspace_policy"], "worktree_base_dir", worktree_base_dir),
         {:ok, canonical_plan} <-
           Plan.new(
             plan_map
             |> Map.put("repo_root", repo_path)
             |> Map.put("workspace_policy", workspace_policy)
           ) do
      {:ok, canonical_plan}
    end
  end

  defp canonicalize_configured_roots(roots, kind) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, acc} ->
      case canonicalize_configured_root(root, kind) do
        {:ok, canonical} -> {:cont, {:ok, [canonical | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, canonical |> Enum.reverse() |> Enum.uniq()}
      {:error, _} = error -> error
    end
  end

  defp canonicalize_configured_root(root, kind) do
    with :ok <- SafePath.validate(root),
         {:ok, canonical} <- SafePath.resolve_real(root),
         true <- canonical != "/" and File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, {:invalid_coding_root, kind}}
    end
  end

  defp resolve_scoped_path(path, roots, field) do
    with :ok <- validate_absolute_path(path, field),
         {:ok, canonical} <- resolve_existing_directory(path, field),
         :ok <- ensure_within_configured_roots(canonical, roots, field) do
      {:ok, canonical}
    end
  end

  defp validate_absolute_path(path, field) do
    with :ok <- SafePath.validate(path),
         true <- SafePath.absolute?(path) do
      :ok
    else
      _ -> {:error, {:invalid_coding_path, field}}
    end
  end

  defp resolve_existing_directory(path, field) do
    case SafePath.resolve_real(path) do
      {:ok, canonical} ->
        if File.dir?(canonical),
          do: {:ok, canonical},
          else: {:error, {:invalid_coding_path, field}}

      _ ->
        {:error, {:invalid_coding_path, field}}
    end
  end

  defp ensure_within_configured_roots(path, roots, field) do
    if Enum.any?(roots, &contained_in?(&1, path)) do
      :ok
    else
      {:error, {:coding_path_outside_roots, field}}
    end
  end

  # `resolve_within/2` compares whole path segments (a root `/repos/app` does
  # not contain `/repos/app-evil`). Both values have already been realpathed.
  defp contained_in?(root, path) do
    case SafePath.resolve_within(path, root) do
      {:ok, ^path} -> true
      _ -> false
    end
  end

  defp resolve_git_top_level(repo_path, repo_roots) do
    case System.cmd("git", ["-C", repo_path, "rev-parse", "--show-toplevel"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        git_root = String.trim(output)

        with :ok <- validate_absolute_path(git_root, :repo_path),
             {:ok, canonical_git_root} <- resolve_existing_directory(git_root, :repo_path),
             :ok <- ensure_within_configured_roots(canonical_git_root, repo_roots, :repo_path) do
          {:ok, canonical_git_root}
        else
          {:error, {:coding_path_outside_roots, :repo_path}} ->
            {:error, :git_root_outside_coding_roots}

          _ ->
            {:error, :invalid_git_repository}
        end

      {_output, _status} ->
        {:error, :invalid_git_repository}
    end
  rescue
    _ -> {:error, :invalid_git_repository}
  catch
    :exit, _ -> {:error, :invalid_git_repository}
  end

  defp resolve_worktree_base(nil, worktree_roots), do: {:ok, List.first(worktree_roots)}

  defp resolve_worktree_base(path, worktree_roots),
    do: resolve_scoped_path(path, worktree_roots, :worktree_base_dir)

  # Production coding executor always fails closed when security is down —
  # before any runner (including injected test doubles) is invoked, and
  # regardless of the global standalone security_required? escape hatch.
  defp require_security_available do
    if Config.security_available?() do
      :ok
    else
      {:error, :security_unavailable}
    end
  end

  defp resolve_template_path do
    path = Config.coding_pipeline_path()

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, :coding_pipeline_unavailable}

      File.regular?(path) ->
        {:ok, path}

      true ->
        {:error, {:coding_pipeline_unavailable, path}}
    end
  end

  defp compile_plan(%Plan{} = plan, template_path) do
    compiler = Config.coding_plan_compiler()

    cond do
      not is_atom(compiler) ->
        {:error, :coding_plan_compiler_unavailable}

      not Code.ensure_loaded?(compiler) ->
        {:error, :coding_plan_compiler_unavailable}

      not function_exported?(compiler, :compile, 2) ->
        {:error, :coding_plan_compiler_unavailable}

      true ->
        invoke_compiler(compiler, plan, template_path)
    end
  end

  defp invoke_compiler(compiler, plan, template_path) do
    case compiler.compile(plan, template_path: template_path) do
      {:ok, %Compilation{} = compilation} ->
        validate_compilation(compilation, plan)

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_coding_plan_compiler_reply}
    end
  rescue
    error -> {:error, {:coding_plan_compile_error, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:coding_plan_compile_exit, reason}}
    kind, reason -> {:error, {:coding_plan_compile_throw, {kind, reason}}}
  end

  defp validate_compilation(%Compilation{} = compilation, %Plan{} = plan) do
    with :ok <- validate_compilation_plan(compilation.plan_map, plan),
         :ok <- validate_nonblank_binary(compilation.dot_source, :dot_source),
         :ok <- validate_hash(compilation.graph_hash, :graph_hash),
         :ok <- validate_dot_hash(compilation.dot_source, compilation.graph_hash),
         :ok <- validate_nonblank_binary(compilation.compiler_version, :compiler_version),
         :ok <- validate_nonblank_binary(compilation.template_version, :template_version),
         :ok <- validate_hash(compilation.plan_fingerprint, :plan_fingerprint),
         :ok <- validate_hash(compilation.action_catalog_digest, :action_catalog_digest),
         :ok <-
           validate_hash(compilation.execution_manifest_digest, :execution_manifest_digest),
         :ok <- validate_json_object(compilation.execution_manifest, :execution_manifest),
         :ok <-
           ExecutionManifest.validate(
             compilation.execution_manifest,
             compilation.execution_manifest_digest,
             compilation.graph_hash
           ),
         :ok <- validate_json_object(compilation.initial_values, :initial_values),
         :ok <-
           reject_forbidden_keys(
             compilation.initial_values,
             @forbidden_initial_value_keys,
             :forbidden_compilation_initial_value
           ),
         :ok <- validate_core_initial_values(compilation.initial_values, plan),
         :ok <- validate_json_object(compilation.manifest, :manifest),
         :ok <- validate_compilation_manifest(compilation, plan) do
      {:ok, compilation}
    else
      {:error, reason} -> {:error, {:invalid_coding_plan_compiler_reply, reason}}
    end
  end

  defp validate_compilation_plan(plan_map, plan) do
    with :ok <- validate_json_object(plan_map, :plan_map),
         true <- plan_map == Plan.to_map(plan) do
      :ok
    else
      false -> {:error, :plan_map_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_nonblank_binary(value, _field)
       when is_binary(value) and byte_size(value) > 0 do
    if String.valid?(value) and String.trim(value) != "",
      do: :ok,
      else: {:error, :invalid_binary}
  end

  defp validate_nonblank_binary(_value, field), do: {:error, {:invalid_field, field}}

  defp validate_hash(value, field) do
    with :ok <- validate_nonblank_binary(value, field),
         true <- Regex.match?(~r/^[0-9a-f]{64}$/, value) do
      :ok
    else
      false -> {:error, {:invalid_hash, field}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_dot_hash(dot_source, graph_hash) do
    if sha256(dot_source) == graph_hash,
      do: :ok,
      else: {:error, :graph_hash_mismatch}
  end

  defp validate_core_initial_values(initial_values, plan) do
    required = %{
      "task" => plan.task,
      "repo_path" => plan.repo_root,
      "acp_agent" => plan.worker["provider"],
      "base_ref" => plan.base_ref,
      "timeout" => plan.budgets["wall_clock_ms"],
      "inactivity_timeout_ms" => plan.budgets["inactivity_timeout_ms"],
      "open_pr" => bool_string(plan.output["draft_pr"]),
      "retain_workspace" => bool_string(plan.output["retain_workspace"]),
      "submit_review" => bool_string(plan.review_profile != "none")
    }

    optional = %{
      "branch_name" => plan.workspace_policy["branch_name"],
      "model" => plan.worker["model"],
      "test_paths" => expected_test_paths(plan),
      "worktree_base_dir" => plan.workspace_policy["worktree_base_dir"]
    }

    with :ok <- validate_present_initial_values(initial_values, required),
         :ok <- validate_optional_initial_values(initial_values, optional) do
      :ok
    end
  end

  defp validate_present_initial_values(initial_values, expected) do
    case Enum.find(expected, fn {key, value} ->
           not Map.has_key?(initial_values, key) or Map.fetch!(initial_values, key) != value
         end) do
      nil -> :ok
      {key, _value} -> {:error, {:initial_value_mismatch, key}}
    end
  end

  defp validate_optional_initial_values(initial_values, expected) do
    case Enum.find(expected, fn
           {key, nil} ->
             Map.has_key?(initial_values, key)

           {key, value} ->
             not Map.has_key?(initial_values, key) or Map.fetch!(initial_values, key) != value
         end) do
      nil -> :ok
      {key, _value} -> {:error, {:initial_value_mismatch, key}}
    end
  end

  defp expected_test_paths(%Plan{validation_profile: "security_regression"} = plan),
    do: plan.requested_paths

  defp expected_test_paths(_plan), do: nil

  defp validate_compilation_manifest(compilation, plan) do
    manifest = compilation.manifest

    expected = %{
      "graph_hash" => compilation.graph_hash,
      "compiler_version" => compilation.compiler_version,
      "template_version" => compilation.template_version,
      "plan_fingerprint" => compilation.plan_fingerprint,
      "action_catalog_digest" => compilation.action_catalog_digest,
      "execution_manifest" => compilation.execution_manifest,
      "execution_manifest_digest" => compilation.execution_manifest_digest,
      "plan_version" => plan.version,
      "task_class" => plan.task_class,
      "validation_profile" => plan.validation_profile,
      "review_profile" => plan.review_profile
    }

    case Enum.find(expected, fn {key, value} -> Map.get(manifest, key) != value end) do
      nil -> :ok
      {key, _value} -> {:error, {:manifest_mismatch, key}}
    end
  end

  defp bool_string(true), do: "true"
  defp bool_string(false), do: "false"

  defp archive_compilation(root, %Plan{} = plan, %Compilation{} = compilation) do
    store = Config.coding_plan_artifact_store()

    cond do
      not is_atom(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not Code.ensure_loaded?(store) ->
        {:error, :coding_plan_artifact_store_unavailable}

      not function_exported?(store, :archive, 4) ->
        {:error, :coding_plan_artifact_store_unavailable}

      true ->
        with {:ok, verified_root} <- verify_task_logs_directory(root, Path.dirname(root)) do
          invoke_artifact_store(store, verified_root, plan, compilation)
        end
    end
  end

  defp invoke_artifact_store(store, root, plan, compilation) do
    case store.archive(
           root,
           Plan.to_map(plan),
           compilation.dot_source,
           compilation.manifest
         ) do
      {:ok, descriptor} ->
        validate_artifact_descriptor(descriptor, root, plan, compilation)

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_coding_plan_artifact_store_reply}
    end
  rescue
    error -> {:error, {:coding_plan_artifact_store_error, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:coding_plan_artifact_store_exit, reason}}
    kind, reason -> {:error, {:coding_plan_artifact_store_throw, {kind, reason}}}
  end

  defp validate_artifact_descriptor(descriptor, root, plan, compilation) do
    with :ok <- validate_json_object(descriptor, :artifact_descriptor),
         :ok <- validate_descriptor_keys(descriptor),
         :ok <- validate_descriptor_values(descriptor),
         :ok <- validate_descriptor_identity(descriptor, compilation),
         {:ok, canonical_root} <- canonical_artifact_root(root),
         :ok <- validate_descriptor_paths(descriptor, canonical_root),
         :ok <- validate_archived_contents(descriptor, plan, compilation) do
      {:ok, descriptor}
    else
      {:error, reason} -> {:error, {:invalid_coding_plan_artifact_store_reply, reason}}
    end
  end

  defp validate_descriptor_keys(descriptor) do
    keys = Map.keys(descriptor) |> MapSet.new()

    if MapSet.equal?(keys, @artifact_descriptor_keys),
      do: :ok,
      else: {:error, :unexpected_descriptor_keys}
  end

  defp validate_descriptor_values(descriptor) do
    Enum.reduce_while(@artifact_descriptor_keys, :ok, fn key, :ok ->
      case validate_nonblank_binary(Map.get(descriptor, key), key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_descriptor_identity(descriptor, compilation) do
    cond do
      descriptor["graph_hash"] != compilation.graph_hash ->
        {:error, :descriptor_graph_hash_mismatch}

      descriptor["compiler_version"] != compilation.compiler_version ->
        {:error, :descriptor_compiler_version_mismatch}

      true ->
        :ok
    end
  end

  defp canonical_artifact_root(root) do
    expanded_root = Path.expand(root)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(expanded_root),
         {:ok, canonical_root} <- SafePath.resolve_real(expanded_root),
         true <- canonical_root == expanded_root,
         true <- File.dir?(canonical_root) do
      {:ok, canonical_root}
    else
      _ -> {:error, :artifact_root_missing}
    end
  end

  defp validate_descriptor_paths(descriptor, canonical_root) do
    Enum.reduce_while(@artifact_path_keys, :ok, fn key, :ok ->
      path = descriptor[key]

      result =
        with true <- SafePath.absolute?(path),
             {:ok, canonical_path} <- SafePath.resolve_real(path),
             true <- File.regular?(canonical_path),
             true <- contained_in?(canonical_root, canonical_path) do
          :ok
        else
          _ -> {:error, {:invalid_artifact_path, key}}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_archived_contents(descriptor, plan, compilation) do
    with {:ok, dot_source} <- File.read(descriptor["coding_pipeline_path"]),
         true <- dot_source == compilation.dot_source,
         {:ok, plan_json} <- File.read(descriptor["coding_plan_path"]),
         {:ok, archived_plan} <- Jason.decode(plan_json),
         true <- archived_plan == Plan.to_map(plan),
         {:ok, manifest_json} <- File.read(descriptor["compile_manifest_path"]),
         {:ok, archived_manifest} <- Jason.decode(manifest_json),
         true <- archived_manifest == compilation.manifest do
      :ok
    else
      false -> {:error, :artifact_content_mismatch}
      {:error, _reason} -> {:error, :artifact_content_unreadable}
    end
  end

  defp verify_execution_boundary(graph_path, %Plan{} = plan, %Compilation{} = compilation) do
    with {:ok, dot_source} <- File.read(graph_path),
         true <- dot_source == compilation.dot_source,
         true <- sha256(dot_source) == compilation.graph_hash,
         {:ok, graph} <- parse_execution_graph(dot_source),
         {:ok, compiled_graph} <- IRCompiler.compile(graph),
         {:ok, profile} <- Profiles.fetch_executable(plan.validation_profile),
         :ok <- Profiles.validate_requirements(profile, compiled_graph),
         :ok <-
           SemanticPreflight.validate(compiled_graph, profile["semantic_policy"],
             review_profile: plan.review_profile,
             worker_use_pool: plan.worker["use_pool"],
             worker_resume_session_id: plan.worker["resume_session_id"],
             rework_max_cycles: plan.rework["max_cycles"]
           ),
         {:ok, live_catalog} <- ActionCatalog.snapshot(),
         {:ok, pinned_action_bindings} <-
           ExecutionManifest.verify(
             compilation.execution_manifest,
             compilation.execution_manifest_digest,
             compiled_graph,
             live_catalog,
             compilation.graph_hash
           ),
         {:ok, pinned_handler_bindings} <-
           ExecutionManifest.handler_binding_index(compilation.execution_manifest) do
      {:ok, {pinned_action_bindings, pinned_handler_bindings}}
    else
      false -> {:error, {:coding_execution_preflight_failed, :archived_graph_mismatch}}
      {:error, reason} -> {:error, {:coding_execution_preflight_failed, reason}}
      _other -> {:error, {:coding_execution_preflight_failed, :invalid_preflight_result}}
    end
  rescue
    exception ->
      {:error, {:coding_execution_preflight_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:coding_execution_preflight_failed, {kind, reason}}}
  end

  defp parse_execution_graph(dot_source) do
    case Parser.parse(dot_source) do
      {:ok, graph} -> {:ok, graph}
      {:ok, _graph, errors} -> {:error, {:execution_graph_parse_failed, errors}}
      {:error, reason} -> {:error, {:execution_graph_parse_failed, reason}}
    end
  end

  defp validate_json_object(value, error_tag) when is_map(value) and not is_struct(value) do
    case ensure_string_keyed_json_map(value, error_tag) do
      :ok -> :ok
      {:error, reason} -> {:error, {error_tag, reason}}
    end
  end

  defp validate_json_object(_value, error_tag), do: {:error, {error_tag, :expected_map}}

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp security_facade do
    security = Config.security_module()

    if is_atom(security) and Code.ensure_loaded?(security) and
         function_exported?(security, :load_signing_key, 1) and
         function_exported?(security, :build_signing_authority_acquisition_proof, 3) and
         function_exported?(security, :open_signing_authority, 1) and
         function_exported?(security, :sign_with_authority, 2) and
         function_exported?(security, :close_signing_authority, 1) do
      {:ok, security}
    else
      {:error, :security_unavailable}
    end
  end

  # The decrypted key exists only while the owner-bound possession proof is
  # constructed. The broker retains the reload-stable authority, never this
  # key or a closure over it.
  defp acquire_signing_authority(security, agent_id) do
    with {:ok, private_key} <- security.load_signing_key(agent_id),
         true <- is_binary(private_key) and private_key != "",
         {:ok, proof} <-
           security.build_signing_authority_acquisition_proof(
             agent_id,
             private_key,
             purpose: :coding_task_executor,
             owner: self()
           ),
         {:ok, opened_authority} <- security.open_signing_authority(proof) do
      case SigningAuthority.canonicalize(opened_authority) do
        {:ok, authority} ->
          {:ok, authority}

        {:error, reason} ->
          # A broker may have opened a live token before a malformed return
          # crossed this boundary. Always attempt public-facade cleanup before
          # reporting the canonicalization failure.
          _ = close_signing_authority(security, opened_authority)
          {:error, {:signing_authority_acquisition_failed, reason}}
      end
    else
      false -> {:error, :invalid_signing_key}
      {:error, :no_signing_key} -> {:error, :no_signing_key}
      {:error, reason} -> {:error, {:signing_authority_acquisition_failed, reason}}
      other -> {:error, {:signing_authority_acquisition_failed, other}}
    end
  rescue
    exception ->
      {:error, {:signing_authority_acquisition_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:signing_authority_acquisition_failed, {kind, reason}}}
  end

  defp close_signing_authority(security, authority) do
    case security.close_signing_authority(authority) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_close_result, other}}
    end
  rescue
    exception -> {:error, {:authority_close_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:authority_close_failed, {kind, reason}}}
  end

  # Validate the authority before dispatching to the runner. The public
  # Orchestrator facade repeats this check as part of its coarse gate; this
  # preflight ensures a signing failure cannot even enter an injected runner.
  defp validate_authority_signing(security, %SigningAuthority{} = authority) do
    case security.sign_with_authority(authority, "arbor://orchestrator/execute") do
      {:ok, _signed_request} -> :ok
      {:error, reason} -> {:error, {:signing_authority_sign_failed, reason}}
      other -> {:error, {:signing_authority_sign_failed, other}}
    end
  rescue
    exception -> {:error, {:signing_authority_sign_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:signing_authority_sign_failed, {kind, reason}}}
  end

  defp build_engine_opts(
         agent_id,
         %Plan{} = plan,
         %Compilation{} = compilation,
         exec_ctx,
         %SigningAuthority{} = authority,
         logs_root,
         pinned_action_bindings,
         pinned_handler_bindings
       ) do
    task_id = exec_ctx.task_id
    caller_id = Map.get(exec_ctx, :caller_id)
    timeout = effective_timeout(plan, Map.get(exec_ctx, :timeout))
    approval_timeout_ms = Config.coding_approval_timeout_ms(timeout)

    initial_values =
      compilation.initial_values
      |> Map.put("session.agent_id", agent_id)
      |> Map.put("session.task_id", task_id)
      |> maybe_put_session_caller_id(caller_id)
      |> maybe_put_session_metadata(Map.get(exec_ctx, :metadata))

    opts =
      [
        authorization: true,
        agent_id: agent_id,
        task_id: task_id,
        run_id: task_id,
        pipeline_id: task_id,
        signing_authority: authority,
        initial_values: initial_values,
        logs_root: logs_root,
        graph_hash: compilation.graph_hash,
        execution_manifest: compilation.execution_manifest,
        execution_manifest_digest: compilation.execution_manifest_digest,
        pinned_action_bindings: pinned_action_bindings,
        pinned_handler_bindings: pinned_handler_bindings,
        workdir: plan.repo_root,
        timeout: timeout,
        approval_timeout_ms: approval_timeout_ms,
        spawning_pid: self(),
        resumable: true,
        cache: false
      ]

    # The authenticated caller remains distinct from the execution principal.
    # Engine middleware intersects both principals' scoped capabilities at
    # every node and action invocation.
    final_opts =
      case caller_id do
        cid when is_binary(cid) and cid != "" ->
          Keyword.put(opts, :caller_id, cid)

        _ ->
          opts
      end

    {:ok, final_opts}
  end

  defp effective_timeout(%Plan{} = plan, context_timeout) do
    plan_timeout = plan.budgets["wall_clock_ms"]

    if is_integer(context_timeout) and context_timeout > 0,
      do: min(plan_timeout, context_timeout),
      else: plan_timeout
  end

  defp maybe_put_session_caller_id(values, caller_id)
       when is_binary(caller_id) and caller_id != "" do
    Map.put(values, "session.caller_id", caller_id)
  end

  defp maybe_put_session_caller_id(values, _), do: values

  # Metadata is data only — never promoted to engine control options.
  defp maybe_put_session_metadata(values, metadata) when is_map(metadata) do
    Map.put(values, "session.metadata", metadata)
  end

  defp maybe_put_session_metadata(values, _), do: values

  defp prepare_task_logs_root(task_id) do
    digest =
      :crypto.hash(:sha256, task_id)
      |> Base.encode16(case: :lower)

    with {:ok, base} <- canonical_logs_base(),
         {:ok, root} <- SafePath.safe_join(base, "task-" <> digest),
         :ok <- ensure_task_logs_directory(root),
         {:ok, canonical_root} <- verify_task_logs_directory(root, base) do
      {:ok, canonical_root}
    end
  end

  defp canonical_logs_base do
    configured = Config.coding_pipeline_logs_root()

    with :ok <- validate_logs_base_path(configured),
         :ok <- create_logs_base(configured),
         {:ok, canonical} <- SafePath.resolve_real(configured),
         true <- File.dir?(canonical) do
      {:ok, canonical}
    else
      _ -> {:error, :invalid_coding_pipeline_logs_root}
    end
  end

  defp validate_logs_base_path(path) when is_binary(path) do
    with :ok <- SafePath.validate(path),
         true <- SafePath.absolute?(path) do
      :ok
    else
      _ -> {:error, :invalid_path}
    end
  end

  defp validate_logs_base_path(_path), do: {:error, :invalid_path}

  defp create_logs_base(path) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp ensure_task_logs_directory(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, :unsafe_coding_task_logs_root}

      {:error, :enoent} ->
        create_task_logs_directory(root)

      {:error, _reason} ->
        {:error, :unsafe_coding_task_logs_root}
    end
  end

  defp create_task_logs_directory(root) do
    case File.mkdir(root) do
      :ok ->
        case File.chmod(root, 0o700) do
          :ok ->
            :ok

          {:error, _reason} ->
            File.rmdir(root)
            {:error, :unsafe_coding_task_logs_root}
        end

      {:error, :eexist} ->
        ensure_task_logs_directory(root)

      {:error, _reason} ->
        {:error, :unsafe_coding_task_logs_root}
    end
  end

  defp verify_task_logs_directory(root, base) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, canonical_root} <- SafePath.resolve_real(root),
         true <- canonical_root == root,
         true <- contained_in?(base, canonical_root) do
      {:ok, canonical_root}
    else
      _ -> {:error, :unsafe_coding_task_logs_root}
    end
  end

  defp reconcile_action_uri_prefixes do
    with :ok <- Arbor.Actions.register_action_uri_prefixes(),
         prefixes when is_list(prefixes) and prefixes != [] <-
           Arbor.Actions.action_namespace_uri_prefixes(),
         true <- Enum.all?(prefixes, &Arbor.Security.uri_registered?/1) do
      :ok
    else
      _ -> {:error, :action_uri_prefix_reconciliation_failed}
    end
  rescue
    _ -> {:error, :action_uri_prefix_reconciliation_failed}
  catch
    _, _ -> {:error, :action_uri_prefix_reconciliation_failed}
  end

  defp invoke_runner(graph_path, opts) do
    runner = Config.coding_pipeline_runner()

    cond do
      not is_atom(runner) ->
        {:error, :coding_pipeline_runner_unavailable}

      not Code.ensure_loaded?(runner) ->
        {:error, :coding_pipeline_runner_unavailable}

      function_exported?(runner, :run_file_as, 4) ->
        principal = Keyword.fetch!(opts, :agent_id)
        authority = Keyword.fetch!(opts, :signing_authority)
        # run_file_as/4 performs the public facade's mixed-credential check and
        # installs the authority into the actual Engine opts. It must not see
        # the process-local credential in its caller-supplied opts.
        runner_opts = Keyword.delete(opts, :signing_authority)

        invoke_with_timeout(
          fn -> runner.run_file_as(graph_path, principal, authority, runner_opts) end,
          runner_opts
        )

      true ->
        {:error, :coding_pipeline_runner_unavailable}
    end
  rescue
    e -> {:error, {:pipeline_run_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_run_exit, reason}}
  end

  defp invoke_with_timeout(fun, opts) when is_function(fun, 0) do
    case Keyword.fetch(opts, :timeout) do
      :error ->
        fun.()

      {:ok, timeout} ->
        # The link is intentional: TaskStore cancellation kills this owner,
        # which must also terminate the Engine process and its owned resources.
        task = Task.async(fn -> capture_runner_result(fun) end)

        case Task.yield(task, timeout) do
          {:ok, {:ok, result}} ->
            result

          {:ok, {:error, reason}} ->
            {:error, reason}

          {:exit, reason} ->
            {:error, {:pipeline_run_exit, reason}}

          nil ->
            _ = Task.shutdown(task, :brutal_kill)
            {:error, {:pipeline_timeout, timeout}}
        end
    end
  end

  defp capture_runner_result(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, {:pipeline_run_error, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:pipeline_run_exit, reason}}
    kind, reason -> {:error, {:pipeline_run_throw, {kind, reason}}}
  end

  # ===========================================================================
  # Result adapter
  # ===========================================================================

  defp adapt_result(%{context: context} = engine_result, started_at, acp_agent)
       when is_map(context) do
    adapt_engine_result(context, engine_result, started_at, acp_agent)
  end

  defp adapt_result(%{"context" => context} = engine_result, started_at, acp_agent)
       when is_map(context) do
    adapt_engine_result(context, engine_result, started_at, acp_agent)
  end

  defp adapt_result({:ok, result}, started_at, acp_agent),
    do: adapt_result(result, started_at, acp_agent)

  defp adapt_result({:error, _} = error, _started_at, _acp_agent), do: error
  defp adapt_result(_other, _started_at, _acp_agent), do: {:error, :invalid_engine_result}

  defp adapt_engine_result(context, engine_result, started_at, acp_agent) do
    with {:ok, payload} <- adapt_context(context, acp_agent) do
      wall_clock_ms = max(System.monotonic_time(:millisecond) - started_at, 0)

      {:ok,
       payload
       |> Map.put("acp_agent", acp_agent)
       |> Map.put("worker_provider", acp_agent)
       |> Map.put("metrics", build_pipeline_metrics(engine_result, context, wall_clock_ms))}
    end
  end

  defp adapt_context(context, worker_provider) when is_map(context) do
    clean = json_clean_map(context)
    status = context_get(clean, "status")
    legacy = context_get(clean, "legacy_status")

    cond do
      status in [nil, ""] ->
        {:error, :missing_terminal_status}

      status == "pipeline_error" ->
        {:error, {:pipeline_error, pipeline_error_detail(clean, worker_provider)}}

      not MapSet.member?(@success_statuses, status) ->
        {:error, {:unknown_terminal_status, status}}

      true ->
        {:ok, build_coding_payload(clean, status, legacy)}
    end
  end

  defp build_pipeline_metrics(engine_result, context, wall_clock_ms) do
    clean_context = json_clean_map(context)
    completed = completed_node_ids(engine_result)
    exposed_completed = Enum.take(completed, @max_metric_completed_nodes)
    {node_durations, durations_truncated?} = metric_node_durations(engine_result)

    close_usage = metric_context_value(clean_context, "close", "usage")
    last_message_usage = metric_context_value(clean_context, "worker_msg", "usage")

    usage =
      clean_metric_usage(close_usage) ||
        clean_metric_usage(last_message_usage)

    context_tokens =
      metric_non_negative_integer(metric_context_value(clean_context, "close", "context_tokens")) ||
        metric_non_negative_integer(
          metric_context_value(clean_context, "worker_msg", "context_tokens")
        ) ||
        usage_input_tokens(clean_metric_usage(last_message_usage))

    %{
      "execution_path" => "pipeline",
      "wall_clock_ms" => wall_clock_ms,
      "node_durations_ms" => node_durations,
      "completed_nodes" => exposed_completed,
      "completed_node_count" => length(completed),
      "validation_attempts" => Enum.count(completed, &(&1 == "validate")),
      "review_attempts" => Enum.count(completed, &(&1 == "review_change")),
      "protocol_retry_count" => metric_counter(clean_context, "protocol_retry_count"),
      "validation_rework_count" => metric_counter(clean_context, "validation_rework_count"),
      "review_rework_count" => metric_counter(clean_context, "review_rework_count"),
      "operator_rework_count" => metric_counter(clean_context, "operator_rework_count"),
      "total_rework_count" => metric_counter(clean_context, "total_rework_count")
    }
    |> maybe_put_metric(
      "completed_nodes_truncated",
      length(completed) > @max_metric_completed_nodes
    )
    |> maybe_put_metric("node_durations_truncated", durations_truncated?)
    |> maybe_put_metric("usage", usage)
    |> maybe_put_metric("context_tokens", context_tokens)
    |> maybe_put_metric(
      "worker_close_status",
      clean_metric_status(metric_context_value(clean_context, "close", "status"))
    )
    |> maybe_put_metric(
      "workspace_release_status",
      clean_metric_status(metric_context_value(clean_context, "release", "status"))
    )
    |> maybe_put_metric(
      "workspace_expires_at",
      workspace_release_expires_at(clean_context)
    )
  end

  defp completed_node_ids(engine_result) do
    case engine_result_field(engine_result, :completed_nodes, "completed_nodes") do
      nodes when is_list(nodes) ->
        nodes
        |> Enum.reduce([], fn node_id, acc ->
          case clean_metric_node_id(node_id) do
            nil -> acc
            clean -> [clean | acc]
          end
        end)
        |> Enum.reverse()

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp metric_node_durations(engine_result) do
    entries =
      case engine_result_field(engine_result, :node_durations, "node_durations") do
        %_{} ->
          []

        durations when is_map(durations) ->
          durations
          |> Enum.reduce([], fn {node_id, duration}, acc ->
            with {clean_id, rank} <- clean_metric_node_key(node_id),
                 true <- is_integer(duration) and duration >= 0 do
              [{clean_id, rank, duration} | acc]
            else
              _ -> acc
            end
          end)
          |> Enum.sort_by(fn {node_id, rank, duration} -> {node_id, rank, duration} end)
          |> Enum.uniq_by(fn {node_id, _rank, _duration} -> node_id end)

        _ ->
          []
      end

    selected = Enum.take(entries, @max_metric_node_durations)

    durations =
      Map.new(selected, fn {node_id, _rank, duration} ->
        {node_id, duration}
      end)

    {durations, length(entries) > @max_metric_node_durations}
  rescue
    _ -> {%{}, false}
  end

  defp engine_result_field(result, atom_key, string_key) when is_map(result) do
    case Map.fetch(result, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(result, string_key)
    end
  end

  defp engine_result_field(_result, _atom_key, _string_key), do: nil

  defp clean_metric_node_id(node_id) do
    case clean_metric_node_key(node_id) do
      {clean, _rank} -> clean
      nil -> nil
    end
  end

  defp clean_metric_node_key(node_id) when is_binary(node_id) do
    if String.valid?(node_id) and node_id != "" and
         byte_size(node_id) <= @max_metric_node_id_bytes,
       do: {node_id, 0},
       else: nil
  end

  defp clean_metric_node_key(node_id) when is_atom(node_id) do
    case clean_metric_node_key(Atom.to_string(node_id)) do
      {clean, _rank} -> {clean, 1}
      nil -> nil
    end
  end

  defp clean_metric_node_key(_node_id), do: nil

  defp metric_context_value(context, prefix, key) do
    context_get(context, "#{prefix}.#{key}") ||
      nested_get(context_get(context, prefix), key)
  end

  defp metric_counter(context, key) do
    metric_non_negative_integer(context_get(context, key)) || 0
  end

  defp metric_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp metric_non_negative_integer(value) when is_binary(value) and byte_size(value) <= 32 do
    if String.valid?(value) do
      case Integer.parse(value) do
        {parsed, ""} when parsed >= 0 -> parsed
        _ -> nil
      end
    end
  end

  defp metric_non_negative_integer(_value), do: nil

  defp usage_input_tokens(usage) when is_map(usage) do
    Enum.find_value(~w(input_tokens inputTokens prompt_tokens promptTokens), fn key ->
      metric_non_negative_integer(Map.get(usage, key))
    end)
  end

  defp usage_input_tokens(_usage), do: nil

  defp clean_metric_status(nil), do: nil

  defp clean_metric_status(value) when is_binary(value) do
    if String.valid?(value) and value != "" and byte_size(value) <= @max_metric_node_id_bytes,
      do: value,
      else: nil
  end

  defp clean_metric_status(value) when is_atom(value),
    do: clean_metric_status(Atom.to_string(value))

  defp clean_metric_status(_value), do: nil

  defp clean_metric_usage(%_{}), do: nil

  defp clean_metric_usage(usage) when is_map(usage) do
    with {:ok, clean} <- clean_metric_map(usage, 0),
         true <- map_size(clean) > 0,
         {:ok, encoded} <- Jason.encode(clean),
         true <- byte_size(encoded) <= @max_metric_usage_encoded_bytes do
      clean
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp clean_metric_usage(_usage), do: nil

  defp clean_metric_map(map, depth) when depth <= @max_metric_usage_depth do
    entries =
      map
      |> Enum.reduce([], fn {key, value}, acc ->
        with {clean_key, rank} <- clean_metric_key(key),
             {:ok, clean_value} <- clean_metric_value(value, depth + 1) do
          [{clean_key, rank, clean_value} | acc]
        else
          _ -> acc
        end
      end)
      |> Enum.sort_by(fn {key, rank, _value} -> {key, rank} end)
      |> Enum.uniq_by(fn {key, _rank, _value} -> key end)
      |> Enum.take(@max_metric_usage_entries)

    {:ok, Map.new(entries, fn {key, _rank, value} -> {key, value} end)}
  end

  defp clean_metric_map(_map, _depth), do: :drop

  defp clean_metric_key(key) when is_binary(key) do
    if String.valid?(key) and byte_size(key) <= @max_metric_usage_key_bytes,
      do: {key, 0},
      else: nil
  end

  defp clean_metric_key(key) when is_atom(key) do
    case clean_metric_key(Atom.to_string(key)) do
      {clean, _rank} -> {clean, 1}
      nil -> nil
    end
  end

  defp clean_metric_key(_key), do: nil

  defp clean_metric_value(_value, depth) when depth > @max_metric_usage_depth, do: :drop

  defp clean_metric_value(value, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp clean_metric_value(value, _depth) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= @max_metric_usage_string_bytes,
      do: {:ok, value},
      else: :drop
  end

  defp clean_metric_value(value, depth) when is_atom(value) do
    clean_metric_value(Atom.to_string(value), depth)
  end

  defp clean_metric_value(%_{}, _depth), do: :drop
  defp clean_metric_value(map, depth) when is_map(map), do: clean_metric_map(map, depth)

  defp clean_metric_value(list, depth) when is_list(list) do
    clean =
      list
      |> Enum.take(@max_metric_usage_list_items)
      |> Enum.reduce([], fn value, acc ->
        case clean_metric_value(value, depth + 1) do
          {:ok, clean_value} -> [clean_value | acc]
          :drop -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, clean}
  end

  defp clean_metric_value(_value, _depth), do: :drop

  defp maybe_put_metric(map, _key, nil), do: map
  defp maybe_put_metric(map, _key, false), do: map
  defp maybe_put_metric(map, key, value), do: Map.put(map, key, value)

  defp build_coding_payload(context, status, legacy) do
    {public_status, canonical_status} =
      case {status, legacy} do
        {"rework_exhausted", legacy_status}
        when is_binary(legacy_status) and legacy_status != "" ->
          {legacy_status, "rework_exhausted"}

        {status, _} ->
          {status, status}
      end

    commit = context_get(context, "commit") || context_get(context, "commit_hash")
    commit_hash = context_get(context, "commit_hash") || commit
    review = extract_review(context)

    %{
      "status" => public_status,
      "canonical_status" => canonical_status,
      "branch" => context_get(context, "branch"),
      "commit" => commit,
      "commit_hash" => commit_hash,
      "repo_path" => context_get(context, "repo_path"),
      "worktree_path" => context_get(context, "worktree_path"),
      "diff" => context_get(context, "diff"),
      "files" => context_get(context, "files"),
      "validation" => extract_validation(context),
      "review" => review,
      "review_recommendation" =>
        context_get(context, "review_recommendation") ||
          nested_get(review, "recommendation"),
      "tier_decision" =>
        context_get(context, "tier_decision") || nested_get(review, "tier_decision"),
      "human_required" =>
        context_get(context, "human_required") || nested_get(review, "human_required"),
      "security_veto" =>
        context_get(context, "security_veto") || nested_get(review, "security_veto"),
      "blast_radius" =>
        context_get(context, "blast_radius") || nested_get(review, "blast_radius"),
      "pr_url" => extract_pr_url(context),
      "workspace_id" => context_get(context, "workspace_id"),
      "worker_session_id" => context_get(context, "worker_session_id"),
      "worker_provider_session_id" => context_get(context, "worker_provider_session_id"),
      "response_text" => extract_response_text(context),
      "error" => context_get(context, "error") || context_get(context, "review_error"),
      # Operator approval fields are stable, bounded, JSON-clean scalars only —
      # never the raw interaction metadata map.
      "approval_request_id" => context_get(context, "approval_request_id"),
      "approval_note" => context_get(context, "approval_note")
    }
    |> Map.merge(workspace_release_projection(context))
    |> reject_nil_values()
  end

  defp pipeline_error_detail(context, worker_provider) do
    %{
      "status" => "pipeline_error",
      "error" => context_get(context, "error"),
      "workspace_id" => context_get(context, "workspace_id"),
      "worker_provider" => worker_provider,
      "worker_session_id" => context_get(context, "worker_session_id"),
      "worker_provider_session_id" => context_get(context, "worker_provider_session_id")
    }
    |> Map.merge(workspace_release_projection(context))
    |> reject_nil_values()
  end

  defp attach_workspace_release_artifact(artifacts, result) do
    case Map.take(result, ["workspace_release_status", "workspace_expires_at"]) do
      release when map_size(release) == 0 ->
        artifacts

      release ->
        Map.put(artifacts, "workspace_release", release)
    end
  end

  defp workspace_release_projection(context) do
    status = clean_metric_status(context_get(context, "release.status"))

    %{}
    |> maybe_put_metric("workspace_release_status", status)
    |> maybe_put_metric("workspace_expires_at", workspace_release_expires_at(context, status))
  end

  defp workspace_release_expires_at(context) do
    workspace_release_expires_at(
      context,
      clean_metric_status(metric_context_value(context, "release", "status"))
    )
  end

  defp workspace_release_expires_at(context, "retained") do
    case metric_context_value(context, "release", "expires_at") do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, expires_at, _offset} -> DateTime.to_iso8601(expires_at)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp workspace_release_expires_at(_context, _status), do: nil

  defp extract_review(context) do
    cond do
      is_map(context_get(context, "review")) ->
        case json_clean_map(context_get(context, "review")) do
          cleaned when map_size(cleaned) > 0 -> cleaned
          _ -> nil
        end

      true ->
        review_keys =
          context
          |> Enum.filter(fn {k, _} ->
            is_binary(k) and String.starts_with?(k, "review.")
          end)

        if review_keys == [] do
          nil
        else
          review_keys
          |> Enum.reduce(%{}, fn {k, v}, acc ->
            suffix = String.replace_prefix(k, "review.", "")
            Map.put(acc, suffix, v)
          end)
          |> json_clean_map()
          |> case do
            cleaned when map_size(cleaned) > 0 -> cleaned
            _ -> nil
          end
        end
    end
  end

  defp extract_validation(context) do
    value =
      context_get(context, "validation") ||
        context_get(context, "validation.result") ||
        extract_prefixed_map(context, "validation.")

    case json_clean_value(value) do
      :drop -> nil
      nil -> nil
      validation when is_map(validation) -> [validation]
      validations when is_list(validations) -> validations
      _ -> nil
    end
  end

  defp extract_response_text(context) do
    context_get(context, "response_text") ||
      context_get(context, "worker_msg.text") ||
      nested_get(context_get(context, "worker_msg"), "text")
  end

  defp extract_prefixed_map(context, prefix) do
    values =
      Enum.reduce(context, %{}, fn
        {key, value}, acc when is_binary(key) ->
          if String.starts_with?(key, prefix) do
            Map.put(acc, String.replace_prefix(key, prefix, ""), value)
          else
            acc
          end

        _, acc ->
          acc
      end)

    if map_size(values) == 0, do: nil, else: values
  end

  defp extract_pr_url(context) do
    context_get(context, "pr_url") ||
      context_get(context, "pr.url") ||
      nested_get(context_get(context, "pr"), "url")
  end

  defp nested_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  defp nested_get(_map, _key), do: nil

  # ===========================================================================
  # Progress / cancel helpers
  # ===========================================================================

  defp progress_from_entry(entry) do
    current_step =
      cond do
        is_binary(Map.get(entry, :current_node)) and Map.get(entry, :current_node) != "" ->
          Map.get(entry, :current_node)

        is_binary(Map.get(entry, "current_node")) and Map.get(entry, "current_node") != "" ->
          Map.get(entry, "current_node")

        is_atom(Map.get(entry, :status)) ->
          Atom.to_string(Map.get(entry, :status))

        is_binary(Map.get(entry, :status)) ->
          Map.get(entry, :status)

        is_binary(Map.get(entry, "status")) ->
          Map.get(entry, "status")

        true ->
          nil
      end

    waiting_on =
      cond do
        is_binary(Map.get(entry, :waiting_on)) -> Map.get(entry, :waiting_on)
        is_binary(Map.get(entry, "waiting_on")) -> Map.get(entry, "waiting_on")
        Map.get(entry, :status) == :suspended -> "suspended"
        Map.get(entry, "status") == "suspended" -> "suspended"
        true -> nil
      end

    %{"current_step" => current_step, "waiting_on" => waiting_on}
  end

  # ===========================================================================
  # JSON cleanliness helpers (result adaptation only)
  # ===========================================================================

  defp context_get(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key)
  end

  # Clean engine context maps for TaskStore. Non-JSON leaves cause the entire
  # affected value to drop (never the atom/string "drop" inside lists/maps).
  defp json_clean_map(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      key =
        cond do
          is_binary(k) -> k
          is_atom(k) -> Atom.to_string(k)
          true -> nil
        end

      cleaned = json_clean_value(v)

      if is_binary(key) and cleaned != :drop do
        Map.put(acc, key, cleaned)
      else
        acc
      end
    end)
  end

  defp json_clean_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v

  defp json_clean_value(v) when is_atom(v), do: Atom.to_string(v)

  defp json_clean_value(list) when is_list(list) do
    # Non-empty keyword lists are atom-keyed — not JSON. Drop the field.
    if Keyword.keyword?(list) and list != [] do
      :drop
    else
      cleaned = Enum.map(list, &json_clean_value/1)

      # Any nested rich value (pid/fun/ref/struct) drops the entire list so
      # :drop never leaks as the atom/string "drop" into the payload.
      if Enum.any?(cleaned, &(&1 == :drop)) do
        :drop
      else
        cleaned
      end
    end
  end

  defp json_clean_value(%_{} = struct) do
    # Never leak structs (RunState, Outcome, etc.) — drop the field.
    _ = struct
    :drop
  end

  defp json_clean_value(map) when is_map(map), do: json_clean_map(map)

  defp json_clean_value(v)
       when is_pid(v) or is_function(v) or is_reference(v) or is_port(v) or is_tuple(v),
       do: :drop

  defp json_clean_value(_), do: :drop

  defp reject_nil_values(map) when is_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end
end
