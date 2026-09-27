defmodule Arbor.Agent.ConversationFacade do
  @moduledoc false

  # Opt-in delivery journal, not another Session or execution engine. All
  # collaborators on production entries are fixed public facades. The explicit
  # run_with/6 seam exists only for isolated tests, never in public options.
  alias Arbor.Agent.{Config, MessageFacade}
  alias Arbor.Contracts.Comms.Engagement
  alias Arbor.Contracts.Pipeline.Response
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Contracts.Session.UserMessage

  @proof_keys [:session_token, :signed_request]
  @max_text_bytes 32_768
  @max_reply_bytes 131_072
  @id_pattern ~r/\A[A-Za-z0-9_-]{1,128}\z/
  @unknown %{status: :uncertain, reason: :delivery_unknown}
  @public_errors [
    :invalid_opts,
    :invalid_timeout,
    :invalid_caller_id,
    :invalid_agent_id,
    :invalid_message,
    :invalid_content,
    :invalid_sender,
    :invalid_engagement_id,
    :invalid_command,
    :invalid_cursor,
    :unauthorized,
    :unsupported_conversation_capability,
    :not_found,
    :command_conflict,
    :conversation_unavailable,
    :conversation_scope_changed,
    :page_too_large
  ]

  def run(operation, caller, target, input, opts) do
    run_with(operation, caller, target, input, opts, production_collaborators())
  end

  @doc false
  def run_with(operation, caller, target, input, opts, collaborators) do
    result =
      with {:ok, auth_opts, page_opts, expected_engagement} <- validate_opts(operation, opts),
           :ok <- validate_input(operation, input),
           :ok <-
             bind_signed_request(
               operation,
               caller,
               target,
               input,
               page_opts,
               expected_engagement,
               auth_opts
             ) do
        message =
          if operation == :submit do
            %{UserMessage.from_string(input.text) | sender_id: caller}
          end

        collaborators.authenticate.(caller, target, message, auth_opts, fn ownership ->
          with {:ok, scope} <- resolve_scope(collaborators, ownership.canonical_owner_id, target),
               :ok <- check_engagement_fence(scope, expected_engagement),
               :ok <- currently_authorized(scope, ownership, collaborators) do
            dispatch(operation, scope, input, page_opts, ownership, collaborators)
          end
        end)
      end

    normalize_result(result)
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  @doc false
  def request_payload(operation, caller, target, input, opts) do
    with true <- operation in [:submit, :command, :events, :history],
         true <- valid_principal?(caller) and valid_principal?(target),
         {:ok, _auth, page, expected_engagement} <- validate_opts(operation, opts),
         :ok <- validate_input(operation, input) do
      {:ok, encode_request(operation, caller, target, input, page, expected_engagement)}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_command}
    end
  rescue
    _ -> {:error, :invalid_command}
  end

  defp bind_signed_request(operation, caller, target, input, page, expected_engagement, auth_opts) do
    case Keyword.fetch(auth_opts, :signed_request) do
      :error ->
        :ok

      {:ok, %SignedRequest{agent_id: ^caller, payload: payload}} ->
        if payload == encode_request(operation, caller, target, input, page, expected_engagement),
          do: :ok,
          else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp encode_request(operation, caller, target, input, page, expected_engagement) do
    normalized = if operation == :submit, do: [input.id, input.text], else: input

    Jason.encode!([
      "arbor.conversation.v2",
      Atom.to_string(operation),
      caller,
      target,
      normalized,
      [Keyword.get(page, :after), Keyword.get(page, :through), Keyword.get(page, :limit)],
      expected_engagement
    ])
  end

  # Compare-only continuity fence: a client cannot select an engagement or gain
  # authority by naming one. Ownership is always resolved through Security first.
  defp check_engagement_fence(_scope, nil), do: :ok
  defp check_engagement_fence(%{engagement_id: id}, id), do: :ok
  defp check_engagement_fence(_, _), do: {:error, :conversation_scope_changed}

  defp valid_principal?(id) when is_binary(id) and byte_size(id) in 1..256,
    do: String.valid?(id) and Regex.match?(~r/\A(?:agent|human)_[A-Za-z0-9_-]+\z/, id)

  defp valid_principal?(_), do: false

  # Successful payloads come only from fixed Comms projection functions, which
  # validate stored journal/history records and exclude claim tokens and private
  # source metadata. Do not expose arbitrary backend errors through this API.
  defp normalize_result({:ok, value}) when is_map(value), do: {:ok, value}

  defp normalize_result({:error, reason}) when reason in [:invalid_options, :invalid_identifier],
    do: {:error, :invalid_opts}

  defp normalize_result({:error, reason}) when reason in @public_errors, do: {:error, reason}
  defp normalize_result(_), do: {:error, :conversation_unavailable}

  defp production_collaborators do
    %{
      authenticate: &MessageFacade.with_authenticated_receipt/5,
      resolve: &Arbor.Comms.resolve_user_engagement/2,
      recheck: &Arbor.Security.recheck_conversation_owner/3,
      admit: &Arbor.Comms.admit_conversation_command/2,
      get: &Arbor.Comms.get_conversation_command/2,
      claim: &Arbor.Comms.claim_conversation_command/2,
      settle: &Arbor.Comms.settle_conversation_command/4,
      events: &Arbor.Comms.conversation_events/3,
      history: &Arbor.Comms.read_user_conversation_page/3,
      start_worker: fn work ->
        Task.Supervisor.start_child(Config.conversation_task_supervisor(), work)
      end
    }
  end

  defp dispatch(:submit, scope, command, _page, ownership, collaborators) do
    case collaborators.admit.(scope, command) do
      {:ok, admitted} ->
        if admitted.status == :admitted do
          work = fn -> execute(scope, command.id, ownership, collaborators) end

          case collaborators.start_worker.(work) do
            {:ok, _pid} ->
              # Receipt lifetime now belongs to the worker, even if publication
              # is denied after a concurrent revocation or the caller disappears.
              {:handoff, release({:ok, admitted}, scope, ownership, collaborators)}

            _ ->
              # No claim or dispatch has occurred. A later authenticated retry
              # may safely start the still-admitted command.
              {:error, :conversation_unavailable}
          end
        else
          release({:ok, admitted}, scope, ownership, collaborators)
        end

      error ->
        release(error, scope, ownership, collaborators)
    end
  end

  defp dispatch(:command, scope, id, _page, ownership, collaborators),
    do: release(collaborators.get.(scope, id), scope, ownership, collaborators)

  defp dispatch(:events, scope, cursor, page, ownership, collaborators) do
    result =
      case collaborators.events.(scope, cursor, page) do
        {:ok, events} when is_map(events) ->
          {:ok, Map.put(events, :engagement_id, scope.engagement_id)}

        error ->
          error
      end

    release(result, scope, ownership, collaborators)
  end

  defp dispatch(:history, scope, _input, page, ownership, collaborators) do
    result = collaborators.history.(scope.agent_id, scope.principal_id, page)
    release(result, scope, ownership, collaborators)
  end

  defp execute(scope, id, ownership, collaborators) do
    # Never verify a signed nonce twice. These source-owned checks follow
    # fresh cryptographic authentication and recheck live identity/capability.
    with :ok <- currently_authorized(scope, ownership, collaborators),
         {:ok, token} <- collaborators.claim.(scope, id) do
      outcome =
        case currently_authorized(scope, ownership, collaborators) do
          :ok -> delivery_outcome(ownership.deliver)
          _ -> @unknown
        end

      # Delivery may outlive an unlink/revocation. A claimed command is never
      # retried automatically, but revoked output must not become a completed
      # journal projection under the old private scope.
      outcome =
        if currently_authorized(scope, ownership, collaborators) == :ok,
          do: outcome,
          else: @unknown

      settle(scope, id, token, outcome, collaborators)
    end
  after
    ownership.discard.()
  end

  defp delivery_outcome(deliver) do
    case deliver.() do
      {:ok, %Response{} = response} ->
        text = Response.content(response)

        if is_binary(text) and byte_size(text) <= @max_reply_bytes and String.valid?(text),
          do: %{status: :completed, text: text},
          else: @unknown

      _ ->
        @unknown
    end
  rescue
    _ -> @unknown
  catch
    _, _ -> @unknown
  end

  defp settle(scope, id, token, outcome, collaborators) do
    case collaborators.settle.(scope, id, token, outcome) do
      {:ok, _command} ->
        :ok

      _ when outcome != @unknown ->
        # A failed acknowledgement may already have committed completion.
        # Journal terminal fencing prevents this fallback from overwriting it.
        collaborators.settle.(scope, id, token, @unknown)

      _ ->
        :ok
    end
  end

  defp release(result, scope, ownership, collaborators) do
    with :ok <- currently_authorized(scope, ownership, collaborators), do: result
  end

  defp currently_authorized(scope, ownership, collaborators) do
    case collaborators.recheck.(
           ownership.authenticated_principal_id,
           scope.agent_id,
           scope.principal_id
         ) do
      {:ok, :authorized} -> :ok
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    _, _ -> {:error, :unauthorized}
  end

  defp resolve_scope(collaborators, caller, target) do
    case collaborators.resolve.(target, caller) do
      {:ok,
       %Engagement{
         id: id,
         agent_id: ^target,
         owner_tenant: ^caller,
         scope: :user,
         visibility: :private
       }}
      when is_binary(id) and byte_size(id) > 0 ->
        {:ok, %{principal_id: caller, agent_id: target, engagement_id: id}}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp validate_opts(operation, opts) when is_list(opts) do
    allowed =
      case operation do
        :submit -> @proof_keys ++ [:timeout, :expected_engagement_id]
        :command -> @proof_keys ++ [:expected_engagement_id]
        :events -> @proof_keys ++ [:through, :limit, :expected_engagement_id]
        :history -> @proof_keys ++ [:after, :through, :limit, :expected_engagement_id]
      end

    if Keyword.keyword?(opts) and
         not (Keyword.has_key?(opts, :session_token) and Keyword.has_key?(opts, :signed_request)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in allowed)) do
      page = Keyword.take(opts, [:after, :through, :limit])

      expected_engagement = Keyword.get(opts, :expected_engagement_id)

      if valid_page?(page) and valid_engagement_fence?(expected_engagement) do
        {:ok, Keyword.take(opts, @proof_keys ++ [:timeout]), page, expected_engagement}
      else
        {:error, :invalid_opts}
      end
    else
      {:error, :invalid_opts}
    end
  rescue
    _ -> {:error, :invalid_opts}
  end

  defp validate_opts(_operation, _opts), do: {:error, :invalid_opts}

  defp valid_engagement_fence?(nil), do: true

  defp valid_engagement_fence?(id) when is_binary(id) and byte_size(id) == 36,
    do: Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, id)

  defp valid_engagement_fence?(_), do: false

  defp valid_page?(page) do
    Enum.all?(page, fn
      {:limit, limit} -> is_integer(limit) and limit in 1..100
      {cursor, value} when cursor in [:after, :through] -> is_integer(value) and value >= 0
    end)
  end

  defp validate_input(:submit, %{id: id, text: text} = command) when map_size(command) == 2 do
    if valid_id?(id) and is_binary(text) and byte_size(text) in 1..@max_text_bytes and
         String.valid?(text) and String.trim(text) != "",
       do: :ok,
       else: {:error, :invalid_command}
  end

  defp validate_input(:command, id),
    do: if(valid_id?(id), do: :ok, else: {:error, :invalid_command})

  defp validate_input(:events, cursor) when is_integer(cursor) and cursor >= 0, do: :ok
  defp validate_input(:history, nil), do: :ok
  defp validate_input(_operation, _input), do: {:error, :invalid_command}

  defp valid_id?(id) when is_binary(id), do: String.valid?(id) and Regex.match?(@id_pattern, id)
  defp valid_id?(_id), do: false
end
