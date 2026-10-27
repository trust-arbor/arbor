defmodule Arbor.Signals.Contracts.DurableSink do
  @moduledoc """
  Consumer-owned port for durable signal persistence.

  Library-specific to `arbor_signals`. Implementations live above this
  library and are injected via `Arbor.Signals.Config.durable_sink_module/0`.

  The port carries only Signals-shaped primitives: stream id, event type,
  original data, and bounded lineage options. It does not expose storage
  structs or backend modules.

  Admitted callback results:

  - `:ok` — the sink observed persist for this event. A ready durable
    target has already accepted the append, so the event is readable
    there. This is not fire-and-forget.
  - `{:error, :persist_failed}` — the sink could not persist

  Callers, including `Arbor.Signals.durable_emit/4`, may block for the
  sink's durable backend operation deadline. Implementations must not
  return `:ok` from a ready durable target until they have observed the
  append result. Missing or invalid durable targets may still return
  `:ok` after a hot-path gap.
  """

  @type stream_id :: String.t()
  @type event_type :: term()
  @type data :: map()
  @type opts :: keyword()

  @callback persist_durable_event(stream_id(), event_type(), data(), opts()) ::
              :ok | {:error, :persist_failed}
end
