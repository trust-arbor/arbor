defmodule Arbor.Historian.Host.DurableSink do
  @moduledoc "Signals consumer adapter; durable construction and acknowledgement remain Historian-owned."
  @behaviour Arbor.Signals.Contracts.DurableSink
  @impl true
  def persist_durable_event(stream_id, event_type, data, opts),
    do: Arbor.Historian.persist_durable_event(stream_id, event_type, data, opts)
end
