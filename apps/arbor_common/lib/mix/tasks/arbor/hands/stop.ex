defmodule Mix.Tasks.Arbor.Hands.Stop do
  @shortdoc "Stop a running Hand"
  @moduledoc """
  Stops a running Hand session.

      $ mix arbor.hands.stop test-writer
      $ mix arbor.hands.stop refactor --force

  Sends `/exit` to Claude first for graceful shutdown, then kills the
  tmux session or Docker container.

  ## Options

    * `--force` - Skip graceful shutdown, kill immediately
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [force: :boolean]
      )

    name = List.first(positional)

    unless name do
      Mix.shell().error("Usage: mix arbor.hands.stop <name> [--force]")
      exit({:shutdown, 1})
    end

    case Hands.find_hand(name) do
      {:local, %{session: session}} ->
        stop_local(name, session, opts[:force])

      {:sandbox, %{container: container}} ->
        stop_sandbox(name, container, opts[:force])

      :not_found ->
        Mix.shell().info("Hand '#{name}' is not running.")
    end
  end

  defp stop_local(name, session, force) do
    unless force do
      Mix.shell().info("Sending /exit to hand '#{name}'...")

      System.cmd("tmux", ["send-keys", "-t", session, "/exit", "Enter"], stderr_to_stdout: true)

      Process.sleep(3_000)
    end

    {_, _} = System.cmd("tmux", ["kill-session", "-t", session], stderr_to_stdout: true)
    Mix.shell().info("Hand '#{name}' stopped.")

    if Hands.summary_exists?(name) do
      Mix.shell().info("Summary available: .arbor/hands/#{name}/summary.md")
    end
  end

  defp stop_sandbox(name, container, force) do
    unless force do
      Mix.shell().info("Sending /exit to hand '#{name}'...")

      System.cmd(
        "docker",
        [
          "exec",
          container,
          "tmux",
          "send-keys",
          "-t",
          "claude",
          "/exit",
          "Enter"
        ], stderr_to_stdout: true)

      Process.sleep(3_000)
    end

    {_, _} = System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
    Mix.shell().info("Hand '#{name}' stopped (container removed).")

    if Hands.summary_exists?(name) do
      Mix.shell().info("Summary available: .arbor/hands/#{name}/summary.md")
    end
  end
end
