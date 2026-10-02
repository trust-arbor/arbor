defmodule Arbor.Security.ConversationSession do
  @moduledoc false

  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  alias Arbor.Security.SessionToken

  @ttl_seconds 90
  @failure {:error, :unauthorized}

  def request_payload(principal, target) do
    if valid_id?(principal, ~r/\Ahuman_[A-Za-z0-9_-]+\z/) and
         valid_id?(target, ~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/) do
      Jason.encode(["arbor.conversation.session", 1, principal, target, @ttl_seconds])
    else
      @failure
    end
  end

  # Possession of an exact fresh signed session request is the authentication
  # boundary. This does not create an identity or a capability. Subsequent
  # conversation admission/rechecks still enforce the current subject's grants.
  def issue(principal, target, proof) do
    with {:ok, payload} <- request_payload(principal, target),
         {:ok, signed} <- SignedRequest.canonicalize(proof),
         true <- signed.agent_id == principal and signed.payload == payload,
         resource = "arbor://chat/agent/" <> target,
         {:ok, receipt} <-
           Security.authorize_and_issue_conversation_receipt(principal, resource, :chat,
             signed_request: signed
           ) do
      try do
        with {:ok, owner} <- Security.conversation_receipt_owner(receipt, principal, target),
             {:ok, ^principal} <- Security.consume_delivery_receipt(receipt, resource, :chat),
             {:ok, token} <- SessionToken.generate_conversation(principal, target),
             {:ok, :authorized} <-
               Security.recheck_conversation_session(principal, target, owner, token) do
          {:ok, token}
        else
          _ -> @failure
        end
      after
        Security.discard_delivery_receipt(receipt)
      end
    else
      _ -> @failure
    end
  rescue
    _ -> @failure
  catch
    _, _ -> @failure
  end

  defp valid_id?(id, pattern) when is_binary(id) and byte_size(id) in 1..256,
    do: String.valid?(id) and Regex.match?(pattern, id)

  defp valid_id?(_, _), do: false
end
