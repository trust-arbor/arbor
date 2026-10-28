defmodule Arbor.Persistence.Ecto.EventSerializer do
  @moduledoc """
  JSON serializer for Arbor's string-typed, JSON-object EventLog contract.

  EventStore's stock JSON serializer treats `event_type` as an Elixir struct
  module during reads and publication. Arbor event types are bounded domain
  strings instead, so deserialization deliberately ignores the optional type
  hint and always returns JSON-clean maps and values.
  """

  @behaviour EventStore.Serializer

  @doc false
  def arbor_event_log_serializer?, do: true

  @impl EventStore.Serializer
  def serialize(term), do: Jason.encode!(term)

  @impl EventStore.Serializer
  def deserialize(binary, _config), do: Jason.decode!(binary)
end
