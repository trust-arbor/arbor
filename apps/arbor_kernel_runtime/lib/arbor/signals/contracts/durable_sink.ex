defmodule Arbor.Signals.Contracts.DurableSink do
  @moduledoc """
  Consumer-owned port for durable signal persistence.

  Library-specific to `arbor_signals`. Implementations live above this
  library and are injected via `Arbor.Signals.Config.durable_sink_module/0`.

  The port carries only Signals-shaped primitives: stream id, event type,
  original data, and bounded lineage options. It does not expose storage
  structs or backend modules.

  Admitted callback results:

  - `:ok` — the sink accepted the request
  - `{:error, :persist_failed}` — the sink could not persist
  """

  @type stream_id :: String.t()
  @type event_type :: term()
  @type data :: map()
  @type opts :: keyword()

  @callback persist_durable_event(stream_id(), event_type(), data(), opts()) ::
              :ok | {:error, :persist_failed}
end
