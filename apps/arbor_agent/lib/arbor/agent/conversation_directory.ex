defmodule Arbor.Agent.ConversationDirectory do
  @moduledoc false
  alias Arbor.Contracts.Security.SignedRequest
  alias Arbor.Security
  @proof_keys [:session_token, :signed_request]
  @human ~r/\Ahuman_[A-Za-z0-9_-]+\z/
  @engagement ~r/\Aeng_[0-9a-f]{32}\z/

  def run(operation, caller, input, opts) do
    with {:ok, query, proof} <- options(operation, opts),
         :ok <- validate_input(operation, caller, input),
         :ok <- authenticate(operation, caller, input, query, proof),
         {:ok, owner} <- Security.resolve_conversation_owner(caller),
         {:ok, _capabilities} <- Security.list_capabilities(caller),
         {:ok, result} <- read(operation, caller, owner, input, query),
         {:ok, result} <- release(operation, caller, owner, result),
         :ok <- continuation(caller, owner, proof) do
      {:ok, result}
    else
      {:error, reason}
      when reason in [
             :invalid_opts,
             :invalid_identifier,
             :unauthorized,
             :not_found,
             :conversation_scope_changed,
             :conversation_unavailable
           ] ->
        {:error, reason}

      _ ->
        {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  def request_payload(operation, caller, input, opts) do
    with {:ok, query, _proof} <- options(operation, opts),
         :ok <- validate_input(operation, caller, input) do
      {:ok, payload(operation, caller, input, query)}
    end
  rescue
    _ -> {:error, :invalid_opts}
  catch
    _, _ -> {:error, :invalid_opts}
  end

  defp options(operation, opts) when operation in [:list, :reference] do
    extra = if operation == :list, do: [:cursor, :limit], else: []

    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in (@proof_keys ++ extra))) and
         not (Keyword.has_key?(opts, :session_token) and Keyword.has_key?(opts, :signed_request)) do
      query = Keyword.take(opts, extra)

      with {:ok, _bounds} <- Arbor.Persistence.normalize_conversation_directory_options(query) do
        {:ok, query, Keyword.take(opts, @proof_keys)}
      else
        _ -> {:error, :invalid_opts}
      end
    else
      {:error, :invalid_opts}
    end
  end

  defp options(_, _), do: {:error, :invalid_opts}

  defp validate_input(:list, caller, nil), do: validate_caller(caller)

  defp validate_input(:reference, caller, id) do
    with :ok <- validate_caller(caller),
         true <- is_binary(id) and byte_size(id) == 36 and Regex.match?(@engagement, id) do
      :ok
    else
      _ -> {:error, :invalid_identifier}
    end
  end

  defp validate_input(_, _, _), do: {:error, :invalid_identifier}

  defp validate_caller(caller) when is_binary(caller) do
    if byte_size(caller) in 1..256 and String.valid?(caller) and Regex.match?(@human, caller),
      do: :ok,
      else: {:error, :invalid_identifier}
  end

  defp validate_caller(_), do: {:error, :invalid_identifier}

  defp payload(:list, caller, nil, query),
    do:
      Jason.encode!([
        "arbor.conversation.index.v1",
        caller,
        [Keyword.get(query, :cursor), Keyword.get(query, :limit)]
      ])

  defp payload(:reference, caller, id, _query),
    do: Jason.encode!(["arbor.conversation.reference.v1", caller, id])

  defp authenticate(operation, caller, input, query,
         signed_request: %SignedRequest{agent_id: caller, payload: bytes} = request
       ) do
    if bytes == payload(operation, caller, input, query) do
      case Security.verify_request(request) do
        {:ok, ^caller} -> :ok
        _ -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp authenticate(_operation, caller, _input, _query, session_token: token),
    do: Security.verify_human_session(caller, token)

  defp authenticate(_, _, _, _, _), do: {:error, :unauthorized}

  defp continuation(caller, owner, proof) do
    with {:ok, ^owner} <- Security.resolve_conversation_owner(caller),
         :ok <- continue_session(caller, proof) do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp continue_session(caller, session_token: token),
    do: Security.verify_human_session(caller, token)

  defp continue_session(_, signed_request: _), do: :ok

  defp read(:list, caller, owner, nil, query) do
    with {:ok, page} <- Arbor.Comms.list_user_conversation_records(owner, query),
         {:ok, conversations} <- project_records(page.records, caller, owner) do
      {:ok,
       %{conversations: conversations, next_cursor: page.next_cursor, has_more: page.has_more}}
    end
  end

  defp read(:reference, caller, owner, id, _query) do
    with {:ok, record} <- Arbor.Comms.read_user_conversation_record(owner, id),
         {:ok, [conversation]} <- project_records([record], caller, owner) do
      {:ok, conversation}
    else
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  defp project_records(records, caller, owner) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case Security.recheck_conversation_owner(caller, record.agent_id, owner) do
        {:ok, :authorized} ->
          case project(record, owner) do
            {:ok, conversation} -> {:cont, {:ok, [conversation | acc]}}
            error -> {:halt, error}
          end

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, conversations} -> {:ok, Enum.reverse(conversations)}
      error -> error
    end
  end

  defp project(record, owner) do
    with {:ok, page} <-
           Arbor.Comms.read_user_conversation_window(record.agent_id, owner, limit: 1),
         true <- page.engagement_id == record.engagement_id do
      latest = List.last(page.entries)

      {:ok,
       %{
         engagement_id: record.engagement_id,
         agent_id: record.agent_id,
         display_name: display_name(record.agent_id),
         status: record.status,
         updated_at: DateTime.to_iso8601(record.updated_at),
         preview: if(latest, do: String.slice(latest.content, 0, 160), else: nil),
         last_message_at: if(latest, do: latest.timestamp, else: nil)
       }}
    else
      false -> {:error, :conversation_scope_changed}
      _ -> {:error, :conversation_unavailable}
    end
  end

  # A single authorized target lookup never enumerates the global directory.
  defp display_name(agent_id) do
    case Arbor.Agent.load_profile(agent_id) do
      {:ok, %{display_name: name}} when is_binary(name) ->
        if String.valid?(name) and String.trim(name) != "",
          do: String.slice(name, 0, 160),
          else: agent_id

      _ ->
        agent_id
    end
  rescue
    _ -> agent_id
  catch
    _, _ -> agent_id
  end

  defp release(:list, caller, owner, page) do
    conversations =
      Enum.filter(page.conversations, fn conversation ->
        Security.recheck_conversation_owner(caller, conversation.agent_id, owner) ==
          {:ok, :authorized}
      end)

    {:ok, %{page | conversations: conversations}}
  end

  defp release(:reference, caller, owner, conversation) do
    if Security.recheck_conversation_owner(caller, conversation.agent_id, owner) ==
         {:ok, :authorized},
       do: {:ok, conversation},
       else: {:error, :not_found}
  end
end
