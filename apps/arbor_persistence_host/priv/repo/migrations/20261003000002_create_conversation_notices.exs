defmodule Arbor.Persistence.Repo.Migrations.CreateConversationNotices do
  use Ecto.Migration

  def change do
    create table(:conversation_notice_heads, primary_key: false) do
      add(
        :engagement_id,
        references(:engagements, column: :engagement_id, type: :text, on_delete: :delete_all),
        primary_key: true
      )

      add(:owner_id, :text, null: false)
      add(:target_agent_id, :text, null: false)
      add(:ordinal, :bigint, null: false)
      add(:activity_at, :utc_datetime_usec, null: false)
    end

    create table(:conversation_notices, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:owner_id, :text, null: false)
      add(:target_agent_id, :text, null: false)

      add(
        :engagement_id,
        references(:engagements, column: :engagement_id, type: :text, on_delete: :delete_all),
        null: false
      )

      add(:notice_id, :text, null: false)
      add(:recipient_subject_id, :text, null: false)
      add(:kind, :text, null: false)
      add(:text, :text, null: false)
      add(:provenance, :map, null: false)
      add(:facts_digest, :text, null: false)
      add(:ordinal, :bigint, null: false)
      add(:created_at, :utc_datetime_usec, null: false)
    end

    create(
      unique_index(
        :conversation_notices,
        [:owner_id, :target_agent_id, :engagement_id, :notice_id],
        name: :conversation_notices_identity
      )
    )

    create(unique_index(:conversation_notices, [:engagement_id, :ordinal]))
    create(index(:conversation_notices, [:owner_id, :target_agent_id, :engagement_id, :ordinal]))
  end
end
