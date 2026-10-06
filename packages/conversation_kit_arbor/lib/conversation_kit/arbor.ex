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
  alias ConversationKit.{Controls, Snapshot}
  alias ConversationKit.Arbor.ControlCodec
  alias ConversationKit.Arbor.NoticeCodec

  @options [:facade, :transport, :page_limit, :max_pages, :expected_engagement_id]
  @proof_keys [:session_token, :signed_request]
  @command_keys ~w(id name text principal_id agent_id engagement_id status outcome admitted_cursor updated_cursor)a
  @assistant_statuses ~w(complete interrupted cancelled failed streaming)
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
    :agent_not_running,
    :invalid_caller_id,
    :invalid_agent_id,
    :invalid_content,
    :invalid_message,
    :invalid_sender,
    :invalid_engagement_id,
    :transport_not_attached,
    :transport_timeout,
    :transport_busy,
    :invalid_transport_response,
    :approval_answer_required,
    :invalid_control_request,
    :invalid_interaction_answer,
    :interaction_not_pending,
    :interaction_unavailable,
    :notice_subject_required,
    :invalid_notice_request,
    :invalid_notice_response,
    :notice_unavailable
  ]

  @doc """
  Classify a bounded composer value without changing ordinary message bytes.

  Local commands are finite UI intents, never host commands. Management and
  runtime slash input must remain local guidance/refusal. No authority is granted
  by this classification; each Connection intent retains its existing gates.
  """
  defdelegate classify_composer_input(text),
    to: ConversationKit.Arbor.ComposerCommands,
    as: :classify

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
         engagement: Keyword.get(opts, :expected_engagement_id),
         history: %{cursor: 0, head: 0, through: nil, limit: limit},
         journal: %{cursor: 0, head: 0, through: nil, limit: limit}
       }}
    else
      {:error, :invalid_client_options}
    end
  end

  @doc "Read bounded transcript and command prefixes atomically."
  def sync(%Client{mode: :window}), do: {:error, :incompatible_replay_mode}

  def sync(%Client{} = client) do
    with {:ok, next} <- sync_stream(client, :history, client.max_pages),
         {:ok, next} <- sync_stream(next, :journal, client.max_pages) do
      {:ok, next}
    end
  end

  @doc """
  Replace the cached transcript with one authenticated, bounded history window.

  No direction means the latest messages. `before` and `after` are exclusive
  ordinal anchors; `through` pins a browsing snapshot. Unlike `sync/1`, this
  API does not replay or retain the complete transcript or delivery journal.
  A successful window also establishes the host-selected submission scope.
  """
  def window(%Client{} = client, opts \\ []) do
    with :ok <- window_options(opts),
         opts = Keyword.put_new(opts, :limit, client.history.limit),
         {:ok, page, limit} <- read_window(client, opts),
         opts = Keyword.put(opts, :limit, limit),
         {:ok, bound} <- bind_engagement(client, page[:engagement_id]),
         :ok <- window_bounds(client, page, opts),
         empty = %{bound | history: %{bound.history | cursor: 0}, message_ids: MapSet.new()},
         {:ok, messages, ids, _last} <- history_entries(empty, page.entries, :window),
         :ok <- window_entries(client, messages, page, opts) do
      next = %{
        bound
        | mode: :window,
          messages: messages,
          message_ids: ids,
          commands: %{},
          event_ids: MapSet.new(),
          history: %{
            bound.history
            | cursor: page.last,
              head: page.head,
              through: nil,
              limit: limit
          },
          journal: %{bound.journal | cursor: 0, head: 0, through: nil},
          observed:
            recent_receipts(
              Map.merge(bound.commands, bound.observed, fn _, a, b -> newer(a, b) end),
              50
            )
      }

      {:ok, next, Map.take(page, ~w(head first last has_older has_newer)a)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_history_page}
    end
  end

  defp read_window(client, opts) do
    limit = opts[:limit]

    case request(client, :window, nil, opts) do
      {:ok, page} ->
        {:ok, page, opts[:limit]}

      {:error, :page_too_large} when limit > 1 ->
        read_window(client, Keyword.put(opts, :limit, max(div(limit, 2), 1)))

      error ->
        error
    end
  end

  defp window_options(opts) do
    if Keyword.keyword?(opts) and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(opts, fn
           {:limit, value} -> is_integer(value) and value in 1..100
           {:before, value} -> ordinal?(value) and value > 0
           {key, value} when key in [:after, :through] -> ordinal?(value)
           _ -> false
         end) and not (Keyword.has_key?(opts, :before) and Keyword.has_key?(opts, :after)) and
         (not Keyword.has_key?(opts, :through) or
            ((not Keyword.has_key?(opts, :before) or opts[:before] <= opts[:through]) and
               (not Keyword.has_key?(opts, :after) or opts[:after] <= opts[:through]))),
       do: :ok,
       else: {:error, :invalid_opts}
  end

  defp window_bounds(client, page, opts) do
    valid =
      exact?(page, ~w(engagement_id entries head first last has_older has_newer)a) and
        is_list(page.entries) and length(page.entries) <= opts[:limit] and
        :erlang.external_size(page) <= 1_100_000 and
        Enum.all?([page.head, page.first, page.last], &ordinal?/1) and
        page.first <= page.last and page.last <= page.head and
        is_boolean(page.has_older) and is_boolean(page.has_newer) and
        if(Keyword.has_key?(opts, :through),
          do: page.head == opts[:through],
          else: page.head >= client.history.head
        )

    if valid, do: :ok, else: {:error, :invalid_history_page}
  end

  defp window_entries(client, messages, page, opts) do
    previous = Map.new(client.messages, &{&1["id"], &1})
    ordinals = Map.new(client.messages, &{&1["ordinal"], &1})

    valid =
      case messages do
        [] ->
          page.first == 0 and page.last == 0

        [first | _] ->
          first["ordinal"] == page.first and List.last(messages)["ordinal"] == page.last
      end

    valid =
      valid and
        Enum.all?(messages, fn message ->
          ordinal = message["ordinal"]

          (not Keyword.has_key?(opts, :before) or ordinal < opts[:before]) and
            (not Keyword.has_key?(opts, :after) or ordinal > opts[:after]) and
            ordinal <= page.head and
            (not Map.has_key?(previous, message["id"]) or previous[message["id"]] == message) and
            (not Map.has_key?(ordinals, ordinal) or ordinals[ordinal] == message)
        end)

    if valid, do: :ok, else: {:error, :invalid_history_entry}
  end

  defp recent_receipts(receipts, limit),
    do:
      receipts
      |> Enum.sort_by(fn {_id, value} -> value["updated_cursor"] end, :desc)
      |> Enum.take(limit)
      |> Map.new()

  @doc "Submit a caller-generated stable ID. Never creates an optimistic message."
  def submit(%Client{engagement: nil}, _id, _text),
    do: {:error, :conversation_not_attached}

  def submit(%Client{} = client, id, text) do
    if validate_command(id, text) == :ok do
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

  @doc "Validate stable request identity and UTF-8 text before retaining an outbox item."
  def validate_command(id, text) do
    if command_id?(id) and text?(text, 32_768) and String.trim(text) != "",
      do: :ok,
      else: {:error, :invalid_command}
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

  @doc "Read one bounded activity page. Discovery never follows a cursor automatically."
  def activity(client, opts \\ [])
  def activity(%Client{engagement: nil}, _opts), do: {:error, :conversation_not_attached}

  def activity(%Client{} = client, opts) do
    if ControlCodec.options?(opts) do
      with {:ok, raw} <- request(client, :activity, nil, opts),
           {:ok, records, discovery} <- ControlCodec.activity(raw, client.engagement, opts) do
        {:ok, client, records, discovery}
      end
    else
      {:error, :invalid_control_request}
    end
  end

  @doc "Read prompts with exact command and authenticated engagement correlation, including empty lists."
  def interactions(%Client{engagement: nil}, _id), do: {:error, :conversation_not_attached}

  def interactions(%Client{} = client, id) do
    if command_id?(id) do
      with {:ok, raw} <- request(client, :interactions, id, []),
           {:ok, prompts} <- ControlCodec.prompts(raw, id, client.engagement),
           do: {:ok, client, prompts}
    else
      {:error, :invalid_control_request}
    end
  end

  @doc "Request cancellation without changing delivery status or consuming a cached control."
  def cancel(%Client{engagement: nil}, _id), do: {:error, :conversation_not_attached}

  def cancel(%Client{} = client, id) do
    if command_id?(id) do
      with {:ok, raw} <- request(client, :cancel, id, []),
           {:ok, result} <- ControlCodec.cancel(raw, id, client.engagement),
           do: {:ok, client, result}
    else
      {:error, :invalid_control_request}
    end
  end

  def answer_choice(client, input), do: answer(client, :interaction_choice, input)
  def answer_approval(client, input), do: answer(client, :interaction_approval, input)
  defp answer(%Client{engagement: nil}, _, _), do: {:error, :conversation_not_attached}

  defp answer(%Client{} = client, operation, input) do
    if ControlCodec.answer_input(input, operation) do
      with {:ok, raw} <- request(client, operation, input, []),
           {:ok, result} <- ControlCodec.answer(raw, input, client.engagement),
           do: {:ok, client, result}
    else
      {:error, :invalid_control_request}
    end
  end

  @doc "Replace disposable controls from one activity page and a bounded set of freshly authenticated prompt reads."
  def controls(%Client{} = client, opts \\ []) do
    opts = if Keyword.keyword?(opts), do: Keyword.put_new(opts, :limit, 8), else: opts

    with true <- ControlCodec.options?(opts) and opts[:limit] <= 8,
         {:ok, client, activities, discovery} <- activity(client, opts),
         {:ok, snapshot, cut, last_complete, preview_cut} <- collect_prompts(client, activities),
         {:ok, snapshot} <- Controls.replace(client.controls, snapshot) do
      discovery = %{
        discovery
        | truncated: discovery.truncated or cut or preview_cut,
          incomplete:
            discovery.incomplete or
              Enum.any?(
                activities,
                &(&1["execution"] == "not_observed" and &1["delivery_status"] != "completed")
              )
      }

      discovery =
        if cut and last_complete do
          %{discovery | has_more: true, next_cursor: discovery.positions[last_complete]}
        else
          discovery
        end

      discovery = Map.delete(discovery, :positions)
      {:ok, %{client | controls: snapshot, controls_discovery: discovery}}
    else
      false -> {:error, :invalid_control_request}
      error -> error
    end
  end

  def clear_controls(%Client{} = client),
    do: %{
      client
      | controls: Controls.new(),
        controls_discovery: %{
          has_more: false,
          incomplete: false,
          truncated: false,
          next_cursor: nil
        }
    }

  def controls_projection(%Client{} = client) do
    {:ok, projection} = Controls.project(client.controls)
    projection
  end

  defp collect_prompts(client, activities) do
    initial = %{"activities" => activities, "interactions" => []}

    Enum.reduce_while(activities, {:ok, initial, false, nil, false}, fn activity,
                                                                        {:ok, snapshot, _,
                                                                         last_complete,
                                                                         preview_cut} ->
      cond do
        activity["execution"] != "running" ->
          {:cont, {:ok, snapshot, false, activity["command_id"], preview_cut}}

        length(snapshot["interactions"]) >= 50 ->
          {:halt, {:ok, snapshot, true, last_complete, preview_cut}}

        true ->
          with {:ok, _, prompts} <- interactions(client, activity["command_id"]),
               {:ok, snapshot, trimmed} <- fit_first_prompts(snapshot, prompts) do
            {next, cut} =
              Enum.reduce_while(prompts, {snapshot, false}, fn prompt, {acc, _} ->
                candidate = Map.update!(acc, "interactions", &(&1 ++ [prompt]))

                if ControlCodec.bounded?(candidate),
                  do: {:cont, {candidate, false}},
                  else: {:halt, {acc, true}}
              end)

            if cut,
              do: {:halt, {:ok, next, true, last_complete, preview_cut or trimmed}},
              else: {:cont, {:ok, next, false, activity["command_id"], preview_cut or trimmed}}
          else
            error -> {:halt, error}
          end
      end
    end)
  end

  # The first nonempty prompt batch must be admitted in full. Defaults can make
  # normalized activity JSON larger than its raw host page, so two raw128KiB
  # bounds alone do not prove fit. Discard only display previews if necessary.
  defp fit_first_prompts(%{"interactions" => []} = snapshot, prompts) do
    if ControlCodec.bounded?(Map.put(snapshot, "interactions", prompts)) do
      {:ok, snapshot, false}
    else
      trimmed =
        Map.update!(snapshot, "activities", fn records ->
          Enum.map(records, fn record ->
            %{
              record
              | "preview" => "",
                "preview_truncated" => record["preview_truncated"] or record["preview"] != ""
            }
          end)
        end)

      if ControlCodec.bounded?(Map.put(trimmed, "interactions", prompts)),
        do: {:ok, trimmed, true},
        else: {:error, :invalid_control_response}
    end
  end

  defp fit_first_prompts(snapshot, _prompts), do: {:ok, snapshot, false}

  @doc false
  def decode_control_response(context, data), do: ControlCodec.wire(context, data)

  @doc "Return only semantic display data; no proof, principal, target or metadata."
  def projection(%Client{} = client) do
    deliveries = Map.merge(client.commands, client.observed, fn _, a, b -> newer(a, b) end)
    Snapshot.project(client.messages, Map.values(deliveries), client.notices)
  end

  @doc "Read one separately authenticated bounded notice page; no publication or transcript effect."
  def notices(client, opts \\ [])
  def notices(%Client{engagement: nil}, _opts), do: {:error, :conversation_not_attached}

  def notices(%Client{} = client, opts) do
    opts = Keyword.put_new(opts, :limit, 8)

    with :ok <- NoticeCodec.options(opts),
         {:ok, raw} <- request(client, :notices, nil, opts),
         expected = %{target_agent_id: client.target, engagement_id: client.engagement},
         expected =
           if(client.owner, do: Map.put(expected, :owner_id, client.owner), else: expected),
         {:ok, page, records} <- NoticeCodec.page(raw, expected, opts),
         true <- page["head"] >= client.notice_head,
         {:ok, bound} <- bind_owner(client, page["owner_id"]),
         true <- notice_records_consistent?(client.notices, records) do
      window = %{
        head: page["head"],
        through: page["through"],
        has_older: page["has_older"],
        next_before: page["next_before"],
        complete: true
      }

      {:ok, %{bound | notices: records, notice_head: page["head"]}, window}
    else
      false -> {:error, :invalid_notice_response}
      {:error, :invalid_transport_response} -> {:error, :invalid_notice_response}
      error -> error
    end
  rescue
    _ -> {:error, :invalid_notice_request}
  end

  @doc "Clear disposable notice display data without removing a canonical owner fence."
  def clear_notices(%Client{} = client), do: %{client | notices: []}

  defp notice_records_consistent?(previous, records) do
    ids = Map.new(previous, &{&1["id"], &1})
    ordinals = Map.new(previous, &{&1["ordinal"], &1})

    Enum.all?(records, fn record ->
      (not Map.has_key?(ids, record["id"]) or ids[record["id"]] == record) and
        (not Map.has_key?(ordinals, record["ordinal"]) or ordinals[record["ordinal"]] == record)
    end)
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

  defp history_entries(client, entries, scope \\ :history) do
    Enum.reduce_while(entries, {:ok, [], client.message_ids, client.history.cursor}, fn entry,
                                                                                        {:ok, acc,
                                                                                         ids,
                                                                                         last} ->
      if history_entry_shape?(entry, scope) and identifier?(entry.id) and
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

        message =
          case Map.fetch(entry, :status) do
            {:ok, status} -> Map.put(message, "status", status)
            :error -> message
          end

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

  defp history_entry_shape?(entry, scope) do
    keys = ~w(id role content timestamp entry_ordinal)a

    exact?(entry, keys) or
      (scope == :window and exact?(entry, keys ++ [:status]) and
         entry.role == "assistant" and entry.status in @assistant_statuses)
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

  defp known_kind(kind)
       when kind in ~w(admitted dispatch_started settled cancel_requested cancel_acknowledged),
       do: :ok

  defp known_kind(_), do: {:error, :unsupported_event_kind}

  defp transition(nil, %{"status" => "admitted"} = next, "admitted") do
    if next["admitted_cursor"] == next["updated_cursor"] and cancel_status(next) == "none",
      do: :ok,
      else: {:error, :invalid_command_transition}
  end

  defp transition(old, next, kind) when is_map(old) do
    allowed =
      case kind do
        "dispatch_started" ->
          old["status"] == "admitted" and next["status"] == "dispatch_started" and
            cancel_status(old) == "none" and cancellation_equal?(old, next)

        "settled" ->
          old["status"] == "dispatch_started" and next["status"] in ~w(completed uncertain) and
            cancellation_equal?(old, next)

        "cancel_requested" ->
          old["status"] in ~w(admitted dispatch_started completed uncertain) and
            delivery_fact_equal?(old, next) and cancel_status(old) == "none" and
            cancel_status(next) == "requested"

        "cancel_acknowledged" ->
          delivery_fact_equal?(old, next) and cancel_status(old) == "requested" and
            cancel_status(next) == "confirmed"

        _ ->
          false
      end

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
    with true <-
           exact?(command, @command_keys) or exact?(command, @command_keys ++ [:cancellation]),
         {:ok, cancellation} <- ControlCodec.cancellation(Map.get(command, :cancellation)),
         true <- ControlCodec.cancellation_delivery?(command.status, cancellation),
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
         "updated_cursor" => command.updated_cursor,
         "cancellation" => cancellation
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
    base =
      case command.status do
        :admitted -> 0
        :dispatch_started -> 1
        status when status in [:completed, :uncertain] -> 2
        _ -> 0
      end

    cancellation =
      case get_in(command, [:cancellation, :status]) do
        :requested -> 1
        :confirmed -> 2
        _ -> 0
      end

    valid =
      if base + cancellation == 0,
        do: command.updated_cursor == command.admitted_cursor,
        else: command.updated_cursor >= command.admitted_cursor + base + cancellation

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
        if old["updated_cursor"] == next["updated_cursor"] do
          old == next
        else
          cancellation_progress?(earlier, later) and
            case earlier["status"] do
              terminal when terminal in ~w(completed uncertain) ->
                delivery_fact_equal?(earlier, later) and
                  cancel_status(earlier) != cancel_status(later)

              "dispatch_started" ->
                later["status"] in ~w(dispatch_started completed uncertain)

              "admitted" ->
                later["status"] in ~w(admitted dispatch_started completed uncertain)

              _ ->
                false
            end
        end

    if valid, do: :ok, else: {:error, :conflicting_response}
  end

  defp cancel_status(delivery), do: get_in(delivery, ["cancellation", "status"]) || "none"
  defp cancellation_equal?(a, b), do: a["cancellation"] == b["cancellation"]

  defp delivery_fact_equal?(a, b),
    do: Map.take(a, ~w(status result_text reason)) == Map.take(b, ~w(status result_text reason))

  defp cancellation_progress?(earlier, later) do
    from = cancel_status(earlier)
    to = cancel_status(later)

    cond do
      from == to -> cancellation_equal?(earlier, later)
      earlier["status"] == "completed" -> false
      from == "none" and to in ~w(requested confirmed) -> true
      from == "requested" and to == "confirmed" -> true
      true -> false
    end
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

      {:error, reason} when reason in [:unauthorized, :approval_answer_required] ->
        {:error, reason}

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
        :window ->
          {:conversation_window, [client.caller, client.target, opts]}

        :history ->
          {:conversation_history, [client.caller, client.target, opts]}

        :events ->
          {:conversation_events, [client.caller, client.target, input, opts]}

        :command ->
          {:conversation_command, [client.caller, client.target, input, opts]}

        :submit ->
          {:submit_conversation_command, [client.caller, client.target, input, opts]}

        :activity ->
          {:conversation_activity, [client.caller, client.target, opts]}

        :notices ->
          {:conversation_notices, [client.caller, client.target, opts]}

        :cancel ->
          {:cancel_conversation_command, [client.caller, client.target, input, opts]}

        :interactions ->
          {:conversation_interactions, [client.caller, client.target, input, opts]}

        :interaction_choice ->
          {:answer_conversation_choice, [client.caller, client.target, input, opts]}

        :interaction_approval ->
          {:answer_conversation_approval, [client.caller, client.target, input, opts]}
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
      Keyword.get(opts, :max_pages, 20) in 1..100 and
      (not Keyword.has_key?(opts, :expected_engagement_id) or
         (is_binary(opts[:expected_engagement_id]) and
            Regex.match?(~r/\Aeng_[0-9a-f]{32}\z/, opts[:expected_engagement_id])))
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
