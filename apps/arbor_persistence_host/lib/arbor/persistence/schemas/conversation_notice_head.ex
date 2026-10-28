defmodule Arbor.Persistence.Schemas.ConversationNoticeHead do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:engagement_id, :string, autogenerate: false}
  schema "conversation_notice_heads" do
    field(:owner_id, :string)
    field(:target_agent_id, :string)
    field(:ordinal, :integer)
    field(:activity_at, :utc_datetime_usec)
  end
end
