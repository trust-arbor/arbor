defmodule Arbor.Comms.Channels.Voice.Session do
  @moduledoc """
  Voice conversation session between an Android phone and an Arbor agent.

  Coordinates the turn loop: phone listens (STT) -> agent processes ->
  phone speaks (TTS) -> repeat. The actual conversation state lives in
  the agent's existing session infrastructure — this GenServer only
  manages the voice I/O coordination.

  ## Usage

      # Single turn (listen, process, speak)
      {:ok, pid} = Session.start_link(phone_node: :"beamapp@10.42.42.205")
      {:ok, response} = Session.conversation_turn(pid, "How's the weather?")

      # Or listen from the phone mic
      {:ok, response} = Session.voice_turn(pid)

      # Continuous conversation loop
      Session.start_loop(pid)
      Session.stop_loop(pid)
  """

  use GenServer

  require Logger

  alias Arbor.Comms.Channels.Voice

  @default_listen_seconds 5
  @thinking_message "Thinking..."

  # -- Client API --

  @doc """
  Start a voice session.

  ## Options

    - `:phone_node` — the phone's BEAM node name (required)
    - `:agent_id` — Arbor agent ID to converse with (uses first agent if nil)
    - `:homelab_node` — node to RPC for agent chat when running on a remote device (optional)
    - `:listen_mode` — `:listen`, `:stream_listen`, or `:buddie_listen` (default: `:listen`)
    - `:listen_seconds` — how long to listen (default: #{@default_listen_seconds})
    - `:voice` — TTS voice index (0-7)
    - `:thinking_sound` — whether to play a thinking indicator (default: true)
    - `:name` — GenServer name for registration
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Execute a single voice turn: listen on phone -> send to agent -> speak response.

  Returns `{:ok, %{transcript: String.t(), response: String.t()}}` on success.
  """
  @spec voice_turn(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def voice_turn(server, opts \\ []) do
    GenServer.call(server, {:voice_turn, opts}, :infinity)
  end

  @doc """
  Execute a text-initiated turn: send text to agent, speak the response.

  Skips STT — useful for testing or text-triggered voice responses.
  """
  @spec conversation_turn(GenServer.server(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def conversation_turn(server, text, opts \\ []) do
    GenServer.call(server, {:conversation_turn, text, opts}, :infinity)
  end

  @doc "Start a continuous conversation loop."
  @spec start_loop(GenServer.server()) :: :ok
  def start_loop(server) do
    GenServer.cast(server, :start_loop)
  end

  @doc "Stop the continuous conversation loop."
  @spec stop_loop(GenServer.server()) :: :ok
  def stop_loop(server) do
    GenServer.cast(server, :stop_loop)
  end

  @doc "Get session status."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  # -- Server --

  @impl true
  def init(opts) do
    phone_node = Keyword.fetch!(opts, :phone_node)

    state = %{
      phone_node: phone_node,
      agent_id: Keyword.get(opts, :agent_id),
      homelab_node: Keyword.get(opts, :homelab_node),
      listen_mode: Keyword.get(opts, :listen_mode, :listen),
      listen_seconds: Keyword.get(opts, :listen_seconds, @default_listen_seconds),
      voice: Keyword.get(opts, :voice),
      thinking_sound: Keyword.get(opts, :thinking_sound, true),
      looping: false,
      turn_count: 0,
      last_turn_at: nil,
      started_at: DateTime.utc_now()
    }

    Logger.info("[Voice.Session] Started for phone=#{phone_node}, agent=#{state.agent_id || "auto"}")
    {:ok, state}
  end

  @impl true
  def handle_call({:voice_turn, opts}, _from, state) do
    case do_listen(state, opts) do
      {:ok, transcript} when transcript != "" ->
        case do_agent_turn(transcript, state, opts) do
          {:ok, response} when response != "" ->
            do_speak(response, state, opts)
            new_state = bump_turn(state)
            {:reply, {:ok, %{transcript: transcript, response: response}}, new_state}

          {:ok, response} ->
            new_state = bump_turn(state)
            {:reply, {:ok, %{transcript: transcript, response: response}}, new_state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      {:ok, _empty} ->
        Logger.info("[Voice.Session] No speech detected")
        {:reply, {:ok, %{transcript: "", response: ""}}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:conversation_turn, text, opts}, _from, state) do
    case do_agent_turn(text, state, opts) do
      {:ok, response} when response != "" ->
        do_speak(response, state, opts)
        new_state = bump_turn(state)
        {:reply, {:ok, %{transcript: text, response: response}}, new_state}

      {:ok, response} ->
        new_state = bump_turn(state)
        {:reply, {:ok, %{transcript: text, response: response}}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state) do
    info = %{
      phone_node: state.phone_node,
      agent_id: state.agent_id,
      listen_mode: state.listen_mode,
      looping: state.looping,
      turn_count: state.turn_count,
      last_turn_at: state.last_turn_at,
      started_at: state.started_at,
      phone_reachable: Voice.ping(state.phone_node)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast(:start_loop, state) do
    Logger.info("[Voice.Session] Starting conversation loop")
    Voice.toast(state.phone_node, "Voice session active")
    send(self(), :loop_turn)
    {:noreply, %{state | looping: true}}
  end

  def handle_cast(:stop_loop, state) do
    Logger.info("[Voice.Session] Stopping conversation loop")
    Voice.toast(state.phone_node, "Voice session ended")
    {:noreply, %{state | looping: false}}
  end

  @impl true
  def handle_info(:loop_turn, %{looping: false} = state) do
    {:noreply, state}
  end

  def handle_info(:loop_turn, %{looping: true} = state) do
    case do_listen(state, []) do
      {:ok, transcript} when transcript != "" ->
        case do_agent_turn(transcript, state, []) do
          {:ok, response} ->
            do_speak(response, state, [])
            new_state = bump_turn(state)
            # Schedule next turn after TTS finishes
            send(self(), :loop_turn)
            {:noreply, new_state}

          {:error, reason} ->
            Logger.warning("[Voice.Session] Agent error in loop: #{inspect(reason)}")
            Voice.speak(state.phone_node, "Sorry, I had trouble processing that.")
            send(self(), :loop_turn)
            {:noreply, state}
        end

      {:ok, _empty} ->
        # No speech detected, try again
        send(self(), :loop_turn)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Voice.Session] Listen error in loop: #{inspect(reason)}")
        # Brief pause before retrying
        Process.send_after(self(), :loop_turn, 2_000)
        {:noreply, state}
    end
  end

  # -- Turn Implementation --

  defp do_listen(state, opts) do
    seconds = Keyword.get(opts, :listen_seconds, state.listen_seconds)
    mode = Keyword.get(opts, :listen_mode, state.listen_mode)

    Logger.info("[Voice.Session] Listening (#{mode}, #{seconds}s)")

    case mode do
      :listen -> Voice.listen(state.phone_node, seconds)
      :stream_listen -> Voice.stream_listen(state.phone_node, seconds)
      :buddie_listen -> Voice.buddie_listen(state.phone_node, seconds)
    end
  end

  defp do_agent_turn(transcript, state, _opts) do
    Logger.info("[Voice.Session] Processing: #{String.slice(transcript, 0..80)}")

    # Show thinking indicator
    if state.thinking_sound do
      Voice.toast(state.phone_node, @thinking_message)
    end

    case agent_chat(transcript, state) do
      {:ok, response} ->
        Logger.info(
          "[Voice.Session] Response: #{String.slice(response, 0..80)}" <>
            " (#{String.length(response)} chars)"
        )

        {:ok, response}

      {:error, reason} = error ->
        Logger.warning("[Voice.Session] Agent error: #{inspect(reason)}")
        error
    end
  end

  defp do_speak(text, state, opts) do
    voice_opts = if state.voice, do: [voice: state.voice], else: []
    voice_opts = Keyword.merge(voice_opts, Keyword.take(opts, [:voice, :timeout]))

    Logger.info("[Voice.Session] Speaking #{String.length(text)} chars")
    Voice.speak(state.phone_node, text, voice_opts)
  end

  defp bump_turn(state) do
    %{state | turn_count: state.turn_count + 1, last_turn_at: DateTime.utc_now()}
  end

  # Try local Manager first, fall back to RPC to homelab node
  defp agent_chat(input, state) do
    manager = Arbor.Agent.Manager

    cond do
      # Local Manager is running
      Code.ensure_loaded?(manager) and function_exported?(manager, :chat, 3) and
          Process.whereis(Arbor.Agent.Supervisor) != nil ->
        chat_opts = if state.agent_id, do: [agent_id: state.agent_id], else: []
        apply(manager, :chat, [input, "Voice", chat_opts])

      # RPC to homelab
      state.homelab_node != nil ->
        chat_opts = if state.agent_id, do: [agent_id: state.agent_id], else: []

        case :rpc.call(state.homelab_node, manager, :chat, [input, "Voice", chat_opts], 60_000) do
          {:badrpc, reason} -> {:error, {:homelab_rpc_failed, reason}}
          result -> result
        end

      true ->
        {:error, :agent_manager_unavailable}
    end
  end
end
