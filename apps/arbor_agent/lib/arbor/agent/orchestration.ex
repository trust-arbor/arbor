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
  @interaction_request_prefix "irq"

  @type approval_decision :: :approve | :deny | :rework

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

  defp maybe_put(map, _key, false), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc false
  @spec interaction_request_id?(String.t()) :: boolean()
  def interaction_request_id?(id) when is_binary(id),
    do: String.starts_with?(id, @interaction_request_prefix)

  def interaction_request_id?(_), do: false
end
