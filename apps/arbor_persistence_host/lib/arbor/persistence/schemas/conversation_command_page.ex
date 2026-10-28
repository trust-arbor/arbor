defmodule Arbor.Persistence.Schemas.ConversationCommandPage do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "conversation_command_pages" do
    field(:stream_id, :string, primary_key: true)
    field(:from_cursor, :integer, primary_key: true)
    field(:to_cursor, :integer)
    field(:digest, :string)
  end
end
