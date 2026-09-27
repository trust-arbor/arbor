defmodule Arbor.Comms.ConversationRead do
  @moduledoc false

  alias Arbor.Comms.Config

  @doc """
  Read one authenticated principal's canonical private user conversation.

  This is the trusted-owner half of the boundary. `verified_principal` must
  come from the caller's authentication receipt, never a request's routing
  fields. The public Agent facade authenticates and authorizes each request
  before calling this function. No principal override, engagement id, session
  id or collaborator module is accepted in `opts`.

  Returns a text-only legacy transcript page. Its aggregate entry-ordinal
  cursor is independent of the conversation command journal's event cursor.
  """
  @spec read_user_conversation_page(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def read_user_conversation_page(agent_id, verified_principal, opts \\ []) do
    persistence = Config.conversation_persistence_module()

    with {:ok, _bounds} <- persistence.normalize_conversation_page_options(opts),
         {:ok, engagement} <-
           Arbor.Comms.resolve_user_engagement(agent_id, verified_principal),
         {:ok, page} <- persistence.read_conversation_page(agent_id, engagement.id, opts) do
      {:ok, Map.put(page, :engagement_id, engagement.id)}
    else
      {:error, reason}
      when reason in [
             :invalid_options,
             :invalid_identifier,
             :invalid_cursor,
             :invalid_transcript,
             :page_too_large,
             :conversation_unavailable,
             :invalid_engagement,
             :engagement_unavailable
           ] ->
        {:error, reason}

      {:error, {:invalid_id, _, _}} ->
        {:error, :invalid_identifier}

      _ ->
        {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end
end
