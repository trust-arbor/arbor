defmodule Arbor.Persistence.Schemas.ConversationCommandCheckpoint do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:stream_id, :string, autogenerate: false}
  schema "conversation_command_checkpoints" do
    field(:owner_id, :string)
    field(:target_agent_id, :string)
    field(:engagement_id, :string)
    field(:watermark, :integer, default: 0)
  end
end
