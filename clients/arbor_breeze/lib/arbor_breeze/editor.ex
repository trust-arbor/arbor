defmodule ArborBreeze.Editor do
  @moduledoc "Adapt closed host snapshots to the shared native composer decisions."
  alias ConversationKit.Composer

  defdelegate new(), to: Composer
  defdelegate draft(editor, text), to: Composer

  def submit(editor, snapshot, id), do: Composer.submit(editor, snapshot.send_allowed, id)

  def observe(editor, %{private_cleared: true}), do: Composer.clear(editor)

  def observe(editor, %{ack: ack}) when not is_nil(ack), do: Composer.acknowledge(editor, ack)

  # A definite host rejection permits editing/resubmitting, whereas an unknown
  # outcome keeps the saved identity in the Connection owner until lookup.
  def observe(%{submitted: %{id: id}} = editor, %{
        busy: false,
        pending_id: nil,
        ack: nil,
        error: error
      })
      when not is_nil(error),
      do: Composer.reject(editor, id)

  def observe(editor, _snapshot), do: editor
end
