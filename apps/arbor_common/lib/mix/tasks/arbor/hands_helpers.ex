defmodule Mix.Tasks.Arbor.HandsHelpers do
  @moduledoc """
  Shared helpers for Arbor Hands management.

  Hands are independent Claude Code sessions spawned to do focused work.
  They can be local (tmux) or sandboxed (Docker).
  """

  @tmux_prefix "arbor-hand-"
  @docker_prefix "claude-hand-"

  def tmux_prefix, do: @tmux_prefix
  def docker_prefix, do: @docker_prefix

  def config_dir do
    cfg = Application.get_env(:arbor_common, :hands, [])
    Path.expand(cfg[:config_dir] || "~/.claude-hands")
  end

  def sandbox_image do
    cfg = Application.get_env(:arbor_common, :hands, [])
    cfg[:sandbox_image] || "claude-sandbox"
  end

  def sandbox_credentials_volume do
    cfg = Application.get_env(:arbor_common, :hands, [])
    cfg[:sandbox_credentials_volume] || "claude-sandbox-credentials"
  end

  def hands_dir, do: Path.join(File.cwd!(), ".arbor/hands")

  def hand_dir(name), do: Path.join(hands_dir(), name)

  def tmux_session_name(name), do: @tmux_prefix <> name

  def docker_container_name(name), do: @docker_prefix <> name

  def ensure_hand_dir(name) do
    dir = hand_dir(name)
    File.mkdir_p!(dir)
    dir
  end

  @doc "Find a hand by name. Returns {:local, info} | {:sandbox, info} | :not_found"
  def find_hand(name) do
    tmux_name = tmux_session_name(name)
    docker_name = docker_container_name(name)

    cond do
      tmux_session_exists?(tmux_name) ->
        {:local, %{name: name, session: tmux_name}}

      docker_container_running?(docker_name) ->
        {:sandbox, %{name: name, container: docker_name}}

      true ->
        :not_found
    end
  end

  def tmux_session_exists?(session_name) do
    case System.cmd("tmux", ["has-session", "-t", session_name], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  def docker_container_running?(container_name) do
    case System.cmd(
           "docker",
           [
             "ps",
             "--filter",
             "name=^#{container_name}$",
             "--format",
             "{{.Names}}"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) == container_name
      _ -> false
    end
  end

  def list_all, do: list_local() ++ list_docker()

  def list_local do
    case System.cmd("tmux", ["list-sessions", "-F", "\#{session_name}"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, @tmux_prefix))
        |> Enum.map(fn session ->
          name = String.replace_prefix(session, @tmux_prefix, "")
          %{name: name, type: :local, session: session}
        end)

      _ ->
        []
    end
  end

  def list_docker do
    case System.cmd(
           "docker",
           [
             "ps",
             "--filter",
             "name=#{@docker_prefix}",
             "--format",
             "{{.Names}}\t{{.Status}}"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&(&1 != ""))
        |> Enum.map(&parse_docker_line/1)

      _ ->
        []
    end
  end

  defp parse_docker_line(line) do
    case String.split(line, "\t", parts: 2) do
      [container, status] ->
        name = String.replace_prefix(container, @docker_prefix, "")
        %{name: name, type: :sandbox, container: container, status: status}

      [container] ->
        name = String.replace_prefix(container, @docker_prefix, "")
        %{name: name, type: :sandbox, container: container, status: "running"}
    end
  end

  # --- Worktree helpers ---

  @doc "Path to the worktree directory for a hand"
  def worktree_path(name), do: Path.join(hand_dir(name), "worktree")

  @doc "Branch name for a hand's worktree"
  def worktree_branch(name), do: "hand/#{name}"

  @doc "Check if a worktree exists for a hand"
  def has_worktree?(name), do: File.dir?(worktree_path(name))

  @doc "Create a git worktree for a hand. Returns {:ok, path} | {:error, reason}"
  def create_worktree(name) do
    wt_path = worktree_path(name)
    branch = worktree_branch(name)

    # Check if branch already exists
    case System.cmd("git", ["rev-parse", "--verify", branch], stderr_to_stdout: true) do
      {_, 0} ->
        {:error,
         "Branch '#{branch}' already exists. Run `mix arbor.hands.cleanup #{name}` first or use a different name."}

      _ ->
        # Check if worktree path already exists
        if File.dir?(wt_path) do
          {:error,
           "Worktree path already exists: #{wt_path}. Run `mix arbor.hands.cleanup #{name}` first."}
        else
          case System.cmd("git", ["worktree", "add", wt_path, "-b", branch],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              symlink_path_deps(name)
              {:ok, wt_path}

            {output, _} ->
              {:error, "Failed to create worktree: #{String.trim(output)}"}
          end
        end
    end
  end

  @doc """
  Symlink path dependencies so the worktree can resolve them.

  Umbrella projects may have path deps like `{:jido, path: "../jido"}`.
  From the worktree at `.arbor/hands/<name>/worktree/`, `../jido` resolves
  to `.arbor/hands/<name>/jido` — which doesn't exist. This function creates
  symlinks so those paths resolve to the actual dependency directories.
  """
  def symlink_path_deps(name) do
    project_root = File.cwd!()
    wt_path = worktree_path(name)

    for {_dep, rel_path} <- extract_path_deps(project_root) do
      # Where the dep actually lives (resolved from project root)
      actual_path = Path.expand(rel_path, project_root)

      # Where the worktree's mix.exs will look for it (resolved from worktree)
      expected_path = Path.expand(rel_path, wt_path)

      # Only create symlink if:
      # - the actual dep exists
      # - the expected path doesn't already exist (not inside the worktree)
      if File.dir?(actual_path) and not File.exists?(expected_path) do
        # Ensure the parent directory exists (for nested paths like ../../foo/bar)
        expected_path |> Path.dirname() |> File.mkdir_p!()
        File.ln_s!(actual_path, expected_path)
      end
    end

    :ok
  end

  defp extract_path_deps(project_root) do
    mix_exs = Path.join(project_root, "mix.exs")

    case File.read(mix_exs) do
      {:ok, content} ->
        Regex.scan(~r/\{:\w+,\s*path:\s*"([^"]+)"/, content)
        |> Enum.map(fn [_full, path] -> {Path.basename(path), path} end)
        |> Enum.uniq_by(fn {dep_name, _} -> dep_name end)

      _ ->
        []
    end
  end

  @doc "Remove a git worktree for a hand. Returns :ok | {:error, reason}"
  def remove_worktree(name) do
    wt_path = worktree_path(name)

    if File.dir?(wt_path) do
      case System.cmd("git", ["worktree", "remove", wt_path, "--force"], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {output, _} -> {:error, "Failed to remove worktree: #{String.trim(output)}"}
      end
    else
      :ok
    end
  end

  @doc "Get the commit count ahead of main for a hand's branch"
  def worktree_ahead_count(name) do
    branch = worktree_branch(name)

    case System.cmd("git", ["rev-list", "--count", "main..#{branch}"], stderr_to_stdout: true) do
      {count, 0} -> {:ok, String.trim(count) |> String.to_integer()}
      _ -> {:error, :unknown}
    end
  end

  @doc "Check if a hand's branch has been merged to main"
  def worktree_branch_merged?(name) do
    branch = worktree_branch(name)

    case System.cmd("git", ["branch", "--merged", "main"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(fn line -> String.trim(line) == branch end)

      _ ->
        false
    end
  end

  @doc "Delete a hand's branch. Returns :ok | {:error, reason}"
  def delete_worktree_branch(name, opts \\ []) do
    branch = worktree_branch(name)
    flag = if opts[:force], do: "-D", else: "-d"

    case System.cmd("git", ["branch", flag, branch], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> {:error, "Failed to delete branch: #{String.trim(output)}"}
    end
  end

  @doc "Build the full prompt with Hand instructions prepended"
  def build_prompt(name, task, opts \\ []) do
    worktree_section =
      if opts[:worktree] do
        branch = worktree_branch(name)

        """

        ## Git Worktree

        You are working in a git worktree on branch `#{branch}`.
        Commit your changes to this branch when you're done.
        The Mind will review and merge your work into main.

        IMPORTANT: All file operations and commands (compile, test, format) MUST
        happen within this worktree directory. NEVER copy files to or run commands
        in the main working tree. The worktree has symlinked path dependencies so
        compilation should work directly here.
        """
      else
        ""
      end

    """
    You are a Hand — a focused coding agent spawned to do independent work.

    ## Your Task

    #{task}

    ## When You Finish

    Write a summary of what you accomplished to: .arbor/hands/#{name}/summary.md

    Include:
    - What you changed (files modified/created)
    - Key decisions you made
    - Any issues or open questions for review
    - Test results if applicable

    ## Guidelines

    - Stay focused on your task
    - Run tests relevant to your changes
    - If you get stuck, write your current status to the summary file
    #{worktree_section}\
    """
  end

  @doc "Check if a summary file exists for a hand"
  def summary_exists?(name) do
    name |> hand_dir() |> Path.join("summary.md") |> File.exists?()
  end

  @doc "Read the summary file for a hand"
  def read_summary(name) do
    path = name |> hand_dir() |> Path.join("summary.md")

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :no_summary}
      {:error, reason} -> {:error, reason}
    end
  end
end
