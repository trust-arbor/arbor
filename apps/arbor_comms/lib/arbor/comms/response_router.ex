defmodule Arbor.Comms.ResponseRouter do
  @moduledoc """
  Routes responses to the appropriate channel based on envelope metadata.

  Implements heuristic-based channel selection when the envelope's
  channel is `:auto`, or honors explicit channel hints.
  """

  @behaviour Arbor.Contracts.Comms.ResponseRouter

  alias Arbor.Comms.Config
  alias Arbor.Contracts.Comms.Message
  alias Arbor.Contracts.Comms.ResponseEnvelope

  @long_body_threshold 2000

  @impl true
  @spec route(Message.t(), ResponseEnvelope.t()) ::
          {:ok, atom(), ResponseEnvelope.t()} | {:error, term()}
  def route(%Message{} = original, %ResponseEnvelope{channel: :auto} = envelope) do
    channel = resolve_auto(original, envelope)
    {:ok, channel, envelope}
  end

  def route(%Message{}, %ResponseEnvelope{channel: channel} = envelope) do
    if channel in available_channels() do
      {:ok, channel, envelope}
    else
      {:error, {:channel_unavailable, channel}}
    end
  end

  @impl true
  @spec available_channels() :: [atom()]
  def available_channels do
    Config.configured_channels()
  end

  # ============================================================================
  # Auto-Resolution
  # ============================================================================

  defp resolve_auto(%Message{channel: origin}, %ResponseEnvelope{} = envelope) do
    cond do
      ResponseEnvelope.has_attachments?(envelope) -> :email
      envelope.format == :html -> :email
      byte_size(envelope.body) > @long_body_threshold -> :email
      true -> origin
    end
  end
end
