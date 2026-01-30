defmodule Arbor.Comms.MessageHandler do
  @moduledoc """
  Processes inbound messages: authorizes, deduplicates, classifies,
  and dispatches to the configured ResponseGenerator for AI responses.

  Started by the Supervisor when handler config is enabled.
  Called directly by the Router with full Message structs.
  """

  use GenServer

  alias Arbor.Comms.ChatLogger
  alias Arbor.Comms.Config
  alias Arbor.Comms.ConversationBuffer
  alias Arbor.Comms.Dispatcher
  alias Arbor.Contracts.Comms.Message

  require Logger

  @dedup_table :comms_message_dedup

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Process an inbound message. Called by the Router.

  Authorization, deduplication, and classification happen here.
  If the message passes all checks, it's dispatched for response.
  """
  @spec process(Message.t()) :: :ok | {:error, term()}
  def process(%Message{} = msg) do
    GenServer.cast(__MODULE__, {:process, msg})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    # Create ETS table for deduplication
    :ets.new(@dedup_table, [:set, :named_table, :public])

    # Schedule periodic dedup cleanup
    schedule_dedup_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:process, %Message{} = msg}, state) do
    case process_message(msg) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.debug("Message #{msg.id} skipped: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_dedup, state) do
    cleanup_dedup_table()
    schedule_dedup_cleanup()
    {:noreply, state}
  end

  # ============================================================================
  # Message Processing Pipeline
  # ============================================================================

  defp process_message(msg) do
    with :ok <- check_authorized(msg),
         :ok <- check_dedup(msg),
         action <- classify(msg) do
      handle_action(action, msg)
    end
  end

  defp check_authorized(%Message{from: from}) do
    allowed = Config.authorized_senders()

    if allowed == [] or from in allowed do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp check_dedup(%Message{id: id}) do
    window = Config.handler_config(:dedup_window_seconds, 300)
    now = System.system_time(:second)

    case :ets.lookup(@dedup_table, id) do
      [{^id, seen_at}] when now - seen_at < window ->
        {:error, :duplicate}

      _ ->
        :ets.insert(@dedup_table, {id, now})
        :ok
    end
  end

  defp classify(%Message{content: "/" <> _}), do: :command
  defp classify(_msg), do: :conversation

  # ============================================================================
  # Action Handlers
  # ============================================================================

  defp handle_action(:command, msg) do
    handle_command(msg)
  end

  defp handle_action(:conversation, msg) do
    generate_and_send_response(msg)
  end

  defp handle_command(%Message{content: "/help" <> _} = msg) do
    response = "Available commands: /help, /status"
    send_response(msg, response)
  end

  defp handle_command(%Message{content: "/status" <> _} = msg) do
    channels = Config.configured_channels()
    response = "Arbor comms active. Channels: #{Enum.join(channels, ", ")}"
    send_response(msg, response)
  end

  defp handle_command(%Message{} = msg) do
    response = "Unknown command. Try /help"
    send_response(msg, response)
  end

  defp generate_and_send_response(msg) do
    case Config.response_generator() do
      nil ->
        Logger.warning("No response_generator configured, skipping response")
        {:error, :no_generator}

      generator_module ->
        history = ConversationBuffer.recent_turns_cross_channel(msg.from)

        system_prompt = load_context_file()

        context = %{
          conversation_history: history,
          system_prompt: system_prompt
        }

        with {:ok, envelope} <- generator_module.generate_response(msg, context),
             {:ok, channel, routed} <- Config.response_router().route(msg, envelope) do
          Dispatcher.deliver_envelope(msg, channel, routed)
        else
          {:error, reason} ->
            Logger.warning("Response pipeline failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp send_response(%Message{} = msg, response) do
    # Log the inbound message
    ChatLogger.log_message(msg)

    # Send the response
    case Dispatcher.reply(msg, response) do
      :ok ->
        # Log the outbound response
        outbound = Message.outbound(msg.channel, msg.from, response)
        ChatLogger.log_message(outbound)
        :ok

      {:error, reason} ->
        Logger.warning("Failed to send response on #{msg.channel}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp load_context_file do
    case Config.context_file() do
      nil ->
        nil

      path ->
        expanded = Path.expand(path)

        case File.read(expanded) do
          {:ok, content} -> content
          {:error, _} -> nil
        end
    end
  end

  # ============================================================================
  # Dedup Cleanup
  # ============================================================================

  defp schedule_dedup_cleanup do
    # Clean up every 5 minutes
    Process.send_after(self(), :cleanup_dedup, :timer.minutes(5))
  end

  defp cleanup_dedup_table do
    window = Config.handler_config(:dedup_window_seconds, 300)
    cutoff = System.system_time(:second) - window

    # Delete entries older than the dedup window
    :ets.select_delete(@dedup_table, [
      {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [true]}
    ])
  end
end
