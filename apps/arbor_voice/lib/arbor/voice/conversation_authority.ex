defmodule Arbor.Voice.ConversationAuthority do
  @moduledoc false

  alias Arbor.Voice.Redacted

  @error {:error, :conversation_unauthorized}
  @engagement_id ~r/\Aeng_[0-9a-f]{32}\z/

  # Authentication belongs to the conversation, independently of whether the
  # selected backend sends bytes off host. Proof and collaborator selectors are
  # retained only inside this redacted, immutable source-owned binding.
  def admit(config, pinned \\ nil) do
    with %Redacted{} = proof <- Map.get(config, :session_token),
         token when is_binary(token) <- Redacted.value(proof),
         true <- byte_size(token) in 1..4096,
         {:ok, receipt} <-
           config.security_module.authorize_and_issue_conversation_receipt(
             config.user_id,
             resource(config.agent_id),
             :chat,
             session_token: token
           ) do
      try do
        with {:ok, owner} <-
               config.security_module.conversation_receipt_owner(
                 receipt,
                 config.user_id,
                 config.agent_id
               ),
             {:ok, engagement_id} <- engagement(config, owner),
             binding = %{
               authenticated_principal_id: config.user_id,
               canonical_owner_id: owner,
               agent_id: config.agent_id,
               engagement_id: engagement_id,
               session_token: token,
               security_module: config.security_module,
               comms: config.comms,
               engagement_store: config.engagement_store
             },
             true <- same_binding?(pinned, binding),
             {:ok, subject} <-
               config.security_module.consume_delivery_receipt(
                 receipt,
                 resource(config.agent_id),
                 :chat
               ),
             true <- subject == config.user_id,
             redacted = Redacted.new(binding),
             :ok <- recheck(redacted) do
          {:ok, redacted}
        else
          _ -> @error
        end
      after
        discard(config.security_module, receipt)
      end
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def admit_turn(%Redacted{} = pinned) do
    binding = Redacted.value(pinned)

    config = %{
      user_id: binding.authenticated_principal_id,
      agent_id: binding.agent_id,
      session_token: Redacted.new(binding.session_token),
      security_module: binding.security_module,
      comms: binding.comms,
      engagement_store: binding.engagement_store
    }

    case admit(config, pinned) do
      {:ok, _same_binding} -> :ok
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def admit_turn(_), do: @error

  def recheck(%Redacted{} = redacted) do
    binding = Redacted.value(redacted)

    with {:ok, :authorized} <-
           binding.security_module.recheck_conversation_session(
             binding.authenticated_principal_id,
             binding.agent_id,
             binding.canonical_owner_id,
             binding.session_token
           ),
         {:ok, engagement_id} <- engagement(binding, binding.canonical_owner_id),
         true <- engagement_id == binding.engagement_id do
      :ok
    else
      _ -> @error
    end
  rescue
    _ -> @error
  catch
    _, _ -> @error
  end

  def recheck(_), do: @error

  defp engagement(config, owner) do
    opts = if config.engagement_store, do: [engagement_store: config.engagement_store], else: []

    case config.comms.resolve_user_engagement(config.agent_id, owner, opts) do
      {:ok,
       %{
         id: id,
         agent_id: agent_id,
         owner_tenant: ^owner,
         scope: :user,
         visibility: :private
       }}
      when agent_id == config.agent_id and is_binary(id) ->
        if Regex.match?(@engagement_id, id), do: {:ok, id}, else: @error

      _ ->
        @error
    end
  end

  defp same_binding?(nil, _binding), do: true
  defp same_binding?(%Redacted{} = pinned, binding), do: Redacted.value(pinned) == binding
  defp same_binding?(_, _), do: false

  defp resource(agent_id), do: "arbor://chat/agent/" <> agent_id

  defp discard(security, receipt) do
    security.discard_delivery_receipt(receipt)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
