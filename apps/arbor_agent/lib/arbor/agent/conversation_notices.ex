defmodule Arbor.Agent.ConversationNotices do
  @moduledoc false
  @options [:session_token, :signed_request, :expected_engagement_id, :before, :through, :limit]
  @errors [
    :invalid_notice_options,
    :unauthorized,
    :notice_subject_required,
    :unsupported_conversation_capability,
    :not_found,
    :conversation_scope_changed,
    :conversation_unavailable,
    :page_too_large
  ]
  def request_payload(subject, target, opts) do
    with {:ok, _auth, page, expected} <- options(opts) do
      Arbor.Security.conversation_notice_read_request_payload(subject, target, page, expected)
    end
  end

  def read(subject, target, opts) do
    with {:ok, auth, page, expected} <- options(opts),
         {:ok, payload} <-
           Arbor.Security.conversation_notice_read_request_payload(
             subject,
             target,
             page,
             expected
           ) do
      Arbor.Security.with_authenticated_conversation_notice_read(
        subject,
        target,
        payload,
        auth,
        fn owner, release ->
          with {:ok, scope} <-
                 Arbor.Comms.existing_user_conversation_scope(target, owner, expected),
               {:ok, result} <- Arbor.Comms.conversation_notice_page(scope, page),
               {:ok, ^scope} <-
                 Arbor.Comms.existing_user_conversation_scope(target, owner, expected),
               :ok <- release.(scope, result) do
            {:ok, result}
          else
            {:error, reason} when reason in @errors -> {:error, reason}
            _ -> {:error, :conversation_unavailable}
          end
        end
      )
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in @options)),
         {:ok, expected} <- Keyword.fetch(opts, :expected_engagement_id) do
      {:ok, Keyword.take(opts, [:session_token, :signed_request, :expected_engagement_id]),
       Keyword.take(opts, [:before, :through, :limit]), expected}
    else
      _ -> {:error, :invalid_notice_options}
    end
  rescue
    _ -> {:error, :invalid_notice_options}
  end
end
