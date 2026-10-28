defmodule Arbor.Persistence.Schemas.ConversationNotice do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "conversation_notices" do
    field(:owner_id, :string)
    field(:target_agent_id, :string)
    field(:engagement_id, :string)
    field(:notice_id, :string)
    field(:recipient_subject_id, :string)
    field(:kind, :string)
    field(:text, :string)
    field(:provenance, :map)
    field(:facts_digest, :string)
    field(:ordinal, :integer)
    field(:created_at, :utc_datetime_usec)
  end
end
