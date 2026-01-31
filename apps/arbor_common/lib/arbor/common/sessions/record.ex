defmodule Arbor.Common.Sessions.Record do
  @moduledoc """
  Struct definitions for normalized session records.

  Records are provider-agnostic representations of session entries.
  Each record represents a single line from a session file (e.g., JSONL).

  ## Record Types

  - `:user` - User messages
  - `:assistant` - Assistant responses
  - `:queue_operation` - Queue/progress metadata
  - `:summary` - Session summaries
  - `:progress` - Progress/hook events
  - `:file_history_snapshot` - File history metadata
  - `:unknown` - Unrecognized record types

  ## Content Items

  The `content` field contains a list of structured content items:

  - `:text` - Plain text content
  - `:tool_use` - Tool invocation (name, input, id)
  - `:tool_result` - Tool execution result
  - `:thinking` - Model thinking/reasoning blocks

  ## Convenience Fields

  - `text` - All text content joined with newlines (for simple text extraction)
  - `metadata` - Provider-specific extras not covered by standard fields
  """

  @type message_role :: :user | :assistant | :system
  @type content_type :: :text | :tool_use | :tool_result | :thinking

  @type content_item :: %{
          type: content_type(),
          text: String.t() | nil,
          tool_name: String.t() | nil,
          tool_input: map() | nil,
          tool_use_id: String.t() | nil,
          tool_result: String.t() | nil,
          is_error: boolean() | nil
        }

  @type record_type ::
          :user
          | :assistant
          | :queue_operation
          | :summary
          | :progress
          | :file_history_snapshot
          | :unknown

  @type t :: %__MODULE__{
          type: record_type(),
          uuid: String.t() | nil,
          parent_uuid: String.t() | nil,
          session_id: String.t() | nil,
          timestamp: DateTime.t() | nil,
          role: message_role() | nil,
          content: [content_item()],
          text: String.t(),
          model: String.t() | nil,
          usage: map() | nil,
          metadata: map()
        }

  defstruct [
    :type,
    :uuid,
    :parent_uuid,
    :session_id,
    :timestamp,
    :role,
    content: [],
    text: "",
    model: nil,
    usage: nil,
    metadata: %{}
  ]

  @doc """
  Create a new record with the given attributes.

  ## Examples

      iex> Record.new(type: :user, role: :user, text: "Hello")
      %Record{type: :user, role: :user, text: "Hello", content: [], metadata: %{}}
  """
  @spec new(keyword()) :: t()
  def new(attrs \\ []) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Check if a record is a message (user or assistant).

  ## Examples

      iex> Record.message?(%Record{type: :user})
      true

      iex> Record.message?(%Record{type: :progress})
      false
  """
  @spec message?(t()) :: boolean()
  def message?(%__MODULE__{type: type}) when type in [:user, :assistant], do: true
  def message?(%__MODULE__{}), do: false

  @doc """
  Check if a record is from the user.

  ## Examples

      iex> Record.user?(%Record{type: :user})
      true
  """
  @spec user?(t()) :: boolean()
  def user?(%__MODULE__{type: :user}), do: true
  def user?(%__MODULE__{}), do: false

  @doc """
  Check if a record is from the assistant.

  ## Examples

      iex> Record.assistant?(%Record{type: :assistant})
      true
  """
  @spec assistant?(t()) :: boolean()
  def assistant?(%__MODULE__{type: :assistant}), do: true
  def assistant?(%__MODULE__{}), do: false
end
