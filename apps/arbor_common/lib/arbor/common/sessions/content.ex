defmodule Arbor.Common.Sessions.Content do
  @moduledoc """
  Content extraction utilities for session records.

  Provides helpers to extract specific content types from records:
  text, tool uses, thinking blocks, and conversation structure.

  ## Usage

      # Extract text from a record
      text = Content.text(record)

      # Get all tool uses
      tool_uses = Content.tool_uses(record)

      # Check for tool use
      Content.has_tool_use?(record)

      # Extract thinking blocks
      thinking = Content.thinking(record)

      # Get conversation pairs (user + assistant)
      pairs = Content.conversation_pairs(records)
  """

  alias Arbor.Common.Sessions.Record

  @type content_item :: map()

  @doc """
  Extract all text content from a record.

  Returns the pre-computed `text` field, which is all `:text` content items
  joined with newlines.

  ## Examples

      iex> Content.text(%Record{text: "Hello world"})
      "Hello world"

      iex> Content.text(%Record{text: ""})
      ""
  """
  @spec text(Record.t()) :: String.t()
  def text(%Record{text: text}), do: text

  @doc """
  Extract all tool use items from a record.

  Returns a list of tool use content items.

  ## Examples

      iex> Content.tool_uses(%Record{content: [%{type: :tool_use, tool_name: "Bash"}]})
      [%{type: :tool_use, tool_name: "Bash"}]
  """
  @spec tool_uses(Record.t()) :: [content_item()]
  def tool_uses(%Record{content: content}) do
    Enum.filter(content, &(&1[:type] == :tool_use))
  end

  @doc """
  Extract all tool result items from a record.

  ## Examples

      iex> Content.tool_results(%Record{content: [%{type: :tool_result, tool_result: "ok"}]})
      [%{type: :tool_result, tool_result: "ok"}]
  """
  @spec tool_results(Record.t()) :: [content_item()]
  def tool_results(%Record{content: content}) do
    Enum.filter(content, &(&1[:type] == :tool_result))
  end

  @doc """
  Extract all thinking blocks from a record.

  ## Examples

      iex> Content.thinking(%Record{content: [%{type: :thinking, text: "Let me think..."}]})
      [%{type: :thinking, text: "Let me think..."}]
  """
  @spec thinking(Record.t()) :: [content_item()]
  def thinking(%Record{content: content}) do
    Enum.filter(content, &(&1[:type] == :thinking))
  end

  @doc """
  Get the text from all thinking blocks joined together.

  ## Examples

      iex> Content.thinking_text(%Record{content: [%{type: :thinking, text: "First"}, %{type: :thinking, text: "Second"}]})
      "First\\nSecond"
  """
  @spec thinking_text(Record.t()) :: String.t()
  def thinking_text(record) do
    record
    |> thinking()
    |> Enum.map(& &1[:text])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc """
  Check if a record contains any tool use.

  ## Examples

      iex> Content.has_tool_use?(%Record{content: [%{type: :tool_use}]})
      true

      iex> Content.has_tool_use?(%Record{content: [%{type: :text}]})
      false
  """
  @spec has_tool_use?(Record.t()) :: boolean()
  def has_tool_use?(%Record{content: content}) do
    Enum.any?(content, &(&1[:type] == :tool_use))
  end

  @doc """
  Check if a record contains any thinking blocks.

  ## Examples

      iex> Content.has_thinking?(%Record{content: [%{type: :thinking}]})
      true
  """
  @spec has_thinking?(Record.t()) :: boolean()
  def has_thinking?(%Record{content: content}) do
    Enum.any?(content, &(&1[:type] == :thinking))
  end

  @doc """
  Get all unique tool names used across a list of records.

  ## Examples

      iex> Content.tools_used([%Record{content: [%{type: :tool_use, tool_name: "Bash"}]}])
      ["Bash"]
  """
  @spec tools_used([Record.t()]) :: [String.t()]
  def tools_used(records) when is_list(records) do
    records
    |> Enum.flat_map(&tool_uses/1)
    |> Enum.map(& &1[:tool_name])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Extract conversation pairs (user message + assistant response).

  Returns a list of `{user_record, assistant_record}` tuples representing
  complete exchanges.

  ## Examples

      iex> Content.conversation_pairs([user_record, assistant_record])
      [{user_record, assistant_record}]
  """
  @spec conversation_pairs([Record.t()]) :: [{Record.t(), Record.t()}]
  def conversation_pairs(records) when is_list(records) do
    records
    |> Enum.filter(&Record.message?/1)
    |> pair_messages([])
    |> Enum.reverse()
  end

  @doc """
  Get only message records (user and assistant) from a list.

  ## Examples

      iex> Content.messages([user, progress, assistant])
      [user, assistant]
  """
  @spec messages([Record.t()]) :: [Record.t()]
  def messages(records) when is_list(records) do
    Enum.filter(records, &Record.message?/1)
  end

  @doc """
  Get only user messages from a list.

  ## Examples

      iex> Content.user_messages([user1, assistant1, user2])
      [user1, user2]
  """
  @spec user_messages([Record.t()]) :: [Record.t()]
  def user_messages(records) when is_list(records) do
    Enum.filter(records, &Record.user?/1)
  end

  @doc """
  Get only assistant messages from a list.

  ## Examples

      iex> Content.assistant_messages([user1, assistant1, user2, assistant2])
      [assistant1, assistant2]
  """
  @spec assistant_messages([Record.t()]) :: [Record.t()]
  def assistant_messages(records) when is_list(records) do
    Enum.filter(records, &Record.assistant?/1)
  end

  @doc """
  Count tokens in usage if available.

  ## Examples

      iex> Content.token_count(%Record{usage: %{"input_tokens" => 100, "output_tokens" => 50}})
      %{input: 100, output: 50, total: 150}

      iex> Content.token_count(%Record{usage: nil})
      nil
  """
  @spec token_count(Record.t()) :: %{input: integer(), output: integer(), total: integer()} | nil
  def token_count(%Record{usage: nil}), do: nil

  def token_count(%Record{usage: usage}) when is_map(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    %{input: input, output: output, total: input + output}
  end

  @doc """
  Sum token usage across multiple records.

  ## Examples

      iex> Content.total_tokens([record1, record2])
      %{input: 200, output: 100, total: 300}
  """
  @spec total_tokens([Record.t()]) :: %{input: integer(), output: integer(), total: integer()}
  def total_tokens(records) when is_list(records) do
    records
    |> Enum.map(&token_count/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{input: 0, output: 0, total: 0}, fn counts, acc ->
      %{
        input: acc.input + counts.input,
        output: acc.output + counts.output,
        total: acc.total + counts.total
      }
    end)
  end

  @doc """
  Extract a specific content item by tool_use_id.

  Useful for matching tool results to their corresponding tool uses.

  ## Examples

      iex> Content.find_by_tool_use_id(record, "toolu_123")
      %{type: :tool_use, tool_use_id: "toolu_123", tool_name: "Bash"}
  """
  @spec find_by_tool_use_id(Record.t(), String.t()) :: content_item() | nil
  def find_by_tool_use_id(%Record{content: content}, tool_use_id) do
    Enum.find(content, fn item ->
      item[:tool_use_id] == tool_use_id
    end)
  end

  # Private functions

  defp pair_messages([], acc), do: acc

  defp pair_messages([%Record{type: :user} = user | rest], acc) do
    case rest do
      [%Record{type: :assistant} = assistant | remaining] ->
        pair_messages(remaining, [{user, assistant} | acc])

      _ ->
        # User message without following assistant message
        pair_messages(rest, acc)
    end
  end

  defp pair_messages([_ | rest], acc) do
    # Skip non-user messages that aren't paired
    pair_messages(rest, acc)
  end
end
