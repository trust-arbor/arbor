defmodule ConversationDemo.ComparisonFixtureFacade do
  @moduledoc false
  @engagement "eng_11111111111111111111111111111111"

  def initial,
    do: %{
      entries: [],
      events: [],
      commands: %{},
      calls: [],
      mode: :normal,
      proofs: 0,
      owner: "human-fixture",
      engagement: @engagement
    }

  def seed(entries), do: Agent.update(__MODULE__, &%{&1 | entries: entries})

  def owner(owner), do: Agent.update(__MODULE__, &%{&1 | owner: owner})

  def remap do
    Agent.update(
      __MODULE__,
      &%{
        &1
        | owner: "human-new-owner",
          engagement: "eng_22222222222222222222222222222222",
          entries: [],
          events: [],
          commands: %{}
      }
    )
  end

  def mode(mode), do: Agent.update(__MODULE__, &%{&1 | mode: mode})
  def state, do: Agent.get(__MODULE__, & &1)

  def proof(_context) do
    n =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.proofs + 1, %{state | proofs: state.proofs + 1}}
      end)

    {:ok, [session_token: "private-proof-#{n}"]}
  end

  def conversation_history(caller, target, opts), do: request(:history, caller, target, nil, opts)

  def conversation_events(caller, target, cursor, opts),
    do: request(:events, caller, target, cursor, opts)

  def conversation_command(caller, target, id, opts),
    do: request(:command, caller, target, id, opts)

  def submit_conversation_command(caller, target, command, opts),
    do: request(:submit, caller, target, command, opts)

  defp request(operation, caller, target, input, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = %{state | calls: state.calls ++ [{operation, input, opts}]}

      cond do
        caller != "human-fixture" or target != "agent-fixture" ->
          {{:error, :unauthorized}, state}

        state.mode == :denied ->
          {{:error, :unauthorized}, state}

        opts[:expected_engagement_id] && opts[:expected_engagement_id] != state.engagement ->
          {{:error, :conversation_scope_changed}, state}

        operation == :history and state.mode == :read_error ->
          {{:error, :conversation_unavailable}, state}

        true ->
          respond(operation, input, opts, state)
      end
    end)
  end

  defp respond(:history, _, opts, state) do
    page = page(state.entries, :entry_ordinal, Keyword.get(opts, :after, 0), opts)

    {{:ok,
      Map.merge(page, %{engagement_id: state.engagement, entries: page.items})
      |> Map.delete(:items)}, state}
  end

  defp respond(:events, after_cursor, opts, state) do
    page = page(state.events, :cursor, after_cursor, opts)

    {{:ok,
      Map.merge(page, %{events: page.items, engagement_id: state.engagement})
      |> Map.delete(:items)}, state}
  end

  defp respond(:command, id, _, state),
    do: {Map.fetch(state.commands, id) |> command_result(), state}

  defp respond(:submit, _command, _, %{mode: :unsupported_capability} = state),
    do: {{:error, :unsupported_conversation_capability}, state}

  defp respond(:submit, _command, _, %{mode: :reject} = state),
    do: {{:error, :invalid_command}, state}

  defp respond(:submit, _command, _, %{mode: :conflict} = state),
    do: {{:error, :command_conflict}, state}

  defp respond(:submit, _command, _, %{mode: :ambiguous_missing} = state),
    do: {{:error, :conversation_unavailable}, %{state | mode: :normal}}

  defp respond(:submit, input, _, state) do
    case Map.fetch(state.commands, input.id) do
      {:ok, command} ->
        {{:ok, command}, state}

      :error ->
        cursor = length(state.events) + 1

        command = %{
          id: input.id,
          name: "chat.send",
          text: input.text,
          principal_id: state.owner,
          agent_id: "agent-fixture",
          engagement_id: state.engagement,
          status: :admitted,
          outcome: nil,
          admitted_cursor: cursor,
          updated_cursor: cursor
        }

        event = %{id: "event-#{cursor}", cursor: cursor, kind: "admitted", command: command}

        entry = %{
          id: "message-#{cursor}",
          role: "user",
          content: input.text,
          timestamp: "2026-09-27T00:00:00Z",
          entry_ordinal: length(state.entries) + 1
        }

        mode =
          case state.mode do
            :read_fails_after_submit -> :read_error
            :unauthorized_saved -> :denied
            _ -> :normal
          end

        next = %{
          state
          | commands: Map.put(state.commands, command.id, command),
            events: state.events ++ [event],
            entries: state.entries ++ [entry],
            mode: mode
        }

        reply =
          case state.mode do
            :ambiguous_saved -> {:error, :conversation_unavailable}
            :unauthorized_saved -> {:error, :unauthorized}
            _ -> {:ok, command}
          end

        {reply, next}
    end
  end

  defp command_result({:ok, command}), do: {:ok, command}
  defp command_result(:error), do: {:error, :not_found}

  defp page(items, key, after_cursor, opts) do
    latest = items |> List.last() |> then(&if(&1, do: Map.fetch!(&1, key), else: 0))
    head = Keyword.get(opts, :through, latest)

    selected =
      Enum.filter(items, &(Map.fetch!(&1, key) > after_cursor and Map.fetch!(&1, key) <= head))
      |> Enum.take(Keyword.get(opts, :limit, 50))

    cursor = selected |> List.last() |> then(&if(&1, do: Map.fetch!(&1, key), else: head))
    %{items: selected, cursor: cursor, head: head, has_more: cursor < head}
  end
end
