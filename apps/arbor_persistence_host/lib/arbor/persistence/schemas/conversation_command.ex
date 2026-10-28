defmodule Arbor.Persistence.Schemas.ConversationCommand do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "conversation_commands" do
    field(:stream_id, :string, primary_key: true)
    field(:command_id, :string, primary_key: true)
    field(:owner_id, :string)
    field(:target_agent_id, :string)
    field(:engagement_id, :string)
    field(:admitted_event_number, :integer)
    field(:source_event_number, :integer)
    field(:delivery_status, :string)
    field(:cancellation_status, :string)
    field(:cancellation_termination, :string)
  end
end
