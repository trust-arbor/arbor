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
           ], stderr_to_stdout: true) do
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

  @doc "Build the full prompt with Hand instructions prepended"
  def build_prompt(name, task) do
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
