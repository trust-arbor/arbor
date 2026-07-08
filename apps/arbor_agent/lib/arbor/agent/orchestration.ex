defmodule Arbor.Agent.Orchestration do
  @moduledoc """
  Shared agent orchestration interface.

  Slice 1 intentionally wraps the existing approval backends:

    * `Arbor.Consensus` authorization proposals
    * `Arbor.Comms.InteractionRouter` approval requests, when available

  The module does not own approval state. It normalizes, filters, and answers
  requests held by those systems.
  """

  alias Arbor.Agent.Orchestration.PendingApproval
  alias Arbor.Contracts.Security.CapabilityUri

  @approval_read_uri "arbor://approval/read"
  @approval_answer_uri "arbor://approval/answer"
  @dispatch_uri "arbor://agent/dispatch"
  @task_read_uri "arbor://agent/task/read"
  @interaction_request_prefix "irq"

  @type approval_decision :: :approve | :deny | :rework

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
         {:ok, caller_id} <- caller_id(opts),
         :ok <- authorize_dispatch(opts, caller_id, agent_id),
         {:ok, task_id} <- dispatch_task(agent_id, task, opts),
         :ok <- record_dispatch(task_id, agent_id, task, caller_id, opts) do
      {:ok, task_id}
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

  defp enrich_waiting_approval(%{state: :running, agent_id: agent_id} = status, opts)
       when is_binary(agent_id) do
    case list_pending_approvals_unchecked(Map.put(normalize_opts(opts), :agent_id, agent_id)) do
      [%PendingApproval{id: approval_id} | _] ->
        status
        |> Map.put(:state, :waiting_approval)
        |> Map.put(:waiting_on, approval_id)

      [] ->
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

  defp task_read_authorization_uris(status) do
    [
      scoped_task_read_uri(Map.get(status, :task_id)),
      scoped_task_read_uri(Map.get(status, :agent_id)),
      @task_read_uri
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
    |> interaction_router()
    |> apply_if_exported(:pending, [])
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
    |> interaction_router()
    |> apply_if_exported(:respond, [id, response, metadata])
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

  defp interaction_router(opts) do
    opt(opts, :interaction_router, Module.concat([:Arbor, :Comms, :InteractionRouter]))
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
       metadata: value(status, :metadata, %{}) || %{}
     }}
  end

  defp normalize_task_status_result({:error, _} = error), do: error
  defp normalize_task_status_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_status_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_result({:ok, result}) when is_map(result), do: {:ok, result}

  defp normalize_task_result({:ok, result}),
    do: {:ok, %{result_type: :value, payload: %{value: result}, raw: result}}

  defp normalize_task_result({:error, _} = error), do: error
  defp normalize_task_result(:module_unavailable), do: {:error, :task_store_unavailable}
  defp normalize_task_result(other), do: {:error, {:unexpected_task_store_result, other}}

  defp normalize_task_state(state) when state in [:running, :waiting_approval, :done, :failed],
    do: state

  defp normalize_task_state("running"), do: :running
  defp normalize_task_state("waiting_approval"), do: :waiting_approval
  defp normalize_task_state("done"), do: :done
  defp normalize_task_state("failed"), do: :failed
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
