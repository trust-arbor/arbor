defmodule Arbor.Agent.Orchestration do
  @moduledoc """
  Shared agent orchestration interface.

  Slice 1 intentionally wraps the existing approval backends:

    * `Arbor.Consensus` authorization proposals
    * `Arbor.Comms` interaction requests, when available

  The module does not own approval state. It normalizes, filters, and answers
  requests held by those systems.

  ## Task dispatch and exact-task control lease

  Public `dispatch/3` **never accepts a caller-selected `task_id`** (including
  under `authorize?: false`). TaskStore generates unguessable server-owned ids
  via `reserve/1`, commits a durable capability-ID-free recovery marker before
  minting, grants the closed six-member exact-task lease (least-risk order,
  `approval_answer` last), then `activate/5`s the reserved identity.

  Recovery markers and `Security.revoke_by_task/1` run through TaskStore-owned
  workers (no Persistence/Security I/O in GenServer callbacks). Grant
  exceptions/exits/throws are mint-outcome uncertainty: reverse-revoke known
  ids, request task-scope reconcile, and never report ordinary `grant_failed`.
  Capability ids never appear in public/MCP/audit projections.

  Deterministic task ids for tests are only available via TaskStore start pin
  `:task_id_generator` — not through authenticated public dispatch options.
  """

  require Logger

  alias Arbor.Agent.Orchestration.{
    ApprovalInventoryProjection,
    DispatchReadiness,
    PendingApproval,
    TaskArtifacts,
    TaskControlLease
  }

  alias Arbor.Contracts.Coding.{TaskOutcome, TaskTerminalEnvelope}
  alias Arbor.Contracts.Security.CapabilityUri

  @approval_read_uri "arbor://approval/read"
  @approval_answer_uri "arbor://approval/answer"
  @dispatch_uri "arbor://agent/dispatch"
  @task_read_uri "arbor://agent/task/read"
  @task_cancel_uri "arbor://agent/task/cancel"
  @task_steer_uri "arbor://agent/task/steer"
  @task_adopt_uri "arbor://agent/task/adopt"
  @default_task_inventory_items 64
  @max_task_inventory_items 1_000
  @default_approval_inventory_items 64
  @max_approval_inventory_items 1_000
  @max_approval_inventory_backend_entries 1_000
  @max_task_id_bytes 256
  @task_id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @max_destination_ref_bytes 256
  @interaction_request_prefix "irq"
  @task_cancel_cleanup_note "Pending approval closed because its orchestration task was cancelled"
  @task_terminal_cleanup_note "Pending approval closed because its orchestration task terminated"

  @type approval_decision :: :approve | :deny | :rework
  @type cleanup_reason :: :task_cancellation | :task_termination

  @doc """
  Dispatch an agent task asynchronously.

  Returns immediately with a stable server-owned `task_id`; the background task
  can be observed with `task_status/2` and `task_result/2`.

  Caller-selected `:task_id` / `\"task_id\"` is **always rejected** (no test
  bypass). Identity is reserved in TaskStore before any capability grant; a
  durable recovery marker is backend-acked before minting.
  """
  @spec dispatch(String.t(), String.t() | map(), keyword() | map()) ::
          {:ok, String.t()} | {:error, term()}
  def dispatch(agent_id, task, opts \\ []) do
    with :ok <- reject_caller_task_id(opts),
         {:ok, agent_id} <- normalize_agent_id(agent_id),
         {:ok, task} <- normalize_task(task),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_dispatch(opts, caller_id, agent_id) do
      # Proof may reach only Security.authorize/4. Strip both key forms before
      # grants, TaskStore, cleanup descriptors, audit, or retained state.
      safe_opts = strip_session_tokens(opts)
      dispatch_with_reservation_and_lease(agent_id, task, caller_id, safe_opts)
    end
  end

  @doc """
  Project a read-only Agent-owned coding-dispatch readiness report.

  Reuses the dispatch authorization gate. On authorization success always
  returns `{:ok, bounded_report}` even when readiness is blocked or degraded.
  Performs no task-identity minting, capability grants, profile/template
  writes, or reconciles. Session proofs reach only `Security.authorize/4`.
  """
  @spec coding_dispatch_readiness(String.t(), String.t() | map(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def coding_dispatch_readiness(agent_id, task, opts \\ []) do
    with :ok <- reject_caller_task_id(opts),
         {:ok, agent_id} <- normalize_agent_id(agent_id),
         {:ok, task} <- normalize_task(task),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_dispatch(opts, caller_id, agent_id) do
      safe_opts =
        opts
        |> strip_session_tokens()
        |> normalize_keyword_opts()
        |> Keyword.put(:caller_id, caller_id)

      DispatchReadiness.project(agent_id, task, safe_opts)
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
         :ok <- require_exact_task_status(task_id, status),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_task_read(opts, caller_id, status) do
      {:ok, enrich_waiting_approval(status, opts)}
    end
  end

  @doc """
  Return a bounded, read-only inventory of volatile orchestration tasks.

  The inventory contains only reconciliation join/lifecycle evidence. It is
  explicitly non-durable: callers must reconcile it with the coding-resource
  inventory or other durable evidence rather than treating absence as proof of
  task completion.
  """
  @spec task_inventory(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def task_inventory(opts \\ []) do
    with {:ok, normalized} <- normalize_task_inventory_options(opts),
         :ok <- authorize_task_inventory(normalized) do
      normalized
      |> task_inventory_store_opts()
      |> Arbor.Agent.Orchestration.TaskStore.inventory()
      |> normalize_task_inventory_result()
    end
  end

  @doc """
  Return the completed structured result for an async orchestration task.
  """
  @spec task_result(String.t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def task_result(task_id, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, status} <- task_status_unchecked(task_id, opts),
         :ok <- require_exact_task_status(task_id, status),
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
         :ok <- require_exact_task_status(task_id, status),
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
         :ok <- require_exact_task_status(task_id, status),
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
  Prove and settle an already externally integrated terminal task change.

  Authorization checks the exact task scope first, followed by the target agent
  and global adoption capability. The destination reference is normalized before
  it crosses into TaskStore. This operation does not merge or cherry-pick the
  candidate; the caller must integrate it into `destination_ref` first.

  HTTP control planes may set `:reconcile_adoption_timeout` after choosing an
  `:adoption_wait_timeout_ms` below their own response timeout. If the bounded
  wait expires, the facade queries TaskStore's authoritative operation state and
  returns a `"pending"` settlement receipt instead of losing the transport
  response. TaskStore remains the sole owner of settlement.
  """
  @spec adopt_task_change(String.t(), String.t(), keyword() | map()) ::
          {:ok, map()} | {:error, term()}
  def adopt_task_change(task_id, destination_ref, opts \\ []) do
    with {:ok, task_id} <- normalize_task_id(task_id),
         {:ok, status} <- task_status_unchecked(task_id, opts),
         :ok <- require_exact_task_status(task_id, status),
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_task_adopt(opts, caller_id, status),
         {:ok, destination_ref} <- normalize_destination_ref(destination_ref),
         :ok <- ensure_successful_task(status),
         store_module = task_store_module(opts),
         store_opts = task_store_opts(opts),
         store_result <-
           apply_if_exported(store_module, :adopt, [task_id, destination_ref, store_opts]),
         {:ok, result} <-
           normalize_task_adopt_result(
             store_result,
             task_id,
             destination_ref,
             store_module,
             store_opts,
             opts
           ) do
      {:ok, result}
    end
  end

  @doc """
  List pending approvals from all configured approval backends.

  Options:

    * `:caller_id` - authenticated caller for the read capability check
    * `:task_id` - exact task filter; task-scoped approval-read is tried first
    * `:agent_id` - filter by the gated agent
    * `:principal_id` - filter by gated principal or approver principal
    * `:resource_uri` - segment-aware resource URI prefix filter

  Without `:task_id`, global `arbor://approval/read` is required. With an exact
  task filter, task-scoped read is tried first, then global compatibility.

  Test and trusted in-process callers may pass `authorize?: false`, but external
  surfaces must keep authorization enabled.
  """
  @spec list_pending_approvals(keyword() | map()) ::
          {:ok, [PendingApproval.t()]} | {:error, term()}
  def list_pending_approvals(opts \\ []) do
    with {:ok, task_filter} <- optional_list_task_id_filter(opts),
         :ok <- authorize_approval_list(opts, task_filter) do
      {:ok, list_pending_approvals_unchecked(opts)}
    end
  end

  @doc """
  Return a bounded, read-only inventory of pending approvals.

  This is a volatile projection of the existing Consensus and Comms approval
  authorities. It contains only reconciliation-safe identifiers, ownership,
  lifecycle, and count evidence; it does not create or retain approval state.
  `:principal_scope` is closed to `:participant` (the default, matching either
  gated principal or approver) and `:subject` (matching only the gated
  principal).
  """
  @spec pending_approval_inventory(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def pending_approval_inventory(opts \\ []) do
    with {:ok, normalized} <- normalize_approval_inventory_options(opts),
         :ok <- authorize_approval_list(opts, normalized.filters.task_id),
         {:ok, entries, evidence} <- approval_inventory_entries(opts) do
      {:ok,
       ApprovalInventoryProjection.from_entries(
         entries,
         normalized.filters,
         normalized.max_items,
         evidence
       )}
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

  defp task_status_unchecked(task_id, opts) do
    opts
    |> task_store_module()
    |> apply_if_exported(:status, [task_id, task_store_opts(opts)])
    |> normalize_task_status_result()
  end

  defp authorize_task_inventory(%{caller_id: caller_id, filters: %{task_id: nil}}) do
    case authorize_caller([], caller_id, @task_read_uri, :read) do
      :ok -> :ok
      _ -> {:error, {:unauthorized, :task_read_required}}
    end
  end

  defp authorize_task_inventory(%{caller_id: caller_id, filters: %{task_id: task_id}}) do
    with {:ok, status} <- task_status_unchecked(task_id, []),
         :ok <- require_exact_task_status(task_id, status),
         :ok <- authorize_task_read([], caller_id, status) do
      :ok
    end
  end

  defp task_inventory_store_opts(%{filters: filters, max_items: max_items}) do
    [
      task_id: filters.task_id,
      agent_id: filters.agent_id,
      state: filters.state,
      max_items: max_items
    ]
  end

  defp normalize_task_inventory_result({:ok, inventory}) when is_map(inventory),
    do: {:ok, inventory}

  defp normalize_task_inventory_result(_result), do: {:error, :task_inventory_unavailable}

  defp normalize_approval_inventory_options(opts) when is_list(opts) or is_map(opts) do
    entries = if is_list(opts), do: opts, else: Map.to_list(opts)
    keys = Enum.map(entries, &approval_inventory_option_key/1)

    allowed = [
      :caller_id,
      :agent_id,
      :principal_id,
      :principal_scope,
      :resource_uri,
      :task_id,
      :max_items,
      :authorize?,
      :consensus_module,
      :interaction_router,
      :security_module
    ]

    cond do
      :invalid in keys or Enum.any?(keys, &(&1 not in allowed)) ->
        {:error, :invalid_approval_inventory_options}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :invalid_approval_inventory_options}

      true ->
        with {:ok, _caller_id} <- inventory_caller_id(entries),
             {:ok, task_id} <- normalize_optional_task_filter(entries),
             {:ok, agent_id} <- normalize_approval_inventory_id_filter(entries, :agent_id),
             {:ok, principal_id} <-
               normalize_approval_inventory_id_filter(entries, :principal_id),
             {:ok, principal_scope} <-
               normalize_approval_inventory_principal_scope(entries),
             {:ok, resource_uri} <- normalize_approval_inventory_resource_filter(entries),
             {:ok, max_items} <- normalize_approval_inventory_max_items(entries),
             {:ok, authorize?} <- normalize_approval_inventory_authorize(entries),
             {:ok, consensus_module} <-
               normalize_approval_inventory_module(entries, :consensus_module, Arbor.Consensus),
             {:ok, interaction_router} <-
               normalize_approval_inventory_module(
                 entries,
                 :interaction_router,
                 Module.concat([:Arbor, :Comms])
               ),
             {:ok, security_module} <-
               normalize_approval_inventory_module(entries, :security_module, Arbor.Security) do
          {:ok,
           %{
             filters: %{
               task_id: task_id,
               agent_id: agent_id,
               principal_id: principal_id,
               principal_scope: principal_scope,
               resource_uri: resource_uri
             },
             max_items: max_items,
             authorize?: authorize?,
             consensus_module: consensus_module,
             interaction_router: interaction_router,
             security_module: security_module
           }}
        else
          _ -> {:error, :invalid_approval_inventory_options}
        end
    end
  end

  defp normalize_approval_inventory_options(_opts),
    do: {:error, :invalid_approval_inventory_options}

  defp approval_inventory_option_key({key, _value}) when is_atom(key), do: key
  defp approval_inventory_option_key(_entry), do: :invalid

  defp normalize_approval_inventory_id_filter(entries, key) do
    case Keyword.get(entries, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and byte_size(value) <= @max_task_id_bytes ->
        if String.valid?(value) and value != "" and not String.contains?(value, <<0>>) do
          {:ok, value}
        else
          {:error, :invalid_approval_inventory_filter}
        end

      _ ->
        {:error, :invalid_approval_inventory_filter}
    end
  end

  defp normalize_approval_inventory_resource_filter(entries) do
    case Keyword.get(entries, :resource_uri) do
      nil ->
        {:ok, nil}

      value when is_binary(value) and byte_size(value) <= @max_task_id_bytes ->
        if CapabilityUri.valid?(value), do: {:ok, value}, else: {:error, :invalid_resource_uri}

      _ ->
        {:error, :invalid_resource_uri}
    end
  end

  defp normalize_approval_inventory_principal_scope(entries) do
    case Keyword.get(entries, :principal_scope, :participant) do
      :participant -> {:ok, :participant}
      :subject -> {:ok, :subject}
      _ -> {:error, :invalid_principal_scope}
    end
  end

  defp normalize_approval_inventory_max_items(entries) do
    case Keyword.get(entries, :max_items, @default_approval_inventory_items) do
      value when is_integer(value) and value > 0 and value <= @max_approval_inventory_items ->
        {:ok, value}

      _ ->
        {:error, :invalid_max_items}
    end
  end

  defp normalize_approval_inventory_authorize(entries) do
    case Keyword.get(entries, :authorize?, true) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :invalid_authorize_option}
    end
  end

  defp normalize_approval_inventory_module(entries, key, default) do
    case Keyword.get(entries, key, default) do
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :invalid_backend_module}
    end
  end

  defp normalize_task_inventory_options(opts) when is_list(opts) or is_map(opts) do
    entries = if is_list(opts), do: opts, else: Map.to_list(opts)
    keys = Enum.map(entries, &task_inventory_option_key/1)

    cond do
      :invalid in keys ->
        {:error, :invalid_task_inventory_options}

      Enum.any?(keys, &(&1 not in [:caller_id, :task_id, :agent_id, :state, :max_items])) ->
        {:error, :invalid_task_inventory_options}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, :invalid_task_inventory_options}

      true ->
        with {:ok, caller_id} <- inventory_caller_id(entries),
             {:ok, task_id} <- normalize_optional_task_filter(entries),
             {:ok, agent_id} <- normalize_optional_agent_filter(entries),
             {:ok, state} <- normalize_optional_state_filter(entries),
             {:ok, max_items} <- normalize_inventory_max_items(entries) do
          {:ok,
           %{
             caller_id: caller_id,
             filters: %{task_id: task_id, agent_id: agent_id, state: state},
             max_items: max_items
           }}
        else
          _ -> {:error, :invalid_task_inventory_options}
        end
    end
  end

  defp normalize_task_inventory_options(_opts), do: {:error, :invalid_task_inventory_options}

  defp task_inventory_option_key({key, _value}) when is_atom(key), do: key
  defp task_inventory_option_key(_entry), do: :invalid

  defp inventory_caller_id(entries) do
    case Keyword.get(entries, :caller_id) do
      caller_id when is_binary(caller_id) and caller_id != "" -> {:ok, caller_id}
      _ -> {:error, :caller_id_required}
    end
  end

  defp normalize_optional_task_filter(entries) do
    case Keyword.get(entries, :task_id) do
      nil -> {:ok, nil}
      task_id -> normalize_task_id(task_id)
    end
  end

  defp normalize_optional_agent_filter(entries) do
    case Keyword.get(entries, :agent_id) do
      nil ->
        {:ok, nil}

      agent_id when is_binary(agent_id) and byte_size(agent_id) <= @max_task_id_bytes ->
        if String.valid?(agent_id) and agent_id != "" and not String.contains?(agent_id, <<0>>) do
          {:ok, agent_id}
        else
          {:error, :invalid_agent_id}
        end

      _ ->
        {:error, :invalid_agent_id}
    end
  end

  defp normalize_optional_state_filter(entries) do
    case Keyword.get(entries, :state) do
      nil ->
        {:ok, nil}

      state when state in [:running, :waiting_approval, :done, :failed, :cancelled] ->
        {:ok, state}

      state when is_binary(state) ->
        case state do
          "running" -> {:ok, :running}
          "waiting_approval" -> {:ok, :waiting_approval}
          "done" -> {:ok, :done}
          "failed" -> {:ok, :failed}
          "cancelled" -> {:ok, :cancelled}
          _ -> {:error, :invalid_state}
        end

      _ ->
        {:error, :invalid_state}
    end
  end

  defp normalize_inventory_max_items(entries) do
    case Keyword.get(entries, :max_items, @default_task_inventory_items) do
      value when is_integer(value) and value > 0 and value <= @max_task_inventory_items ->
        {:ok, value}

      _ ->
        {:error, :invalid_max_items}
    end
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
      # Reject malformed/duplicate session proofs before any grant/TaskStore work.
      case security_auth_opts(opts) do
        {:error, :invalid_session_token} ->
          {:error, {:unauthorized, :invalid_session_token}}

        {:ok, _auth_opts} ->
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
  end

  defp require_exact_task_status(requested_id, status) when is_map(status) do
    case Map.get(status, :task_id) || Map.get(status, "task_id") do
      ^requested_id -> :ok
      _other -> {:error, :task_id_mismatch}
    end
  end

  defp require_exact_task_status(_requested_id, _status), do: {:error, :task_id_mismatch}

  defp authorize_task_read(opts, caller_id, status) do
    authorize_task_ladder(
      opts,
      caller_id,
      status,
      :read,
      &task_read_authorization_uris/1,
      :task_read_required
    )
  end

  defp authorize_task_cancel(opts, caller_id, status) do
    authorize_task_ladder(
      opts,
      caller_id,
      status,
      :execute,
      &task_cancel_authorization_uris/1,
      :task_cancel_required
    )
  end

  defp authorize_task_steer(opts, caller_id, status) do
    authorize_task_ladder(
      opts,
      caller_id,
      status,
      :execute,
      &task_steer_authorization_uris/1,
      :task_steer_required
    )
  end

  defp authorize_task_adopt(opts, caller_id, status) do
    authorize_task_ladder(
      opts,
      caller_id,
      status,
      :execute,
      &task_adopt_authorization_uris/1,
      :task_adoption_required
    )
  end

  defp authorize_task_ladder(opts, caller_id, status, action, uris_fun, unauthorized_reason) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      trusted_task_id = Map.get(status, :task_id) || Map.get(status, "task_id")

      status
      |> uris_fun.()
      |> Enum.find_value(fn resource_uri ->
        case authorize_caller(opts, caller_id, resource_uri, action, trusted_task_id) do
          :ok -> :ok
          _ -> nil
        end
      end)
      |> case do
        :ok -> :ok
        nil -> {:error, {:unauthorized, unauthorized_reason}}
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

  # Exact-task URIs go through TaskControlLease so grant specs and authorize
  # ladders cannot diverge. Agent-scoped ladder steps reuse the same grammar
  # (agent ids are single-segment) via the same constructors when valid.
  defp scoped_task_read_uri(id), do: lease_exact_uri(:task_read, id)
  defp scoped_task_cancel_uri(id), do: lease_exact_uri(:task_cancel, id)
  defp scoped_task_steer_uri(id), do: lease_exact_uri(:task_steer, id)
  defp scoped_task_adopt_uri(id), do: lease_exact_uri(:task_adopt, id)

  defp lease_exact_uri(kind, id) when is_binary(id) and id != "" do
    case TaskControlLease.uri(kind, id) do
      {:ok, uri} -> uri
      _ -> nil
    end
  end

  defp lease_exact_uri(_kind, _id), do: nil

  defp reject_caller_task_id(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :task_id) or List.keymember?(opts, "task_id", 0) do
      {:error, :caller_selected_task_id_rejected}
    else
      :ok
    end
  end

  defp reject_caller_task_id(opts) when is_map(opts) do
    if Map.has_key?(opts, :task_id) or Map.has_key?(opts, "task_id") do
      {:error, :caller_selected_task_id_rejected}
    else
      :ok
    end
  end

  defp reject_caller_task_id(_), do: :ok

  # Closed scalar data only — never MFA/module/function/fun/PID selection.
  # TaskStore pins cleanup MFA, backend modules, lease revoke transport, and
  # cleanup supervisor at init.
  defp approval_cleanup_descriptor(agent_id, caller_id, opts) do
    %{caller_id: caller_id, principal_id: agent_id}
    |> maybe_put_cleanup_trace_id(opt(opts, :trace_id))
  end

  defp maybe_put_cleanup_trace_id(descriptor, trace_id)
       when is_binary(trace_id) and trace_id != "" do
    Map.put(descriptor, :trace_id, trace_id)
  end

  defp maybe_put_cleanup_trace_id(descriptor, _trace_id), do: descriptor

  # reserve → durable marker ack → grant → activate (token-bound).
  defp dispatch_with_reservation_and_lease(agent_id, task, caller_id, opts) do
    store = task_store_module(opts)
    store_opts = task_store_opts(opts)

    with {:ok, %{task_id: task_id, reservation_token: token}} <-
           reserve_task_identity(store, store_opts),
         :ok <- commit_recovery_marker(store, task_id, token, store_opts) do
      case grant_task_control_lease(caller_id, task_id, opts) do
        {:ok, lease, granted} ->
          activate_opts =
            store_opts
            |> Keyword.put(:task_control_lease, lease)
            |> Keyword.put(
              :approval_cleanup_descriptor,
              approval_cleanup_descriptor(agent_id, caller_id, opts)
            )

          case activate_reserved_task(store, agent_id, task, task_id, token, activate_opts) do
            {:ok, ^task_id} ->
              case record_dispatch_result(task_id, agent_id, task, caller_id, opts) do
                :ok ->
                  {:ok, task_id}

                {:error, reason} ->
                  Logger.warning(
                    "Orchestration task dispatch audit failed after admission " <>
                      "task_id=#{bounded_inspect(task_id)} " <>
                      "reason=#{bounded_inspect(reason)}"
                  )

                  {:error,
                   {:task_control_lease_dispatch_admitted_audit_outcome_unknown,
                    %{
                      task_id: task_id,
                      uncertainty: true,
                      audit_reason: sanitize_public_reason(reason)
                    }}}
              end

            {:ok, other_task_id} ->
              case compensate_after_mint(opts, store, store_opts, task_id, token, granted) do
                {:ok, :clean} ->
                  {:error, {:task_id_mismatch, other_task_id}}

                {:uncertain, details} ->
                  {:error,
                   {:task_control_lease_dispatch_outcome_unknown,
                    Map.put(details, :dispatch_reason, :task_id_mismatch)}}
              end

            {:error, reason} = error ->
              case compensate_after_mint(opts, store, store_opts, task_id, token, granted) do
                {:ok, :clean} ->
                  error

                {:uncertain, details} ->
                  {:error,
                   {:task_control_lease_dispatch_outcome_unknown,
                    Map.merge(details, %{dispatch_reason: sanitize_public_reason(reason)})}}
              end
          end

        {:error, _} = error ->
          _ = release_reservation(store, task_id, token, store_opts)
          error
      end
    else
      {:error, _} = error ->
        error
    end
  end

  defp reserve_task_identity(store, store_opts) do
    case apply_if_exported(store, :reserve, [store_opts]) do
      {:ok, %{task_id: task_id, reservation_token: token}}
      when is_binary(task_id) and is_binary(token) ->
        {:ok, %{task_id: task_id, reservation_token: token}}

      {:error, reason} ->
        {:error, reason}

      :module_unavailable ->
        {:error, :task_store_unavailable}

      other ->
        {:error, sanitize_public_reason(other)}
    end
  end

  defp commit_recovery_marker(store, task_id, token, store_opts) do
    case apply_if_exported(store, :commit_recovery_marker, [task_id, token, store_opts]) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      :module_unavailable -> {:error, :task_store_unavailable}
      other -> {:error, sanitize_public_reason(other)}
    end
  end

  defp activate_reserved_task(store, agent_id, task, task_id, token, opts) do
    case apply_if_exported(store, :activate, [agent_id, task, task_id, token, opts]) do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, reason}
      :module_unavailable -> {:error, :task_store_unavailable}
      other -> {:error, sanitize_public_reason(other)}
    end
  end

  defp release_reservation(store, task_id, token, store_opts) do
    _ = apply_if_exported(store, :release, [task_id, token, store_opts])
    :ok
  end

  # Reverse-revoke once, then request store-owned task-scope reconcile + release.
  # Returns the reverse-revoke outcome so callers never revoke a second time.
  defp compensate_after_mint(opts, store, store_opts, task_id, token, granted) do
    revoke_outcome = compensate_reverse_revoke(opts, granted)
    _ = apply_if_exported(store, :request_reconcile, [task_id, store_opts])
    _ = release_reservation(store, task_id, token, store_opts)
    revoke_outcome
  end

  defp grant_task_control_lease(caller_id, task_id, opts) do
    now = DateTime.utc_now()

    case grant_lease_members(caller_id, task_id, opts, now, TaskControlLease.grant_order(), []) do
      {:ok, granted} ->
        kind_to_id = Map.new(granted)

        case TaskControlLease.new(task_id, kind_to_id) do
          {:ok, lease} ->
            {:ok, lease, granted}

          {:error, reason} ->
            case compensate_reverse_revoke(opts, granted) do
              {:ok, :clean} ->
                {:error,
                 {:task_control_lease_grant_failed, :lease_shape, sanitize_public_reason(reason)}}

              {:uncertain, details} ->
                {:error,
                 {:task_control_lease_grant_outcome_unknown,
                  Map.merge(details, %{
                    failed_kind: :lease_shape,
                    grant_reason: sanitize_public_reason(reason)
                  })}}
            end
        end

      {:error, _} = error ->
        error
    end
  end

  # Six sequential Security.grant/1 calls are intentional: closed least-risk-first
  # order with approval_answer last, full reverse-revoke compensation, and no
  # batch grant API in this slice (packet non-goal). Cost is ~2× the prior
  # three-member path; do not parallelize (compensation ordering) or add a
  # generic batch API without a separate design decision.
  defp grant_lease_members(_caller_id, _task_id, _opts, _now, [], granted), do: {:ok, granted}

  defp grant_lease_members(caller_id, task_id, opts, now, [kind | rest], granted) do
    with {:ok, spec} <- TaskControlLease.grant_spec(kind, caller_id, task_id, now),
         {:ok, cap_id} <- grant_one_lease_member(opts, kind, spec) do
      grant_lease_members(caller_id, task_id, opts, now, rest, granted ++ [{kind, cap_id}])
    else
      # Mint-outcome uncertainty: never report ordinary grant_failed.
      {:error, {:mint_outcome_uncertain, class}} ->
        mint_outcome_unknown_result(opts, task_id, granted, kind, class)

      {:error, :missing_capability_id} ->
        mint_outcome_unknown_result(opts, task_id, granted, kind, :missing_capability_id)

      {:error, reason} ->
        case compensate_reverse_revoke(opts, granted) do
          {:ok, :clean} ->
            _ = request_task_reconcile(opts, task_id)

            {:error, {:task_control_lease_grant_failed, kind, sanitize_public_reason(reason)}}

          {:uncertain, details} ->
            _ = request_task_reconcile(opts, task_id)

            {:error,
             {:task_control_lease_grant_outcome_unknown,
              Map.merge(details, %{
                failed_kind: kind,
                grant_reason: sanitize_public_reason(reason)
              })}}
        end
    end
  end

  defp mint_outcome_unknown_result(opts, task_id, granted, kind, class) do
    revoke_result = compensate_reverse_revoke(opts, granted)
    reconcile = request_task_reconcile(opts, task_id)

    details =
      case revoke_result do
        {:ok, :clean} ->
          %{
            uncertainty: true,
            failed_kind: kind,
            grant_reason: sanitize_public_reason(class),
            revoke_failure_kinds: [],
            revoke_failure_count: 0,
            revoke_uncertain_count: 0,
            reconciled: reconcile == :ok
          }

        {:uncertain, base} ->
          Map.merge(base, %{
            failed_kind: kind,
            grant_reason: sanitize_public_reason(class),
            reconciled: reconcile == :ok
          })
      end

    {:error, {:task_control_lease_grant_outcome_unknown, details}}
  end

  defp request_task_reconcile(opts, task_id) when is_binary(task_id) do
    store = task_store_module(opts)
    store_opts = task_store_opts(opts)

    case apply_if_exported(store, :request_reconcile, [task_id, store_opts]) do
      :ok -> :ok
      {:ok, _} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp request_task_reconcile(_opts, _task_id), do: :error

  defp grant_one_lease_member(opts, _kind, spec) do
    case invoke_lease_grant(security_module(opts), spec) do
      {:ok, capability} ->
        case value(capability, :id) do
          id when is_binary(id) and id != "" ->
            if valid_granted_capability_id?(id) do
              {:ok, id}
            else
              # Invalid id shape on a successful response is still mint uncertainty.
              {:error, :missing_capability_id}
            end

          _other ->
            {:error, :missing_capability_id}
        end

      {:error, reason} ->
        {:error, reason}

      :module_unavailable ->
        {:error, :security_unavailable}

      other ->
        {:error, other}
    end
  rescue
    _exception ->
      {:error, {:mint_outcome_uncertain, :exception}}
  catch
    :exit, _reason ->
      {:error, {:mint_outcome_uncertain, :exit}}

    :throw, _reason ->
      {:error, {:mint_outcome_uncertain, :throw}}

    _catch_kind, _reason ->
      {:error, {:mint_outcome_uncertain, :error}}
  end

  # Grant exceptions are mint-outcome uncertainty. Do not route this call
  # through apply_if_exported/3, which deliberately collapses exceptions into
  # :module_unavailable for ordinary optional integrations.
  defp invoke_lease_grant(module, spec) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :grant, 1) do
      apply(module, :grant, [spec])
    else
      :module_unavailable
    end
  end

  defp invoke_lease_grant(_module, _spec), do: :module_unavailable

  defp valid_granted_capability_id?(id)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= 256 do
    String.valid?(id) and not String.match?(id, ~r/[\x00-\x1F\x7F]/)
  end

  defp valid_granted_capability_id?(_), do: false

  # Reverse-revoke every minted capability; never stop early.
  # Returns {:ok, :clean} or {:uncertain, public_details} — never capability ids.
  defp compensate_reverse_revoke(opts, granted) when is_list(granted) do
    failures =
      granted
      |> Enum.reverse()
      |> Enum.reduce([], fn {kind, cap_id}, acc ->
        case revoke_one_lease_member(opts, cap_id) do
          :ok -> acc
          {:error, reason} -> [{kind, reason} | acc]
          :uncertain -> [{kind, :outcome_unknown} | acc]
        end
      end)
      |> Enum.reverse()

    if failures == [] do
      {:ok, :clean}
    else
      uncertain_count =
        Enum.count(failures, fn {_kind, reason} -> reason == :outcome_unknown end)

      {:uncertain,
       %{
         uncertainty: true,
         revoke_failure_kinds: Enum.map(failures, fn {kind, _} -> kind end),
         revoke_failure_count: length(failures),
         revoke_uncertain_count: uncertain_count
       }}
    end
  end

  defp revoke_one_lease_member(opts, cap_id)
       when is_binary(cap_id) and cap_id != "" do
    case opts |> security_module() |> apply_if_exported(:revoke, [cap_id]) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, :already_revoked} -> :ok
      {:error, reason} -> {:error, sanitize_public_reason(reason)}
      :module_unavailable -> :uncertain
      _other -> :uncertain
    end
  rescue
    _ -> :uncertain
  catch
    :exit, _ -> :uncertain
    _, _ -> :uncertain
  end

  defp revoke_one_lease_member(_opts, _cap_id), do: :ok

  defp sanitize_public_reason(reason) when is_atom(reason), do: reason

  defp sanitize_public_reason(reason) when is_binary(reason) do
    if String.valid?(reason) and byte_size(reason) <= 128 and
         not String.contains?(reason, "cap_") do
      reason
    else
      :invalid_reason
    end
  end

  defp sanitize_public_reason({a, b}) when is_atom(a),
    do: {a, sanitize_public_reason(b)}

  defp sanitize_public_reason(_), do: :error

  # Strict audit observation for post-admission dispatch: do not swallow errors.
  defp record_dispatch_result(task_id, agent_id, task, caller_id, opts) do
    data = [
      trace_id: opt(opts, :trace_id),
      metadata: opt(opts, :metadata),
      task_preview: task_preview(task)
    ]

    case opts
         |> audit_module()
         |> apply_if_exported(:record_orchestration_task_dispatched, [
           caller_id,
           task_id,
           agent_id,
           data
         ]) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      :module_unavailable -> {:error, :security_unavailable}
      other -> {:error, {:unexpected_audit_result, sanitize_public_reason(other)}}
    end
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
    |> Enum.filter(&matches_cleanup_principal?(&1, opt(opts, :principal_id)))
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
    |> apply_if_exported(:cancel_proposal_by_id, [id])
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

  defp approval_inventory_entries(opts) do
    with {:ok, consensus, consensus_evidence} <-
           approval_inventory_backend(
             :consensus,
             consensus_module(opts),
             :list_pending_proposals
           ),
         {:ok, interactions, interaction_evidence} <-
           approval_inventory_backend(
             :interaction,
             interaction_backend(opts),
             :pending_interactions
           ) do
      entries =
        inventory_entries(:consensus, consensus) ++ inventory_entries(:interaction, interactions)

      evidence = %{
        "max_entries" => @max_approval_inventory_backend_entries,
        "omitted" => consensus_evidence.omitted + interaction_evidence.omitted,
        "truncated" => consensus_evidence.truncated or interaction_evidence.truncated,
        "sources" => %{
          "consensus" => %{
            "observed" => consensus_evidence.observed,
            "omitted" => consensus_evidence.omitted,
            "truncated" => consensus_evidence.truncated
          },
          "interaction" => %{
            "observed" => interaction_evidence.observed,
            "omitted" => interaction_evidence.omitted,
            "truncated" => interaction_evidence.truncated
          }
        }
      }

      {:ok, entries, evidence}
    end
  end

  defp approval_inventory_backend(source, module, function) do
    case apply_if_exported(module, function, []) do
      entries when is_list(entries) ->
        {bounded, omitted} = Enum.split(entries, @max_approval_inventory_backend_entries)

        {:ok, bounded,
         %{
           observed: length(bounded),
           omitted: length(omitted),
           truncated: omitted != []
         }}

      :module_unavailable ->
        {:error, {:approval_backend_unavailable, source}}

      _other ->
        {:error, {:invalid_approval_backend_result, source}}
    end
  rescue
    _ -> {:error, {:approval_backend_unavailable, source}}
  catch
    _, _ -> {:error, {:approval_backend_unavailable, source}}
  end

  defp inventory_entries(source, entries) do
    Enum.map(entries, fn entry ->
      cond do
        not is_map(entry) ->
          {:malformed, source}

        source == :consensus and authorization_request?(entry) ->
          inventory_consensus_entry(entry)

        source == :interaction and value(entry, :kind) in [:approval, "approval"] ->
          inventory_interaction_entry(entry)

        source == :consensus and is_nil(value(entry, :topic)) ->
          {:malformed, source}

        source == :interaction and is_nil(value(entry, :kind)) ->
          {:malformed, source}

        true ->
          {:ignored, source}
      end
    end)
  end

  defp inventory_consensus_entry(proposal) do
    if inventory_backend_shape?(proposal, :consensus) do
      approval = from_consensus(proposal)
      {:approval, :consensus, approval, approval_task_id(approval)}
    else
      {:malformed, :consensus}
    end
  rescue
    _ -> {:malformed, :consensus}
  catch
    _, _ -> {:malformed, :consensus}
  end

  defp inventory_interaction_entry(interaction) do
    if inventory_backend_shape?(interaction, :interaction) do
      approval = from_interaction(interaction)
      {:approval, :interaction, approval, approval_task_id(approval)}
    else
      {:malformed, :interaction}
    end
  rescue
    _ -> {:malformed, :interaction}
  catch
    _, _ -> {:malformed, :interaction}
  end

  defp inventory_backend_shape?(entry, :consensus) do
    is_binary(value(entry, :id)) and value(entry, :id) != "" and
      is_binary(value(entry, :proposer)) and value(entry, :proposer) != "" and
      is_map(value(entry, :metadata, %{})) and is_map(value(entry, :context, %{})) and
      value(entry, :status) in [:pending, "pending", :evaluating, "evaluating"]
  end

  defp inventory_backend_shape?(entry, :interaction) do
    is_binary(value(entry, :request_id)) and value(entry, :request_id) != "" and
      is_binary(value(entry, :agent_id)) and value(entry, :agent_id) != "" and
      is_map(value(entry, :metadata, %{}))
  end

  defp all_pending_approvals(opts) do
    consensus_pending(opts) ++ interaction_pending(opts)
  end

  defp consensus_pending(opts) do
    opts
    |> consensus_module()
    |> apply_if_exported(:list_pending_proposals, [])
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

    metadata = interaction_answer_metadata(decision, caller_id, opts)

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
        |> apply_if_exported(:force_approve_proposal_by_authority, [id, caller_id])
        |> normalize_backend_result()

      true ->
        consensus
        |> apply_if_exported(:force_reject_proposal_by_authority, [id, caller_id])
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

  defp interaction_answer_metadata(decision, caller_id, opts) do
    %{
      "actor" => caller_id,
      "decision" => Atom.to_string(decision),
      "note" => opt(opts, :note),
      "answered_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> maybe_put("rework", decision == :rework)
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
    matches_task?(approval, opt(opts, :task_id)) and
      matches_agent?(approval, opt(opts, :agent_id)) and
      matches_principal?(approval, opt(opts, :principal_id)) and
      matches_resource?(approval, opt(opts, :resource_uri))
  end

  defp matches_task?(_approval, nil), do: true

  defp matches_task?(%PendingApproval{} = approval, task_id) when is_binary(task_id) do
    approval_task_id(approval) == task_id
  end

  defp matches_task?(_approval, _task_id), do: false

  defp optional_list_task_id_filter(opts) do
    case opt(opts, :task_id) do
      nil -> {:ok, nil}
      task_id -> normalize_task_id(task_id)
    end
  end

  defp authorize_approval_list(opts, nil) do
    authorize(opts, @approval_read_uri, :read)
  end

  defp authorize_approval_list(opts, task_id) when is_binary(task_id) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      with {:ok, actor} <- caller_id(opts),
           {:ok, resource} <- TaskControlLease.uri(:approval_read, task_id) do
        case authorize_caller(opts, actor, resource, :read, task_id) do
          :ok ->
            :ok

          _ ->
            authorize(opts, @approval_read_uri, :read)
        end
      end
    end
  end

  defp matches_agent?(_approval, nil), do: true
  defp matches_agent?(%PendingApproval{agent_id: agent_id}, agent_id), do: true
  defp matches_agent?(_approval, _agent_id), do: false

  defp matches_principal?(_approval, nil), do: true

  defp matches_principal?(%PendingApproval{} = approval, principal_id) do
    principal_id in [approval.principal_id, approval.approver_id]
  end

  # Listing includes approvals a principal may answer; destructive cleanup
  # binds only the principal whose operation is gated by the approval.
  defp matches_cleanup_principal?(_approval, nil), do: true

  defp matches_cleanup_principal?(
         %PendingApproval{principal_id: principal_id},
         principal_id
       ),
       do: true

  defp matches_cleanup_principal?(%PendingApproval{}, _principal_id), do: false

  defp matches_resource?(_approval, nil), do: true

  defp matches_resource?(%PendingApproval{resource_uri: resource_uri}, prefix) do
    CapabilityUri.prefix_match?(prefix, resource_uri)
  end

  defp authorize(opts, resource_uri, action) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      with {:ok, actor} <- caller_id(opts),
           {:ok, auth_opts} <- security_auth_opts(opts),
           {:ok, :authorized} <-
             opts
             |> security_module()
             |> apply_if_exported(:authorize, [
               actor,
               resource_uri,
               action,
               auth_opts
             ]) do
        :ok
      else
        {:error, :invalid_session_token} ->
          {:error, {:unauthorized, :invalid_session_token}}

        {:ok, :pending_approval, _id} ->
          {:error, {:unauthorized, :pending_approval}}

        {:error, reason} ->
          {:error, {:unauthorized, reason}}

        :module_unavailable ->
          {:error, {:unauthorized, :security_unavailable}}

        other ->
          {:error, {:unauthorized, other}}
      end
    end
  end

  defp authorize_answer(opts, caller_id, %PendingApproval{} = approval) do
    if opt(opts, :authorize?, true) == false do
      :ok
    else
      approval
      |> answer_authorization_ladder()
      |> Enum.find_value(fn {resource_uri, scope_task_id} ->
        case authorize_caller(opts, caller_id, resource_uri, :execute, scope_task_id) do
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

  # Exact task → agent → principal → global (compatibility break-glass).
  defp answer_authorization_ladder(%PendingApproval{} = approval) do
    task_scope =
      case approval_task_id(approval) do
        task_id when is_binary(task_id) ->
          case normalize_task_id(task_id) do
            {:ok, normalized} ->
              case TaskControlLease.uri(:approval_answer, normalized) do
                {:ok, uri} -> {uri, normalized}
                _ -> nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end

    # Exact → agent-scoped → principal-scoped → global.
    base = [
      {scoped_answer_uri(approval.agent_id), nil},
      {scoped_answer_uri(approval.principal_id), nil},
      {@approval_answer_uri, nil}
    ]

    ladder =
      case task_scope do
        {uri, task_id} -> [{uri, task_id} | base]
        nil -> base
      end

    ladder
    |> Enum.reject(fn {uri, _} -> is_nil(uri) end)
    |> Enum.uniq_by(fn {uri, _} -> uri end)
  end

  defp scoped_answer_uri(id) when is_binary(id) and id != "",
    do: "#{@approval_answer_uri}/#{id}"

  defp scoped_answer_uri(_), do: nil

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

  defp authorize_caller(opts, caller_id, resource_uri, action, trusted_task_id \\ nil) do
    case security_auth_opts(opts) do
      {:error, :invalid_session_token} ->
        {:error, {:unauthorized, :invalid_session_token}}

      {:ok, auth_opts} ->
        auth_opts =
          if is_binary(trusted_task_id) and trusted_task_id != "" do
            Keyword.put(auth_opts, :task_id, trusted_task_id)
          else
            auth_opts
          end

        case opts
             |> security_module()
             |> apply_if_exported(:authorize, [
               caller_id,
               resource_uri,
               action,
               auth_opts
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
  end

  # Absent vs exactly one atom/string session_token. Alias duplicates and every
  # malformed present value fail closed before grants/TaskStore/audit.
  @max_session_token_bytes 4096

  defp security_auth_opts(opts) do
    case parse_session_token_opt(opts) do
      :absent ->
        {:ok, [verify_identity: false]}

      {:ok, token} ->
        {:ok, [verify_identity: false, session_token: token]}

      {:error, :invalid_session_token} = error ->
        error
    end
  end

  defp parse_session_token_opt(opts) when is_list(opts) do
    try do
      values =
        opts
        |> Enum.filter(fn
          {k, _} when k in [:session_token, "session_token"] -> true
          _ -> false
        end)
        |> Enum.map(fn {_k, v} -> v end)

      case values do
        [] ->
          :absent

        [token]
        when is_binary(token) and byte_size(token) > 0 and
               byte_size(token) <= @max_session_token_bytes ->
          {:ok, token}

        [_invalid] ->
          {:error, :invalid_session_token}

        _duplicates ->
          {:error, :invalid_session_token}
      end
    rescue
      _ -> {:error, :invalid_session_token}
    catch
      :exit, _ -> {:error, :invalid_session_token}
    end
  end

  defp parse_session_token_opt(opts) when is_map(opts) do
    parse_session_token_opt(Map.to_list(opts))
  end

  defp parse_session_token_opt(_opts), do: :absent

  defp strip_session_tokens(opts) when is_list(opts) do
    Enum.reject(opts, fn
      {k, _} when k in [:session_token, "session_token"] -> true
      _ -> false
    end)
  end

  defp strip_session_tokens(opts) when is_map(opts) do
    opts
    |> Map.drop([:session_token, "session_token"])
  end

  defp strip_session_tokens(_opts), do: []

  defp normalize_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, :invalid_approval_id}, else: {:ok, id}
  end

  defp normalize_id(_), do: {:error, :invalid_approval_id}

  defp normalize_task_id(id)
       when is_binary(id) and byte_size(id) <= @max_task_id_bytes do
    if String.valid?(id) and Regex.match?(@task_id_pattern, id),
      do: {:ok, id},
      else: {:error, :invalid_task_id}
  end

  defp normalize_task_id(_), do: {:error, :invalid_task_id}

  defp normalize_destination_ref(destination_ref)
       when is_binary(destination_ref) and
              byte_size(destination_ref) <= @max_destination_ref_bytes do
    destination_ref = String.trim(destination_ref)

    if destination_ref != "" and String.valid?(destination_ref) and
         not String.match?(destination_ref, ~r/[\x00-\x1F\x7F]/) do
      {:ok, destination_ref}
    else
      {:error, :invalid_destination_ref}
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

  # Production facades are fixed. Executable selectors (task_store / security /
  # audit modules) are honored only behind the test double seam.
  defp task_store_module(opts) do
    if orchestration_test_doubles_allowed?() do
      opt(opts, :task_store, Arbor.Agent.Orchestration.TaskStore)
    else
      Arbor.Agent.Orchestration.TaskStore
    end
  end

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

  defp security_module(opts) do
    if orchestration_test_doubles_allowed?() do
      opt(opts, :security_module, Arbor.Security)
    else
      Arbor.Security
    end
  end

  defp audit_module(opts) do
    if orchestration_test_doubles_allowed?() do
      opt(opts, :audit_module, Arbor.Security)
    else
      Arbor.Security
    end
  end

  # Test-only seam: compile-environment gated. Runtime Application config cannot
  # enable per-call executable selectors in non-test beams. Store-start pins
  # remain the only TaskStore recovery DI path.
  @orchestration_test_doubles_compile_env Mix.env() == :test

  # Pure gate used by tests to prove compile env ∧ app flag semantics.
  @doc false
  def orchestration_test_doubles_allowed?(compile_test_env?, app_flag) do
    compile_test_env? == true and app_flag == true
  end

  defp orchestration_test_doubles_allowed? do
    app_flag =
      Application.get_env(:arbor_agent, :allow_orchestration_test_doubles, true) == true

    orchestration_test_doubles_allowed?(@orchestration_test_doubles_compile_env, app_flag)
  end

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

  defp normalize_task_status_result({:ok, status}) when is_map(status) do
    normalized = %{
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
    }

    case value(status, :outcome, :__missing__) do
      :__missing__ ->
        {:ok, normalized}

      nil ->
        {:ok, normalized}

      outcome ->
        case TaskOutcome.validate_registered(outcome) do
          {:ok, outcome} -> {:ok, Map.put(normalized, :outcome, TaskOutcome.to_map(outcome))}
          {:error, reason} -> {:error, {:invalid_task_status_outcome, reason}}
        end
    end
  end

  defp normalize_task_status_result({:error, _} = error), do: error
  defp normalize_task_status_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_status_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_result({:ok, result}) do
    case normalize_terminal_envelope_result(result) do
      {:ok, envelope} -> {:ok, envelope}
      {:error, reason} -> {:error, reason}
      :not_an_envelope -> {:ok, TaskArtifacts.normalize(result)}
    end
  end

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

  defp normalize_task_adopt_result(
         {:error, :task_adoption_wait_timeout},
         task_id,
         destination_ref,
         store_module,
         store_opts,
         opts
       ) do
    if opt(opts, :reconcile_adoption_timeout, false) == true do
      store_module
      |> apply_if_exported(:adoption_status, [task_id, destination_ref, store_opts])
      |> normalize_task_adoption_reconciliation(task_id, destination_ref)
    else
      {:error, :task_adoption_wait_timeout}
    end
  end

  defp normalize_task_adopt_result(
         result,
         _task_id,
         _destination_ref,
         _store_module,
         _store_opts,
         _opts
       ),
       do: normalize_settled_task_adopt_result(result)

  defp normalize_task_adoption_reconciliation(
         {:ok, :pending},
         task_id,
         destination_ref
       ) do
    {:ok,
     %{
       task_id: task_id,
       destination_ref: destination_ref,
       settlement_status: :pending
     }}
  end

  defp normalize_task_adoption_reconciliation(
         {:ok, {:settled, result}},
         _task_id,
         _destination_ref
       ),
       do: normalize_settled_task_adopt_result({:ok, result})

  defp normalize_task_adoption_reconciliation(
         {:ok, {:failed, reason}},
         _task_id,
         _destination_ref
       ),
       do: {:error, {:task_adoption_failed, reason}}

  defp normalize_task_adoption_reconciliation(
         {:ok, :not_started},
         _task_id,
         _destination_ref
       ),
       do: {:error, :task_adoption_not_admitted}

  defp normalize_task_adoption_reconciliation(
         {:error, _reason} = error,
         _task_id,
         _destination_ref
       ),
       do: error

  defp normalize_task_adoption_reconciliation(
         :module_unavailable,
         _task_id,
         _destination_ref
       ),
       do: {:error, :task_store_unavailable}

  defp normalize_task_adoption_reconciliation(other, _task_id, _destination_ref),
    do: {:error, {:unexpected_task_adoption_status, other}}

  defp normalize_settled_task_adopt_result({:ok, result}) do
    case normalize_terminal_envelope_result(result) do
      {:ok, _envelope} -> {:error, :task_not_adoptable}
      {:error, reason} -> {:error, reason}
      :not_an_envelope -> {:ok, TaskArtifacts.normalize(result)}
    end
  end

  defp normalize_settled_task_adopt_result({:error, _} = error), do: error

  defp normalize_settled_task_adopt_result(:module_unavailable),
    do: {:error, :task_store_unavailable}

  defp normalize_settled_task_adopt_result(other),
    do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_state(state)
       when state in [:running, :waiting_approval, :done, :failed, :cancelled],
       do: state

  defp normalize_task_state("running"), do: :running
  defp normalize_task_state("waiting_approval"), do: :waiting_approval
  defp normalize_task_state("done"), do: :done
  defp normalize_task_state("failed"), do: :failed
  defp normalize_task_state("cancelled"), do: :cancelled
  defp normalize_task_state(_state), do: :running

  defp ensure_successful_task(%{state: :done}), do: :ok
  defp ensure_successful_task(%{state: state}), do: {:error, {:task_not_adoptable, state}}

  defp normalize_terminal_envelope_result(result) when is_map(result) and not is_struct(result) do
    if envelope_shaped?(result) do
      case TaskTerminalEnvelope.normalize(result) do
        {:ok, envelope} -> {:ok, envelope}
        {:error, reason} -> {:error, reason}
      end
    else
      :not_an_envelope
    end
  end

  defp normalize_terminal_envelope_result(_result), do: :not_an_envelope

  # `version` also appears in ordinary coding payloads. The terminal state and
  # prior outcome are envelope-specific markers, so they are the only fields
  # used to decide whether malformed terminal data must fail closed.
  defp envelope_shaped?(result) do
    Map.has_key?(result, :terminal_state) or
      Map.has_key?(result, "terminal_state") or
      Map.has_key?(result, :prior_outcome) or
      Map.has_key?(result, "prior_outcome")
  end

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

  # Mixed atom/string option lists are valid for session_token alias support.
  # Never use Keyword.* on mixed lists — Keyword.get/3 raises on non-atom keys
  # in the list (Applied Learning: Elixir Keyword APIs require atom keys).
  # Atom-first, then string-key fallback via List.keyfind/3 only.
  defp opt(opts, key, default) when is_list(opts) and is_atom(key) do
    case List.keyfind(opts, key, 0) do
      {^key, value} ->
        value

      nil ->
        string_key = Atom.to_string(key)

        case List.keyfind(opts, string_key, 0) do
          {^string_key, value} -> value
          nil -> default
        end
    end
  end

  defp opt(opts, key, default) when is_map(opts) and is_atom(key) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp opt(_opts, _key, default), do: default

  defp task_store_opts(opts) when is_list(opts), do: strip_session_tokens(opts)

  defp task_store_opts(opts) when is_map(opts),
    do: opts |> strip_session_tokens() |> Map.to_list()

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
