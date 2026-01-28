defmodule Arbor.Consensus.EventSink do
  @moduledoc """
  Behaviour for optional external event persistence.

  The default EventStore uses ETS only. Host apps can implement
  this behaviour to persist events to Ecto, the historian, or
  external systems.

  ## Example Implementation

      defmodule MyApp.EventPersistence do
        @behaviour Arbor.Consensus.EventSink

        @impl true
        def record(event) do
          MyApp.Repo.insert(event_to_changeset(event))
          :ok
        end
      end
  """

  alias Arbor.Contracts.Autonomous.ConsensusEvent

  @doc """
  Record a consensus event to external storage.

  This is called after the event is stored in ETS. Failures
  here do not affect the consensus process — they are logged
  but not propagated.
  """
  @callback record(event :: ConsensusEvent.t()) :: :ok | {:error, term()}
end
