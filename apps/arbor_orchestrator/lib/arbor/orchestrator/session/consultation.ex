defmodule Arbor.Orchestrator.Session.Consultation do
  @moduledoc false
  alias Arbor.Contracts.Session.TurnAuthority

  # This marker is installed only by receipt-authenticated dedicated ingress.
  # It is process-local and bound to the exchanged authority, never metadata.
  def valid_parent?(id) when is_binary(id) and byte_size(id) == 38,
    do: Regex.match?(~r/\Avoice_[0-9a-f]{32}\z/, id)

  def valid_parent?(_), do: false

  def bind(state, %TurnAuthority{turn_id: id} = authority, parent) do
    %{state | consultation: %{turn_id: id, parent_voice_id: parent}, turn_authority: authority}
  end

  def parent(%{
        consultation: %{turn_id: id, parent_voice_id: parent},
        turn_authority: %TurnAuthority{turn_id: id}
      }) do
    if valid_parent?(parent), do: parent
  end

  def parent(_), do: nil
  def active?(state), do: not is_nil(parent(state))

  def clear_idle(%{turn_in_flight: false, consultation: purpose} = state)
      when not is_nil(purpose), do: %{state | consultation: nil, turn_authority: nil}

  def clear_idle(state), do: state

  def classify_entries(state, entries) do
    case parent(state) do
      nil ->
        entries

      parent ->
        Enum.map(entries, fn entry ->
          %{
            entry
            | entry_type: "consultation",
              metadata: Map.put(entry.metadata, "voice_parent_id", parent)
          }
        end)
    end
  end
end
