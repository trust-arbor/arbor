defmodule Arbor.Actions.File do
  @moduledoc """
  File system operations as Jido actions.

  This module provides Jido-compatible actions for common file operations
  with proper error handling and observability through Arbor.Signals.

  ## Path Safety

  When the context includes a `:workspace` key, all paths are validated
  using `Arbor.Common.SafePath.resolve_within/2` to prevent path traversal
  attacks. Without a workspace, paths are used as-is — callers are
  responsible for validation.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Read` | Read content from a file |
  | `Write` | Write content to a file |
  | `List` | List directory contents |
  | `Glob` | Find files matching a pattern |
  | `Exists` | Check if a file or directory exists |

  ## Examples

      # Read a file within a workspace
      {:ok, result} = Arbor.Actions.File.Read.run(
        %{path: "lib/my_module.ex"},
        %{workspace: "/opt/arbor/workspace"}
      )
  """

  alias Arbor.Common.SafePath

  @doc false
  def validate_path(path, context) do
    case Map.get(context, :workspace) do
      nil ->
        {:ok, path}

      workspace ->
        case SafePath.resolve_within(path, workspace) do
          {:ok, safe_path} -> {:ok, safe_path}
          {:error, _} -> {:error, "Path traversal denied: #{path}"}
        end
    end
  end

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

    @doc """
    Declares taint roles for File.Read parameters.

    Control parameters:
    - `path` - Which file to read affects security boundary

    Data parameters:
    - `encoding` - Just affects how content is decoded
    """
    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{
        path: :control,
        encoding: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, context) do
      with {:ok, safe_path} <- Arbor.Actions.File.validate_path(path, context) do
        Actions.emit_started(__MODULE__, params)
        encoding = params[:encoding] || :utf8

        case File.read(safe_path) do
          {:ok, content} ->
            content = maybe_decode_content(content, encoding)

            result = %{
              path: safe_path,
              content: content,
              size: byte_size(content)
            }

            Actions.emit_completed(__MODULE__, %{path: safe_path, size: byte_size(content)})
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to read file '#{safe_path}': #{format_posix_error(reason)}"}
        end
      end
    end

    defp maybe_decode_content(content, :binary), do: content

    defp maybe_decode_content(content, _encoding) do
      case :unicode.characters_to_binary(content, :utf8) do
        {:error, _, _} -> content
        {:incomplete, _, _} -> content
        binary -> binary
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

    @doc """
    Declares taint roles for File.Write parameters.

    Control parameters:
    - `path` - Which file to write affects security boundary
    - `mode` - Write mode affects how file is modified

    Data parameters:
    - `content` - Just the data being written
    - `create_dirs` - Boolean flag, doesn't affect security
    """
    @spec taint_roles() :: %{atom() => :control | :data}
    def taint_roles do
      %{
        path: :control,
        mode: :control,
        content: :data,
        create_dirs: :data
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, content: content} = params, context) do
      with {:ok, safe_path} <- Arbor.Actions.File.validate_path(path, context) do
        Actions.emit_started(__MODULE__, %{path: safe_path, size: byte_size(content)})

        create_dirs = params[:create_dirs] || false
        mode = params[:mode] || :write

        # Create parent directories if requested
        if create_dirs do
          File.mkdir_p(Path.dirname(safe_path))
        end

        result =
          case mode do
            :write -> File.write(safe_path, content)
            :append -> File.write(safe_path, content, [:append])
          end

        case result do
          :ok ->
            result = %{
              path: safe_path,
              bytes_written: byte_size(content)
            }

            Actions.emit_completed(__MODULE__, result)
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to write file '#{safe_path}': #{format_posix_error(reason)}"}
        end
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
    def run(%{path: path} = params, context) do
      with {:ok, safe_path} <- Arbor.Actions.File.validate_path(path, context) do
        Actions.emit_started(__MODULE__, params)

        include_hidden = params[:include_hidden] || false
        include_dirs = Map.get(params, :include_dirs, true)

        case File.ls(safe_path) do
          {:ok, entries} ->
            entries =
              entries
              |> maybe_filter_hidden(include_hidden)
              |> maybe_filter_dirs(safe_path, include_dirs)
              |> Enum.sort()

            result = %{
              path: safe_path,
              entries: entries,
              count: length(entries)
            }

            Actions.emit_completed(__MODULE__, %{path: safe_path, count: length(entries)})
            {:ok, result}

          {:error, reason} ->
            Actions.emit_failed(__MODULE__, reason)
            {:error, "Failed to list directory '#{safe_path}': #{format_posix_error(reason)}"}
        end
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
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{pattern: pattern} = params, context) do
      base_path = params[:base_path]

      # Validate base_path if provided and workspace is set
      with {:ok, safe_base} <- validate_base_path(base_path, context) do
        Actions.emit_started(__MODULE__, params)
        match_dot = params[:match_dot] || false

        full_pattern =
          if safe_base do
            Path.join(safe_base, pattern)
          else
            pattern
          end

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

    defp validate_base_path(nil, _context), do: {:ok, nil}
    defp validate_base_path(path, context), do: Arbor.Actions.File.validate_path(path, context)
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
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, context) do
      with {:ok, safe_path} <- Arbor.Actions.File.validate_path(path, context) do
        Actions.emit_started(__MODULE__, params)

        result =
          case File.stat(safe_path) do
            {:ok, %{type: :regular, size: size}} ->
              %{path: safe_path, exists: true, type: :file, size: size}

            {:ok, %{type: :directory}} ->
              %{path: safe_path, exists: true, type: :directory, size: nil}

            {:ok, %{type: type}} ->
              %{path: safe_path, exists: true, type: :other, file_type: type, size: nil}

            {:error, :enoent} ->
              %{path: safe_path, exists: false, type: nil, size: nil}

            {:error, _reason} ->
              %{path: safe_path, exists: true, type: :unknown, size: nil}
          end

        Actions.emit_completed(__MODULE__, %{path: safe_path, exists: result.exists})
        {:ok, result}
      end
    end
  end

  defmodule Edit do
    @moduledoc """
    Targeted string replacement in a file.

    Unlike Write which does a full overwrite, Edit performs targeted find-and-replace
    operations. This is the essential action for code-modifying agents.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the file |
    | `old_string` | string | yes | String to find and replace |
    | `new_string` | string | yes | Replacement string |
    | `replace_all` | boolean | no | Replace all occurrences (default: false) |

    ## Returns

    - `path` - The file path
    - `replacements_made` - Number of replacements made
    - `preview` - Preview of the modified content (first 100 chars around first change)

    ## Examples

        {:ok, result} = Arbor.Actions.File.Edit.run(
          %{path: "/tmp/code.ex", old_string: "foo", new_string: "bar"},
          %{}
        )
        result.replacements_made  # => 1
    """

    use Jido.Action,
      name: "file_edit",
      description: "Targeted string replacement in a file",
      category: "file",
      tags: ["file", "edit", "replace"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the file to edit"
        ],
        old_string: [
          type: :string,
          required: true,
          doc: "String to find and replace"
        ],
        new_string: [
          type: :string,
          required: true,
          doc: "Replacement string"
        ],
        replace_all: [
          type: :boolean,
          default: false,
          doc: "Replace all occurrences (default: replace first only)"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, old_string: old_string, new_string: new_string} = params, context) do
      replace_all = params[:replace_all] || false

      with {:ok, safe_path} <- Arbor.Actions.File.validate_path(path, context),
           :ok <-
             (
               Actions.emit_started(__MODULE__, %{path: safe_path})
               :ok
             ),
           {:ok, content} <- read_file(safe_path),
           {:ok, new_content, count} <-
             perform_replacement(content, old_string, new_string, replace_all),
           :ok <- write_file(safe_path, new_content) do
        result = %{
          path: safe_path,
          replacements_made: count,
          preview: generate_preview(new_content, new_string)
        }

        Actions.emit_completed(__MODULE__, %{path: safe_path, replacements_made: count})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    defp read_file(path) do
      case File.read(path) do
        {:ok, content} -> {:ok, content}
        {:error, :enoent} -> {:error, "File not found: #{path}"}
        {:error, :eacces} -> {:error, "Permission denied: #{path}"}
        {:error, :eisdir} -> {:error, "Path is a directory: #{path}"}
        {:error, reason} -> {:error, "Failed to read file: #{inspect(reason)}"}
      end
    end

    defp perform_replacement(_content, old_string, _new_string, _replace_all)
         when not is_binary(old_string) or old_string == "" do
      {:error, "old_string must be a non-empty string"}
    end

    defp perform_replacement(content, old_string, new_string, _replace_all)
         when content == old_string do
      # Special case: entire content matches
      {:ok, new_string, 1}
    end

    defp perform_replacement(content, old_string, new_string, replace_all) do
      if String.contains?(content, old_string) do
        {new_content, count} =
          if replace_all do
            count = count_occurrences(content, old_string)
            {String.replace(content, old_string, new_string), count}
          else
            {String.replace(content, old_string, new_string, global: false), 1}
          end

        {:ok, new_content, count}
      else
        {:error, "String not found in file: #{truncate(old_string, 50)}"}
      end
    end

    defp count_occurrences(content, substring) do
      # Count non-overlapping occurrences
      content
      |> String.split(substring)
      |> length()
      |> Kernel.-(1)
    end

    defp write_file(path, content) do
      case File.write(path, content) do
        :ok -> :ok
        {:error, :eacces} -> {:error, "Permission denied: #{path}"}
        {:error, :enospc} -> {:error, "No space left on device"}
        {:error, :erofs} -> {:error, "Read-only file system"}
        {:error, reason} -> {:error, "Failed to write file: #{inspect(reason)}"}
      end
    end

    defp generate_preview(content, new_string) do
      # Find first occurrence of new_string and show context
      case :binary.match(content, new_string) do
        {start, _len} ->
          preview_start = max(0, start - 20)
          preview_length = min(100, byte_size(content) - preview_start)
          String.slice(content, preview_start, preview_length)

        :nomatch ->
          String.slice(content, 0, 100)
      end
    end

    defp truncate(string, max_len) when byte_size(string) > max_len do
      String.slice(string, 0, max_len - 3) <> "..."
    end

    defp truncate(string, _max_len), do: string
  end

  defmodule Search do
    @moduledoc """
    Search file contents by pattern.

    Searches for a pattern (regex or literal string) within files. Can search
    a single file or recursively search a directory with glob filtering.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `pattern` | string | yes | Search pattern (regex or literal) |
    | `path` | string | yes | File or directory to search |
    | `glob` | string | no | File filter pattern (e.g., "*.ex") |
    | `max_results` | integer | no | Maximum matches to return (default: 50) |
    | `context_lines` | integer | no | Lines of context around match (default: 2) |
    | `regex` | boolean | no | Treat pattern as regex (default: false) |

    ## Returns

    - `matches` - List of matches, each with `file`, `line`, `content`
    - `count` - Total number of matches found

    ## Examples

        {:ok, result} = Arbor.Actions.File.Search.run(
          %{pattern: "defmodule", path: "/path/to/project", glob: "*.ex"},
          %{}
        )
        result.matches  # => [%{file: "lib/foo.ex", line: 1, content: "defmodule Foo do"}]
    """

    use Jido.Action,
      name: "file_search",
      description: "Search file contents by pattern",
      category: "file",
      tags: ["file", "search", "grep"],
      schema: [
        pattern: [
          type: :string,
          required: true,
          doc: "Search pattern (regex or literal string)"
        ],
        path: [
          type: :string,
          required: true,
          doc: "File or directory to search"
        ],
        glob: [
          type: :string,
          doc: "File filter pattern (e.g., '*.ex')"
        ],
        max_results: [
          type: :integer,
          default: 50,
          doc: "Maximum number of matches to return"
        ],
        context_lines: [
          type: :integer,
          default: 2,
          doc: "Lines of context to include around matches"
        ],
        regex: [
          type: :boolean,
          default: false,
          doc: "Treat pattern as a regular expression"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{pattern: pattern, path: path} = params, context) do
      max_results = params[:max_results] || 50
      ctx_lines = params[:context_lines] || 2
      glob_pattern = params[:glob]
      use_regex = params[:regex] || false

      with {:ok, safe_path} <- Arbor.Actions.File.validate_path(path, context),
           :ok <-
             (
               Actions.emit_started(__MODULE__, %{path: safe_path, pattern: pattern})
               :ok
             ),
           {:ok, search_pattern} <- compile_pattern(pattern, use_regex),
           {:ok, files} <- get_files_to_search(safe_path, glob_pattern),
           {:ok, matches} <- search_files(files, search_pattern, ctx_lines, max_results) do
        result = %{
          matches: matches,
          count: length(matches)
        }

        Actions.emit_completed(__MODULE__, %{path: path, count: length(matches)})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, reason}
      end
    end

    @max_pattern_length 500

    defp compile_pattern(pattern, false) do
      if String.length(pattern) > @max_pattern_length do
        {:error, "Pattern too long (max #{@max_pattern_length} characters)"}
      else
        # Literal string search - escape regex special characters
        escaped = Regex.escape(pattern)
        # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
        {:ok, Regex.compile!(escaped)}
      end
    end

    defp compile_pattern(pattern, true) do
      if String.length(pattern) > @max_pattern_length do
        {:error, "Pattern too long (max #{@max_pattern_length} characters)"}
      else
        # credo:disable-for-next-line Credo.Check.Security.UnsafeRegexCompile
        case Regex.compile(pattern) do
          {:ok, regex} -> {:ok, regex}
          {:error, _} -> {:error, "Invalid regex pattern: #{pattern}"}
        end
      end
    end

    defp get_files_to_search(path, glob_pattern) do
      cond do
        File.regular?(path) ->
          {:ok, [path]}

        File.dir?(path) ->
          pattern =
            if glob_pattern,
              do: Path.join(path, "**/" <> glob_pattern),
              else: Path.join(path, "**/*")

          files = Path.wildcard(pattern) |> Enum.filter(&File.regular?/1)
          {:ok, files}

        true ->
          {:error, "Path does not exist: #{path}"}
      end
    end

    defp search_files(files, pattern, context_lines, max_results) do
      matches =
        files
        |> Enum.flat_map(fn file -> search_file(file, pattern, context_lines) end)
        |> Enum.take(max_results)

      {:ok, matches}
    end

    defp search_file(file, pattern, context_lines) do
      case File.read(file) do
        {:ok, content} ->
          lines = String.split(content, ~r/\r?\n/)

          lines
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _idx} -> Regex.match?(pattern, line) end)
          |> Enum.map(fn {_line, idx} ->
            %{
              file: file,
              line: idx,
              content: get_context(lines, idx, context_lines)
            }
          end)

        {:error, _} ->
          []
      end
    end

    defp get_context(lines, line_idx, context_lines) do
      # line_idx is 1-based
      start_idx = max(0, line_idx - 1 - context_lines)
      end_idx = min(length(lines) - 1, line_idx - 1 + context_lines)

      lines
      |> Enum.slice(start_idx..end_idx)
      |> Enum.with_index(start_idx + 1)
      |> Enum.map_join("\n", fn {line, idx} ->
        prefix = if idx == line_idx, do: "> ", else: "  "
        "#{prefix}#{idx}: #{line}"
      end)
    end
  end
end
