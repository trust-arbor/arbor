defmodule Arbor.Comms.ConversationJournalCore do
  @moduledoc """
  Pure admission/dispatch/result reducer for a private conversation's ingress log.

  This records ingress evidence, not execution authority. A dispatch claim is
  never reclaimed. An unresolved claim is not evidence that execution failed.
  """

  @types %{
    "arbor.conversation.admitted.v1" => "admitted",
    "arbor.conversation.dispatch_started.v1" => "dispatch_started",
    "arbor.conversation.settled.v1" => "settled"
  }
  @scope_keys [:principal_id, :agent_id, :engagement_id]

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
      {:ok, %{status: :admitted}} ->
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

  def apply_event(state, event) do
    with %{id: id, stream_id: stream, event_number: cursor, type: type, data: data} <- event,
         true <- stream == stream_id(state.scope),
         true <- cursor == state.cursor + 1,
         {:ok, kind} <- Map.fetch(@types, type),
         %{"command_id" => command_id, "schema_version" => 1} <- data,
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
         {:ok, %{status: :admitted} = command} <- Map.fetch(state.commands, data["command_id"]) do
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
