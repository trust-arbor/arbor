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
  | `Branch` | Create / switch / list branches |
  | `PR` | Open a draft pull request / merge request through the configured SCM |

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
    alias Arbor.Actions.Git

    def taint_roles do
      %{path: {:control, requires: [:path_traversal]}}
    end

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
             timeout: Git.git_timeout(),
             sandbox: Git.git_sandbox()
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
    alias Arbor.Actions.Git

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        ref: {:control, requires: [:command_injection]},
        file: {:control, requires: [:path_traversal]},
        staged: :control,
        stat_only: :control
      }
    end

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
             timeout: Git.git_timeout(),
             sandbox: Git.git_sandbox()
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
    alias Arbor.Actions.Git
    alias Arbor.Common.ShellEscape

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        message: {:control, requires: [:command_injection]},
        files: {:control, requires: [:path_traversal]},
        all: :control,
        allow_empty: :control
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, message: message} = params, _context) do
      Actions.emit_started(__MODULE__, %{path: path, message: message})

      # Stage files if specified
      with {:ok, message} <- normalize_message(message),
           :ok <- maybe_stage_files(path, params),
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

    defp normalize_message(message) when is_binary(message) do
      message =
        message
        |> sanitize_message_for_basic_shell()
        |> String.trim()

      if message == "", do: {:error, "commit message is required"}, else: {:ok, message}
    end

    defp normalize_message(nil), do: {:error, "commit message is required"}
    defp normalize_message(message), do: normalize_message(to_string(message))

    defp sanitize_message_for_basic_shell(message) do
      message
      |> String.replace("$(", "(")
      |> String.replace("&&", " and ")
      |> String.replace("||", " or ")
      |> String.replace(~r/[;|`<>\r\n]/, " ")
      |> String.replace(~r/\s+/, " ")
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
        |> Enum.map(&ShellEscape.escape_arg/1)
        |> then(&["git" | &1])
        |> Enum.join(" ")

      case Shell.execute(command,
             cwd: path,
             timeout: Git.git_timeout(),
             sandbox: Git.git_sandbox()
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
    alias Arbor.Actions.Git

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        ref: {:control, requires: [:command_injection]},
        file: {:control, requires: [:path_traversal]},
        limit: :data,
        oneline: :control
      }
    end

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
             timeout: Git.git_timeout(),
             sandbox: Git.git_sandbox()
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

  defmodule Branch do
    @moduledoc """
    Create, switch, or list branches.

    ## Parameters

    | Name | Type | Required | Description |
    |------|------|----------|-------------|
    | `path` | string | yes | Path to the Git repository |
    | `mode` | atom | yes | `:create`, `:switch`, or `:list` |
    | `name` | string | conditional | Branch name (required for `:create` / `:switch`) |
    | `from` | string | no | Base ref for `:create` (default: current HEAD) |

    ## Returns

    - `path` — repository path
    - `mode` — operation performed
    - `branch` — branch name (for `:create` / `:switch`)
    - `branches` — list of branch names (for `:list`)
    - `current` — current branch name (for `:list`)
    """

    use Jido.Action,
      name: "git_branch",
      description: "Create, switch, or list Git branches",
      category: "git",
      tags: ["git", "branch", "vcs"],
      schema: [
        path: [type: :string, required: true, doc: "Path to the Git repository"],
        mode: [
          type: {:in, [:create, :switch, :list]},
          required: true,
          doc: "Operation: :create, :switch, or :list"
        ],
        name: [type: :string, doc: "Branch name (for :create / :switch)"],
        from: [type: :string, doc: "Base ref for :create (default: HEAD)"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Git
    alias Arbor.Common.ShellEscape

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        mode: :control,
        name: {:control, requires: [:command_injection]},
        from: {:control, requires: [:command_injection]}
      }
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, mode: :list} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      with {:ok, branches_result} <- git_command(path, ["branch", "--list"]),
           {:ok, current_result} <- git_command(path, ["branch", "--show-current"]) do
        branches =
          branches_result.stdout
          |> String.split("\n", trim: true)
          |> Enum.map(&(String.trim_leading(&1, "* ") |> String.trim()))
          |> Enum.reject(&(&1 == ""))

        result = %{
          path: path,
          mode: :list,
          branches: branches,
          current: String.trim(current_result.stdout)
        }

        Actions.emit_completed(__MODULE__, %{path: path, count: length(branches)})
        {:ok, result}
      else
        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to list branches: #{reason}"}
      end
    end

    def run(%{path: path, mode: :create, name: name} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      args = ["checkout", "-b", name]
      args = if params[:from], do: args ++ [params[:from]], else: args

      case git_command(path, args) do
        {:ok, _result} ->
          result = %{path: path, mode: :create, branch: name}
          Actions.emit_completed(__MODULE__, %{path: path, branch: name})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to create branch '#{name}': #{reason}"}
      end
    end

    def run(%{path: path, mode: :switch, name: name} = params, _context) do
      Actions.emit_started(__MODULE__, params)

      case git_command(path, ["checkout", name]) do
        {:ok, _result} ->
          result = %{path: path, mode: :switch, branch: name}
          Actions.emit_completed(__MODULE__, %{path: path, branch: name})
          {:ok, result}

        {:error, reason} ->
          Actions.emit_failed(__MODULE__, reason)
          {:error, "Failed to switch to branch '#{name}': #{reason}"}
      end
    end

    def run(%{mode: mode}, _context) when mode in [:create, :switch] do
      {:error, "Branch mode :#{mode} requires a 'name' parameter"}
    end

    defp git_command(path, args) do
      command =
        args
        |> Enum.map(&ShellEscape.escape_arg/1)
        |> then(&["git" | &1])
        |> Enum.join(" ")

      case Arbor.Shell.execute(command,
             cwd: path,
             timeout: Git.git_timeout(),
             sandbox: Git.git_sandbox()
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
  end

  defmodule PR do
    @moduledoc """
    Open a draft pull request or merge request through the configured SCM.

    This is intentionally one platform-agnostic action. The caller supplies the
    review content and branch names; provider, endpoint, and token are resolved
    from action config or the selected git remote.
    """

    use Jido.Action,
      name: "git_pr",
      description: "Open a draft pull request or merge request through the configured SCM",
      category: "git",
      tags: ["git", "pr", "mr", "vcs"],
      schema: [
        path: [type: :string, required: true, doc: "Path to the Git repository"],
        head: [type: :string, doc: "Source branch name"],
        branch: [type: :string, doc: "Source branch name alias"],
        base: [type: :string, default: "main", doc: "Target branch name"],
        title: [type: :string, required: true, doc: "PR/MR title"],
        body: [type: :string, doc: "PR/MR body"],
        draft: [type: :boolean, default: true, doc: "Open as draft"],
        owner: [type: :string, doc: "Repository owner/group override"],
        repo: [type: :string, doc: "Repository name override"],
        remote: [type: :string, default: "origin", doc: "Git remote to derive owner/repo from"],
        provider: [type: {:in, [:github, :gitlab, :gitea]}, doc: "SCM provider override"],
        scm_base_url: [type: :string, doc: "SCM API base URL override"],
        project_id: [type: :string, doc: "GitLab project id/path override"]
      ]

    alias Arbor.Actions
    alias Arbor.Actions.Config
    alias Arbor.Common.{EgressClassifier, SensitiveData}

    def taint_roles do
      %{
        path: {:control, requires: [:path_traversal]},
        head: {:control, requires: [:command_injection]},
        branch: {:control, requires: [:command_injection]},
        base: {:control, requires: [:command_injection]},
        title: {:control, requires: [:command_injection]},
        body: {:control, requires: [:command_injection]},
        draft: :control,
        owner: {:control, requires: [:command_injection]},
        repo: {:control, requires: [:command_injection]},
        remote: {:control, requires: [:command_injection]},
        provider: :control,
        scm_base_url: {:control, requires: [:ssrf]},
        project_id: {:control, requires: [:command_injection]}
      }
    end

    def effect_class, do: :network_egress

    def egress_tier(params, context) do
      case resolved_base_url(params, context) do
        {:ok, base_url} ->
          case EgressClassifier.locality(base_url) do
            :on_host -> :on_host
            :on_premises -> :on_premises
            :public -> :external_peer
          end

        {:error, _reason} ->
          :external_provider
      end
    end

    def egress_destination(params, context) do
      with {:ok, base_url} <- resolved_base_url(params, context),
           %URI{host: host} when is_binary(host) <- URI.parse(base_url) do
        host
      else
        _ -> nil
      end
    end

    @impl true
    @spec run(map(), map()) :: {:ok, map()} | {:error, String.t()}
    def run(%{path: path, title: title} = params, context) do
      Actions.emit_started(__MODULE__, %{
        path: path,
        title: title,
        remote: Config.get(params, :remote, "origin")
      })

      remote_result = remote_info(params)
      remote_hint = remote_hint(remote_result)

      with {:ok, provider} <- Config.scm_provider(params, context, remote_hint),
           {:ok, base_url} <- Config.scm_base_url(provider, params, context, remote_hint),
           {:ok, token} <- Config.scm_token(provider, params, context),
           {:ok, head} <- resolve_head(path, params),
           {:ok, {owner, repo}} <- resolve_owner_repo(params, remote_result),
           {:ok, request} <-
             build_request(provider, base_url, owner, repo, head, params),
           {:ok, response} <- post_request(request, provider, token, context),
           {:ok, result} <- normalize_response(provider, response, params) do
        completed = Map.merge(result, %{provider: provider, owner: owner, repo: repo, head: head})
        Actions.emit_completed(__MODULE__, Map.drop(completed, [:body]))
        {:ok, completed}
      else
        {:error, reason} ->
          safe_reason = redact(reason, nil)
          Actions.emit_failed(__MODULE__, safe_reason)
          {:error, safe_reason}
      end
    end

    def run(_params, _context), do: {:error, "path and title are required"}

    defp resolved_base_url(params, context) do
      remote_result = remote_info(params)
      remote_hint = remote_hint(remote_result)

      with {:ok, provider} <- Config.scm_provider(params, context, remote_hint) do
        Config.scm_base_url(provider, params, context, remote_hint)
      end
    end

    defp remote_hint({:ok, remote}), do: remote
    defp remote_hint({:error, _reason}), do: nil

    defp remote_info(params) do
      path = Config.get(params, :path)
      remote = Config.get(params, :remote, "origin")

      case System.cmd("git", ["-C", path, "remote", "get-url", remote], stderr_to_stdout: true) do
        {output, 0} ->
          parse_remote_url(String.trim(output), remote)

        {output, _code} ->
          {:error, "failed to read git remote #{inspect(remote)}: #{String.trim(output)}"}
      end
    end

    defp parse_remote_url(url, remote) do
      parsed =
        if String.contains?(url, "://") do
          parse_uri_remote(url)
        else
          parse_scp_remote(url)
        end

      case parsed do
        {:ok, info} -> {:ok, Map.merge(info, %{remote: remote, url: url})}
        {:error, reason} -> {:error, reason}
      end
    end

    defp parse_uri_remote(url) do
      case URI.parse(url) do
        %URI{scheme: scheme, host: host, path: path, port: port}
        when is_binary(scheme) and is_binary(host) and is_binary(path) ->
          with {:ok, owner, repo} <- owner_repo_from_path(path) do
            {:ok,
             %{scheme: scheme, host: String.downcase(host), port: port, owner: owner, repo: repo}}
          end

        _ ->
          {:error, "unsupported git remote URL: #{url}"}
      end
    end

    defp parse_scp_remote(url) do
      case Regex.run(~r/^(?:[^@]+@)?([^:\/]+):(.+)$/, url) do
        [_, host, path] ->
          with {:ok, owner, repo} <- owner_repo_from_path(path) do
            {:ok,
             %{scheme: nil, host: String.downcase(host), port: nil, owner: owner, repo: repo}}
          end

        _ ->
          {:error, "unsupported git remote URL: #{url}"}
      end
    end

    defp owner_repo_from_path(path) do
      parts =
        path
        |> String.trim_leading("/")
        |> String.trim_trailing(".git")
        |> String.split("/", trim: true)

      case parts do
        [_repo] ->
          {:error, "git remote URL does not include an owner/group"}

        parts when length(parts) >= 2 ->
          {owner_parts, [repo]} = Enum.split(parts, -1)
          {:ok, Enum.join(owner_parts, "/"), repo}

        _ ->
          {:error, "git remote URL does not include a repository path"}
      end
    end

    defp resolve_owner_repo(params, remote_result) do
      owner = Config.get(params, :owner)
      repo = Config.get(params, :repo)

      cond do
        is_binary(owner) and owner != "" and is_binary(repo) and repo != "" ->
          {:ok, {owner, repo}}

        match?({:ok, _}, remote_result) ->
          {:ok, remote} = remote_result
          {:ok, {remote.owner, remote.repo}}

        true ->
          remote_result
      end
    end

    defp resolve_head(_path, params) do
      case Config.get(params, :head) || Config.get(params, :branch) do
        value when is_binary(value) and value != "" ->
          {:ok, value}

        _ ->
          current_branch(Config.get(params, :path))
      end
    end

    defp current_branch(path) do
      case System.cmd("git", ["-C", path, "branch", "--show-current"], stderr_to_stdout: true) do
        {output, 0} ->
          case String.trim(output) do
            "" -> {:error, "head/branch is required when the repo is detached"}
            branch -> {:ok, branch}
          end

        {output, _code} ->
          {:error, "failed to resolve current git branch: #{String.trim(output)}"}
      end
    end

    defp build_request(:github, base_url, owner, repo, head, params) do
      body = %{
        "head" => head,
        "base" => base_branch(params),
        "title" => Config.get(params, :title),
        "body" => Config.get(params, :body, ""),
        "draft" => draft?(params)
      }

      {:ok,
       %{url: "#{base_url}/repos/#{path_segment(owner)}/#{path_segment(repo)}/pulls", body: body}}
    end

    defp build_request(:gitea, base_url, owner, repo, head, params) do
      body = %{
        "head" => head,
        "base" => base_branch(params),
        "title" => Config.get(params, :title),
        "body" => Config.get(params, :body, ""),
        "draft" => draft?(params)
      }

      {:ok,
       %{
         url: "#{base_url}/api/v1/repos/#{path_segment(owner)}/#{path_segment(repo)}/pulls",
         body: body
       }}
    end

    defp build_request(:gitlab, base_url, owner, repo, head, params) do
      project_id = Config.get(params, :project_id) || "#{owner}/#{repo}"
      title = draft_title(Config.get(params, :title), draft?(params))

      body = %{
        "source_branch" => head,
        "target_branch" => base_branch(params),
        "title" => title,
        "description" => Config.get(params, :body, "")
      }

      {:ok,
       %{
         url: "#{base_url}/api/v4/projects/#{URI.encode_www_form(project_id)}/merge_requests",
         body: body
       }}
    end

    defp post_request(%{url: url, body: body}, provider, token, context) do
      opts = [
        json: body,
        headers: headers(provider, token),
        receive_timeout: 60_000,
        retry: false
      ]

      case http_post(url, opts, context) do
        {:ok, %{status: status, body: response_body}} when status in 200..299 ->
          {:ok, response_body}

        {:ok, %{status: status, body: response_body}} ->
          safe_body =
            response_body
            |> inspect()
            |> SensitiveData.redact()
            |> redact(token)

          {:error, "SCM PR request failed: HTTP #{status}: #{safe_body}"}

        {:error, reason} ->
          {:error, "SCM PR request failed: #{redact(inspect(reason), token)}"}
      end
    end

    defp http_post(url, opts, context) do
      case Config.get(context, :http_request) do
        request when is_function(request, 3) -> request.(:post, url, opts)
        request when is_function(request, 2) -> request.(url, opts)
        _ -> Req.post(url, opts)
      end
    end

    defp normalize_response(provider, body, params) when is_map(body) do
      number =
        body["number"] || body[:number] || body["iid"] || body[:iid] || body["id"] || body[:id]

      url =
        body["html_url"] || body[:html_url] || body["web_url"] || body[:web_url] || body["url"] ||
          body[:url]

      if is_binary(url) and url != "" do
        {:ok,
         %{
           number: number,
           url: url,
           title: Config.get(params, :title),
           draft?: draft?(params),
           kind: if(provider == :gitlab, do: "merge_request", else: "pull_request")
         }}
      else
        {:error, "SCM PR response did not include a URL"}
      end
    end

    defp normalize_response(_provider, body, _params) do
      {:error, "SCM PR response was not a JSON object: #{inspect(body)}"}
    end

    defp headers(:github, token) do
      [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"content-type", "application/json"}
      ]
    end

    defp headers(:gitlab, token) do
      [
        {"private-token", token},
        {"accept", "application/json"},
        {"content-type", "application/json"}
      ]
    end

    defp headers(:gitea, token) do
      [
        {"authorization", "token #{token}"},
        {"accept", "application/json"},
        {"content-type", "application/json"}
      ]
    end

    defp base_branch(params), do: Config.get(params, :base, "main")
    defp draft?(params), do: Config.get(params, :draft, true) != false

    defp draft_title(title, true) do
      if String.starts_with?(title, "Draft:"), do: title, else: "Draft: #{title}"
    end

    defp draft_title(title, false), do: title

    defp path_segment(value) do
      value
      |> to_string()
      |> String.split("/", trim: true)
      |> Enum.map_join("/", &URI.encode/1)
    end

    defp redact(text, secret) do
      text
      |> SensitiveData.redact()
      |> Config.redact_secret(secret)
    end
  end
end
