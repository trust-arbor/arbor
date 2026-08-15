defmodule Arbor.Common.Sessions.Providers.Claude do
  @moduledoc """
  Claude Code JSONL format specifics.

  Handles parsing of Claude Code session files, which use a JSONL format
  with one JSON object per line.

  ## Format Overview

  Each line is a JSON object with these common fields:
  - `type` - Record type: "user", "assistant", "progress", "summary", etc.
  - `uuid` - Unique identifier for this record
  - `parentUuid` - UUID of parent record (for conversation threading)
  - `sessionId` - Session identifier
  - `timestamp` - ISO 8601 timestamp
  - `message` - For user/assistant types, contains `role` and `content`

  ## Message Content

  User messages typically have string content, but may have array content
  (e.g., tool results). Assistant messages always have array content with
  items like:
  - `{type: "text", text: "..."}` - Plain text
  - `{type: "tool_use", id: "...", name: "Bash", input: {...}}` - Tool calls
  - `{type: "tool_result", tool_use_id: "...", content: "..."}` - Tool results
  - `{type: "thinking", thinking: "...", signature: "..."}` - Thinking blocks

  ## Default Directories

  Claude Code stores sessions in `~/.claude/projects/<encoded-path>/`.
  The encoded path replaces `/` with `-` (e.g., `/path/to/project` becomes
  `-path-to-project`).
  """

  alias Arbor.Common.Sessions.Record

  @type json_map :: map()

  @doc """
  Parse a raw JSON map into a Record struct.

  ## Examples

      iex> Claude.parse_record(%{"type" => "user", "message" => %{"role" => "user", "content" => "Hello"}})
      {:ok, %Record{type: :user, role: :user, text: "Hello"}}
  """
  @spec parse_record(json_map()) :: {:ok, Record.t()} | {:error, term()}
  def parse_record(json) when is_map(json) do
    type = parse_type(json["type"])

    record =
      Record.new(
        type: type,
        uuid: json["uuid"],
        parent_uuid: json["parentUuid"],
        session_id: json["sessionId"],
        timestamp: parse_timestamp(json["timestamp"]),
        metadata: extract_metadata(json, type)
      )

    record = parse_message(record, json["message"], type)

    {:ok, record}
  rescue
    e -> {:error, {:parse_error, e}}
  end

  @doc """
  Check if a JSON map appears to be Claude Code format.

  Looks for Claude-specific field patterns.

  ## Examples

      iex> Claude.matches?(%{"sessionId" => "abc", "uuid" => "123"})
      true

      iex> Claude.matches?(%{"other" => "format"})
      false
  """
  @spec matches?(json_map()) :: boolean()
  def matches?(json) when is_map(json) do
    # Claude Code JSONL has sessionId and uuid fields
    Map.has_key?(json, "sessionId") and Map.has_key?(json, "uuid")
  end

  def matches?(_), do: false

  @doc """
  Get the default session directory for Claude Code.

  Returns the path where Claude Code stores session files.

  ## Examples

      iex> Claude.session_dir()
      "~/.claude/projects"
  """
  @spec session_dir() :: String.t()
  def session_dir do
    "~/.claude/projects"
  end

  @doc """
  Expand the session directory to an absolute path.

  ## Examples

      iex> expanded = Claude.expanded_session_dir()
      iex> String.ends_with?(expanded, ".claude/projects")
      true
  """
  @spec expanded_session_dir() :: String.t()
  def expanded_session_dir do
    Path.expand(session_dir())
  end

  @doc """
  Decode an encoded project path from a session directory name.

  Claude Code encodes project paths by replacing `/` with `-`.

  ## Examples

      iex> path = Claude.decode_project_path("-home-testuser-myproject")
      iex> String.contains?(path, "testuser")
      true
  """
  @spec decode_project_path(String.t()) :: String.t()
  def decode_project_path(encoded) when is_binary(encoded) do
    # The encoding replaces "/" with "-", but this is ambiguous
    # for paths that contain actual hyphens. We use a heuristic:
    # assume the path starts with a common root like /Users, /home, etc.
    cond do
      String.starts_with?(encoded, "-Users-") ->
        # macOS path
        parts = String.split(encoded, "-", parts: 3)
        [_, "Users", rest] = parts
        ("/Users/" <> String.replace(rest, "-", "/", global: false)) |> fixup_path()

      String.starts_with?(encoded, "-home-") ->
        # Linux path
        parts = String.split(encoded, "-", parts: 3)
        [_, "home", rest] = parts
        ("/home/" <> String.replace(rest, "-", "/", global: false)) |> fixup_path()

      true ->
        # Fallback: just replace leading dash and use heuristics
        "/" <> String.trim_leading(encoded, "-")
    end
  end

  @doc """
  Encode a project path for use in session directory names.

  ## Examples

      iex> Claude.encode_project_path("/Users/foo/myproject")
      "-Users-foo-myproject"
  """
  @spec encode_project_path(String.t()) :: String.t()
  def encode_project_path(path) when is_binary(path) do
    String.replace(path, "/", "-")
  end

  # Private functions

  defp parse_type("user"), do: :user
  defp parse_type("assistant"), do: :assistant
  defp parse_type("queue_operation"), do: :queue_operation
  defp parse_type("summary"), do: :summary
  defp parse_type("progress"), do: :progress
  defp parse_type("file-history-snapshot"), do: :file_history_snapshot
  defp parse_type(_), do: :unknown

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp parse_timestamp(_), do: nil

  defp parse_message(record, nil, _type), do: record

  defp parse_message(record, message, type)
       when is_map(message) and type in [:user, :assistant] do
    role = parse_role(message["role"])
    {content_items, text} = parse_content(message["content"], role)
    model = get_in(message, ["model"])
    usage = get_in(message, ["usage"])

    %{record | role: role, content: content_items, text: text, model: model, usage: usage}
  end

  defp parse_message(record, _message, _type), do: record

  defp parse_role("user"), do: :user
  defp parse_role("assistant"), do: :assistant
  defp parse_role("system"), do: :system
  defp parse_role(_), do: nil

  # Content can be a string (user messages) or an array (assistant messages, tool results)
  defp parse_content(content, _role) when is_binary(content) do
    {[%{type: :text, text: content}], content}
  end

  defp parse_content(content, _role) when is_list(content) do
    items = Enum.map(content, &parse_content_item/1)
    text = extract_text_from_items(items)
    {items, text}
  end

  defp parse_content(nil, _role), do: {[], ""}
  defp parse_content(_, _role), do: {[], ""}

  defp parse_content_item(%{"type" => "text", "text" => text}) do
    %{type: :text, text: text}
  end

  defp parse_content_item(%{"type" => "tool_use"} = item) do
    %{
      type: :tool_use,
      tool_name: item["name"],
      tool_input: item["input"],
      tool_use_id: item["id"]
    }
  end

  defp parse_content_item(%{"type" => "tool_result"} = item) do
    %{
      type: :tool_result,
      tool_use_id: item["tool_use_id"],
      tool_result: item["content"],
      is_error: item["is_error"] || false
    }
  end

  defp parse_content_item(%{"type" => "thinking"} = item) do
    %{
      type: :thinking,
      text: item["thinking"]
    }
  end

  defp parse_content_item(item) when is_map(item) do
    # Unknown content type - store as-is in metadata
    %{type: :unknown, metadata: item}
  end

  defp parse_content_item(other) do
    %{type: :unknown, text: inspect(other)}
  end

  defp extract_text_from_items(items) do
    items
    |> Enum.filter(fn item -> item[:type] == :text and is_binary(item[:text]) end)
    |> Enum.map_join("\n", & &1[:text])
  end

  defp extract_metadata(json, type) do
    # Extract type-specific metadata
    base = %{
      cwd: json["cwd"],
      git_branch: json["gitBranch"],
      version: json["version"],
      is_sidechain: json["isSidechain"],
      user_type: json["userType"],
      slug: json["slug"]
    }

    case type do
      :progress ->
        Map.put(base, :progress_data, json["data"])

      :file_history_snapshot ->
        Map.put(base, :snapshot, json["snapshot"])

      _ ->
        base
    end
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Path fixup for decoded paths - handles remaining dashes that should be slashes
  # This is a best-effort heuristic since the encoding is lossy
  defp fixup_path(path) do
    # For now, just return as-is. A more sophisticated approach would
    # check if path segments exist on the filesystem.
    path
  end
end
