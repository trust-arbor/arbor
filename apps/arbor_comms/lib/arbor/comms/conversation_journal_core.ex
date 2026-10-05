defmodule Arbor.Comms.ConversationJournalCore do
  @moduledoc """
  Pure admission/dispatch/result reducer for a private conversation's ingress log.

  This records ingress evidence, not execution authority. A dispatch claim is
  never reclaimed. An unresolved claim is not evidence that execution failed.
  """

  @types %{
    "arbor.conversation.admitted.v1" => "admitted",
    "arbor.conversation.dispatch_started.v1" => "dispatch_started",
    "arbor.conversation.settled.v1" => "settled",
    "arbor.conversation.cancel_requested.v2" => "cancel_requested",
    "arbor.conversation.cancel_acknowledged.v2" => "cancel_acknowledged"
  }
  @scope_keys [:principal_id, :agent_id, :engagement_id]

  def control_request_payload(operation, caller, target, input, page, expected_engagement)
      when operation in [:activity, :cancel] do
    cursor = Keyword.get(page, :cursor)
    encoded_cursor = if cursor, do: [cursor.admitted_event_number, cursor.command_id], else: nil

    Jason.encode!([
      if(operation == :activity,
        do: "arbor.conversation.activity.v1",
        else: "arbor.conversation.cancel.v1"
      ),
      caller,
      target,
      input,
      [encoded_cursor, Keyword.get(page, :limit), Keyword.get(page, :control_timeout)],
      expected_engagement
    ])
  end

  def new(scope), do: %{scope: scope, cursor: 0, commands: %{}}

  def validate_scope(scope) when is_map(scope) do
    if exact_keys?(scope, @scope_keys) and
         Enum.all?(@scope_keys, &bounded_string?(scope[&1], 256)),
       do: :ok,
       else: {:error, :invalid_scope}
  end

  def validate_scope(_), do: {:error, :invalid_scope}

  def validate_id(id) do
    if is_binary(id) and byte_size(id) in 1..128 and String.valid?(id) and
         String.match?(id, ~r/\A[A-Za-z0-9_-]+\z/),
       do: :ok,
       else: {:error, :invalid_command_id}
  end

  def validate_command(%{id: id, text: text} = command) do
    with true <- exact_keys?(command, [:id, :text]),
         :ok <- validate_id(id),
         true <- bounded_string?(text, 32_768) and String.trim(text) != "" do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_command}
    end
  end

  def validate_command(_), do: {:error, :invalid_command}

  @doc false
  # Transport metadata is caller data, never the source of private command
  # authority. These names are reserved at every authenticated ingress.
  def validate_ingress_metadata(metadata) do
    if contains_binding_key?(metadata), do: {:error, :invalid_message}, else: :ok
  end

  defp contains_binding_key?(value) when is_map(value) do
    Enum.any?(Map.to_list(value), fn {key, nested} ->
      key in [
        :command_binding,
        "command_binding",
        :conversation_command_binding,
        "conversation_command_binding",
        :claim_token,
        "claim_token"
      ] or
        contains_binding_key?(nested)
    end)
  end

  defp contains_binding_key?([head | tail]),
    do: contains_binding_key?(head) or contains_binding_key?(tail)

  defp contains_binding_key?(_), do: false

  def validate_outcome(%{status: :completed, text: text} = outcome) do
    if exact_keys?(outcome, [:status, :text]) and bounded_string?(text, 131_072, true),
      do: :ok,
      else: {:error, :invalid_outcome}
  end

  def validate_outcome(%{status: :uncertain, reason: :delivery_unknown} = outcome) do
    if exact_keys?(outcome, [:status, :reason]),
      do: :ok,
      else: {:error, :invalid_outcome}
  end

  def validate_outcome(_), do: {:error, :invalid_outcome}

  def valid_token?(token),
    do:
      is_binary(token) and byte_size(token) == 64 and String.valid?(token) and
        String.match?(token, ~r/\A[0-9a-f]+\z/)

  def stream_id(scope),
    do: "conversation_" <> digest({scope.principal_id, scope.agent_id, scope.engagement_id})

  # Exclude mutable destination and input. Reuse in another destination must
  # conflict against the global EventLog ID instead of admitting another effect.
  def event_id(scope, command_id, kind),
    do: "conversation_" <> kind <> "_" <> digest({scope.principal_id, command_id})

  def get(state, id) do
    case Map.fetch(state.commands, id) do
      {:ok, command} -> {:ok, show(command)}
      :error -> {:error, :not_found}
    end
  end

  def show(command), do: Map.delete(command, :claim_token)

  def task_id(scope, id), do: "conversation_" <> digest({scope, id})

  # Sparse exact command records are bounded to the five permanent event IDs.
  # Other commands may occupy the intervening source positions. The ordered
  # transition reducer still validates this command's complete known chain.
  def from_command_events(scope, events, head) when is_list(events) and length(events) <= 5 do
    Enum.reduce_while(Enum.sort_by(events, & &1.event_number), {:ok, new(scope)}, fn event,
                                                                                     {:ok, state} ->
      with true <- event.event_number > state.cursor and event.event_number <= head,
           {:ok, next, _} <- apply_event(%{state | cursor: event.event_number - 1}, event) do
        {:cont, {:ok, next}}
      else
        _ -> {:halt, {:error, :invalid_journal}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, %{state | cursor: head}}
      error -> error
    end
  end

  def from_command_events(_, _, _), do: {:error, :invalid_journal}

  def decide(state, {:admit, %{id: id, text: text}}) do
    case Map.fetch(state.commands, id) do
      {:ok, %{text: ^text} = command} ->
        {:return, show(command)}

      {:ok, _} ->
        {:error, :command_conflict}

      :error ->
        data = %{
          "schema_version" => 1,
          "command_id" => id,
          "name" => "chat.send",
          "text" => text,
          "principal_id" => state.scope.principal_id,
          "agent_id" => state.scope.agent_id,
          "engagement_id" => state.scope.engagement_id
        }

        {:append, "arbor.conversation.admitted.v1", "admitted", data}
    end
  end

  def decide(state, {:claim, id, token}) do
    case Map.fetch(state.commands, id) do
      {:ok, %{status: :admitted, cancellation: %{status: :none}}} ->
        {:append, "arbor.conversation.dispatch_started.v1", "dispatch_started",
         %{"schema_version" => 1, "command_id" => id, "token" => token}}

      {:ok, _} ->
        {:error, :already_claimed}

      :error ->
        {:error, :not_found}
    end
  end

  def decide(state, {:settle, id, token, outcome}) do
    case Map.fetch(state.commands, id) do
      {:ok, %{status: :dispatch_started, claim_token: ^token}} ->
        {:append, "arbor.conversation.settled.v1", "settled",
         %{
           "schema_version" => 1,
           "command_id" => id,
           "token" => token,
           "outcome" => encode_outcome(outcome)
         }}

      {:ok, %{claim_token: ^token, outcome: ^outcome} = command} when not is_nil(outcome) ->
        {:return, show(command)}

      {:ok, %{claim_token: ^token}} ->
        {:error, :terminal_conflict}

      {:ok, _} ->
        {:error, :invalid_claim}

      :error ->
        {:error, :not_found}
    end
  end

  def decide(state, {:cancel, id}) do
    case Map.fetch(state.commands, id) do
      {:ok, %{cancellation: %{status: :none}}} ->
        {:append, "arbor.conversation.cancel_requested.v2", "cancel_requested",
         %{"schema_version" => 2, "command_id" => id}}

      {:ok, command} ->
        {:return, show(command)}

      :error ->
        {:error, :not_found}
    end
  end

  def decide(state, {:ack_cancel, id, claim_token, termination})
      when termination in [:never_dispatched, :queued_removed, :engine_terminated] do
    case Map.fetch(state.commands, id) do
      {:ok,
       %{
         claim_token: ^claim_token,
         cancellation: %{status: :confirmed, termination: ^termination}
       } = command} ->
        {:return, show(command)}

      {:ok, %{claim_token: ^claim_token, cancellation: %{status: :requested}} = command} ->
        if termination == :never_dispatched == is_nil(command.claim_token) do
          {:append, "arbor.conversation.cancel_acknowledged.v2", "cancel_acknowledged",
           %{
             "schema_version" => 2,
             "command_id" => id,
             "token" => claim_token,
             "termination" => Atom.to_string(termination)
           }}
        else
          {:error, :invalid_cancellation}
        end

      {:ok, _} ->
        {:error, :invalid_cancellation}

      :error ->
        {:error, :not_found}
    end
  end

  # A pinned head may belong to another command. Validate its closed domain
  # envelope before accepting the position; fingerprints alone do not admit an
  # unknown journal schema or kind. Exact records then validate the full chain.
  def valid_event_envelope?(event, scope) do
    with %{id: event_id, stream_id: stream, type: type, data: data} <- event,
         true <- stream == stream_id(scope),
         {:ok, kind} <- Map.fetch(@types, type),
         %{"command_id" => id, "schema_version" => schema} <- data,
         :ok <- validate_id(id),
         true <- event_id == event_id(scope, id, kind),
         true <- schema == if(kind in ["cancel_requested", "cancel_acknowledged"], do: 2, else: 1) do
      valid_kind_data?(kind, data, scope)
    else
      _ -> false
    end
  end

  defp valid_kind_data?("admitted", data, scope),
    do:
      exact_keys?(
        data,
        ~w(schema_version command_id name text principal_id agent_id engagement_id)
      ) and
        data["name"] == "chat.send" and data["principal_id"] == scope.principal_id and
        data["agent_id"] == scope.agent_id and data["engagement_id"] == scope.engagement_id and
        validate_command(%{id: data["command_id"], text: data["text"]}) == :ok

  defp valid_kind_data?("dispatch_started", data, _scope),
    do: exact_keys?(data, ~w(schema_version command_id token)) and valid_token?(data["token"])

  defp valid_kind_data?("settled", data, _scope),
    do:
      exact_keys?(data, ~w(schema_version command_id token outcome)) and
        valid_token?(data["token"]) and
        match?({:ok, _}, decode_outcome(data["outcome"]))

  defp valid_kind_data?("cancel_requested", data, _scope),
    do: exact_keys?(data, ~w(schema_version command_id))

  defp valid_kind_data?("cancel_acknowledged", data, _scope),
    do:
      exact_keys?(data, ~w(schema_version command_id token termination)) and
        data["termination"] in ["never_dispatched", "queued_removed", "engine_terminated"] and
        if(data["termination"] == "never_dispatched",
          do: is_nil(data["token"]),
          else: valid_token?(data["token"])
        )

  def apply_event(state, event) do
    with %{id: id, stream_id: stream, event_number: cursor, type: type, data: data} <- event,
         true <- stream == stream_id(state.scope),
         true <- cursor == state.cursor + 1,
         {:ok, kind} <- Map.fetch(@types, type),
         %{"command_id" => command_id, "schema_version" => schema} <- data,
         true <- schema == if(kind in ["cancel_requested", "cancel_acknowledged"], do: 2, else: 1),
         :ok <- validate_id(command_id),
         true <- id == event_id(state.scope, command_id, kind),
         {:ok, command} <- reduce_command(state, kind, data, cursor) do
      updated = %{state | cursor: cursor, commands: Map.put(state.commands, command_id, command)}

      public_event = %{
        id: id,
        cursor: cursor,
        kind: kind,
        command: show(command)
      }

      {:ok, updated, public_event}
    else
      _ -> {:error, :invalid_journal}
    end
  end

  defp reduce_command(state, "admitted", data, cursor) do
    keys = ~w(schema_version command_id name text principal_id agent_id engagement_id)

    with true <- exact_keys?(data, keys),
         true <- data["name"] == "chat.send",
         true <- data["principal_id"] == state.scope.principal_id,
         true <- data["agent_id"] == state.scope.agent_id,
         true <- data["engagement_id"] == state.scope.engagement_id,
         :ok <- validate_command(%{id: data["command_id"], text: data["text"]}),
         false <- Map.has_key?(state.commands, data["command_id"]) do
      {:ok,
       Map.merge(state.scope, %{
         id: data["command_id"],
         name: "chat.send",
         text: data["text"],
         status: :admitted,
         claim_token: nil,
         outcome: nil,
         cancellation: %{status: :none},
         admitted_cursor: cursor,
         updated_cursor: cursor
       })}
    else
      _ -> {:error, :invalid_admission}
    end
  end

  defp reduce_command(state, "dispatch_started", data, cursor) do
    with true <- exact_keys?(data, ~w(schema_version command_id token)),
         true <- valid_token?(data["token"]),
         {:ok, %{status: :admitted, cancellation: %{status: :none}} = command} <-
           Map.fetch(state.commands, data["command_id"]) do
      {:ok,
       %{command | status: :dispatch_started, claim_token: data["token"], updated_cursor: cursor}}
    else
      _ -> {:error, :invalid_dispatch}
    end
  end

  defp reduce_command(state, "settled", data, cursor) do
    with true <- exact_keys?(data, ~w(schema_version command_id token outcome)),
         true <- valid_token?(data["token"]),
         {:ok, outcome} <- decode_outcome(data["outcome"]),
         {:ok, %{status: :dispatch_started} = command} <-
           Map.fetch(state.commands, data["command_id"]),
         true <- command.claim_token == data["token"] do
      {:ok, %{command | status: outcome.status, outcome: outcome, updated_cursor: cursor}}
    else
      _ -> {:error, :invalid_settlement}
    end
  end

  defp reduce_command(state, "cancel_requested", data, cursor) do
    with true <- exact_keys?(data, ~w(schema_version command_id)),
         {:ok, %{cancellation: %{status: :none}} = command} <-
           Map.fetch(state.commands, data["command_id"]) do
      {:ok, %{command | cancellation: %{status: :requested}, updated_cursor: cursor}}
    else
      _ -> {:error, :invalid_cancellation}
    end
  end

  defp reduce_command(state, "cancel_acknowledged", data, cursor) do
    termination =
      case data["termination"] do
        "never_dispatched" -> :never_dispatched
        "queued_removed" -> :queued_removed
        "engine_terminated" -> :engine_terminated
        _ -> nil
      end

    with true <- exact_keys?(data, ~w(schema_version command_id token termination)),
         true <- not is_nil(termination),
         {:ok, %{cancellation: %{status: :requested}} = command} <-
           Map.fetch(state.commands, data["command_id"]),
         true <- command.claim_token == data["token"],
         true <- termination == :never_dispatched == is_nil(command.claim_token) do
      {:ok,
       %{
         command
         | cancellation: %{status: :confirmed, termination: termination},
           updated_cursor: cursor
       }}
    else
      _ -> {:error, :invalid_cancellation}
    end
  end

  defp encode_outcome(%{status: :completed, text: text}),
    do: %{"status" => "completed", "text" => text}

  defp encode_outcome(%{status: :uncertain, reason: :delivery_unknown}),
    do: %{"status" => "uncertain", "reason" => "delivery_unknown"}

  defp decode_outcome(%{"status" => "completed", "text" => text} = data) do
    outcome = %{status: :completed, text: text}

    if exact_keys?(data, ~w(status text)) and validate_outcome(outcome) == :ok,
      do: {:ok, outcome},
      else: {:error, :invalid_outcome}
  end

  defp decode_outcome(%{"status" => "uncertain", "reason" => "delivery_unknown"} = data) do
    if exact_keys?(data, ~w(status reason)),
      do: {:ok, %{status: :uncertain, reason: :delivery_unknown}},
      else: {:error, :invalid_outcome}
  end

  defp decode_outcome(_), do: {:error, :invalid_outcome}

  defp exact_keys?(map, keys),
    do: map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))

  defp bounded_string?(value, max, empty? \\ false),
    do:
      is_binary(value) and byte_size(value) <= max and (empty? or byte_size(value) > 0) and
        String.valid?(value)

  defp digest(term),
    do:
      term
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
end
