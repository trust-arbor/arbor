defmodule Arbor.Voice.Test.ConversationSecurityFixture do
  @moduledoc false

  # Reviewed, test-only authority for lifecycle/presentation fixtures. Real
  # security regressions select Arbor.Security and provision actual identities,
  # capabilities and tokens instead. No public Voice option selects this seam.
  def install do
    prior = Application.fetch_env(:arbor_voice, :security_module)
    Application.put_env(:arbor_voice, :security_module, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbor_voice, :security_module, value)
        :error -> Application.delete_env(:arbor_voice, :security_module)
      end
    end)
  end

  def authorize_and_issue_conversation_receipt(subject, resource, :chat, session_token: token)
      when is_binary(token) and byte_size(token) > 0,
      do: {:ok, {:fixture_receipt, subject, resource}}

  def conversation_receipt_owner({:fixture_receipt, subject, resource}, subject, target) do
    if resource == "arbor://chat/agent/" <> target,
      do: {:ok, subject},
      else: {:error, :unauthorized}
  end

  def consume_delivery_receipt({:fixture_receipt, subject, resource}, resource, :chat),
    do: {:ok, subject}

  def discard_delivery_receipt(_), do: :ok

  def recheck_conversation_session(subject, _agent, subject, token) when is_binary(token),
    do: {:ok, :authorized}

  defdelegate authorize(a, b, c, d), to: Arbor.Security
  defdelegate authorize_and_issue_delivery_receipt(a, b, c, d), to: Arbor.Security
  defdelegate grant_capability_id(opts), to: Arbor.Security
  defdelegate issue_disclosure_capability_id(opts), to: Arbor.Security
  defdelegate revoke(id), to: Arbor.Security
  defdelegate uri_registered?(uri), to: Arbor.Security
  defdelegate validate_disclosure_capability(a, b, c), to: Arbor.Security
end
