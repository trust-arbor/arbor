defmodule Arbor.AI.SessionReader do
  @moduledoc """
  Reads Claude Code session files to extract thinking blocks and other content.

  Claude Code stores sessions as JSONL files in `~/.claude/projects/`.
  Each line is a JSON object representing an event in the session.

  ## Session File Format

  ```json
  {"type":"assistant","sessionId":"uuid","message":{"id":"msg_xxx","content":[...]}}
  ```

  Content blocks include:
  - `{"type":"text","text":"..."}` — regular text responses
  - `{"type":"thinking","thinking":"...","signature":"..."}` — extended thinking

  ## Usage

      # Read thinking blocks from a session
      {:ok, blocks} = SessionReader.read_thinking("session-uuid")

      # Read from a specific file
      {:ok, blocks} = SessionReader.read_thinking_from_file("/path/to/session.jsonl")

      # Get latest session's thinking
      {:ok, blocks} = SessionReader.latest_thinking(project_path: "~/code/my-project")
  """

  require Logger

  @type thinking_block :: %{
          text: String.t(),
          signature: String.t() | nil,
          message_id: String.t() | nil,
          timestamp: DateTime.t() | nil
        }

  @type session_event :: %{
          type: String.t(),
          session_id: String.t(),
          message: map()
        }

  @doc """
  Read thinking blocks from a session by its ID.

  Searches for the session file in `~/.claude/projects/` directory.
  """
  @spec read_thinking(String.t(), keyword()) :: {:ok, [thinking_block()]} | {:error, term()}
  def read_thinking(session_id, opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, session_base_dir())

    case find_session_file(session_id, base_dir) do
      {:ok, path} -> read_thinking_from_file(path, opts)
      {:error, _} = error -> error
    end
  end

  @doc """
  Read thinking blocks from a specific session file.
  """
  @spec read_thinking_from_file(String.t(), keyword()) ::
          {:ok, [thinking_block()]} | {:error, term()}
  def read_thinking_from_file(path, opts \\ []) do
    case File.read(path) do
      {:ok, content} ->
        blocks = parse_thinking_blocks(content, opts)
        {:ok, blocks}

      {:error, reason} ->
        {:error, {:file_read_error, reason, path}}
    end
  end

  @doc """
  Get thinking blocks from the most recently modified session.
  """
  @spec latest_thinking(keyword()) :: {:ok, [thinking_block()]} | {:error, term()}
  def latest_thinking(opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, session_base_dir())
    project_path = Keyword.get(opts, :project_path)

    case find_latest_session(base_dir, project_path) do
      {:ok, path} -> read_thinking_from_file(path, opts)
      {:error, _} = error -> error
    end
  end

  @doc """
  List all sessions with thinking blocks.
  """
  @spec sessions_with_thinking(keyword()) :: {:ok, [map()]} | {:error, term()}
  def sessions_with_thinking(opts \\ []) do
    base_dir = Keyword.get(opts, :base_dir, session_base_dir())
    limit = Keyword.get(opts, :limit, 20)

    sessions =
      base_dir
      |> find_all_session_files()
      |> Stream.filter(&has_thinking_blocks?/1)
      |> Stream.map(&extract_session_info/1)
      |> Enum.take(limit)

    {:ok, sessions}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp session_base_dir do
    home = System.get_env("HOME") || "~"
    Path.join([home, ".claude", "projects"])
  end

  defp find_session_file(session_id, base_dir) do
    pattern = Path.join([base_dir, "**", "#{session_id}.jsonl"])

    case Path.wildcard(pattern) do
      [path | _] -> {:ok, path}
      [] -> {:error, {:session_not_found, session_id}}
    end
  end

  defp find_latest_session(base_dir, project_path) do
    pattern =
      if project_path do
        # Convert project path to Claude's directory naming
        escaped_path = project_path |> Path.expand() |> String.replace("/", "-")
        Path.join([base_dir, "*#{escaped_path}*", "*.jsonl"])
      else
        Path.join([base_dir, "**", "*.jsonl"])
      end

    case Path.wildcard(pattern) |> sort_by_mtime() do
      [latest | _] -> {:ok, latest}
      [] -> {:error, :no_sessions_found}
    end
  end

  defp find_all_session_files(base_dir) do
    Path.join([base_dir, "**", "*.jsonl"])
    |> Path.wildcard()
    |> sort_by_mtime()
  end

  defp sort_by_mtime(files) do
    files
    |> Enum.map(fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: mtime}} -> {path, mtime}
        _ -> {path, 0}
      end
    end)
    |> Enum.sort_by(fn {_, mtime} -> mtime end, :desc)
    |> Enum.map(fn {path, _} -> path end)
  end

  defp parse_thinking_blocks(content, _opts) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&extract_thinking_from_line/1)
  end

  defp extract_thinking_from_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "assistant", "message" => message}} ->
        extract_thinking_from_message(message)

      _ ->
        []
    end
  end

  defp extract_thinking_from_message(%{"content" => content, "id" => message_id})
       when is_list(content) do
    content
    |> Enum.filter(fn block -> block["type"] == "thinking" end)
    |> Enum.map(fn block ->
      %{
        text: block["thinking"] || "",
        signature: block["signature"],
        message_id: message_id,
        timestamp: nil
      }
    end)
  end

  defp extract_thinking_from_message(_), do: []

  defp has_thinking_blocks?(path) do
    case File.open(path, [:read, :utf8]) do
      {:ok, file} ->
        result = stream_has_thinking?(file)
        File.close(file)
        result

      _ ->
        false
    end
  end

  defp stream_has_thinking?(file) do
    case IO.read(file, :line) do
      :eof ->
        false

      {:error, _} ->
        false

      line ->
        if String.contains?(line, "\"type\":\"thinking\"") do
          true
        else
          stream_has_thinking?(file)
        end
    end
  end

  defp extract_session_info(path) do
    session_id = Path.basename(path, ".jsonl")

    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        %{
          session_id: session_id,
          path: path,
          modified_at: DateTime.from_unix!(stat.mtime),
          size_bytes: stat.size
        }

      _ ->
        %{session_id: session_id, path: path}
    end
  end
end
