defmodule Arbor.Actions.Git do
  @moduledoc """
  Git repository operations as Jido actions.

  This module provides Jido-compatible actions for common Git operations
  with proper error handling and observability through Arbor.Signals.

  All actions execute Git commands through Arbor.Shell with :basic sandboxing
  to ensure safety while allowing necessary Git operations.

  ## Actions

  | Action | Description |
  |--------|-------------|
  | `Status` | Get repository status |
  | `Diff` | Show changes between commits or working tree |
  | `Commit` | Create a new commit |
  | `Log` | Show commit history |

  ## Examples

      # Get status
      {:ok, result} = Arbor.Actions.Git.Status.run(%{path: "/path/to/repo"}, %{})
      result.is_clean  # => false
      result.modified  # => ["file1.txt", "file2.txt"]

      # Show diff
      {:ok, result} = Arbor.Actions.Git.Diff.run(%{path: "/path/to/repo"}, %{})
      result.diff  # => "diff --git a/file.txt..."

      # Create commit
      {:ok, result} = Arbor.Actions.Git.Commit.run(
        %{path: "/path/to/repo", message: "Fix bug", files: ["file.txt"]},
        %{}
      )

      # Show log
      {:ok, result} = Arbor.Actions.Git.Log.run(
        %{path: "/path/to/repo", limit: 5},
        %{}
      )
  """

  alias Arbor.Shell

  # Git command defaults - used by all nested action modules
  @doc false
  def git_timeout, do: 30_000
  @doc false
  def git_sandbox, do: :basic

  defmodule Status do
    @moduledoc """
    Get repository status.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |

    ## Returns

    - `path` - Repository path
    - `branch` - Current branch name
    - `is_clean` - Whether the working tree is clean
    - `staged` - List of staged files
    - `modified` - List of modified (unstaged) files
    - `untracked` - List of untracked files
    - `ahead` - Commits ahead of upstream (if tracking)
    - `behind` - Commits behind upstream (if tracking)
    """

    use Jido.Action,
      name: "git_status",
      description: "Get the status of a Git repository",
      category: "git",
      tags: ["git", "status", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, branch_result} <- git_command(path, ["branch", "--show-current"]),
           {:ok, status_result} <- git_command(path, ["status", "--porcelain", "-b"]) do
        status = parse_status(status_result.stdout, branch_result.stdout)

        result = Map.put(status, :path, path)
        Actions.emit_completed(__MODULE__, %{path: path, is_clean: status.is_clean})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get git status: #{reason}"}
      end
    end

    defp git_command(path, args) do
      command = Enum.join(["git" | args], " ")

      case Shell.execute(command,
             cwd: path,
             timeout: Arbor.Actions.Git.git_timeout(),
             sandbox: Arbor.Actions.Git.git_sandbox()
           ) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr}} ->
          {:error, String.trim(stderr)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end

    defp parse_status(porcelain_output, branch_output) do
      branch = String.trim(branch_output)
      lines = String.split(porcelain_output, "\n", trim: true)

      # Parse branch line for ahead/behind info
      {ahead, behind} = parse_tracking_info(Enum.at(lines, 0, ""))

      # Parse file status lines (skip first line which is branch info)
      file_lines = Enum.drop(lines, 1)

      {staged, modified, untracked} =
        Enum.reduce(file_lines, {[], [], []}, fn line, {s, m, u} ->
          case parse_status_line(line) do
            {:staged, file} -> {[file | s], m, u}
            {:modified, file} -> {s, [file | m], u}
            {:untracked, file} -> {s, m, [file | u]}
            :skip -> {s, m, u}
          end
        end)

      %{
        branch: branch,
        is_clean: Enum.empty?(staged) and Enum.empty?(modified) and Enum.empty?(untracked),
        staged: Enum.reverse(staged),
        modified: Enum.reverse(modified),
        untracked: Enum.reverse(untracked),
        ahead: ahead,
        behind: behind
      }
    end

    defp parse_tracking_info(line) do
      ahead =
        case Regex.run(~r/ahead (\d+)/, line) do
          [_, n] -> String.to_integer(n)
          nil -> 0
        end

      behind =
        case Regex.run(~r/behind (\d+)/, line) do
          [_, n] -> String.to_integer(n)
          nil -> 0
        end

      {ahead, behind}
    end

    defp parse_status_line(line) when byte_size(line) >= 3 do
      index = String.at(line, 0)
      worktree = String.at(line, 1)
      file = String.slice(line, 3..-1//1) |> String.trim()

      cond do
        worktree == "?" -> {:untracked, file}
        index in ["A", "M", "D", "R", "C"] and worktree == " " -> {:staged, file}
        worktree in ["M", "D"] -> {:modified, file}
        index in ["A", "M", "D", "R", "C"] -> {:staged, file}
        true -> :skip
      end
    end

    defp parse_status_line(_), do: :skip
  end

  defmodule Diff do
    @moduledoc """
    Show changes between commits, commit and working tree, etc.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `staged` | boolean | no | Show staged changes (default: false) |
    | `ref` | string | no | Compare against specific ref |
    | `file` | string | no | Show diff for specific file |
    | `stat_only` | boolean | no | Show diffstat only (default: false) |

    ## Returns

    - `path` - Repository path
    - `diff` - The diff output
    - `files_changed` - Number of files changed (if stat_only)
    - `insertions` - Lines added (if stat_only)
    - `deletions` - Lines removed (if stat_only)
    """

    use Jido.Action,
      name: "git_diff",
      description: "Show changes in a Git repository",
      category: "git",
      tags: ["git", "diff", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ],
        staged: [
          type: :boolean,
          default: false,
          doc: "Show staged (cached) changes"
        ],
        ref: [
          type: :string,
          doc: "Compare against specific ref (commit, branch, tag)"
        ],
        file: [
          type: :string,
          doc: "Show diff for specific file only"
        ],
        stat_only: [
          type: :boolean,
          default: false,
          doc: "Show diffstat summary only"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      args = build_diff_args(params)

      case git_command(path, ["diff" | args]) do
        {:ok, result} ->
          output = %{
            path: path,
            diff: result.stdout
          }

          output =
            if params[:stat_only] do
              Map.merge(output, parse_stat(result.stdout))
            else
              output
            end

          Actions.emit_completed(__MODULE__, %{path: path})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get git diff: #{reason}"}
      end
    end

    defp build_diff_args(params) do
      args = []
      args = if params[:staged], do: ["--cached" | args], else: args
      args = if params[:stat_only], do: ["--stat" | args], else: args
      args = if params[:ref], do: args ++ [params[:ref]], else: args
      args = if params[:file], do: args ++ ["--", params[:file]], else: args
      args
    end

    defp git_command(path, args) do
      command = Enum.join(["git" | args], " ")

      case Shell.execute(command,
             cwd: path,
             timeout: Arbor.Actions.Git.git_timeout(),
             sandbox: Arbor.Actions.Git.git_sandbox()
           ) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr}} ->
          {:error, String.trim(stderr)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end

    defp parse_stat(output) do
      # Parse the summary line like "3 files changed, 10 insertions(+), 5 deletions(-)"
      case Regex.run(
             ~r/(\d+) files? changed(?:, (\d+) insertions?\(\+\))?(?:, (\d+) deletions?\(-\))?/,
             output
           ) do
        [_, files, insertions, deletions] ->
          %{
            files_changed: String.to_integer(files),
            insertions: parse_int_or_zero(insertions),
            deletions: parse_int_or_zero(deletions)
          }

        [_, files, insertions] ->
          %{
            files_changed: String.to_integer(files),
            insertions: parse_int_or_zero(insertions),
            deletions: 0
          }

        [_, files] ->
          %{
            files_changed: String.to_integer(files),
            insertions: 0,
            deletions: 0
          }

        nil ->
          %{files_changed: 0, insertions: 0, deletions: 0}
      end
    end

    defp parse_int_or_zero(nil), do: 0
    defp parse_int_or_zero(""), do: 0
    defp parse_int_or_zero(s), do: String.to_integer(s)
  end

  defmodule Commit do
    @moduledoc """
    Create a new commit.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `message` | string | yes | Commit message |
    | `files` | list | no | Files to stage before commit |
    | `all` | boolean | no | Stage all modified files (default: false) |
    | `allow_empty` | boolean | no | Allow empty commits (default: false) |

    ## Returns

    - `path` - Repository path
    - `commit_hash` - The new commit hash
    - `message` - Commit message
    - `files_committed` - Number of files in commit
    """

    use Jido.Action,
      name: "git_commit",
      description: "Create a new Git commit",
      category: "git",
      tags: ["git", "commit", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ],
        message: [
          type: :string,
          required: true,
          doc: "Commit message"
        ],
        files: [
          type: {:list, :string},
          doc: "Files to stage before commit"
        ],
        all: [
          type: :boolean,
          default: false,
          doc: "Stage all modified and deleted files"
        ],
        allow_empty: [
          type: :boolean,
          default: false,
          doc: "Allow creating empty commits"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, message: message} = params, _context) do
      Actions.emit_started(__MODULE__, %{path: path, message: message})

      # Stage files if specified
      with :ok <- maybe_stage_files(path, params),
           {:ok, commit_result} <- create_commit(path, message, params),
           {:ok, hash} <- get_commit_hash(path) do
        result = %{
          path: path,
          commit_hash: hash,
          message: message,
          output: commit_result.stdout
        }

        Actions.emit_completed(__MODULE__, %{path: path, commit_hash: hash})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to create commit: #{reason}"}
      end
    end

    defp maybe_stage_files(path, %{files: files}) when is_list(files) and files != [] do
      case git_command(path, ["add" | files]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_stage_files(path, %{all: true}) do
      case git_command(path, ["add", "-A"]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_stage_files(_path, _params), do: :ok

    defp create_commit(path, message, params) do
      args = ["commit", "-m", message]
      args = if params[:allow_empty], do: args ++ ["--allow-empty"], else: args
      git_command(path, args)
    end

    defp get_commit_hash(path) do
      case git_command(path, ["rev-parse", "HEAD"]) do
        {:ok, result} -> {:ok, String.trim(result.stdout)}
        error -> error
      end
    end

    defp git_command(path, args) do
      # For commit messages with special characters, we need careful escaping
      command =
        args
        |> Enum.map(&escape_shell_arg/1)
        |> then(&["git" | &1])
        |> Enum.join(" ")

      case Shell.execute(command,
             cwd: path,
             timeout: Arbor.Actions.Git.git_timeout(),
             sandbox: Arbor.Actions.Git.git_sandbox()
           ) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr, stdout: stdout}} ->
          error = if stderr != "", do: stderr, else: stdout
          {:error, String.trim(error)}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end

    defp escape_shell_arg(arg) do
      if String.contains?(arg, [" ", "'", "\"", "\n", "$", "`", "\\"]) do
        # Use single quotes and escape any existing single quotes
        escaped = String.replace(arg, "'", "'\\''")
        "'#{escaped}'"
      else
        arg
      end
    end
  end

  defmodule Log do
    @moduledoc """
    Show commit history.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `limit` | integer | no | Maximum number of commits (default: 10) |
    | `ref` | string | no | Starting ref (branch, tag, commit) |
    | `oneline` | boolean | no | One line per commit (default: false) |
    | `file` | string | no | Show history for specific file |

    ## Returns

    - `path` - Repository path
    - `commits` - List of commit objects with hash, author, date, message
    - `count` - Number of commits returned
    """

    use Jido.Action,
      name: "git_log",
      description: "Show Git commit history",
      category: "git",
      tags: ["git", "log", "history", "vcs"],
      schema: [
        path: [
          type: :string,
          required: true,
          doc: "Path to the Git repository"
        ],
        limit: [
          type: :non_neg_integer,
          default: 10,
          doc: "Maximum number of commits to show"
        ],
        ref: [
          type: :string,
          doc: "Starting ref (branch, tag, commit)"
        ],
        oneline: [
          type: :boolean,
          default: false,
          doc: "Show one line per commit"
        ],
        file: [
          type: :string,
          doc: "Show history for specific file"
        ]
      ]

    alias Arbor.Actions

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      args = build_log_args(params)

      case git_command(path, ["log" | args]) do
        {:ok, result} ->
          commits =
            if params[:oneline] do
              parse_oneline_log(result.stdout)
            else
              parse_log(result.stdout)
            end

          output = %{
            path: path,
            commits: commits,
            count: length(commits)
          }

          Actions.emit_completed(__MODULE__, %{path: path, count: length(commits)})
          {:ok, output}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to get git log: #{reason}"}
      end
    end

    defp build_log_args(params) do
      args = ["-n", to_string(params[:limit] || 10)]

      args =
        if params[:oneline] do
          ["--oneline" | args]
        else
          ["--format=%H%n%an%n%ae%n%aI%n%s%n%b%n---COMMIT_END---" | args]
        end

      args = if params[:ref], do: args ++ [params[:ref]], else: args
      args = if params[:file], do: args ++ ["--", params[:file]], else: args
      args
    end

    defp git_command(path, args) do
      command = Enum.join(["git" | args], " ")

      case Shell.execute(command,
             cwd: path,
             timeout: Arbor.Actions.Git.git_timeout(),
             sandbox: Arbor.Actions.Git.git_sandbox()
           ) do
        {:ok, %{exit_code: 0} = result} ->
          {:ok, result}

        {:ok, %{stderr: stderr}} when stderr != "" ->
          {:error, String.trim(stderr)}

        {:ok, result} ->
          # Empty log is okay
          {:ok, result}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end

    defp parse_oneline_log(output) do
      output
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        case String.split(line, " ", parts: 2) do
          [hash, message] -> %{hash: hash, message: message}
          [hash] -> %{hash: hash, message: ""}
        end
      end)
    end

    defp parse_log(output) do
      output
      |> String.split("---COMMIT_END---", trim: true)
      |> Enum.map(&parse_commit_block/1)
      |> Enum.reject(&is_nil/1)
    end

    defp parse_commit_block(block) do
      lines = String.split(block, "\n", trim: true)

      case lines do
        [hash, author, email, date, subject | body_lines] ->
          %{
            hash: hash,
            author: author,
            email: email,
            date: date,
            subject: subject,
            body: Enum.join(body_lines, "\n") |> String.trim()
          }

        _ ->
          nil
      end
    end
  end
end
