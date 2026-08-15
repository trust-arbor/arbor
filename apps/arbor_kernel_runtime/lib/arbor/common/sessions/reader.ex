defmodule Arbor.Common.Sessions.Reader do
  @moduledoc """
  Streaming JSONL file reader for session files.

  Pure functions, no process state. Provides streaming reads for memory efficiency
  with large session files.

  ## Usage

      # Stream records from a file (memory efficient)
      {:ok, stream} = Reader.stream("path/to/session.jsonl")
      records = Enum.to_list(stream)

      # Read all at once (for small files)
      {:ok, records} = Reader.read_all("path/to/session.jsonl")

      # Find session files
      {:ok, files} = Reader.find_sessions("~/.claude/projects/-Users-foo-project/")

      # Find the most recent session
      {:ok, path} = Reader.latest_session("~/.claude/projects/-Users-foo-project/")

  ## Path Safety

  All user-provided paths are validated using `Arbor.Common.SafePath` to prevent
  path traversal attacks.
  """

  alias Arbor.Common.SafePath
  alias Arbor.Common.Sessions.Parser
  alias Arbor.Common.Sessions.Providers.Claude
  alias Arbor.Common.Sessions.Record

  @type path :: String.t()
  @type stream_result :: {:ok, Enumerable.t()} | {:error, term()}
  @type read_result :: {:ok, [Record.t()]} | {:error, term()}

  @doc """
  Stream records from a JSONL session file.

  Returns a lazy stream that yields `Record.t()` structs. Invalid lines are
  skipped with a warning in the stream.

  ## Options

  - `:provider` - Explicit provider (`:claude`, `:auto`). Default: `:auto`
  - `:skip_errors` - Skip malformed lines instead of stopping. Default: `true`

  ## Examples

      {:ok, stream} = Reader.stream("session.jsonl")
      messages = stream |> Enum.filter(&Record.message?/1) |> Enum.to_list()
  """
  @spec stream(path(), keyword()) :: stream_result()
  def stream(path, opts \\ []) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      skip_errors = Keyword.get(opts, :skip_errors, true)
      provider = Keyword.get(opts, :provider, :auto)

      stream =
        expanded
        |> File.stream!([], :line)
        |> Stream.map(&String.trim_trailing(&1, "\n"))
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&parse_line(&1, provider, skip_errors))
        |> Stream.reject(&is_nil/1)

      {:ok, stream}
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Read all records from a JSONL session file.

  Loads all records into memory. Use `stream/2` for large files.

  ## Options

  - `:provider` - Explicit provider (`:claude`, `:auto`). Default: `:auto`
  - `:skip_errors` - Skip malformed lines instead of stopping. Default: `true`

  ## Examples

      {:ok, records} = Reader.read_all("session.jsonl")
  """
  @spec read_all(path(), keyword()) :: read_result()
  def read_all(path, opts \\ []) do
    case stream(path, opts) do
      {:ok, stream} -> {:ok, Enum.to_list(stream)}
      error -> error
    end
  end

  @doc """
  Find all session files in a directory.

  Returns a list of `.jsonl` file paths sorted by modification time (newest first).

  ## Options

  - `:pattern` - Glob pattern for session files. Default: `"*.jsonl"`

  ## Examples

      {:ok, files} = Reader.find_sessions("~/.claude/projects/-path-to-project/")
      # Returns list of .jsonl files sorted by modification time
  """
  @spec find_sessions(path(), keyword()) :: {:ok, [path()]} | {:error, term()}
  def find_sessions(dir, opts \\ []) do
    expanded = Path.expand(dir)
    pattern = Keyword.get(opts, :pattern, "*.jsonl")

    if File.dir?(expanded) do
      files =
        Path.join(expanded, pattern)
        |> Path.wildcard()
        |> Enum.sort_by(&file_mtime/1, :desc)

      {:ok, files}
    else
      {:error, :not_a_directory}
    end
  end

  @doc """
  Find the most recent session file in a directory.

  ## Examples

      {:ok, path} = Reader.latest_session("~/.claude/projects/-Users-foo-project/")
  """
  @spec latest_session(path(), keyword()) :: {:ok, path()} | {:error, term()}
  def latest_session(dir, opts \\ []) do
    case find_sessions(dir, opts) do
      {:ok, [latest | _]} -> {:ok, latest}
      {:ok, []} -> {:error, :no_sessions_found}
      error -> error
    end
  end

  @doc """
  Resolve a session by name or UUID prefix.

  Resolution order:
  1. Check `~/.arbor/session-names.json` for named sessions
  2. Check `~/.arbor/{name}-session-id` files
  3. Try UUID prefix matching across project directories

  ## Examples

      {:ok, path} = Reader.resolve("my-session")
      {:ok, path} = Reader.resolve("9070fa86")  # UUID prefix
  """
  @spec resolve(String.t()) :: {:ok, path()} | {:error, term()}
  def resolve(identifier) when is_binary(identifier) do
    with {:error, _} <- resolve_from_names_json(identifier),
         {:error, _} <- resolve_from_session_id_file(identifier),
         {:error, _} <- resolve_by_uuid_prefix(identifier) do
      {:error, :session_not_found}
    end
  end

  @doc """
  Resolve a session within a specific allowed root directory.

  Uses SafePath to ensure the resolved path stays within bounds.

  ## Examples

      {:ok, path} = Reader.resolve_within("session.jsonl", "/workspace/sessions")
  """
  @spec resolve_within(String.t(), path()) :: {:ok, path()} | {:error, term()}
  def resolve_within(identifier, allowed_root) do
    case SafePath.resolve_within(identifier, allowed_root) do
      {:ok, path} ->
        if File.exists?(path) and String.ends_with?(path, ".jsonl") do
          {:ok, path}
        else
          {:error, :file_not_found}
        end

      error ->
        error
    end
  end

  @doc """
  Find all Claude Code project directories.

  ## Examples

      {:ok, dirs} = Reader.find_project_dirs()
      #=> {:ok, ["-Users-foo-project1", "-Users-foo-project2"]}
  """
  @spec find_project_dirs() :: {:ok, [path()]} | {:error, term()}
  def find_project_dirs do
    base = Claude.expanded_session_dir()

    if File.dir?(base) do
      dirs =
        base
        |> File.ls!()
        |> Enum.map(&Path.join(base, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort()

      {:ok, dirs}
    else
      {:error, :claude_projects_dir_not_found}
    end
  end

  # Private functions

  defp parse_line(line, provider, skip_errors) do
    case Parser.parse_json(line, provider: provider) do
      {:ok, record} ->
        record

      {:error, reason} ->
        if skip_errors do
          nil
        else
          raise "Failed to parse line: #{inspect(reason)}"
        end
    end
  end

  defp file_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp resolve_from_names_json(identifier) do
    names_file = Path.expand("~/.arbor/session-names.json")

    with :ok <- check_file_exists(names_file, :no_names_json),
         {:ok, content} <- read_file(names_file, :cannot_read_names_json),
         {:ok, names} <- decode_names_json(content) do
      lookup_name_and_resolve(names, identifier)
    end
  end

  defp check_file_exists(path, error_tag) do
    if File.exists?(path), do: :ok, else: {:error, error_tag}
  end

  defp read_file(path, error_tag) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      _ -> {:error, error_tag}
    end
  end

  defp decode_names_json(content) do
    case Jason.decode(content) do
      {:ok, names} when is_map(names) -> {:ok, names}
      _ -> {:error, :invalid_names_json}
    end
  end

  defp lookup_name_and_resolve(names, identifier) do
    case Map.get(names, identifier) do
      nil -> {:error, :not_found_in_names}
      session_id -> resolve_by_uuid_prefix(session_id)
    end
  end

  defp resolve_from_session_id_file(identifier) do
    session_id_file = Path.expand("~/.arbor/#{identifier}-session-id")

    with :ok <- check_file_exists(session_id_file, :no_session_id_file),
         {:ok, session_id} <- read_file(session_id_file, :cannot_read_session_id_file) do
      resolve_by_uuid_prefix(String.trim(session_id))
    end
  end

  defp resolve_by_uuid_prefix(uuid_prefix) do
    with {:ok, dirs} <- find_project_dirs() do
      dirs
      |> Enum.find_value(&find_session_by_prefix(&1, uuid_prefix))
      |> case do
        nil -> {:error, :uuid_not_found}
        path -> {:ok, path}
      end
    end
  end

  defp find_session_by_prefix(dir, uuid_prefix) do
    case find_sessions(dir) do
      {:ok, files} ->
        Enum.find(files, fn file ->
          file |> Path.basename(".jsonl") |> String.starts_with?(uuid_prefix)
        end)

      _ ->
        nil
    end
  end
end
