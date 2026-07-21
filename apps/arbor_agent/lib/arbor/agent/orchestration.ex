defmodule Arbor.Agent.Orchestration do
  @moduledoc """
  Shared agent orchestration interface.

  Slice 1 intentionally wraps the existing approval backends:

    * `Arbor.Consensus` authorization proposals
    * `Arbor.Comms` interaction requests, when available

  The module does not own approval state. It normalizes, filters, and answers
  requests held by those systems.
  """

  require Logger

  alias Arbor.Agent.Orchestration.{PendingApproval, TaskArtifacts}
  alias Arbor.Contracts.Security.CapabilityUri

  @approval_read_uri "arbor://approval/read"
  @approval_answer_uri "arbor://approval/answer"
  @dispatch_uri "arbor://agent/dispatch"
  @task_read_uri "arbor://agent/task/read"
  @task_cancel_uri "arbor://agent/task/cancel"
  @task_steer_uri "arbor://agent/task/steer"
  @task_adopt_uri "arbor://agent/task/adopt"
  @max_destination_ref_bytes 256
  @interaction_request_prefix "irq"
  @approval_answer_cap_ttl_seconds 86_400
  @task_cancel_cleanup_note "Pending approval closed because its orchestration task was cancelled"
  @task_terminal_cleanup_note "Pending approval closed because its orchestration task terminated"

  @type approval_decision :: :approve | :deny | :rework
  @type cleanup_reason :: :task_cancellation | :task_termination

  @doc """
  Dispatch an agent task asynchronously.

  Returns immediately with a stable `task_id`; the background task can be
  observed with `task_status/2` and `task_result/2`.
  """
  @spec dispatch(String.t(), String.t() | map(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch(agent_id, task, opts \\ []) do
    with {:ok, agent_id} <- normalize_agent_id(agent_id),
         {:ok, task} <- normalize_task(task),
         {:ok, task_id} <- normalize_or_generate_task_id(opts),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_dispatch(opts, caller_id, agent_id) do
      dispatch_with_task_capabilities(agent_id, task, task_id, caller_id, opts)
    end
  end

  @doc """
  Return structured status for an async orchestration task.

  If a running task has a pending approval for the same agent, the returned
  status is reported as `:waiting_approval` with `:waiting_on` set to the
  approval id.
  """
  @spec task_status(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def task_status(task_id, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, status} <- task_status_unchecked(task_id, opts),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_task_read(opts, caller_id, status) do
      {:ok, enrich_waiting_approval(status, opts)}
    end
  end

  @doc """
  Return the completed structured result for an async orchestration task.
  """
  @spec task_result(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def task_result(task_id, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, status} <- task_status_unchecked(task_id, opts),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_task_read(opts, caller_id, status) do
      case enrich_waiting_approval(status, opts) do
        %{state: :waiting_approval, waiting_on: approval_id} when is_binary(approval_id) ->
          {:error, {:waiting_approval, approval_id}}

        _status ->
          opts
          |> task_store_module()
          |> apply_if_exported(:result, [task_id, task_store_opts(opts)])
          |> normalize_task_result()
      end
    end
  end

  @doc """
  Cancel a running async orchestration task.
  """
  @spec cancel_task(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def cancel_task(task_id, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, status} <- task_status_unchecked(task_id, opts),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_task_cancel(opts, caller_id, status) do
      cancel_result =
        opts
        |> task_store_module()
        |> apply_if_exported(:cancel, [task_id, task_store_opts(opts)])
        |> normalize_task_cancel_result()

      case cancel_result do
        {:ok, _status} = success ->
          unless task_store_owns_cancel_cleanup?(opts) do
            cleanup_opts =
              opts
              |> normalize_keyword_opts()
              |> Keyword.put(:caller_id, caller_id)
              |> Keyword.put(:cleanup_reason, :task_cancellation)

            _ = cleanup_approvals_for_task(task_id, cleanup_opts)
          end

          success

        error ->
          error
      end
    end
  end

  @doc false
  @spec cleanup_approvals_for_task(String.t(), keyword() | map()) :: :ok
  def cleanup_approvals_for_task(task_id, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, caller_id} <- cleanup_caller_id(opts) do
      reason = cleanup_reason(opts)
      do_cleanup_task_approvals(task_id, caller_id, reason, opts)
    else
      {:error, reason} ->
        Logger.warning(
          "Approval cleanup skipped task_id=#{bounded_inspect(task_id)} " <>
            "reason=#{bounded_inspect(reason)}"
        )

        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "Approval cleanup failed task_id=#{bounded_inspect(task_id)} " <>
          "reason=#{Exception.message(exception)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.warning(
        "Approval cleanup failed task_id=#{bounded_inspect(task_id)} " <>
          "reason=#{bounded_inspect({kind, reason})}"
      )

      :ok
  end

  @doc """
  Persist and deliver a steering control to an async orchestration task.

  Authorization checks the exact task scope first, followed by the target agent
  and the global steering capability. The authenticated caller becomes the
  control sender; task execution receives no caller-controlled authority beyond
  that JSON-clean control record.
  """
  @spec steer_task(String.t(), String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def steer_task(task_id, message, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, status} <- task_status_unchecked(task_id, opts),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_task_steer(opts, caller_id, status) do
      steer_opts =
        opts
        |> task_store_opts()
        |> Keyword.put(:sender_id, caller_id)

      opts
      |> task_store_module()
      |> apply_if_exported(:steer, [task_id, message, steer_opts])
      |> normalize_task_steer_result()
    end
  end

  @doc """
  Adopt a successful terminal task change into a destination reference.

  Authorization checks the exact task scope first, followed by the target agent
  and global adoption capability. The destination reference is normalized before
  it crosses into TaskStore.
  """
  @spec adopt_task_change(String.t(), String.t(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def adopt_task_change(task_id, destination_ref, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, status} <- task_status_unchecked(task_id, opts),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_task_adopt(opts, caller_id, status),
         {:ok, destination_ref} <- normalize_destination_ref(destination_ref),
         store_result <-
           opts
           |> task_store_module()
           |> apply_if_exported(:adopt, [task_id, destination_ref, task_store_opts(opts)]),
         {:ok, result} <- normalize_task_adopt_result(store_result) do
      {:ok, result}
    end
  end

  @doc """
  List pending approvals from all configured approval backends.

  Options:

    * `:caller_id` - authenticated caller for the read capability check
    * `:agent_id` - filter by the gated agent
    * `:principal_id` - filter by gated principal or approver principal
    * `:resource_uri` - segment-aware resource URI prefix filter

  Test and trusted in-process callers may pass `authorize?: false`, but external
  surfaces must keep authorization enabled.
  """
  @spec list_pending_approvals(keyword() | map()) ::
          {:ok, [PendingApproval.t()]} | {:error, term()}
  def list_pending_approvals(opts \\ []) do
    with :ok <- authorize(opts, @approval_read_uri, :read) do
      {:ok, list_pending_approvals_unchecked(opts)}
    end
  end

  @doc """
  Answer a pending approval.

  `:rework` is represented as a rejection in the underlying backend with
  metadata preserving the requested rework outcome and optional note.
  """
  @spec answer_approval(String.t(), approval_decision() | String.t(), keyword() | map()) ::
          :ok | {:error, term()}
  def answer_approval(id, decision, opts \\ []) do
    with {:ok, id} <- normalize_id(id),
         {:ok, normalized_decision} <- normalize_decision(decision),
         {:ok, caller_id} <- caller_id(opts),
         {:ok, approval} <- get_pending_approval(id, opts),
         :ok <- authorize_answer(opts, caller_id, approval),
         :ok <- reject_blocked_approval(approval, normalized_decision),
         :ok <- dispatch_answer(approval, normalized_decision, caller_id, opts),
         :ok <- record_answer(approval, normalized_decision, caller_id, opts) do
      :ok
    end
  end

  defp dispatch_task(agent_id, task, opts) do
    opts
    |> task_store_module()
    |> apply_if_exported(:dispatch, [agent_id, task, task_store_opts(opts)])
    |> normalize_task_dispatch_result()
  end

  defp task_status_unchecked(task_id, opts) do
    opts
    |> task_store_module()
    |> apply_if_exported(:status, [task_id, task_store_opts(opts)])
    |> normalize_task_status_result()
  end

  # Facade projection only: a still-running task may surface as :waiting_approval
  # when a same-task pending approval exists. Ownerless pending-approval runner
  # returns are fail-closed to :failed by TaskStore and are not projected here.
  defp enrich_waiting_approval(%{state: :running, agent_id: agent_id} = status, opts)
       when is_binary(agent_id) do
    task_id = Map.get(status, :task_id)

    pending_approval =
      if is_binary(task_id) and task_id != "" do
        opts
        |> normalize_opts()
        |> Map.put(:agent_id, agent_id)
        |> list_pending_approvals_unchecked()
        |> Enum.find(&(approval_task_id(&1) == task_id))
      end

    case pending_approval do
      %PendingApproval{id: approval_id} ->
        status
        |> Map.put(:state, :waiting_approval)
        |> Map.put(:waiting_on, approval_id)

      nil ->
        status
    end
  end

  defp enrich_waiting_approval(status, _opts), do: status

  defp authorize_dispatch(opts, caller_id, agent_id) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      [scoped_dispatch_uri(agent_id), @dispatch_uri]
      |> Enum.find_value(fn resource_uri ->
        case authorize_caller(opts, caller_id, resource_uri, :execute) do
          :ok -> :ok
          _ -> nil
        end
      end)
      |> case do
        :ok -> :ok
        nil -> {:error, {:unauthorized, :agent_dispatch_required}}
      end
    end
  end

  defp authorize_task_read(opts, caller_id, status) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      status
      |> task_read_authorization_uris()
      |> Enum.find_value(fn resource_uri ->
        case authorize_caller(opts, caller_id, resource_uri, :read) do
          :ok -> :ok
          _ -> nil
        end
      end)
      |> case do
        :ok -> :ok
        nil -> {:error, {:unauthorized, :task_read_required}}
      end
    end
  end

  defp authorize_task_cancel(opts, caller_id, status) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      status
      |> task_cancel_authorization_uris()
      |> Enum.find_value(fn resource_uri ->
        case authorize_caller(opts, caller_id, resource_uri, :execute) do
          :ok -> :ok
          _ -> nil
        end
      end)
      |> case do
        :ok -> :ok
        nil -> {:error, {:unauthorized, :task_cancel_required}}
      end
    end
  end

  defp authorize_task_steer(opts, caller_id, status) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      status
      |> task_steer_authorization_uris()
      |> Enum.find_value(fn resource_uri ->
        case authorize_caller(opts, caller_id, resource_uri, :execute) do
          :ok -> :ok
          _ -> nil
        end
      end)
      |> case do
        :ok -> :ok
        nil -> {:error, {:unauthorized, :task_steer_required}}
      end
    end
  end

  defp authorize_task_adopt(opts, caller_id, status) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      status
      |> task_adopt_authorization_uris()
      |> Enum.find_value(fn resource_uri ->
        case authorize_caller(opts, caller_id, resource_uri, :execute) do
          :ok -> :ok
          _ -> nil
        end
      end)
      |> case do
        :ok -> :ok
        nil -> {:error, {:unauthorized, :task_adoption_required}}
      end
    end
  end

  defp task_read_authorization_uris(status) do
    [
      scoped_task_read_uri(Map.get(status, :task_id)),
      scoped_task_read_uri(Map.get(status, :agent_id)),
      @task_read_uri
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp task_cancel_authorization_uris(status) do
    [
      scoped_task_cancel_uri(Map.get(status, :task_id)),
      scoped_task_cancel_uri(Map.get(status, :agent_id)),
      @task_cancel_uri
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp task_steer_authorization_uris(status) do
    [
      scoped_task_steer_uri(Map.get(status, :task_id)),
      scoped_task_steer_uri(Map.get(status, :agent_id)),
      @task_steer_uri
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp task_adopt_authorization_uris(status) do
    [
      scoped_task_adopt_uri(Map.get(status, :task_id)),
      scoped_task_adopt_uri(Map.get(status, :agent_id)),
      @task_adopt_uri
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp scoped_dispatch_uri(agent_id) when is_binary(agent_id) and agent_id != "",
    do: "#{@dispatch_uri}/#{agent_id}"

  defp scoped_dispatch_uri(_), do: nil

  defp scoped_task_read_uri(id) when is_binary(id) and id != "",
    do: "#{@task_read_uri}/#{id}"

  defp scoped_task_read_uri(_), do: nil

  defp scoped_task_cancel_uri(id) when is_binary(id) and id != "",
    do: "#{@task_cancel_uri}/#{id}"

  defp scoped_task_cancel_uri(_), do: nil

  defp scoped_task_steer_uri(id) when is_binary(id) and id != "",
    do: "#{@task_steer_uri}/#{id}"

  defp scoped_task_steer_uri(_), do: nil

  defp scoped_task_adopt_uri(id) when is_binary(id) and id != "",
    do: "#{@task_adopt_uri}/#{id}"

  defp scoped_task_adopt_uri(_), do: nil

  defp normalize_or_generate_task_id(opts) do
    case opt(opts, :task_id) do
      id when is_binary(id) -> normalize_task_id(id)
      nil -> {:ok, "task_" <> Integer.to_string(System.unique_integer([:positive]))}
      _ -> {:error, :invalid_task_id}
    end
  end

  defp task_scoped_opts(
         opts,
         task_id,
         caller_id,
         approval_answer_cap_id,
         steer_cap_id,
         adoption_cap_id
       ) do
    opts
    |> task_store_opts()
    |> Keyword.put(:task_id, task_id)
    |> Keyword.put(:approval_answer_cap_id, approval_answer_cap_id)
    |> Keyword.put(:approval_answer_security_module, security_module(opts))
    |> Keyword.put(:steer_cap_id, steer_cap_id)
    |> Keyword.put(:steer_security_module, security_module(opts))
    |> Keyword.put(:adoption_cap_id, adoption_cap_id)
    |> Keyword.put(:adoption_security_module, security_module(opts))
    |> Keyword.put(:approval_cleanup_descriptor, approval_cleanup_descriptor(caller_id, opts))
  end

  # Closed scalar data only — never MFA/module/function/fun/PID selection.
  # TaskStore pins cleanup MFA, backend modules, and cleanup supervisor at init.
  defp approval_cleanup_descriptor(caller_id, opts) do
    %{caller_id: caller_id}
    |> maybe_put_cleanup_trace_id(opt(opts, :trace_id))
  end

  defp maybe_put_cleanup_trace_id(descriptor, trace_id)
       when is_binary(trace_id) and trace_id != "" do
    Map.put(descriptor, :trace_id, trace_id)
  end

  defp maybe_put_cleanup_trace_id(descriptor, _trace_id), do: descriptor

  defp dispatch_with_task_capabilities(agent_id, task, task_id, caller_id, opts) do
    case grant_task_approval_answer(caller_id, task_id, opts) do
      {:ok, approval_answer_cap_id} ->
        case grant_task_steer(caller_id, task_id, opts) do
          {:ok, steer_cap_id} ->
            case grant_task_adopt(caller_id, task_id, opts) do
              {:ok, adoption_cap_id} ->
                task_opts =
                  task_scoped_opts(
                    opts,
                    task_id,
                    caller_id,
                    approval_answer_cap_id,
                    steer_cap_id,
                    adoption_cap_id
                  )

                case dispatch_task(agent_id, task, task_opts) do
                  {:ok, ^task_id} ->
                    with :ok <- record_dispatch(task_id, agent_id, task, caller_id, opts) do
                      {:ok, task_id}
                    end

                  {:ok, other_task_id} ->
                    revoke_task_capabilities(
                      opts,
                      approval_answer_cap_id,
                      steer_cap_id,
                      adoption_cap_id
                    )

                    {:error, {:task_id_mismatch, other_task_id}}

                  {:error, _reason} = error ->
                    revoke_task_capabilities(
                      opts,
                      approval_answer_cap_id,
                      steer_cap_id,
                      adoption_cap_id
                    )

                    error
                end

              {:error, _reason} = error ->
                revoke_task_capabilities(opts, approval_answer_cap_id, steer_cap_id)
                error
            end

          {:error, _reason} = error ->
            revoke_task_approval_answer(opts, approval_answer_cap_id)
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp grant_task_approval_answer(caller_id, task_id, opts) do
    grant_opts = [
      principal: caller_id,
      resource: scoped_task_answer_uri(task_id),
      expires_at: DateTime.add(DateTime.utc_now(), @approval_answer_cap_ttl_seconds, :second),
      constraints: %{},
      metadata: %{
        source: :orchestration_task_dispatch,
        task_id: task_id
      }
    ]

    case opts |> security_module() |> apply_if_exported(:grant, [grant_opts]) do
      {:ok, capability} ->
        case value(capability, :id) do
          id when is_binary(id) and id != "" -> {:ok, id}
          other -> {:error, {:approval_answer_grant_failed, {:missing_capability_id, other}}}
        end

      {:error, reason} ->
        {:error, {:approval_answer_grant_failed, reason}}

      :module_unavailable ->
        {:error, {:approval_answer_grant_failed, :security_unavailable}}

      other ->
        {:error, {:approval_answer_grant_failed, other}}
    end
  end

  defp grant_task_steer(caller_id, task_id, opts) do
    grant_opts = [
      principal: caller_id,
      resource: scoped_task_steer_uri(task_id),
      expires_at: DateTime.add(DateTime.utc_now(), @approval_answer_cap_ttl_seconds, :second),
      constraints: %{},
      metadata: %{source: :orchestration_task_dispatch, task_id: task_id}
    ]

    case opts |> security_module() |> apply_if_exported(:grant, [grant_opts]) do
      {:ok, capability} ->
        case value(capability, :id) do
          id when is_binary(id) and id != "" -> {:ok, id}
          other -> {:error, {:steer_grant_failed, {:missing_capability_id, other}}}
        end

      {:error, reason} ->
        {:error, {:steer_grant_failed, reason}}

      :module_unavailable ->
        {:error, {:steer_grant_failed, :security_unavailable}}

      other ->
        {:error, {:steer_grant_failed, other}}
    end
  end

  defp grant_task_adopt(caller_id, task_id, opts) do
    grant_opts = [
      principal: caller_id,
      resource: scoped_task_adopt_uri(task_id),
      expires_at: DateTime.add(DateTime.utc_now(), @approval_answer_cap_ttl_seconds, :second),
      constraints: %{},
      metadata: %{source: :orchestration_task_dispatch, task_id: task_id}
    ]

    case opts |> security_module() |> apply_if_exported(:grant, [grant_opts]) do
      {:ok, capability} ->
        case value(capability, :id) do
          id when is_binary(id) and id != "" -> {:ok, id}
          other -> {:error, {:adoption_grant_failed, {:missing_capability_id, other}}}
        end

      {:error, reason} ->
        {:error, {:adoption_grant_failed, reason}}

      :module_unavailable ->
        {:error, {:adoption_grant_failed, :security_unavailable}}

      other ->
        {:error, {:adoption_grant_failed, other}}
    end
  end

  defp revoke_task_approval_answer(opts, capability_id)
       when is_binary(capability_id) and capability_id != "" do
    opts
    |> security_module()
    |> apply_if_exported(:revoke, [capability_id])
    |> case do
      :ok -> :ok
      _ -> :ok
    end
  end

  defp revoke_task_approval_answer(_opts, _capability_id), do: :ok

  defp revoke_task_capabilities(opts, approval_answer_cap_id, steer_cap_id, adoption_cap_id) do
    revoke_task_approval_answer(opts, approval_answer_cap_id)
    revoke_task_steer(opts, steer_cap_id)
    revoke_task_adopt(opts, adoption_cap_id)
  end

  defp revoke_task_capabilities(opts, approval_answer_cap_id, steer_cap_id) do
    revoke_task_approval_answer(opts, approval_answer_cap_id)
    revoke_task_steer(opts, steer_cap_id)
  end

  defp revoke_task_steer(opts, capability_id),
    do: revoke_task_approval_answer(opts, capability_id)

  defp revoke_task_adopt(opts, capability_id),
    do: revoke_task_approval_answer(opts, capability_id)

  defp record_dispatch(task_id, agent_id, task, caller_id, opts) do
    data = [
      trace_id: opt(opts, :trace_id),
      metadata: opt(opts, :metadata),
      task_preview: task_preview(task)
    ]

    opts
    |> audit_module()
    |> apply_if_exported(:record_orchestration_task_dispatched, [
      caller_id,
      task_id,
      agent_id,
      data
    ])
    |> normalize_audit_result()
  end

  defp task_preview(task) when is_binary(task) do
    if byte_size(task) > 500, do: String.slice(task, 0, 500) <> "...", else: task
  end

  defp task_preview(task) when is_map(task) do
    task
    |> inspect(limit: 20)
    |> task_preview()
  end

  defp task_preview(task), do: inspect(task, limit: 20)

  defp list_pending_approvals_unchecked(opts) do
    opts
    |> all_pending_approvals()
    |> Enum.filter(&matches_filters?(&1, opts))
  end

  defp do_cleanup_task_approvals(task_id, caller_id, reason, opts) do
    opts
    |> all_pending_approvals()
    |> Enum.filter(&(approval_task_id(&1) == task_id))
    |> Enum.each(fn approval ->
      cleanup_task_approval(approval, task_id, caller_id, reason, opts)
    end)

    :ok
  end

  defp cleanup_task_approval(%PendingApproval{} = approval, task_id, caller_id, reason, opts) do
    result =
      approval
      |> dispatch_task_lifecycle_cleanup(task_id, caller_id, reason, opts)
      |> normalize_backend_result()

    case result do
      :ok ->
        record_task_approval_cleanup(approval, task_id, caller_id, reason, :resolved, nil, opts)

      {:error, backend_reason}
      when backend_reason in [:not_found, :already_decided, :already_resolved] ->
        record_task_approval_cleanup(
          approval,
          task_id,
          caller_id,
          reason,
          :already_resolved,
          backend_reason,
          opts
        )

      {:error, {:already_terminal, _status} = backend_reason} ->
        record_task_approval_cleanup(
          approval,
          task_id,
          caller_id,
          reason,
          :already_resolved,
          backend_reason,
          opts
        )

      {:error, backend_reason} ->
        Logger.warning(
          "Approval cleanup after task #{cleanup_reason_label(reason)} failed " <>
            "task_id=#{bounded_inspect(task_id)} approval_id=#{bounded_inspect(approval.id)} " <>
            "source=#{approval.source} reason=#{bounded_inspect(backend_reason)}"
        )

        record_task_approval_cleanup(
          approval,
          task_id,
          caller_id,
          reason,
          :failed,
          backend_reason,
          opts
        )
    end

    :ok
  end

  defp dispatch_task_lifecycle_cleanup(
         %PendingApproval{source: :interaction, id: id},
         _task_id,
         _caller_id,
         reason,
         opts
       ) do
    opts
    |> interaction_backend()
    |> apply_if_exported(:abandon_interaction, [id, reason])
  end

  defp dispatch_task_lifecycle_cleanup(
         %PendingApproval{source: :consensus, id: id},
         _task_id,
         _caller_id,
         _reason,
         opts
       ) do
    opts
    |> consensus_module()
    |> apply_if_exported(:cancel, [id])
  end

  defp record_task_approval_cleanup(
         approval,
         task_id,
         caller_id,
         reason,
         outcome,
         error_reason,
         opts
       ) do
    {success_decision, cleanup_tag, note} = cleanup_semantics(reason)

    decision =
      if outcome == :failed do
        cleanup_failed_decision(reason)
      else
        success_decision
      end

    data = [
      resource_uri: approval.resource_uri,
      agent_id: approval.agent_id,
      principal_id: approval.principal_id,
      task_id: task_id,
      cleanup: cleanup_tag,
      outcome: outcome,
      error: if(is_nil(error_reason), do: nil, else: bounded_inspect(error_reason)),
      note: note,
      trace_id: opt(opts, :trace_id)
    ]

    opts
    |> audit_module()
    |> apply_if_exported(:record_approval_answered, [
      caller_id,
      approval.id,
      approval.source,
      decision,
      data
    ])
    |> normalize_audit_result()
  end

  defp cleanup_semantics(:task_cancellation) do
    {:task_cancelled, :task_cancellation, @task_cancel_cleanup_note}
  end

  defp cleanup_semantics(:task_termination) do
    {:task_terminated, :task_termination, @task_terminal_cleanup_note}
  end

  defp cleanup_failed_decision(:task_cancellation), do: :task_cancellation_cleanup_failed
  defp cleanup_failed_decision(:task_termination), do: :task_termination_cleanup_failed

  defp cleanup_reason(opts) do
    case opt(opts, :cleanup_reason, :task_termination) do
      :task_cancellation -> :task_cancellation
      :task_termination -> :task_termination
      "task_cancellation" -> :task_cancellation
      "task_termination" -> :task_termination
      _ -> :task_termination
    end
  end

  defp cleanup_reason_label(:task_cancellation), do: "cancellation"
  defp cleanup_reason_label(:task_termination), do: "termination"

  defp cleanup_caller_id(opts) do
    case opt(opts, :caller_id) || opt(opts, :actor_id) || opt(opts, :authenticated_principal_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :caller_id_required}
    end
  end

  defp normalize_keyword_opts(opts) when is_list(opts), do: opts
  defp normalize_keyword_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_keyword_opts(_opts), do: []

  defp bounded_inspect(term), do: inspect(term, limit: 10, printable_limit: 500)

  defp all_pending_approvals(opts) do
    consensus_pending(opts) ++ interaction_pending(opts)
  end

  defp consensus_pending(opts) do
    opts
    |> consensus_module()
    |> apply_if_exported(:list_pending, [])
    |> case do
      proposals when is_list(proposals) ->
        proposals
        |> Enum.filter(&authorization_request?/1)
        |> Enum.map(&from_consensus/1)

      _ ->
        []
    end
  end

  defp interaction_pending(opts) do
    opts
    |> interaction_backend()
    |> apply_if_exported(:pending_interactions, [])
    |> case do
      interactions when is_list(interactions) ->
        interactions
        |> Enum.filter(&(value(&1, :kind) in [:approval, "approval"]))
        |> Enum.map(&from_interaction/1)

      _ ->
        []
    end
  end

  defp from_consensus(proposal) do
    metadata = value(proposal, :metadata, %{}) || %{}
    context = value(proposal, :context, %{}) || %{}
    principal_id = value(metadata, :principal_id) || value(proposal, :proposer)

    %PendingApproval{
      id: to_string(value(proposal, :id)),
      source: :consensus,
      agent_id: value(proposal, :proposer) || principal_id,
      principal_id: principal_id,
      approver_id: value(metadata, :approver_id),
      resource_uri: value(metadata, :resource_uri) || value(context, :resource_uri),
      action: value(metadata, :action) || value(context, :action) || value(proposal, :topic),
      description: value(proposal, :description),
      context: context,
      metadata: metadata,
      created_at: value(proposal, :created_at),
      status: normalize_status(value(proposal, :status))
    }
  end

  defp from_interaction(interaction) do
    metadata = value(interaction, :metadata, %{}) || %{}
    agent_id = value(interaction, :agent_id)

    %PendingApproval{
      id: to_string(value(interaction, :request_id)),
      source: :interaction,
      agent_id: agent_id,
      principal_id: value(metadata, :principal_id) || agent_id,
      approver_id: value(interaction, :user_id),
      resource_uri: value(interaction, :resource_uri) || value(metadata, :resource_uri),
      action: value(metadata, :action) || value(interaction, :kind),
      description: value(interaction, :description),
      context: metadata,
      metadata: metadata,
      created_at: value(interaction, :submitted_at),
      status: :pending
    }
  end

  defp authorization_request?(proposal) do
    value(proposal, :topic) in [:authorization_request, "authorization_request"]
  end

  defp get_pending_approval(id, opts) do
    case Enum.find(list_pending_approvals_unchecked(opts), &(&1.id == id)) do
      nil -> {:error, :not_found}
      approval -> {:ok, approval}
    end
  end

  defp dispatch_answer(%PendingApproval{source: :interaction, id: id}, decision, caller_id, opts) do
    response =
      case decision do
        :approve -> :approved
        :deny -> :rejected
        :rework -> :rejected
      end

    metadata = answer_metadata(decision, caller_id, opts)

    opts
    |> interaction_backend()
    |> apply_if_exported(:respond_to_interaction, [id, response, metadata])
    |> normalize_backend_result()
  end

  defp dispatch_answer(%PendingApproval{source: :consensus, id: id}, decision, caller_id, opts) do
    metadata = answer_metadata(decision, caller_id, opts)
    metadata_opts = Map.to_list(metadata)
    consensus = consensus_module(opts)

    cond do
      function_exported?(consensus, :answer_authorization_request, 4) ->
        consensus
        |> apply_if_exported(:answer_authorization_request, [
          id,
          decision,
          caller_id,
          metadata_opts
        ])
        |> normalize_backend_result()

      decision == :approve ->
        consensus
        |> apply_if_exported(:force_approve, [id, caller_id])
        |> normalize_backend_result()

      true ->
        consensus
        |> apply_if_exported(:force_reject, [id, caller_id])
        |> normalize_backend_result()
    end
  end

  defp answer_metadata(decision, caller_id, opts) do
    %{
      actor: caller_id,
      decision: decision,
      note: opt(opts, :note),
      answered_at: DateTime.utc_now()
    }
    |> maybe_put(:rework, decision == :rework)
  end

  defp reject_blocked_approval(%PendingApproval{} = approval, :approve) do
    if blocked_approval?(approval) do
      {:error, :blocked_approval_cannot_be_approved}
    else
      :ok
    end
  end

  defp reject_blocked_approval(%PendingApproval{}, _decision), do: :ok

  defp blocked_approval?(%PendingApproval{metadata: metadata, context: context}) do
    Enum.any?([metadata, context], fn map ->
      value(map, :blocked) == true or
        blocked_mode?(value(map, :approval_mode)) or
        blocked_mode?(value(map, :policy_mode)) or
        blocked_mode?(value(map, :trust_mode))
    end)
  end

  defp blocked_mode?(:block), do: true
  defp blocked_mode?("block"), do: true
  defp blocked_mode?(_), do: false

  defp record_answer(%PendingApproval{} = approval, decision, caller_id, opts) do
    data = [
      resource_uri: approval.resource_uri,
      agent_id: approval.agent_id,
      principal_id: approval.principal_id,
      note: opt(opts, :note),
      trace_id: opt(opts, :trace_id)
    ]

    opts
    |> audit_module()
    |> apply_if_exported(:record_approval_answered, [
      caller_id,
      approval.id,
      approval.source,
      decision,
      data
    ])
    |> normalize_audit_result()
  end

  defp matches_filters?(%PendingApproval{} = approval, opts) do
    matches_agent?(approval, opt(opts, :agent_id)) and
      matches_principal?(approval, opt(opts, :principal_id)) and
      matches_resource?(approval, opt(opts, :resource_uri))
  end

  defp matches_agent?(_approval, nil), do: true
  defp matches_agent?(%PendingApproval{agent_id: agent_id}, agent_id), do: true
  defp matches_agent?(_approval, _agent_id), do: false

  defp matches_principal?(_approval, nil), do: true

  defp matches_principal?(%PendingApproval{} = approval, principal_id) do
    principal_id in [approval.principal_id, approval.approver_id]
  end

  defp matches_resource?(_approval, nil), do: true

  defp matches_resource?(%PendingApproval{resource_uri: resource_uri}, prefix) do
    CapabilityUri.prefix_match?(prefix, resource_uri)
  end

  defp authorize(opts, resource_uri, action) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      with {:ok, actor} <- caller_id(opts),
           {:ok, :authorized} <-
             opts
             |> security_module()
             |> apply_if_exported(:authorize, [
               actor,
               resource_uri,
               action,
               [verify_identity: false]
             ]) do
        :ok
      else
        {:ok, :pending_approval, _id} -> {:error, {:unauthorized, :pending_approval}}
        {:error, reason} -> {:error, {:unauthorized, reason}}
        :module_unavailable -> {:error, {:unauthorized, :security_unavailable}}
        other -> {:error, {:unauthorized, other}}
      end
    end
  end

  defp authorize_answer(opts, caller_id, %PendingApproval{} = approval) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      approval
      |> answer_authorization_uris()
      |> Enum.find_value(fn resource_uri ->
        case authorize_caller(opts, caller_id, resource_uri, :execute) do
          :ok -> :ok
          _ -> nil
        end
      end)
      |> case do
        :ok -> :ok
        nil -> {:error, {:unauthorized, :approval_answer_required}}
      end
    end
  end

  defp answer_authorization_uris(%PendingApproval{} = approval) do
    [
      approval |> approval_task_id() |> scoped_task_answer_uri(),
      scoped_answer_uri(approval.principal_id),
      scoped_answer_uri(approval.agent_id),
      @approval_answer_uri
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp scoped_answer_uri(id) when is_binary(id) and id != "",
    do: "#{@approval_answer_uri}/#{id}"

  defp scoped_answer_uri(_), do: nil

  defp scoped_task_answer_uri(task_id) when is_binary(task_id) and task_id != "",
    do: "#{@approval_answer_uri}/task/#{task_id}"

  defp scoped_task_answer_uri(_), do: nil

  defp approval_task_id(%PendingApproval{metadata: metadata, context: context}) do
    Enum.find_value([metadata, context], &task_id_from_approval_map/1)
  end

  defp task_id_from_approval_map(map) when is_map(map) do
    value(map, :task_id) ||
      nested_value(map, [:provenance, :task_id]) ||
      nested_value(map, [:approval_context, :task_id]) ||
      nested_value(map, [:approval_context, :provenance, :task_id])
  end

  defp task_id_from_approval_map(_), do: nil

  defp nested_value(term, []), do: term

  defp nested_value(term, [key | rest]) do
    case value(term, key) do
      nil -> nil
      next -> nested_value(next, rest)
    end
  end

  defp authorize_caller(opts, caller_id, resource_uri, action) do
    case opts
         |> security_module()
         |> apply_if_exported(:authorize, [
           caller_id,
           resource_uri,
           action,
           [verify_identity: false]
         ]) do
      {:ok, :authorized} -> :ok
      :ok -> :ok
      :authorized -> :ok
      {:ok, :pending_approval, _id} -> {:error, {:unauthorized, :pending_approval}}
      {:error, reason} -> {:error, {:unauthorized, reason}}
      :module_unavailable -> {:error, {:unauthorized, :security_unavailable}}
      other -> {:error, {:unauthorized, other}}
    end
  end

  defp normalize_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, :invalid_approval_id}, else: {:ok, id}
  end

  defp normalize_id(_), do: {:error, :invalid_approval_id}

  defp normalize_task_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, :invalid_task_id}, else: {:ok, id}
  end

  defp normalize_task_id(_), do: {:error, :invalid_task_id}

  defp normalize_destination_ref(destination_ref)
       when is_binary(destination_ref) and
              byte_size(destination_ref) <= @max_destination_ref_bytes do
    destination_ref = String.trim(destination_ref)

    if destination_ref == "" do
      {:error, :invalid_destination_ref}
    else
      {:ok, destination_ref}
    end
  end

  defp normalize_destination_ref(_), do: {:error, :invalid_destination_ref}

  defp normalize_agent_id(agent_id) when is_binary(agent_id) do
    if String.trim(agent_id) == "", do: {:error, :invalid_agent_id}, else: {:ok, agent_id}
  end

  defp normalize_agent_id(_agent_id), do: {:error, :invalid_agent_id}

  defp normalize_task(task) when is_binary(task) do
    if String.trim(task) == "", do: {:error, :empty_task}, else: {:ok, task}
  end

  defp normalize_task(task) when is_map(task), do: {:ok, task}
  defp normalize_task(_task), do: {:error, :invalid_task}

  defp normalize_decision(decision) when decision in [:approve, :approved], do: {:ok, :approve}

  defp normalize_decision(decision) when decision in [:deny, :denied, :reject, :rejected],
    do: {:ok, :deny}

  defp normalize_decision(:rework), do: {:ok, :rework}
  defp normalize_decision("approve"), do: {:ok, :approve}
  defp normalize_decision("approved"), do: {:ok, :approve}
  defp normalize_decision("deny"), do: {:ok, :deny}
  defp normalize_decision("denied"), do: {:ok, :deny}
  defp normalize_decision("reject"), do: {:ok, :deny}
  defp normalize_decision("rejected"), do: {:ok, :deny}
  defp normalize_decision("rework"), do: {:ok, :rework}
  defp normalize_decision(_), do: {:error, :invalid_decision}

  defp normalize_status(nil), do: :pending
  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status("pending"), do: :pending
  defp normalize_status("evaluating"), do: :evaluating
  defp normalize_status("approved"), do: :approved
  defp normalize_status("rejected"), do: :rejected
  defp normalize_status("deadlock"), do: :deadlock
  defp normalize_status("vetoed"), do: :vetoed
  defp normalize_status(_status), do: :pending

  defp caller_id(opts) do
    case opt(opts, :caller_id) || opt(opts, :actor_id) || opt(opts, :authenticated_principal_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, {:unauthorized, :caller_id_required}}
    end
  end

  defp consensus_module(opts), do: opt(opts, :consensus_module, Arbor.Consensus)
  defp task_store_module(opts), do: opt(opts, :task_store, Arbor.Agent.Orchestration.TaskStore)

  defp task_store_owns_cancel_cleanup?(opts) do
    module = task_store_module(opts)

    Code.ensure_loaded?(module) and
      function_exported?(module, :cancel_owns_approval_cleanup?, 0) and
      apply(module, :cancel_owns_approval_cleanup?, []) == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp interaction_backend(opts) do
    opt(opts, :interaction_router, Module.concat([:Arbor, :Comms]))
  end

  defp security_module(opts), do: opt(opts, :security_module, Arbor.Security)
  defp audit_module(opts), do: opt(opts, :audit_module, Arbor.Security)

  defp apply_if_exported(module, function, args) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      :module_unavailable
    end
  rescue
    _ -> :module_unavailable
  catch
    :exit, _ -> :module_unavailable
  end

  defp normalize_backend_result(:ok), do: :ok
  defp normalize_backend_result({:ok, _}), do: :ok
  defp normalize_backend_result({:error, _} = error), do: error
  defp normalize_backend_result(:module_unavailable), do: {:error, :approval_backend_unavailable}
  defp normalize_backend_result(other), do: {:error, {:unexpected_approval_backend_result, other}}

  defp normalize_task_dispatch_result({:ok, task_id}) when is_binary(task_id), do: {:ok, task_id}
  defp normalize_task_dispatch_result({:error, _} = error), do: error
  defp normalize_task_dispatch_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_dispatch_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_status_result({:ok, status}) when is_map(status) do
    {:ok,
     %{
       task_id: value(status, :task_id),
       agent_id: value(status, :agent_id),
       state: normalize_task_state(value(status, :state)),
       current_step: value(status, :current_step),
       waiting_on: value(status, :waiting_on),
       started_at: value(status, :started_at),
       updated_at: value(status, :updated_at),
       completed_at: value(status, :completed_at),
       metadata: value(status, :metadata, %{}) || %{},
       steering: value(status, :steering, %{"counts" => %{}, "last" => nil}) || %{}
     }}
  end

  defp normalize_task_status_result({:error, _} = error), do: error
  defp normalize_task_status_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_status_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_result({:ok, result}), do: {:ok, TaskArtifacts.normalize(result)}

  defp normalize_task_result({:error, _} = error), do: error
  defp normalize_task_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_cancel_result({:ok, status}) when is_map(status),
    do: normalize_task_status_result({:ok, status})

  defp normalize_task_cancel_result({:error, _} = error), do: error
  defp normalize_task_cancel_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_cancel_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_steer_result({:ok, control}) when is_map(control), do: {:ok, control}
  defp normalize_task_steer_result({:error, _} = error), do: error
  defp normalize_task_steer_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_steer_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_adopt_result({:ok, result}), do: {:ok, TaskArtifacts.normalize(result)}
  defp normalize_task_adopt_result({:error, _} = error), do: error
  defp normalize_task_adopt_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_adopt_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_state(state)
       when state in [:running, :waiting_approval, :done, :failed, :cancelled],
       do: state

  defp normalize_task_state("running"), do: :running
  defp normalize_task_state("waiting_approval"), do: :waiting_approval
  defp normalize_task_state("done"), do: :done
  defp normalize_task_state("failed"), do: :failed
  defp normalize_task_state("cancelled"), do: :cancelled
  defp normalize_task_state(_state), do: :running

  defp normalize_audit_result(:ok), do: :ok
  defp normalize_audit_result({:error, _}), do: :ok
  defp normalize_audit_result(:module_unavailable), do: :ok
  defp normalize_audit_result(_), do: :ok

  defp value(term, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp value(_term, _key, default), do: default

  defp opt(opts, key, default \\ nil)

  defp opt(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, to_string(key), default))
  end

  defp opt(_opts, _key, default), do: default

  defp task_store_opts(opts) when is_list(opts), do: opts
  defp task_store_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp task_store_opts(_opts), do: []

  defp normalize_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(_opts), do: %{}

  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec interaction_request_id?(String.t()) :: boolean()
  def interaction_request_id?(id) when is_binary(id),
    do: String.starts_with?(id, @interaction_request_prefix)

  def interaction_request_id?(_), do: false
end
