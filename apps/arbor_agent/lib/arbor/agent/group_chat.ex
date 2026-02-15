defmodule Arbor.Agent.GroupChat do
  @moduledoc """
  Multi-agent group chat server.

  Manages a conversation between N participants (agents and/or humans).
  Messages are broadcast via PubSub. Agent participants auto-respond
  when a message arrives from someone else (humans or other agents).

  ## Usage

      {:ok, group} = GroupChat.create("brainstorm", participants: [
        %{id: agent_id, name: "Alice", type: :agent, host_pid: alice_pid},
        %{id: "hysun", name: "Hysun", type: :human}
      ])
      GroupChat.send_message(group, "hysun", "Hysun", :human, "Hello everyone!")

  ## Auto-relay behavior

  When a message arrives:
  - If from a **human**: All agents respond in parallel (or sequential if configured)
  - If from an **agent**: Broadcast only, no relay (prevents infinite loops)

  ## Loop prevention

  Simple and reliable: only human messages trigger agent responses. Agent responses
  are added to history and broadcast to subscribers, but do not trigger additional
  agent queries. This prevents agent-to-agent feedback loops.
  """

  use GenServer
  require Logger

  alias Arbor.Agent.GroupChat.{Context, Message, Participant}

  @type group_id :: String.t()
  @type response_mode :: :parallel | :sequential

  @type state :: %{
          group_id: group_id(),
          name: String.t(),
          participants: %{String.t() => Participant.t()},
          messages: [Message.t()],
          pubsub_topic: String.t(),
          response_mode: response_mode(),
          max_history: pos_integer()
        }

  @default_max_history 50
  @default_response_mode :parallel
  @query_timeout 120_000

  # Client API

  @doc """
  Creates and starts a new group chat.

  ## Options

  - `:participants` - List of participant maps (required)
  - `:response_mode` - `:parallel` (default) or `:sequential`
  - `:max_history` - Number of messages to include in agent context (default: 50)

  ## Examples

      GroupChat.create("planning", participants: [
        %{id: "agent_123", name: "Alice", type: :agent, host_pid: pid},
        %{id: "user_1", name: "Hysun", type: :human}
      ])
  """
  @spec create(String.t(), keyword()) :: GenServer.on_start()
  def create(name, opts \\ []) do
    participants = Keyword.fetch!(opts, :participants)
    response_mode = Keyword.get(opts, :response_mode, @default_response_mode)
    max_history = Keyword.get(opts, :max_history, @default_max_history)

    group_id = generate_group_id()

    GenServer.start_link(
      __MODULE__,
      %{
        group_id: group_id,
        name: name,
        participants: participants,
        response_mode: response_mode,
        max_history: max_history
      },
      name: via_tuple(group_id)
    )
  end

  @doc """
  Sends a message to the group chat.

  This will:
  1. Add the message to history
  2. Broadcast to all subscribers via PubSub
  3. Trigger agent responses (only if message is from a human)
  """
  @spec send_message(
          GenServer.server(),
          String.t(),
          String.t(),
          Participant.participant_type(),
          String.t()
        ) :: :ok
  def send_message(server, sender_id, sender_name, sender_type, content) do
    GenServer.cast(
      server,
      {:send_message, sender_id, sender_name, sender_type, content}
    )
  end

  @doc """
  Adds a participant to the group chat.
  """
  @spec add_participant(GenServer.server(), map()) :: :ok
  def add_participant(server, participant_attrs) do
    GenServer.call(server, {:add_participant, participant_attrs})
  end

  @doc """
  Removes a participant from the group chat.
  """
  @spec remove_participant(GenServer.server(), String.t()) :: :ok
  def remove_participant(server, participant_id) do
    GenServer.call(server, {:remove_participant, participant_id})
  end

  @doc """
  Returns the message history (newest first).
  """
  @spec get_history(GenServer.server()) :: [Message.t()]
  def get_history(server) do
    GenServer.call(server, :get_history)
  end

  @doc """
  Returns the participants map.
  """
  @spec get_participants(GenServer.server()) :: %{String.t() => Participant.t()}
  def get_participants(server) do
    GenServer.call(server, :get_participants)
  end

  # Server Callbacks

  @impl true
  def init(%{
        group_id: group_id,
        name: name,
        participants: participant_attrs_list,
        response_mode: response_mode,
        max_history: max_history
      }) do
    # Build participants map
    participants =
      participant_attrs_list
      |> Enum.map(&Participant.new/1)
      |> Map.new(fn p -> {p.id, p} end)

    # Register in ExecutorRegistry so groups can be discovered
    Registry.register(Arbor.Agent.ExecutorRegistry, {:group, group_id}, %{})

    state = %{
      group_id: group_id,
      name: name,
      participants: participants,
      messages: [],
      pubsub_topic: "group_chat:#{group_id}",
      response_mode: response_mode,
      max_history: max_history
    }

    # Broadcast join events for initial participants
    Enum.each(participants, fn {_id, participant} ->
      broadcast(state, {:group_participant_joined, participant})
    end)

    {:ok, state}
  end

  @impl true
  def handle_call({:add_participant, attrs}, _from, state) do
    participant = Participant.new(attrs)
    new_participants = Map.put(state.participants, participant.id, participant)
    new_state = %{state | participants: new_participants}

    broadcast(new_state, {:group_participant_joined, participant})

    {:reply, :ok, new_state}
  end

  def handle_call({:remove_participant, participant_id}, _from, state) do
    new_participants = Map.delete(state.participants, participant_id)
    new_state = %{state | participants: new_participants}

    broadcast(new_state, {:group_participant_left, participant_id})

    {:reply, :ok, new_state}
  end

  def handle_call(:get_history, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:get_participants, _from, state) do
    {:reply, state.participants, state}
  end

  @impl true
  def handle_cast(
        {:send_message, sender_id, sender_name, sender_type, content},
        state
      ) do
    # Build and add message
    message =
      Message.new(%{
        group_id: state.group_id,
        sender_id: sender_id,
        sender_name: sender_name,
        sender_type: sender_type,
        content: content
      })

    new_state = %{state | messages: [message | state.messages]}

    # Broadcast to PubSub subscribers
    broadcast(new_state, {:group_message, message})

    # Relay to agents (only for human messages to prevent loops)
    relay_to_agents(message, new_state)

    {:noreply, new_state}
  end

  def handle_cast({:agent_response, participant, text}, state) do
    # Build message from agent response
    message =
      Message.new(%{
        group_id: state.group_id,
        sender_id: participant.id,
        sender_name: participant.name,
        sender_type: :agent,
        content: text
      })

    # Add to history and broadcast, but don't relay again (prevents loops)
    new_state = %{state | messages: [message | state.messages]}
    broadcast(new_state, {:group_message, message})

    {:noreply, new_state}
  end

  # Internal Helpers

  defp relay_to_agents(message, state) do
    # Only relay human messages (prevents infinite agent-to-agent loops)
    if message.sender_type != :agent do
      # Get all online agent participants except the sender
      agent_participants =
        state.participants
        |> Map.values()
        |> Enum.filter(&(&1.type == :agent))
        |> Enum.filter(&(&1.id != message.sender_id))
        |> Enum.filter(&Participant.agent_online?/1)

      # Query agents based on response mode
      case state.response_mode do
        :parallel ->
          query_agents_parallel(state, agent_participants)

        :sequential ->
          query_agents_sequential(state, agent_participants)
      end
    end
  end

  defp query_agents_parallel(state, agents) do
    server = self()

    Enum.each(agents, fn participant ->
      Task.start(fn ->
        query_single_agent(server, state, participant)
      end)
    end)
  end

  defp query_agents_sequential(state, agents) do
    server = self()

    Task.start(fn ->
      Enum.each(agents, fn participant ->
        query_single_agent(server, state, participant)
      end)
    end)
  end

  defp query_single_agent(server, state, participant) do
    try do
      # Build conversation context
      prompt =
        Context.build_agent_prompt(
          participant.name,
          state.messages,
          max_messages: state.max_history,
          group_name: state.name
        )

      # Query the agent's host process
      case GenServer.call(participant.host_pid, {:query, prompt, []}, @query_timeout) do
        {:ok, response} when is_binary(response) and response != "" ->
          # Send the agent's response back through the group
          GenServer.cast(server, {:agent_response, participant, response})

        {:ok, %{text: text}} when is_binary(text) and text != "" ->
          # Handle structured response with text field
          GenServer.cast(server, {:agent_response, participant, text})

        other ->
          Logger.debug("Agent #{participant.id} returned non-text response: #{inspect(other)}")
      end
    rescue
      error ->
        Logger.error("Error querying agent #{participant.id}: #{inspect(error)}")
    catch
      :exit, reason ->
        Logger.warning("Agent #{participant.id} process exited: #{inspect(reason)}")
    end
  end

  defp broadcast(state, message) do
    pubsub_module = get_pubsub_module()

    try do
      Phoenix.PubSub.broadcast(pubsub_module, state.pubsub_topic, message)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp get_pubsub_module do
    if Code.ensure_loaded?(Arbor.Web.PubSub) do
      Arbor.Web.PubSub
    else
      Phoenix.PubSub
    end
  end

  defp generate_group_id do
    suffix =
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)

    "grp_#{suffix}"
  end

  defp via_tuple(group_id) do
    {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:group, group_id}}}
  end
end
