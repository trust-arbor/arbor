defmodule ConversationKit.Arbor.Client do
  @moduledoc false
  defstruct [
    :caller,
    :target,
    :proof_provider,
    :facade,
    :transport,
    :max_pages,
    :engagement,
    :owner,
    controls: %{"activities" => [], "interactions" => []},
    controls_discovery: %{has_more: false, incomplete: false, truncated: false, next_cursor: nil},
    notices: [],
    notice_head: 0,
    mode: :replay,
    history: %{cursor: 0, head: 0, through: nil, limit: 50},
    journal: %{cursor: 0, head: 0, through: nil, limit: 50},
    messages: [],
    message_ids: MapSet.new(),
    commands: %{},
    observed: %{},
    event_ids: MapSet.new()
  ]

  defimpl Inspect do
    def inspect(_, _), do: "#ConversationKit.Arbor.Client<private>"
  end
end
