defmodule Arbor.Common.Sessions.Reader do
  @moduledoc """
  Streaming JSONL file reader for session files.

  Pure functions, no process state. Provides streaming reads for memory efficiency
  with large session files.

  ## Usage

      # Stream records from a file (memory efficient)
      {:ok, stream} = Reader.stream("session.jsonl", allowed_root: "/trusted/sessions")
      records = Enum.to_list(stream)

      # Read all at once (for small files)
      {:ok, records} = Reader.read_all("session.jsonl", allowed_root: "/trusted/sessions")

      # Find session files
      {:ok, files} = Reader.find_sessions("project", allowed_root: "~/.claude/projects")

      # Find the most recent session
      {:ok, path} = Reader.latest_session("project", allowed_root: "~/.claude/projects")

  ## Path Safety

  Direct file and directory APIs require an `:allowed_root`; paths are resolved
  through `Arbor.Common.SafePath` before any file access.
  """

  alias Arbor.Common.SafePath
  alias Arbor.Common.Sessions.Parser
  alias Arbor.Common.Sessions.Providers.Claude
  alias Arbor.Common.Sessions.Record

  @type path :: String.t()
  @type stream_result :: {:ok, Enumerable.t()} | {:error, term()}
  @type read_result :: {:ok, [Record.t()]} | {:error, term()}

  @default_max_line_bytes 1_048_576
  @max_line_bytes 10_485_760
  @read_chunk_bytes 65_536
  @identifier_pattern ~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z/

  @doc """
  Stream records from a JSONL session file.

  Returns a lazy stream that yields `Record.t()` structs. Invalid lines are
  skipped with a warning in the stream.

  ## Options

  - `:allowed_root` - Required trusted root directory
  - `:provider` - Explicit provider (`:claude`, `:auto`). Default: `:auto`
  - `:skip_errors` - Skip malformed lines instead of stopping. Default: `true`
  - `:max_line_bytes` - Maximum JSONL record size. Default: 1 MiB

  ## Examples

      {:ok, stream} = Reader.stream("session.jsonl", allowed_root: "/trusted/sessions")
      messages = stream |> Enum.filter(&Record.message?/1) |> Enum.to_list()
  """
  @spec stream(path(), keyword()) :: stream_result()
  def stream(path, opts \\ []) do
    with {:ok, resolved} <- resolve_allowed_path(path, opts),
         :ok <- validate_max_line_bytes(opts),
         :ok <- require_regular_path(resolved) do
      skip_errors = Keyword.get(opts, :skip_errors, true)
      provider = Keyword.get(opts, :provider, :auto)
      max_line_bytes = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)
      allowed_root = opts |> Keyword.fetch!(:allowed_root) |> Path.expand()

      stream =
        bounded_line_stream(resolved, allowed_root, max_line_bytes, skip_errors)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&parse_line(&1, provider, skip_errors, max_line_bytes))
        |> Stream.reject(&is_nil/1)

      {:ok, stream}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Read all records from a JSONL session file.

  Loads all records into memory. Use `stream/2` for large files.

  ## Options

  - `:allowed_root` - Required trusted root directory
  - `:provider` - Explicit provider (`:claude`, `:auto`). Default: `:auto`
  - `:skip_errors` - Skip malformed lines instead of stopping. Default: `true`

  ## Examples

      {:ok, records} = Reader.read_all("session.jsonl", allowed_root: "/trusted/sessions")
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

  - `:allowed_root` - Required trusted root directory
  - `:pattern` - Glob pattern for session files. Default: `"*.jsonl"`

  ## Examples

      {:ok, files} = Reader.find_sessions("project", allowed_root: "~/.claude/projects")
      # Returns list of .jsonl files sorted by modification time
  """
  @spec find_sessions(path(), keyword()) :: {:ok, [path()]} | {:error, term()}
  def find_sessions(dir, opts \\ []) do
    pattern = Keyword.get(opts, :pattern, "*.jsonl")

    with :ok <- validate_glob_pattern(pattern),
         {:ok, resolved} <- resolve_allowed_path(dir, opts),
         true <- File.dir?(resolved) do
      files =
        Path.join(resolved, pattern)
        |> Path.wildcard()
        |> Enum.sort_by(&file_mtime/1, :desc)

      {:ok, files}
    else
      false -> {:error, :not_a_directory}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Find the most recent session file in a directory.

  ## Examples

      {:ok, path} = Reader.latest_session("project", allowed_root: "~/.claude/projects")
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
    with :ok <- validate_identifier(identifier),
         {:error, _} <- resolve_from_names_json(identifier),
         {:error, _} <- resolve_from_session_id_file(identifier),
         {:error, _} <- resolve_by_uuid_prefix(identifier) do
      {:error, :session_not_found}
    end
  end

  def resolve(_identifier), do: {:error, :invalid_identifier}

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

  defp bounded_line_stream(path, allowed_root, max_line_bytes, skip_errors) do
    Stream.resource(
      fn -> open_line_reader(path, allowed_root, max_line_bytes, skip_errors) end,
      &next_bounded_line/1,
      &close_line_reader/1
    )
  end

  defp open_line_reader(path, allowed_root, max_line_bytes, skip_errors) do
    case open_verified_descriptor(path, allowed_root) do
      {:ok, io_device} ->
        %{
          io_device: io_device,
          buffer: <<>>,
          discarding_oversized?: false,
          eof?: false,
          ready: :queue.new(),
          max_line_bytes: max_line_bytes,
          skip_errors: skip_errors
        }

      {:error, reason} ->
        {:open_error, reason, skip_errors}
    end
  end

  defp next_bounded_line({:open_error, _reason, true} = state), do: {:halt, state}

  defp next_bounded_line({:open_error, reason, false}) do
    raise "Session file changed before it could be opened safely: #{inspect(reason)}"
  end

  defp next_bounded_line(%{ready: ready} = state) do
    case :queue.out(ready) do
      {{:value, line}, rest} ->
        {[line], %{state | ready: rest}}

      {:empty, _ready} ->
        read_next_bounded_line(state)
    end
  end

  defp read_next_bounded_line(%{eof?: true, buffer: <<>>} = state), do: {:halt, state}

  defp read_next_bounded_line(%{eof?: true} = state) do
    line = state.buffer
    next_bounded_line(%{state | buffer: <<>>, ready: :queue.in(line, state.ready)})
  end

  defp read_next_bounded_line(state) do
    case :file.read(state.io_device, @read_chunk_bytes) do
      {:ok, chunk} ->
        state
        |> ingest_chunk(chunk)
        |> next_bounded_line()

      :eof ->
        state = %{state | eof?: true}

        if state.discarding_oversized? do
          {:halt, %{state | buffer: <<>>}}
        else
          next_bounded_line(state)
        end

      {:error, reason} ->
        if state.skip_errors do
          {:halt, %{state | eof?: true, buffer: <<>>}}
        else
          raise "Failed to read session file: #{inspect(reason)}"
        end
    end
  end

  defp ingest_chunk(%{discarding_oversized?: true} = state, chunk) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        state

      {newline_at, 1} ->
        remaining = binary_part(chunk, newline_at + 1, byte_size(chunk) - newline_at - 1)
        ingest_chunk(%{state | discarding_oversized?: false}, remaining)
    end
  end

  defp ingest_chunk(state, <<>>), do: state

  defp ingest_chunk(state, chunk) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        append_partial_line(state, chunk)

      {newline_at, 1} ->
        prefix = binary_part(chunk, 0, newline_at)
        remaining = binary_part(chunk, newline_at + 1, byte_size(chunk) - newline_at - 1)

        state
        |> complete_line(prefix)
        |> ingest_chunk(remaining)
    end
  end

  defp append_partial_line(state, chunk) do
    if byte_size(state.buffer) + byte_size(chunk) <= state.max_line_bytes do
      %{state | buffer: state.buffer <> chunk}
    else
      oversized_line(state)
    end
  end

  defp complete_line(state, suffix) do
    if byte_size(state.buffer) + byte_size(suffix) <= state.max_line_bytes do
      line = state.buffer <> suffix
      %{state | buffer: <<>>, ready: :queue.in(line, state.ready)}
    else
      state
      |> oversized_line()
      |> Map.put(:discarding_oversized?, false)
    end
  end

  defp oversized_line(%{skip_errors: true} = state) do
    %{state | buffer: <<>>, discarding_oversized?: true}
  end

  defp oversized_line(%{skip_errors: false}) do
    raise "Session JSONL record exceeds max_line_bytes"
  end

  defp close_line_reader(%{io_device: io_device}) do
    File.close(io_device)
  end

  defp close_line_reader(_state), do: :ok

  defp open_verified_descriptor(path, allowed_root) do
    with {:ok, ^path} <- SafePath.resolve_within(path, allowed_root),
         {:ok, checked_info} <- :file.read_link_info(path),
         :ok <- require_regular_info(checked_info),
         {:ok, io_device} <- File.open(path, [:read, :binary, :raw]) do
      verify_opened_descriptor(io_device, path, allowed_root, checked_info)
    else
      {:ok, _different_path} -> {:error, :path_changed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :path_changed}
  catch
    _kind, _reason -> {:error, :path_changed}
  end

  defp verify_opened_descriptor(io_device, path, allowed_root, checked_info) do
    result =
      with {:ok, opened_info} <- :file.read_file_info(io_device),
           true <- same_file_identity?(checked_info, opened_info),
           {:ok, ^path} <- SafePath.resolve_within(path, allowed_root),
           {:ok, current_info} <- :file.read_link_info(path),
           true <- same_file_identity?(opened_info, current_info) do
        {:ok, io_device}
      else
        false -> {:error, :path_changed}
        {:ok, _different_path} -> {:error, :path_changed}
        {:error, reason} -> {:error, reason}
      end

    case result do
      {:ok, ^io_device} = ok ->
        ok

      {:error, _reason} = error ->
        File.close(io_device)
        error
    end
  end

  defp require_regular_path(path) do
    case :file.read_link_info(path) do
      {:ok, info} -> require_regular_info(info)
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_regular_info(
         {:file_info, _size, :regular, _access, _atime, _mtime, _ctime, _mode, _links, _major,
          _minor, _inode, _uid, _gid}
       ),
       do: :ok

  defp require_regular_info(_info), do: {:error, :file_not_found}

  defp same_file_identity?(
         {:file_info, _size_a, type, _access_a, _atime_a, _mtime_a, _ctime_a, _mode_a, _links_a,
          major, minor, inode, _uid_a, _gid_a},
         {:file_info, _size_b, type, _access_b, _atime_b, _mtime_b, _ctime_b, _mode_b, _links_b,
          major, minor, inode, _uid_b, _gid_b}
       ),
       do: true

  defp same_file_identity?(_left, _right), do: false

  defp parse_line(line, _provider, true, max_line_bytes)
       when byte_size(line) > max_line_bytes,
       do: nil

  defp parse_line(line, _provider, false, max_line_bytes)
       when byte_size(line) > max_line_bytes,
       do: raise("Session JSONL record exceeds max_line_bytes")

  defp parse_line(line, provider, skip_errors, _max_line_bytes) do
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
    case find_sessions(dir, allowed_root: Claude.expanded_session_dir()) do
      {:ok, files} ->
        Enum.find(files, fn file ->
          file |> Path.basename(".jsonl") |> String.starts_with?(uuid_prefix)
        end)

      _ ->
        nil
    end
  end

  defp resolve_allowed_path(path, opts) when is_binary(path) do
    case Keyword.fetch(opts, :allowed_root) do
      {:ok, allowed_root} when is_binary(allowed_root) ->
        SafePath.resolve_within(path, Path.expand(allowed_root))

      _ ->
        {:error, :allowed_root_required}
    end
  end

  defp resolve_allowed_path(_path, _opts), do: {:error, :invalid_path}

  defp validate_max_line_bytes(opts) do
    case Keyword.get(opts, :max_line_bytes, @default_max_line_bytes) do
      value when is_integer(value) and value > 0 and value <= @max_line_bytes -> :ok
      _ -> {:error, :invalid_max_line_bytes}
    end
  end

  defp validate_glob_pattern(pattern)
       when is_binary(pattern) and pattern != "" and byte_size(pattern) <= 128 do
    if String.contains?(pattern, ["/", "\\", "..", <<0>>]),
      do: {:error, :invalid_pattern},
      else: :ok
  end

  defp validate_glob_pattern(_pattern), do: {:error, :invalid_pattern}

  defp validate_identifier(identifier) do
    if Regex.match?(@identifier_pattern, identifier),
      do: :ok,
      else: {:error, :invalid_identifier}
  end
end
