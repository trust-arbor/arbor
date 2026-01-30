defmodule Arbor.Comms.ResponseRouter do
  @moduledoc """
  Routes responses to the appropriate channel based on envelope metadata.

  Implements layered channel resolution when the envelope's channel is `:auto`:

  1. **Content heuristics** — attachments, HTML, long body → email
  2. **Origin metadata** — `response_channel` hint from inbound message
  3. **Origin channel** — where the message came from

  After resolution, `ensure_sendable/2` verifies the channel supports
  outbound delivery. If not, it walks a fallback chain:

  1. `message.metadata[:response_channel]`
  2. `Config.default_response_channel()`
  3. `:signal`
  4. `{:error, :no_sendable_channel}`

  Explicit (non-`:auto`) channel hints are validated for both availability
  and sendability.
  """

  @behaviour Arbor.Contracts.Comms.ResponseRouter

  alias Arbor.Comms.Config
  alias Arbor.Comms.Dispatcher
  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  @long_body_threshold 2000

  @impl true
  @spec route(Message.t(), ResponseEnvelope.t()) ::
          {:ok, atom(), ResponseEnvelope.t()} | {:error, term()}
  def route(%Message{} = original, %ResponseEnvelope{channel: :auto} = envelope) do
    channel = resolve_auto(original, envelope)

    case ensure_sendable(channel, original) do
      {:ok, resolved} -> {:ok, resolved, envelope}
      {:error, _} = err -> err
    end
  end

  def route(%Message{} = original, %ResponseEnvelope{channel: channel} = envelope) do
    cond do
      channel not in available_channels() ->
        {:error, {:channel_unavailable, channel}}

      not can_send?(channel) ->
        # Explicit hint to a non-sendable channel — try fallback
        case ensure_sendable(channel, original) do
          {:ok, resolved} -> {:ok, resolved, envelope}
          {:error, _} = err -> err
        end

      true ->
        {:ok, channel, envelope}
    end
  end

  @impl true
  @spec available_channels() :: [atom()]
  def available_channels do
    Config.configured_channels()
  end

  # ============================================================================
  # Layered Auto-Resolution
  # ============================================================================

  defp resolve_auto(%Message{} = original, %ResponseEnvelope{} = envelope) do
    # Layer 1: Content heuristics
    cond do
      ResponseEnvelope.has_attachments?(envelope) -> :email
      envelope.format == :html -> :email
      byte_size(envelope.body) > @long_body_threshold -> :email
      true -> resolve_from_metadata(original)
    end
  end

  # Layer 2: Origin metadata (e.g. Limitless sets response_channel: :signal)
  defp resolve_from_metadata(%Message{metadata: metadata, channel: origin}) do
    case metadata[:response_channel] do
      nil -> origin
      channel when is_atom(channel) -> channel
      _ -> origin
    end
  end

  # ============================================================================
  # Capability Check & Fallback
  # ============================================================================

  @doc """
  Check whether a channel supports outbound delivery.

  Looks up the channel module via `Dispatcher.channel_module/1` and
  checks the `supports_outbound` field in `channel_info/0`.
  """
  @spec can_send?(atom()) :: boolean()
  def can_send?(channel) do
    Dispatcher.sender_module(channel) != nil
  end

  @doc """
  Verify the resolved channel can send; if not, walk a fallback chain.

  Fallback order:
  1. `message.metadata[:response_channel]`
  2. `Config.default_response_channel()`
  3. `:signal`
  4. `{:error, :no_sendable_channel}`
  """
  @spec ensure_sendable(atom(), Message.t()) :: {:ok, atom()} | {:error, :no_sendable_channel}
  def ensure_sendable(channel, %Message{} = message) do
    if can_send?(channel) do
      {:ok, channel}
    else
      fallback_chain(message)
    end
  end

  defp fallback_chain(%Message{metadata: metadata}) do
    candidates =
      [
        metadata[:response_channel],
        Config.default_response_channel(),
        :signal
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Enum.find(candidates, &can_send?/1) do
      nil -> {:error, :no_sendable_channel}
      channel -> {:ok, channel}
    end
  end
end
