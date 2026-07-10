defmodule Arbor.Orchestrator.CodingTaskExecutor do
  @moduledoc """
  `Arbor.Contracts.Agent.TaskExecutor` for the packaged coding-change pipeline.

  Accepts only canonical JSON task maps with `kind: "coding_change"`. Builds
  Engine opts from allowlisted task/context fields and trusted `run/3`
  identity — never from task-supplied authorization, signer, agent_id,
  task_id, engine module, action executor, graph path, or capabilities.

  Authorization is mandatory (`authorization: true`) with a signer derived from
  the target agent's signing key via the public Security facade. Missing
  identity/key/runtime graph fails closed (no system/unsigned fallback).

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
  persisted control's exact task id to the execution context, wraps the user
  correction as JSON data in the existing worker protocol, and resolves the
  active session only through the public managed ACP task/principal facade.
  """

  @behaviour Arbor.Contracts.Agent.TaskExecutor

  alias Arbor.Common.SafePath
  alias Arbor.Orchestrator.Config

  @kind "coding_change"

  @required_task_fields ~w(task repo_path acp_agent)
  @optional_task_fields ~w(base_ref branch_name worktree_base_dir open_pr submit_review)
  @allowed_task_keys MapSet.new(["kind" | @required_task_fields ++ @optional_task_fields])

  @boolean_task_fields MapSet.new(~w(open_pr submit_review))

  @forbidden_task_keys MapSet.new(~w(
    authorization
    signer
    agent_id
    task_id
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

  @success_statuses MapSet.new(~w(
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
  required fields `task`, `repo_path`, and `acp_agent`. `context` must include a
  nonblank `task_id`; optional `timeout` / `caller_id` / `metadata` are accepted
  as data only (not as control authority).
  """
  @impl true
  @spec run(String.t(), term(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(agent_id, task, context) when is_binary(agent_id) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, task_data} <- validate_task(task),
         {:ok, exec_ctx} <- validate_context(context),
         :ok <- require_security_available(),
         {:ok, task_data} <- normalize_workspace_scope(task_data),
         {:ok, graph_path} <- resolve_graph_path(),
         {:ok, {signer, private_key}} <- build_signer(agent_id),
         opts <- build_engine_opts(agent_id, task_data, exec_ctx, signer, private_key),
         {:ok, engine_result} <- invoke_runner(graph_path, opts) do
      adapt_result(engine_result)
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

    Respond with ONLY the existing worker protocol JSON and no prose or Markdown: {"status":"implemented"} or {"status":"declined"}, with an optional "summary" string.
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

  defp validate_task(task) when is_map(task) and not is_struct(task) do
    with :ok <- ensure_string_keyed_json_map(task, :non_json_task),
         :ok <- reject_forbidden_keys(task, @forbidden_task_keys, :forbidden_task_key),
         :ok <- reject_unknown_keys(task, @allowed_task_keys, :unknown_task_key),
         :ok <- require_kind(task),
         {:ok, required} <- require_nonblank_fields(task, @required_task_fields),
         {:ok, optional} <- extract_optional_fields(task) do
      {:ok, Map.merge(required, optional)}
    end
  end

  defp validate_task(_task), do: {:error, :invalid_task}

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

  defp require_kind(%{"kind" => kind}) when is_binary(kind) do
    case String.trim(kind) do
      @kind -> :ok
      other -> {:error, {:unsupported_task_kind, other}}
    end
  end

  defp require_kind(%{"kind" => _}), do: {:error, {:invalid_field_type, "kind"}}
  defp require_kind(_), do: {:error, :missing_task_kind}

  defp require_nonblank_fields(map, fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case require_nonblank(map, field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

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

  defp extract_optional_fields(map) do
    Enum.reduce_while(@optional_task_fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch(map, field) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          case normalize_optional_field(field, value) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, field, normalized)}}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp normalize_optional_field(field, value) do
    if MapSet.member?(@boolean_task_fields, field) do
      normalize_bool_string(field, value)
    else
      case value do
        v when is_binary(v) ->
          case String.trim(v) do
            "" -> {:error, {:blank_field, field}}
            trimmed -> {:ok, trimmed}
          end

        _ ->
          {:error, {:invalid_field_type, field}}
      end
    end
  end

  defp normalize_bool_string(field, value) do
    case value do
      true ->
        {:ok, "true"}

      false ->
        {:ok, "false"}

      "true" ->
        {:ok, "true"}

      "false" ->
        {:ok, "false"}

      "TRUE" ->
        {:ok, "true"}

      "FALSE" ->
        {:ok, "false"}

      "1" ->
        {:ok, "true"}

      "0" ->
        {:ok, "false"}

      other when is_binary(other) ->
        case String.trim(String.downcase(other)) do
          "true" -> {:ok, "true"}
          "false" -> {:ok, "false"}
          _ -> {:error, {:invalid_field_type, field}}
        end

      _ ->
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
  defp normalize_workspace_scope(task_data) do
    with {:ok, configured_repo_roots} <- Config.coding_repo_roots(),
         {:ok, configured_worktree_roots} <- Config.coding_worktree_roots(),
         {:ok, repo_roots} <- canonicalize_configured_roots(configured_repo_roots, :repo),
         {:ok, worktree_roots} <-
           canonicalize_configured_roots(configured_worktree_roots, :worktree),
         {:ok, requested_repo_path} <-
           resolve_scoped_path(Map.fetch!(task_data, "repo_path"), repo_roots, :repo_path),
         {:ok, repo_path} <- resolve_git_top_level(requested_repo_path, repo_roots),
         {:ok, worktree_base_dir} <- resolve_worktree_base(task_data, worktree_roots) do
      {:ok,
       task_data
       |> Map.put("repo_path", repo_path)
       |> Map.put("worktree_base_dir", worktree_base_dir)}
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

  defp resolve_worktree_base(task_data, worktree_roots) do
    case Map.fetch(task_data, "worktree_base_dir") do
      {:ok, path} -> resolve_scoped_path(path, worktree_roots, :worktree_base_dir)
      :error -> {:ok, List.first(worktree_roots)}
    end
  end

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

  defp resolve_graph_path do
    path = Config.coding_pipeline_path()

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, :coding_pipeline_unavailable}

      File.exists?(path) ->
        {:ok, path}

      true ->
        {:error, {:coding_pipeline_unavailable, path}}
    end
  end

  # Returns {:ok, {signer_fn, private_key}}. The private key is trusted Engine
  # material for checkpoint HMAC only — never placed in task data, initial
  # values, status, result, logs, or error payloads.
  defp build_signer(agent_id) do
    security = Config.security_module()

    unless is_atom(security) and Code.ensure_loaded?(security) and
             function_exported?(security, :load_signing_key, 1) and
             function_exported?(security, :make_signer, 2) do
      {:error, :security_unavailable}
    else
      case security.load_signing_key(agent_id) do
        {:ok, private_key} when is_binary(private_key) and private_key != "" ->
          signer = security.make_signer(agent_id, private_key)

          if is_function(signer, 1) do
            {:ok, {signer, private_key}}
          else
            {:error, :invalid_signer}
          end

        {:error, :no_signing_key} ->
          {:error, :no_signing_key}

        {:error, reason} ->
          {:error, {:signing_key_unavailable, reason}}

        other ->
          {:error, {:signing_key_unavailable, other}}
      end
    end
  end

  defp build_engine_opts(agent_id, task_data, exec_ctx, signer, private_key) do
    task_id = exec_ctx.task_id
    repo_path = Map.fetch!(task_data, "repo_path")
    caller_id = Map.get(exec_ctx, :caller_id)

    initial_values =
      task_data
      |> Map.drop(["kind"])
      |> Map.put("session.agent_id", agent_id)
      |> Map.put("session.task_id", task_id)
      # Graph defaults when optional flags omitted.
      |> Map.put_new("open_pr", "false")
      |> Map.put_new("submit_review", "true")
      |> maybe_put_session_caller_id(caller_id)
      |> maybe_put_session_metadata(Map.get(exec_ctx, :metadata))

    opts =
      [
        authorization: true,
        agent_id: agent_id,
        task_id: task_id,
        run_id: task_id,
        pipeline_id: task_id,
        signer: signer,
        authorizer: build_authorizer(agent_id, signer),
        # Trusted checkpoint HMAC material — Engine opt only, never context.
        identity_private_key: private_key,
        initial_values: initial_values,
        logs_root: task_logs_root(task_id),
        workdir: repo_path,
        spawning_pid: self(),
        resumable: true
      ]
      |> maybe_put_timeout(Map.get(exec_ctx, :timeout))

    # Authenticated caller is non-authority provenance only; does not replace
    # agent_id or signer.
    case caller_id do
      cid when is_binary(cid) and cid != "" ->
        Keyword.put(opts, :caller_id, cid)

      _ ->
        opts
    end
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

  defp maybe_put_timeout(opts, timeout) when is_integer(timeout) and timeout > 0 do
    Keyword.put(opts, :timeout, timeout)
  end

  defp maybe_put_timeout(opts, _), do: opts

  defp task_logs_root(task_id) do
    digest =
      :crypto.hash(:sha256, task_id)
      |> Base.encode16(case: :lower)

    Path.join(Config.coding_pipeline_logs_root(), "task-" <> digest)
  end

  defp build_authorizer(agent_id, signer) do
    security = Config.security_module()

    fn received_agent_id, _handler_type ->
      if received_agent_id != agent_id do
        {:error, :agent_id_mismatch}
      else
        authorize_orchestrator_execute(security, agent_id, signer)
      end
    end
  end

  # Coarse arbor://orchestrator/execute gate (Engine authorizer). CapabilityCheck
  # middleware still authorizes per-node resources separately. This production
  # path never honors the standalone security_required? escape hatch.
  defp authorize_orchestrator_execute(security, agent_id, signer) do
    if Config.security_available?() do
      auth_opts = signed_auth_opts(signer)

      case security.authorize(agent_id, "arbor://orchestrator/execute", :execute, auth_opts) do
        {:ok, :authorized} -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:authorization_failed, other}}
      end
    else
      {:error, :security_unavailable}
    end
  end

  defp signed_auth_opts(signer) when is_function(signer, 1) do
    case signer.("arbor://orchestrator/execute") do
      {:ok, signed} ->
        [
          signed_request: signed,
          verify_identity: true,
          expected_resource: "arbor://orchestrator/execute"
        ]

      _ ->
        []
    end
  end

  defp signed_auth_opts(_), do: []

  defp invoke_runner(graph_path, opts) do
    runner = Config.coding_pipeline_runner()

    cond do
      not is_atom(runner) ->
        {:error, :coding_pipeline_runner_unavailable}

      not Code.ensure_loaded?(runner) ->
        {:error, :coding_pipeline_runner_unavailable}

      function_exported?(runner, :run_file, 2) ->
        invoke_with_timeout(fn -> runner.run_file(graph_path, opts) end, opts)

      function_exported?(runner, :run, 2) ->
        # Test doubles may implement run/2 with path + opts.
        invoke_with_timeout(fn -> runner.run(graph_path, opts) end, opts)

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

  defp adapt_result(%{context: context} = result) when is_map(context) do
    _ = result
    adapt_context(context)
  end

  defp adapt_result(%{"context" => context}) when is_map(context) do
    adapt_context(context)
  end

  defp adapt_result({:ok, result}), do: adapt_result(result)
  defp adapt_result({:error, _} = error), do: error
  defp adapt_result(_other), do: {:error, :invalid_engine_result}

  defp adapt_context(context) when is_map(context) do
    clean = json_clean_map(context)
    status = context_get(clean, "status")
    legacy = context_get(clean, "legacy_status")

    cond do
      status in [nil, ""] ->
        {:error, :missing_terminal_status}

      status == "pipeline_error" ->
        {:error, {:pipeline_error, pipeline_error_detail(clean)}}

      not MapSet.member?(@success_statuses, status) ->
        {:error, {:unknown_terminal_status, status}}

      true ->
        {:ok, build_coding_payload(clean, status, legacy)}
    end
  end

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
      "response_text" => extract_response_text(context),
      "error" => context_get(context, "error") || context_get(context, "review_error")
    }
    |> reject_nil_values()
  end

  defp pipeline_error_detail(context) do
    %{
      "status" => "pipeline_error",
      "error" => context_get(context, "error"),
      "workspace_id" => context_get(context, "workspace_id"),
      "worker_session_id" => context_get(context, "worker_session_id")
    }
    |> reject_nil_values()
  end

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
