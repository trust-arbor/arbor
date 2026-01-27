defmodule Arbor.Actions.File do
  @moduledoc """
  File system operations as Jido actions.

  This module provides Jido-compatible actions for common file operations
  with proper error handling and observability through Arbor.Signals.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Read` | Read content from a file |
  | `Write` | Write content to a file |
  | `List` | List directory contents |
  | `Glob` | Find files matching a pattern |
  | `Exists` | Check if a file or directory exists |

  ## Examples

      # Read a file
      {:ok, result} = Arbor.Actions.File.Read.run(%{path: "/etc/hosts"}, %{})
      result.content  # => "127.0.0.1 localhost\\n..."

      # Write a file
      {:ok, result} = Arbor.Actions.File.Write.run(
        %{path: "/tmp/test.txt", content: "Hello, World!"},
        %{}
      )

      # List directory
      {:ok, result} = Arbor.Actions.File.List.run(%{path: "/tmp"}, %{})
      result.entries  # => ["file1.txt", "file2.txt", ...]

      # Glob pattern
      {:ok, result} = Arbor.Actions.File.Glob.run(
        %{pattern: "/tmp/**/*.txt"},
        %{}
      )

      # Check existence
      {:ok, result} = Arbor.Actions.File.Exists.run(%{path: "/etc/hosts"}, %{})
      result.exists  # => true
  """

  defmodule Read do
    @moduledoc """
    Read content from a file.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the file to read |
    | `encoding` | atom | no | File encoding (default: :utf8) |

    ## Returns

    - `path` - The file path
    - `content` - The file content
    - `size` - File size in bytes
    """

    use Jido.Action,
      name: "file_read",
      description: "Read content from a file",
      category: "file",
      tags: ["file", "read", "io"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the file to read"
        ],
        encoding: [
          type: {:in, [:utf8, :latin1, :binary]},
          default: :utf8,
          doc: "File encoding"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)
      encoding = params[:encoding] || :utf8

      case File.read(path) do
        {:ok, content} ->
          content =
            if encoding == :binary do
              content
            else
              case :unicode.characters_to_binary(content, :utf8) do
                {:error, _, _} -> content
                {:incomplete, _, _} -> content
                binary -> binary
              end
            end

          result = %{
            path: path,
            content: content,
            size: byte_size(content)
          }

          Actions.emit_completed(__MODULE__, %{path: path, size: byte_size(content)})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to read file '#{path}': #{format_posix_error(reason)}"}
      end
    end

    defp format_posix_error(:enoent), do: "file not found"
    defp format_posix_error(:eacces), do: "permission denied"
    defp format_posix_error(:eisdir), do: "is a directory"
    defp format_posix_error(:enomem), do: "not enough memory"
    defp format_posix_error(reason), do: inspect(reason)
  end

  defmodule Write do
    @moduledoc """
    Write content to a file.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the file to write |
    | `content` | string | yes | Content to write |
    | `create_dirs` | boolean | no | Create parent directories if needed (default: false) |
    | `mode` | atom | no | Write mode: :write or :append (default: :write) |

    ## Returns

    - `path` - The file path
    - `bytes_written` - Number of bytes written
    """

    use Jido.Action,
      name: "file_write",
      description: "Write content to a file",
      category: "file",
      tags: ["file", "write", "io"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the file to write"
        ],
        content: [
          type: :string,
          required: true,
          doc: "Content to write to the file"
        ],
        create_dirs: [
          type: :boolean,
          default: false,
          doc: "Create parent directories if they don't exist"
        ],
        mode: [
          type: {:in, [:write, :append]},
          default: :write,
          doc: "Write mode - :write overwrites, :append adds to end"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, content: content} = params, _context) do
      Actions.emit_started(__MODULE__, %{path: path, size: byte_size(content)})

      create_dirs = params[:create_dirs] || false
      mode = params[:mode] || :write

      # Create parent directories if requested
      if create_dirs do
        File.mkdir_p(Path.dirname(path))
      end

      result =
        case mode do
          :write -> File.write(path, content)
          :append -> File.write(path, content, [:append])
        end

      case result do
        :ok ->
          result = %{
            path: path,
            bytes_written: byte_size(content)
          }

          Actions.emit_completed(__MODULE__, result)
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to write file '#{path}': #{format_posix_error(reason)}"}
      end
    end

    defp format_posix_error(:enoent), do: "directory not found"
    defp format_posix_error(:eacces), do: "permission denied"
    defp format_posix_error(:enospc), do: "no space left on device"
    defp format_posix_error(:erofs), do: "read-only file system"
    defp format_posix_error(reason), do: inspect(reason)
  end

  defmodule List do
    @moduledoc """
    List directory contents.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the directory to list |
    | `include_hidden` | boolean | no | Include hidden files (default: false) |
    | `include_dirs` | boolean | no | Include directories in results (default: true) |

    ## Returns

    - `path` - The directory path
    - `entries` - List of entry names
    - `count` - Number of entries
    """

    use Jido.Action,
      name: "file_list",
      description: "List directory contents",
      category: "file",
      tags: ["file", "directory", "list"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the directory to list"
        ],
        include_hidden: [
          type: :boolean,
          default: false,
          doc: "Include hidden files (starting with .)"
        ],
        include_dirs: [
          type: :boolean,
          default: true,
          doc: "Include directories in results"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      include_hidden = params[:include_hidden] || false
      include_dirs = Map.get(params, :include_dirs, true)

      case File.ls(path) do
        {:ok, entries} ->
          # Filter based on options
          entries =
            entries
            |> maybe_filter_hidden(include_hidden)
            |> maybe_filter_dirs(path, include_dirs)
            |> Enum.sort()

          result = %{
            path: path,
            entries: entries,
            count: length(entries)
          }

          Actions.emit_completed(__MODULE__, %{path: path, count: length(entries)})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to list directory '#{path}': #{format_posix_error(reason)}"}
      end
    end

    defp maybe_filter_hidden(entries, true), do: entries

    defp maybe_filter_hidden(entries, false) do
      Enum.reject(entries, &String.starts_with?(&1, "."))
    end

    defp maybe_filter_dirs(entries, _path, true), do: entries

    defp maybe_filter_dirs(entries, path, false) do
      Enum.reject(entries, fn entry ->
        File.dir?(Path.join(path, entry))
      end)
    end

    defp format_posix_error(:enoent), do: "directory not found"
    defp format_posix_error(:eacces), do: "permission denied"
    defp format_posix_error(:enotdir), do: "not a directory"
    defp format_posix_error(reason), do: inspect(reason)
  end

  defmodule Glob do
    @moduledoc """
    Find files matching a glob pattern.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `pattern` | string | yes | Glob pattern (e.g., "**/*.ex") |
    | `base_path` | string | no | Base directory for relative patterns |
    | `match_dot` | boolean | no | Match hidden files (default: false) |

    ## Returns

    - `pattern` - The glob pattern used
    - `matches` - List of matching file paths
    - `count` - Number of matches
    """

    use Jido.Action,
      name: "file_glob",
      description: "Find files matching a glob pattern",
      category: "file",
      tags: ["file", "glob", "search"],
      schema: [
        pattern: [
          type: :string,
          required: true,
          doc: "Glob pattern to match (e.g., '**/*.ex')"
        ],
        base_path: [
          type: :string,
          doc: "Base directory for relative patterns"
        ],
        match_dot: [
          type: :boolean,
          default: false,
          doc: "Match hidden files and directories"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()}
    def run(%{pattern: pattern} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      base_path = params[:base_path]
      match_dot = params[:match_dot] || false

      # Construct full pattern if base_path provided
      full_pattern =
        if base_path do
          Path.join(base_path, pattern)
        else
          pattern
        end

      # Build glob options
      opts = if match_dot, do: [match_dot: true], else: []

      matches =
        Path.wildcard(full_pattern, opts)
        |> Enum.sort()

      result = %{
        pattern: full_pattern,
        matches: matches,
        count: length(matches)
      }

      Actions.emit_completed(__MODULE__, %{pattern: full_pattern, count: length(matches)})
      {:ok, result}
    end
  end

  defmodule Exists do
    @moduledoc """
    Check if a file or directory exists.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to check |

    ## Returns

    - `path` - The checked path
    - `exists` - Whether the path exists
    - `type` - Type if exists: :file, :directory, or :other
    - `size` - File size in bytes (only if regular file)
    """

    use Jido.Action,
      name: "file_exists",
      description: "Check if a file or directory exists",
      category: "file",
      tags: ["file", "exists", "check"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to check for existence"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      result =
        case File.stat(path) do
          {:ok, %{type: :regular, size: size}} ->
            %{
              path: path,
              exists: true,
              type: :file,
              size: size
            }

          {:ok, %{type: :directory}} ->
            %{
              path: path,
              exists: true,
              type: :directory,
              size: nil
            }

          {:ok, %{type: type}} ->
            %{
              path: path,
              exists: true,
              type: :other,
              file_type: type,
              size: nil
            }

          {:error, :enoent} ->
            %{
              path: path,
              exists: false,
              type: nil,
              size: nil
            }

          {:error, _reason} ->
            # Other errors (permission, etc.) - path exists but we can't access it
            %{
              path: path,
              exists: true,
              type: :unknown,
              size: nil
            }
        end

      Actions.emit_completed(__MODULE__, %{path: path, exists: result.exists})
      {:ok, result}
    end
  end
end
