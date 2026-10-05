defmodule Arbor.Agent.ConversationInteractions do
  @moduledoc false

  alias Arbor.Agent.MessageFacade
  alias Arbor.Contracts.Comms.Engagement

  @operations [:interactions, :interaction_choice, :interaction_approval]
  @option_keys [:session_token, :signed_request, :expected_engagement_id, :timeout]
  @public_errors [
    :invalid_opts,
    :invalid_interaction_answer,
    :invalid_caller_id,
    :invalid_agent_id,
    :invalid_timeout,
    :unauthorized,
    :unsupported_conversation_capability,
    :conversation_scope_changed,
    :conversation_unavailable,
    :approval_answer_required,
    :not_found,
    :already_responded,
    :expired,
    :source_lost,
    :invalid_choice,
    :stale_interaction,
    :page_too_large
  ]

  def run(operation, caller, target, input, opts) do
    with {:ok, auth_opts, expected} <- validate_options(operation, opts),
         {:ok, payload} <- request_payload(operation, caller, target, input, expected) do
      MessageFacade.with_authenticated_operation_receipt(
        caller,
        target,
        payload,
        auth_opts,
        fn ownership ->
          with {:ok, scope} <- resolve_scope(ownership.canonical_owner_id, target),
               :ok <- check_fence(scope, expected),
               :ok <- recheck(caller, scope),
               {:ok, result} <-
                 dispatch(operation, scope, caller, input, payload, ownership, opts, expected),
               result = public_response(operation, result, scope, input),
               :ok <- recheck(caller, scope),
               {:ok, ^scope} <- resolve_scope(ownership.canonical_owner_id, target),
               true <- byte_size(Jason.encode!(result)) <= 131_072 do
            {:ok, result}
          else
            false -> {:error, :page_too_large}
            {:error, _} = error -> error
            _ -> {:error, :conversation_unavailable}
          end
        end
      )
      |> normalize()
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  # The transport can correlate even an empty prompt list with the requested
  # command and pinned engagement. These fields come from the authenticated
  # host scope and the operation accepted by Authority, never renderer state.
  defp public_response(:interactions, result, scope, command_id) do
    Map.merge(result, %{engagement_id: scope.engagement_id, command_id: command_id})
  end

  defp public_response(operation, result, scope, input)
       when operation in [:interaction_choice, :interaction_approval] do
    Map.merge(result, %{
      engagement_id: scope.engagement_id,
      command_id: input.command_id,
      operation_id: input.operation_id,
      revision: input.revision
    })
  end

  def request_payload(operation, caller, target, input, expected),
    do:
      Arbor.Comms.conversation_interaction_request_payload(
        operation,
        caller,
        target,
        input,
        expected
      )

  defp validate_options(operation, opts) do
    with true <- operation in @operations,
         true <- is_list(opts) and Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.all?(keys, &(&1 in @option_keys)),
         true <- Keyword.has_key?(opts, :session_token) != Keyword.has_key?(opts, :signed_request),
         true <- operation != :interaction_approval or Keyword.has_key?(opts, :session_token),
         expected = Keyword.get(opts, :expected_engagement_id),
         true <-
           not Keyword.has_key?(opts, :expected_engagement_id) or
             (is_binary(expected) and Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, expected)) do
      {:ok, opts, expected}
    else
      _ -> {:error, :invalid_opts}
    end
  end

  defp dispatch(:interactions, scope, caller, command_id, payload, ownership, _opts, expected) do
    with {:ok,
          %{
            principal_id: ^caller,
            canonical_owner_id: owner,
            expected_engagement_id: ^expected
          }} <-
           Arbor.Security.consume_conversation_operation_receipt(
             ownership.receipt,
             "arbor://chat/agent/" <> scope.agent_id,
             payload
           ),
         true <- owner == scope.principal_id do
      Arbor.Comms.conversation_interactions(scope, command_id)
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp dispatch(operation, scope, caller, input, _payload, ownership, opts, expected)
       when operation in [:interaction_choice, :interaction_approval] do
    proof = %{receipt: ownership.receipt, expected_engagement_id: expected}

    proof =
      if operation == :interaction_approval,
        do: Map.put(proof, :session_token, Keyword.fetch!(opts, :session_token)),
        else: proof

    Arbor.Comms.respond_conversation_interaction(scope, input, caller, proof)
  end

  defp resolve_scope(owner, target) do
    case Arbor.Comms.resolve_user_engagement(target, owner) do
      {:ok,
       %Engagement{
         id: id,
         agent_id: ^target,
         owner_tenant: ^owner,
         scope: :user,
         visibility: :private
       }} ->
        {:ok, %{principal_id: owner, agent_id: target, engagement_id: id}}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp check_fence(_scope, nil), do: :ok
  defp check_fence(%{engagement_id: expected}, expected), do: :ok
  defp check_fence(_, _), do: {:error, :conversation_scope_changed}

  defp recheck(caller, scope) do
    case Arbor.Security.recheck_conversation_owner(caller, scope.agent_id, scope.principal_id) do
      {:ok, :authorized} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp normalize({:ok, result}) when is_map(result), do: {:ok, result}
  defp normalize({:error, reason}) when reason in @public_errors, do: {:error, reason}
  defp normalize(_), do: {:error, :conversation_unavailable}
end
