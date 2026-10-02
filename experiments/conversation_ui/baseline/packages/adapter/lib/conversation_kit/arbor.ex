defmodule ConversationKit.Arbor do
  @moduledoc """
  Connection-local adapter for Arbor's authenticated conversation facade.

  Keep the returned client inside a trusted owner process. Only `projection/1`,
  `position/1`, and `sync_status/1` belong in renderer state. A fresh proof provider
  invocation precedes every host request, including every page and retry.

  `sync/1` commits both independently paged prefixes together. Each stream reads
  at most `max_pages` successful pages per call, retaining its pinned head until
  caught up. Errors return no replacement client. Client state is a cache; a
  reconnect can reconstruct it from zero with the same caller and target.
  """

  alias ConversationKit.Arbor.Client
  alias ConversationKit.Snapshot

  @options [:facade, :transport, :page_limit, :max_pages]
  @proof_keys [:session_token, :signed_request]
  @command_keys ~w(id name text principal_id agent_id engagement_id status outcome admitted_cursor updated_cursor)a
  @errors [
    :unauthorized,
    :conversation_scope_changed,
    :unsupported_conversation_capability,
    :not_found,
    :command_conflict,
    :conversation_unavailable,
    :page_too_large,
    :invalid_opts,
    :invalid_cursor,
    :invalid_command,
    :invalid_caller_id,
    :invalid_agent_id,
    :invalid_content,
    :invalid_message,
    :invalid_sender,
    :invalid_engagement_id,
    :transport_not_attached,
    :transport_timeout,
    :transport_busy,
    :invalid_transport_response
  ]

  @doc "Construct a private client; opts are trusted process configuration."
  def new(caller, target, proof_provider, opts \\ []) do
    if identifier?(caller) and identifier?(target) and is_function(proof_provider, 1) and
         options?(opts) do
      limit = Keyword.get(opts, :page_limit, 50)

      {:ok,
       %Client{
         caller: caller,
         target: target,
         proof_provider: proof_provider,
         facade: Keyword.get(opts, :facade, Arbor.Agent),
         transport: Keyword.get(opts, :transport),
         max_pages: Keyword.get(opts, :max_pages, 20),
         history: %{cursor: 0, head: 0, through: nil, limit: limit},
         journal: %{cursor: 0, head: 0, through: nil, limit: limit}
       }}
    else
      {:error, :invalid_client_options}
    end
  end

  @doc "Read bounded transcript and command prefixes atomically."
  def sync(%Client{} = client) do
    with {:ok, next} <- sync_stream(client, :history, client.max_pages),
         {:ok, next} <- sync_stream(next, :journal, client.max_pages) do
      {:ok, next}
    end
  end

  @doc "Submit a caller-generated stable ID. Never creates an optimistic message."
  def submit(%Client{engagement: nil}, _id, _text),
    do: {:error, :conversation_not_attached}

  def submit(%Client{} = client, id, text) do
    if command_id?(id) and text?(text, 32_768) and String.trim(text) != "" do
      with {:ok, raw} <- request(client, :submit, %{id: id, text: text}, []),
           {:ok, next, delivery} <- observe(client, raw, id),
           true <- delivery["input_text"] == text do
        {:ok, next, delivery}
      else
        false -> {:error, :conflicting_response}
        error -> error
      end
    else
      {:error, :invalid_command}
    end
  end

  @doc "Read one saved command without advancing the command replay cursor."
  def command(%Client{} = client, id) do
    if command_id?(id) do
      with {:ok, raw} <- request(client, :command, id, []),
           {:ok, next, delivery} <- observe(client, raw, id) do
        {:ok, next, delivery}
      end
    else
      {:error, :invalid_command}
    end
  end

  @doc "Return only semantic display data; no proof, principal, target or metadata."
  def projection(%Client{} = client) do
    deliveries = Map.merge(client.commands, client.observed, fn _, a, b -> newer(a, b) end)
    Snapshot.project(client.messages, Map.values(deliveries))
  end

  def position(%Client{} = client),
    do: %{history: client.history.cursor, commands: client.journal.cursor}

  def sync_status(%Client{} = client) do
    %{
      history: stream_status(client.history),
      commands: stream_status(client.journal)
    }
  end

  defp stream_status(stream),
    do: %{head: stream.head, has_more: not is_nil(stream.through)}

  defp sync_stream(client, _, 0), do: {:ok, client}

  defp sync_stream(client, stream_name, remaining) do
    stream = Map.fetch!(client, stream_name)
    opts = [limit: stream.limit]
    opts = if stream.through, do: Keyword.put(opts, :through, stream.through), else: opts

    {operation, input, opts} =
      if stream_name == :history,
        do: {:history, nil, Keyword.put(opts, :after, stream.cursor)},
        else: {:events, stream.cursor, opts}

    case request(client, operation, input, opts) do
      {:ok, page} ->
        with {:ok, next} <- consume_page(client, stream_name, page) do
          if page.has_more,
            do: sync_stream(next, stream_name, remaining - 1),
            else: {:ok, next}
        end

      {:error, :page_too_large} when stream.limit > 1 ->
        # Limits decrease monotonically: at most seven extra attempts per stream
        # (100 -> 50 -> 25 -> 12 -> 6 -> 3 -> 1), each with a fresh proof.
        next = Map.put(client, stream_name, %{stream | limit: max(div(stream.limit, 2), 1)})
        sync_stream(next, stream_name, remaining)

      error ->
        error
    end
  end

  defp consume_page(client, :history, page) do
    with true <- exact?(page, ~w(engagement_id entries cursor head has_more)a),
         :ok <- bounds(page, client.history),
         {:ok, client} <- bind_engagement(client, page.engagement_id),
         true <- is_list(page.entries) and length(page.entries) <= client.history.limit,
         true <- :erlang.external_size(page) <= 1_100_000,
         {:ok, messages, ids, last} <- history_entries(client, page.entries),
         true <- history_end?(page, last, client.history.cursor) do
      {:ok,
       %{
         client
         | history: advance(client.history, page),
           messages: client.messages ++ messages,
           message_ids: ids
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_history_page}
    end
  end

  defp consume_page(client, :journal, page) do
    with true <- exact?(page, ~w(engagement_id events cursor head has_more)a),
         :ok <- bounds(page, client.journal),
         {:ok, client} <- bind_engagement(client, page.engagement_id),
         true <- is_list(page.events) and length(page.events) <= client.journal.limit,
         true <- :erlang.external_size(page) <= 1_100_000,
         {:ok, next} <- journal_events(client, page.events),
         true <- next.journal.cursor == page.cursor do
      {:ok, %{next | journal: advance(next.journal, page)}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_command_page}
    end
  end

  defp bounds(page, stream) do
    if ordinal?(page.cursor) and ordinal?(page.head) and
         is_boolean(page.has_more) and stream.cursor <= page.cursor and
         page.cursor <= page.head and (is_nil(stream.through) or page.head == stream.through) and
         page.has_more == page.cursor < page.head and
         (not page.has_more or page.cursor > stream.cursor) do
      :ok
    else
      {:error, :invalid_page_bounds}
    end
  end

  defp advance(stream, page),
    do: %{
      stream
      | cursor: page.cursor,
        head: page.head,
        through: if(page.has_more, do: page.head)
    }

  defp history_entries(client, entries) do
    Enum.reduce_while(entries, {:ok, [], client.message_ids, client.history.cursor}, fn entry,
                                                                                        {:ok, acc,
                                                                                         ids,
                                                                                         last} ->
      if exact?(entry, ~w(id role content timestamp entry_ordinal)a) and identifier?(entry.id) and
           entry.role in ~w(user assistant) and text?(entry.content, 262_144) and
           timestamp?(entry.timestamp) and ordinal?(entry.entry_ordinal) and
           entry.entry_ordinal > last and not MapSet.member?(ids, entry.id) do
        message = %{
          "id" => entry.id,
          "role" => entry.role,
          "text" => entry.content,
          "timestamp" => entry.timestamp,
          "ordinal" => entry.entry_ordinal
        }

        {:cont, {:ok, [message | acc], MapSet.put(ids, entry.id), entry.entry_ordinal}}
      else
        {:halt, {:error, :invalid_history_entry}}
      end
    end)
    |> case do
      {:ok, reversed, ids, last} -> {:ok, Enum.reverse(reversed), ids, last}
      error -> error
    end
  end

  defp history_end?(page, last, after_cursor) do
    last <= page.cursor and
      if(page.has_more,
        do: last > after_cursor and last == page.cursor,
        else: page.cursor == page.head
      )
  end

  defp journal_events(client, events) do
    Enum.reduce_while(events, {:ok, client}, fn event, {:ok, current} ->
      case consume_event(current, event) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp consume_event(client, event) do
    with true <- exact?(event, ~w(id cursor kind command)a),
         true <- identifier?(event.id) and event.cursor == client.journal.cursor + 1,
         false <- MapSet.member?(client.event_ids, event.id),
         :ok <- known_kind(event.kind),
         {:ok, bound, delivery} <- normalize_command(client, event.command),
         true <- event.command.updated_cursor == event.cursor,
         :ok <- transition(bound.commands[delivery["id"]], delivery, event.kind),
         :ok <- consistent_observation(bound.observed[delivery["id"]], delivery) do
      {:ok,
       %{
         bound
         | journal: %{bound.journal | cursor: event.cursor},
           commands: Map.put(bound.commands, delivery["id"], delivery),
           event_ids: MapSet.put(bound.event_ids, event.id)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_command_event}
    end
  end

  defp known_kind(kind) when kind in ~w(admitted dispatch_started settled), do: :ok
  defp known_kind(_), do: {:error, :unsupported_event_kind}

  defp transition(nil, %{"status" => "admitted"} = next, "admitted") do
    if next["admitted_cursor"] == next["updated_cursor"],
      do: :ok,
      else: {:error, :invalid_command_transition}
  end

  defp transition(old, next, kind) when is_map(old) do
    allowed =
      {old["status"], kind, next["status"]} in [
        {"admitted", "dispatch_started", "dispatch_started"},
        {"dispatch_started", "settled", "completed"},
        {"dispatch_started", "settled", "uncertain"}
      ]

    if allowed and immutable_equal?(old, next),
      do: :ok,
      else: {:error, :invalid_command_transition}
  end

  defp transition(_, _, _), do: {:error, :invalid_command_transition}

  defp observe(client, raw, expected_id) do
    with {:ok, next, delivery} <- normalize_command(client, raw),
         true <- delivery["id"] == expected_id,
         :ok <- consistent_observation(client.commands[expected_id], delivery),
         :ok <- consistent_observation(client.observed[expected_id], delivery) do
      current = latest_known(client, expected_id)
      saved = if current, do: newer(current, delivery), else: delivery
      {:ok, %{next | observed: Map.put(next.observed, expected_id, saved)}, saved}
    else
      false -> {:error, :conflicting_response}
      error -> error
    end
  end

  defp latest_known(client, id) do
    case {client.commands[id], client.observed[id]} do
      {nil, observed} -> observed
      {replayed, nil} -> replayed
      {replayed, observed} -> newer(replayed, observed)
    end
  end

  defp normalize_command(client, command) do
    with true <- exact?(command, @command_keys),
         :ok <- command_scope(client, command),
         {:ok, client} <- bind_engagement(client, command.engagement_id),
         {:ok, client} <- bind_owner(client, command.principal_id),
         true <- command_id?(command.id) and command.name == "chat.send",
         true <- text?(command.text, 32_768) and String.trim(command.text) != "",
         true <- ordinal?(command.admitted_cursor) and command.admitted_cursor > 0,
         true <-
           ordinal?(command.updated_cursor) and command.updated_cursor >= command.admitted_cursor,
         :ok <- command_cursors(command),
         {:ok, result, reason} <- outcome(command.status, command.outcome) do
      {:ok, client,
       %{
         "id" => command.id,
         "status" => Atom.to_string(command.status),
         "input_text" => command.text,
         "result_text" => result,
         "reason" => reason,
         "admitted_cursor" => command.admitted_cursor,
         "updated_cursor" => command.updated_cursor
       }}
    else
      {:error, _} = error -> error
      false -> {:error, :invalid_command_response}
      _ -> {:error, :invalid_command_response}
    end
  end

  defp command_scope(client, command) do
    if identifier?(command.principal_id) and command.agent_id == client.target,
      do: :ok,
      else: {:error, :scope_mismatch}
  end

  # The authenticated subject and canonical owner are distinct. Only the
  # authenticated host response establishes owner identity; renderers cannot
  # select it, and all later commands must agree with the pinned owner.
  defp bind_owner(%{owner: nil} = client, owner), do: {:ok, %{client | owner: owner}}
  defp bind_owner(%{owner: owner} = client, owner), do: {:ok, client}
  defp bind_owner(_, _), do: {:error, :conversation_scope_changed}

  defp command_cursors(command) do
    valid =
      case command.status do
        :admitted ->
          command.updated_cursor == command.admitted_cursor

        :dispatch_started ->
          command.updated_cursor > command.admitted_cursor

        status when status in [:completed, :uncertain] ->
          command.updated_cursor >= command.admitted_cursor + 2

        _ ->
          true
      end

    if valid, do: :ok, else: {:error, :invalid_command_response}
  end

  defp outcome(status, nil) when status in [:admitted, :dispatch_started], do: {:ok, nil, nil}

  defp outcome(:completed, %{status: :completed, text: text} = outcome) do
    if exact?(outcome, [:status, :text]) and text?(text, 131_072),
      do: {:ok, text, nil},
      else: {:error, :invalid_command_outcome}
  end

  defp outcome(:uncertain, %{status: :uncertain, reason: :delivery_unknown} = outcome) do
    if exact?(outcome, [:status, :reason]),
      do: {:ok, nil, "delivery_unknown"},
      else: {:error, :invalid_command_outcome}
  end

  defp outcome(_, _), do: {:error, :unsupported_command_status}

  defp bind_engagement(client, id) do
    cond do
      not (is_binary(id) and Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, id)) ->
        {:error, :scope_mismatch}

      is_nil(client.engagement) or client.engagement == id ->
        {:ok, %{client | engagement: id}}

      true ->
        {:error, :conversation_scope_changed}
    end
  end

  defp consistent_observation(nil, _), do: :ok

  defp consistent_observation(old, next) do
    {earlier, later} =
      if old["updated_cursor"] <= next["updated_cursor"], do: {old, next}, else: {next, old}

    valid =
      immutable_equal?(old, next) and
        cond do
          old["updated_cursor"] == next["updated_cursor"] ->
            old == next

          earlier["status"] in ~w(completed uncertain) ->
            false

          earlier["status"] == "dispatch_started" ->
            later["status"] in ~w(completed uncertain)

          earlier["status"] == "admitted" ->
            later["status"] in ~w(dispatch_started completed uncertain)

          true ->
            false
        end

    if valid, do: :ok, else: {:error, :conflicting_response}
  end

  defp immutable_equal?(a, b),
    do:
      Map.take(a, ~w(id input_text admitted_cursor)) ==
        Map.take(b, ~w(id input_text admitted_cursor))

  defp newer(a, b), do: if(a["updated_cursor"] >= b["updated_cursor"], do: a, else: b)

  defp request(client, operation, input, opts) do
    opts =
      if client.engagement,
        do: Keyword.put(opts, :expected_engagement_id, client.engagement),
        else: opts

    context = %{
      operation: operation,
      caller: client.caller,
      target: client.target,
      input: input,
      options: opts
    }

    with {:ok, proof} <- proof(client.proof_provider, context),
         {:ok, value} <- transport_call(client, context, proof, opts) do
      {:ok, value}
    end
  end

  # Transport callbacks are trusted connection-owner configuration. They receive
  # exactly the operation covered by the freshly acquired proof, never renderer
  # routing fields. The same semantic page/command validators run afterward.
  defp transport_call(%{transport: nil} = client, context, proof, opts),
    do: call(client, context.operation, context.input, proof ++ opts)

  defp transport_call(client, context, proof, _opts) do
    case client.transport.(context, proof) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:error, reason} when reason in @errors -> {:error, reason}
      _ -> {:error, :invalid_transport_response}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp proof(provider, context) do
    case provider.(context) do
      {:ok, [{key, value}]} when key in @proof_keys and not is_nil(value) ->
        {:ok, [{key, value}]}

      {:error, :unauthorized} ->
        {:error, :unauthorized}

      _ ->
        {:error, :proof_unavailable}
    end
  rescue
    _ -> {:error, :proof_unavailable}
  catch
    _, _ -> {:error, :proof_unavailable}
  end

  defp call(client, operation, input, opts) do
    {function, args} =
      case operation do
        :history -> {:conversation_history, [client.caller, client.target, opts]}
        :events -> {:conversation_events, [client.caller, client.target, input, opts]}
        :command -> {:conversation_command, [client.caller, client.target, input, opts]}
        :submit -> {:submit_conversation_command, [client.caller, client.target, input, opts]}
      end

    case apply(client.facade, function, args) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:error, reason} when reason in @errors -> {:error, reason}
      _ -> {:error, :conversation_unavailable}
    end
  rescue
    _ -> {:error, :conversation_unavailable}
  catch
    _, _ -> {:error, :conversation_unavailable}
  end

  defp options?(opts) do
    Keyword.keyword?(opts) and length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
      Enum.all?(Keyword.keys(opts), &(&1 in @options)) and
      is_atom(Keyword.get(opts, :facade, Arbor.Agent)) and
      Keyword.get(opts, :facade, Arbor.Agent) not in [nil, true, false] and
      (not Keyword.has_key?(opts, :transport) or is_function(opts[:transport], 2)) and
      is_integer(Keyword.get(opts, :page_limit, 50)) and
      Keyword.get(opts, :page_limit, 50) in 1..100 and
      is_integer(Keyword.get(opts, :max_pages, 20)) and
      Keyword.get(opts, :max_pages, 20) in 1..100
  end

  defp exact?(map, keys),
    do: is_map(map) and map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))

  defp identifier?(value), do: text?(value, 256) and String.trim(value) != ""

  defp text?(value, limit),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= limit

  defp ordinal?(value),
    do: is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807

  defp command_id?(id),
    do: is_binary(id) and Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, id)

  defp timestamp?(value) when is_binary(value) do
    byte_size(value) <= 64 and match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp timestamp?(_), do: false
end
