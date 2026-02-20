defmodule Arbor.Agent.GroupChat.Message do
  @moduledoc """
  A message in a group chat conversation.

  Messages are created by either human users (via LiveView) or agents (via their
  APIAgent GenServer). Each message is timestamped and includes sender information.
  """

  @type sender_type :: :human | :agent | :system

  @type t :: %__MODULE__{
          id: String.t(),
          group_id: String.t(),
          sender_id: String.t(),
          sender_name: String.t(),
          sender_type: sender_type(),
          content: String.t(),
          timestamp: DateTime.t(),
          metadata: map()
        }

  @enforce_keys [:id, :group_id, :sender_id, :sender_name, :sender_type, :content]
  defstruct [
    :id,
    :group_id,
    :sender_id,
    :sender_name,
    :sender_type,
    :content,
    timestamp: nil,
    metadata: %{}
  ]

  @doc """
  Creates a new message with auto-generated ID and timestamp.

  ## Examples

      iex> Message.new(%{
      ...>   group_id: "grp_abc123",
      ...>   sender_id: "agent_def456",
      ...>   sender_name: "Claude",
      ...>   sender_type: :agent,
      ...>   content: "Hello, group!"
      ...> })
      %Message{
        id: "msg_a1b2c3d4",
        group_id: "grp_abc123",
        sender_id: "agent_def456",
        sender_name: "Claude",
        sender_type: :agent,
        content: "Hello, group!",
        timestamp: ~U[2026-02-15 12:34:56.789Z],
        metadata: %{}
      }
  """
  @spec new(map()) :: t()
  def new(attrs) do
    id = generate_id()
    timestamp = DateTime.utc_now()

    attrs
    |> Map.put(:id, id)
    |> Map.put_new(:timestamp, timestamp)
    |> Map.put_new(:metadata, %{})
    |> then(&struct!(__MODULE__, &1))
  end

  defp generate_id do
    suffix =
      :crypto.strong_rand_bytes(4)
      |> Base.encode16(case: :lower)

    "msg_#{suffix}"
  end
end
