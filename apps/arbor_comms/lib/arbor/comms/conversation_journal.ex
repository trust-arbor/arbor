defmodule Arbor.Comms.ConversationJournal do
  @moduledoc """
  Durable, append-only evidence for authenticated conversation ingress.

  Agent owns authentication and private engagement binding; this module accepts
  only the resulting scope. It never executes a turn or grants execution
  authority. A fresh successful claim permits its caller to attempt the existing
  Session ingress once. A saved claim is never handed out again, even if the
  claiming BEAM disappears before calling Session. Such commands remain factual
  `:dispatch_started` until their source owner can supply a terminal outcome.

  All operations use the public Persistence facade and a node-restart durable
  target (Ecto by default). Reads reconstruct a pinned prefix in bounded pages;
  this initial implementation costs O(history) and does not prune identities.
  Storage errors, gaps, unknown event kinds and malformed history fail closed.
  A journal cursor covers only these ingress events, not the separate Session
  transcript. Claim tokens are excluded from all replay/read projections.
  """

  alias Arbor.Comms.Config
  alias Arbor.Comms.ConversationJournalCore, as: Core
  alias Arbor.Persistence

  @page_size 100
  @max_attempts 12

  def admit(scope, command) do
    guarded(fn ->
      with :ok <- Core.validate_scope(scope),
           :ok <- Core.validate_command(command),
           {:ok, target} <- target() do
        mutate(target, scope, {:admit, command}, @max_attempts)
      end
    end)
  end

  def get(scope, id) do
    guarded(fn ->
      with :ok <- Core.validate_scope(scope),
           :ok <- Core.validate_id(id),
           {:ok, target} <- target(),
           {:ok, state, _events, _head} <- load(target, scope, 0, nil, 0) do
        Core.get(state, id)
      end
    end)
  end

  def claim(scope, id) do
    guarded(fn ->
      with :ok <- Core.validate_scope(scope),
           :ok <- Core.validate_id(id),
           {:ok, target} <- target() do
        # Generated once for this invocation; never accepted from a client.
        mutate(target, scope, {:claim, id, token()}, @max_attempts)
      end
    end)
  end

  def settle(scope, id, claim_token, outcome) do
    guarded(fn ->
      with :ok <- Core.validate_scope(scope),
           :ok <- Core.validate_id(id),
           true <- Core.valid_token?(claim_token),
           :ok <- Core.validate_outcome(outcome),
           {:ok, target} <- target() do
        mutate(target, scope, {:settle, id, claim_token, outcome}, @max_attempts)
      else
        false -> {:error, :invalid_claim}
        {:error, _} = error -> error
      end
    end)
  end

  def events(scope, after_cursor, opts \\ []) do
    guarded(fn ->
      with :ok <- Core.validate_scope(scope),
           {:ok, through, limit} <- page_options(after_cursor, opts),
           {:ok, target} <- target(),
           {:ok, _state, events, head} <- load(target, scope, after_cursor, through, limit) do
        cursor =
          case List.last(events) do
            nil -> after_cursor
            event -> event.cursor
          end

        {:ok, %{events: events, cursor: cursor, head: head, has_more: cursor < head}}
      end
    end)
  end

  defp target do
    with {:ok, target} <- Config.conversation_journal(),
         {:ok, :node_restart} <-
           Persistence.durability_class(target.name, target.backend, target.opts),
         true <-
           Enum.all?(
             [append: 3, reconcile_append: 2, read_stream_head: 2, read_stream_range: 2],
             fn {name, arity} ->
               function_exported?(target.backend, name, arity)
             end
           ) do
      {:ok, target}
    else
      {:error, _} = error -> error
      _ -> {:error, :journal_not_durable}
    end
  end

  defp mutate(_target, _scope, _operation, 0), do: {:error, :journal_busy}

  defp mutate(target, scope, operation, attempts) do
    with {:ok, state, _events, _head} <- load(target, scope, 0, nil, 0) do
      case Core.decide(state, operation) do
        {:return, command} ->
          {:ok, command}

        {:error, _} = error ->
          error

        {:append, type, kind, data} ->
          event =
            Persistence.new_event(Core.stream_id(scope), type, data,
              id: Core.event_id(scope, data["command_id"], kind),
              agent_id: scope.agent_id,
              metadata: %{"attempt_id" => token()}
            )

          case commit(target, event, state.cursor) do
            {:ok, committed} ->
              with {:ok, updated, _public} <- Core.apply_event(state, committed) do
                mutation_result(updated, operation)
              end

            {:error, :version_conflict} ->
              # Exact append operations are fenced after version failure. The
              # next attempt must have a new event timestamp/attempt identity.
              mutate(target, scope, operation, attempts - 1)

            {:error, :event_identity_conflict} ->
              resolve_identity_conflict(target, scope, operation)

            {:error, _} = error ->
              error
          end
      end
    end
  end

  defp resolve_identity_conflict(target, scope, operation) do
    with {:ok, state, _events, _head} <- load(target, scope, 0, nil, 0) do
      case Core.decide(state, operation) do
        {:return, command} -> {:ok, command}
        {:error, _} = error -> error
        {:append, _, _, _} -> {:error, :command_conflict}
      end
    end
  end

  defp mutation_result(_state, {:claim, _id, claim_token}), do: {:ok, claim_token}
  defp mutation_result(state, {:admit, command}), do: Core.get(state, command.id)
  defp mutation_result(state, {:settle, id, _token, _outcome}), do: Core.get(state, id)

  defp commit(target, event, expected_version) do
    opts = Keyword.put(target.opts, :expected_version, expected_version)

    case Persistence.append(target.name, target.backend, event.stream_id, [event], opts) do
      {:ok, [committed]} ->
        verify_commit(event, committed)

      {:error, {:append_indeterminate, operation}} ->
        case Persistence.reconcile_append(target.name, target.backend, operation, target.opts) do
          {:ok, {:committed, [committed]}} -> verify_commit(event, committed)
          _ -> {:error, :journal_commit_unresolved}
        end

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_journal_acknowledgement}
    end
  end

  defp verify_commit(event, committed) do
    if Persistence.committed_event_matches_submission?(event.stream_id, event, committed),
      do: {:ok, committed},
      else: {:error, :invalid_journal_acknowledgement}
  end

  defp load(target, scope, after_cursor, through, limit) do
    stream = Core.stream_id(scope)

    with {:ok, head_event} <-
           Persistence.read_stream_head(target.name, target.backend, stream, target.opts),
         {:ok, current_head} <- head_cursor(head_event, scope),
         head = if(is_nil(through), do: current_head, else: through),
         true <- head <= current_head and after_cursor <= head,
         {:ok, state, events} <-
           read_prefix(target, Core.new(scope), head, after_cursor, limit, []) do
      {:ok, state, Enum.reverse(events), head}
    else
      false -> {:error, :invalid_cursor}
      {:error, _} = error -> error
      _ -> {:error, :invalid_journal}
    end
  end

  defp head_cursor(nil, _scope), do: {:ok, 0}

  defp head_cursor(%{event_number: cursor} = event, scope)
       when is_integer(cursor) and cursor > 0 do
    if valid_stored_event?(event, scope), do: {:ok, cursor}, else: {:error, :invalid_journal}
  end

  defp head_cursor(_, _scope), do: {:error, :invalid_journal}

  defp read_prefix(_target, %{cursor: head} = state, head, _after, _limit, events),
    do: {:ok, state, events}

  defp read_prefix(target, state, head, after_cursor, limit, collected) do
    opts = Keyword.merge(target.opts, from: state.cursor + 1, to: head, limit: @page_size)

    with {:ok, page} <-
           Persistence.read_stream_range(
             target.name,
             target.backend,
             Core.stream_id(state.scope),
             opts
           ),
         true <- is_list(page) and length(page) in 1..@page_size,
         {:ok, next_state, events} <- fold_page(state, page, head, after_cursor, limit, collected) do
      read_prefix(target, next_state, head, after_cursor, limit, events)
    else
      false -> {:error, :invalid_journal}
      {:error, _} = error -> error
      _ -> {:error, :invalid_journal}
    end
  end

  defp fold_page(state, page, head, after_cursor, limit, collected) do
    Enum.reduce_while(page, {:ok, state, collected}, fn event, {:ok, current, events} ->
      with true <- valid_stored_event?(event, state.scope) and event.event_number <= head,
           {:ok, updated, public_event} <- Core.apply_event(current, event) do
        next_events =
          if public_event.cursor > after_cursor and length(events) < limit,
            do: [public_event | events],
            else: events

        {:cont, {:ok, updated, next_events}}
      else
        _ -> {:halt, {:error, :invalid_journal}}
      end
    end)
  end

  defp valid_stored_event?(event, scope) do
    with %{stream_id: stream, agent_id: agent_id, metadata: %{"attempt_id" => attempt} = metadata} <-
           event,
         true <- stream == Core.stream_id(scope) and agent_id == scope.agent_id,
         true <- map_size(metadata) == 1 and Core.valid_token?(attempt) do
      Persistence.committed_event_matches_submission?(stream, event, event)
    else
      _ -> false
    end
  end

  defp page_options(cursor, opts) do
    if is_integer(cursor) and cursor >= 0 and is_list(opts) and Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:through, :limit])) do
      through = Keyword.get(opts, :through)
      limit = Keyword.get(opts, :limit, @page_size)

      if (is_nil(through) or (is_integer(through) and through >= cursor)) and
           is_integer(limit) and limit in 1..@page_size,
         do: {:ok, through, limit},
         else: {:error, :invalid_cursor}
    else
      {:error, :invalid_cursor}
    end
  end

  defp token, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:error, :journal_unavailable}
  catch
    _, _ -> {:error, :journal_unavailable}
  end
end
