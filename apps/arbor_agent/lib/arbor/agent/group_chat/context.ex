defmodule Arbor.Agent.GroupChat.Context do
  @moduledoc """
  Builds conversation context for agent queries in group chat.

  Formats recent message history into a prompt that:
  1. Shows the conversation transcript
  2. Identifies the agent by name
  3. Encourages brief, unique responses
  """

  alias Arbor.Agent.GroupChat.Message

  @doc """
  Builds a prompt for an agent to respond to the group conversation.

  ## Options

  - `:max_messages` - Maximum number of recent messages to include (default: 20)
  - `:group_name` - Optional group name to include in context

  ## Examples

      iex> messages = [
      ...>   %Message{sender_name: "Alice", content: "Hello!"},
      ...>   %Message{sender_name: "Bob", content: "Hi Alice!"}
      ...> ]
      iex> Context.build_agent_prompt("Charlie", messages)
      "[Group chat conversation]\\n\\nAlice: Hello!\\nBob: Hi Alice!\\n\\n..."
  """
  @spec build_agent_prompt(String.t(), [Message.t()], keyword()) :: String.t()
  def build_agent_prompt(agent_name, messages, opts \\ []) do
    max_messages = Keyword.get(opts, :max_messages, 20)
    group_name = Keyword.get(opts, :group_name)

    # Take most recent N messages and reverse for chronological order
    recent = messages |> Enum.take(max_messages) |> Enum.reverse()

    # Build transcript
    transcript =
      Enum.map_join(recent, "\n", fn msg ->
        "#{msg.sender_name}: #{msg.content}"
      end)

    header = build_header(group_name)

    """
    #{header}

    #{transcript}

    Respond as #{agent_name}. Keep your reply to 2-3 sentences.
    Do not repeat what others have said. Add your unique perspective.
    """
  end

  defp build_header(nil), do: "[Group chat conversation]"
  defp build_header(name), do: "[Group chat: #{name}]"
end
