defmodule Arbor.Common.AgentTelemetry.Persistence do
  @moduledoc """
  Consumer-owned durable telemetry port.

  Library-specific to `arbor_common`. Implementations live above this
  library and are injected via `Arbor.Common.Config.telemetry_persistence_module/0`.

  Common errors:

  - `:repo_unavailable` — no durable repository process is running
  - other `{:error, reason}` — insert or query failure from the backend
  """

  @type event_type :: :turn_completed | :tool_call | :routing_decision | :compaction

  @type event :: %{
          id: term(),
          agent_id: String.t(),
          event_type: term(),
          timestamp: term(),
          data: map()
        }

  @type lifetime :: %{optional(atom()) => term()}

  @callback persist_event(String.t(), event_type(), map()) ::
              :ok | {:error, :repo_unavailable | term()}

  @callback load_lifetime(String.t()) :: lifetime() | nil

  @callback query_events(String.t(), keyword()) ::
              {:ok, [event()]} | {:error, :repo_unavailable | term()}
end
