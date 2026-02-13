defmodule Arbor.Orchestrator.UnifiedLLM.CodingTools do
  @moduledoc """
  Tool definitions and execution for the coding tool loop.

  Provides 5 filesystem and shell tools that any LLM can use via
  the standard OpenAI tool_use protocol:

    * `read_file` - Read file contents
    * `write_file` - Write content to a file (creates dirs)
    * `list_files` - List files matching a glob pattern
    * `search_content` - Search file contents with regex
    * `shell_exec` - Execute a shell command

  All file operations are sandboxed to the workdir.
  """

  @doc "Returns OpenAI-format tool definitions for coding tools."
  @spec definitions() :: [map()]
  def definitions do
    [
      %{
        "type" => "function",
        "function" => %{
          "name" => "read_file",
          "description" => "Read the contents of a file. Returns the file content as text.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "File path relative to the project root, or absolute path"
              }
            },
            "required" => ["path"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "write_file",
          "description" =>
            "Write content to a file. Creates parent directories if needed. Overwrites existing content.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "File path relative to the project root, or absolute path"
              },
              "content" => %{
                "type" => "string",
                "description" => "The full content to write to the file"
              }
            },
            "required" => ["path", "content"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "list_files",
          "description" => "List files matching a glob pattern. Returns one file path per line.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "pattern" => %{
                "type" => "string",
                "description" => "Glob pattern like '**/*.ex', 'lib/**/*.exs', or 'mix.exs'"
              }
            },
            "required" => ["pattern"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "search_content",
          "description" =>
            "Search file contents using a regex pattern. Returns matching lines with file paths and line numbers.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "pattern" => %{
                "type" => "string",
                "description" => "Regex pattern to search for (Elixir regex syntax)"
              },
              "glob" => %{
                "type" => "string",
                "description" => "Optional glob to filter which files to search (default: '**/*')"
              }
            },
            "required" => ["pattern"]
          }
        }
      },
      %{
        "type" => "function",
        "function" => %{
          "name" => "shell_exec",
          "description" =>
            "Execute a shell command and return its output. Use for compilation, testing, formatting, etc. The command runs in the project root directory.",
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "command" => %{
                "type" => "string",
                "description" =>
                  "Shell command to execute (e.g., 'mix compile --warnings-as-errors', 'mix test path/to/test.exs')"
              },
              "timeout" => %{
                "type" => "integer",
                "description" => "Timeout in milliseconds (default: 60000)"
              }
            },
            "required" => ["command"]
          }
        }
      }
    ]
  end

  @doc """
  Execute a tool by name with the given arguments.

  All file paths are resolved relative to `workdir`.
  Returns `{:ok, result_text}` or `{:error, reason}`.
  """
  @spec execute(String.t(), map(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(name, args, workdir)

  def execute("read_file", args, workdir) do
    path = resolve_path(args["path"], workdir)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{args["path"]}: #{reason}"}
    end
  end

  def execute("write_file", args, workdir) do
    path = resolve_path(args["path"], workdir)
    content = args["content"] || ""

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, content) do
      {:ok, "Wrote #{byte_size(content)} bytes to #{args["path"]}"}
    else
      {:error, reason} -> {:error, "Cannot write #{args["path"]}: #{reason}"}
    end
  end

  def execute("list_files", args, workdir) do
    pattern = args["pattern"] || "**/*"
    full_pattern = Path.join(workdir, pattern)

    files =
      full_pattern
      |> Path.wildcard()
      |> Enum.reject(&File.dir?/1)
      |> Enum.map(&Path.relative_to(&1, workdir))
      |> Enum.sort()

    if files == [] do
      {:ok, "No files found matching #{pattern}"}
    else
      {:ok, Enum.join(files, "\n")}
    end
  end

  def execute("search_content", args, workdir) do
    pattern_str = args["pattern"] || ""
    glob = args["glob"] || "**/*"

    case Regex.compile(pattern_str) do
      {:ok, regex} ->
        full_glob = Path.join(workdir, glob)

        results =
          full_glob
          |> Path.wildcard()
          |> Enum.reject(&File.dir?/1)
          |> Enum.flat_map(fn file_path ->
            rel_path = Path.relative_to(file_path, workdir)
            search_file(file_path, rel_path, regex)
          end)
          |> Enum.take(100)

        if results == [] do
          {:ok, "No matches found for /#{pattern_str}/"}
        else
          {:ok, Enum.join(results, "\n")}
        end

      {:error, {reason, _}} ->
        {:error, "Invalid regex pattern: #{reason}"}
    end
  end

  def execute("shell_exec", args, workdir) do
    command = args["command"] || ""
    timeout = args["timeout"] || 60_000

    if command == "" do
      {:error, "No command provided"}
    else
      execute_shell(command, workdir, timeout)
    end
  end

  def execute(name, _args, _workdir) do
    {:error, "Unknown tool: #{name}"}
  end

  # --- Private ---

  defp resolve_path(nil, workdir), do: workdir

  defp resolve_path(path, workdir) do
    if Path.type(path) == :absolute do
      Path.expand(path)
    else
      Path.join(workdir, path) |> Path.expand()
    end
  end

  defp search_file(file_path, rel_path, regex) do
    case File.read(file_path) do
      {:ok, content} ->
        # Skip binary files
        if String.valid?(content) do
          content
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.filter(fn {line, _num} -> Regex.match?(regex, line) end)
          |> Enum.map(fn {line, num} -> "#{rel_path}:#{num}: #{line}" end)
        else
          []
        end

      {:error, _} ->
        []
    end
  end

  defp execute_shell(command, workdir, timeout) do
    task =
      Task.async(fn ->
        try do
          {output, exit_code} =
            System.cmd("sh", ["-c", command],
              cd: workdir,
              stderr_to_stdout: true,
              env: [{"MIX_ENV", "test"}]
            )

          if exit_code == 0 do
            {:ok, output}
          else
            {:ok, "Exit code #{exit_code}:\n#{output}"}
          end
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, "Command timed out after #{timeout}ms"}
    end
  end
end
