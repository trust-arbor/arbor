defmodule Arbor.Persistence.Repo.Migrations.CreateConversationCommandIndex do
  use Ecto.Migration

  def change do
    create table(:conversation_command_checkpoints, primary_key: false) do
      add(:stream_id, :text, primary_key: true)
      add(:owner_id, :text, null: false)
      add(:target_agent_id, :text, null: false)
      add(:engagement_id, :text, null: false)
      add(:watermark, :bigint, null: false, default: 0)
    end

    create table(:conversation_commands, primary_key: false) do
      add(:stream_id, :text, primary_key: true)
      add(:command_id, :text, primary_key: true)
      add(:owner_id, :text, null: false)
      add(:target_agent_id, :text, null: false)
      add(:engagement_id, :text, null: false)
      add(:admitted_event_number, :bigint, null: false)
      add(:source_event_number, :bigint, null: false)
      add(:delivery_status, :text, null: false)
      add(:cancellation_status, :text, null: false)
      add(:cancellation_termination, :text)
    end

    create(
      index(
        :conversation_commands,
        [
          :owner_id,
          :target_agent_id,
          :engagement_id,
          :stream_id,
          :admitted_event_number,
          :command_id
        ],
        name: :conversation_commands_scope_admission_index
      )
    )

    # Receipts bind retries to the exact committed page; they are observation
    # metadata and never issue execution or cancellation authority.
    create table(:conversation_command_pages, primary_key: false) do
      add(:stream_id, :text, primary_key: true)
      add(:from_cursor, :bigint, primary_key: true)
      add(:to_cursor, :bigint, null: false)
      add(:digest, :text, null: false)
    end
  end
end
