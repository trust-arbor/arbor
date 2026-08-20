defmodule Arbor.Security.Contracts.EventLogAdapter do
  @moduledoc """
  Security-owned port for durable security-event persistence and reads.

  Library-specific to `arbor_security`. Implementations live above this
  library and are injected via `Arbor.Security.Config.event_log_adapter/0`.

  The write port carries Security-shaped envelopes only: an event type atom
  and the data map produced by `Arbor.Security.Events`. Read results are
  storage-agnostic maps with `:type` and `:data`; callers must not depend on
  the implementing backend's module identity.

  Admitted callback results:

  - `persist_security_event/2` — `:ok` when the adapter observed persist,
    or `{:error, term()}` when it could not. Callers treat either outcome
    as best-effort and must not fail the security operation.
  - `read_security_events/1` — `{:ok, events}` on a successful read, or
    `{:error, :event_log_unavailable}` when no log is ready. Other
    `{:error, term()}` reasons are adapter-specific.
  """

  @type event_type :: atom()
  @type event_data :: map()
  @type event :: %{
          required(:type) => atom() | String.t(),
          required(:data) => map(),
          optional(atom()) => term()
        }
  @type opts :: keyword()

  @callback persist_security_event(event_type(), event_data()) :: :ok | {:error, term()}

  @callback read_security_events(opts()) ::
              {:ok, [event()]} | {:error, :event_log_unavailable | term()}
end
