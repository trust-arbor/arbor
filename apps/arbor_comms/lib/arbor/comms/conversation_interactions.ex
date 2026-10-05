defmodule Arbor.Comms.ConversationInteractions do
  @moduledoc false

  alias Arbor.Comms.{InteractionRegistry, InteractionRouter}
  alias Arbor.Comms.InteractionRegistry.Authority

  def request_payload(operation, caller, target, input, expected),
    do:
      Arbor.Comms.ConversationInteractionsCore.request_payload(
        operation,
        caller,
        target,
        input,
        expected
      )

  def open_source(binding, session_pid, generation),
    do: Authority.open_conversation_source(binding, session_pid, generation)

  def retire_source(handle, reason), do: Authority.retire_conversation_source(handle, reason)

  # Scoped Agent reads own delivery; the legacy adapter router has no fresh
  # conversation ownership proof and must never render these records.
  def request(handle, spec, timeout_ms),
    do: Authority.request_conversation_interaction(handle, spec, timeout_ms)

  def list(scope, command_id), do: Authority.conversation_interactions(scope, command_id)

  def respond(scope, operation, actor_id, proof) do
    case InteractionRegistry.respond_conversation(scope, operation, actor_id, proof) do
      {:ok, interaction, response, metadata} ->
        InteractionRouter.publish_conversation_response(interaction, response, metadata)
        {:ok, %{request_id: operation.request_id, status: :responded}}

      {:error, _} = error ->
        error

      _ ->
        {:error, :not_found}
    end
  end
end
