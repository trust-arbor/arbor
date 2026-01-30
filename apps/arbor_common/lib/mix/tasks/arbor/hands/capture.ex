defmodule Mix.Tasks.Arbor.Hands.Capture do
  @shortdoc "Capture recent output from a Hand"
  @moduledoc """
  Captures recent terminal output from a running Hand.

      $ mix arbor.hands.capture test-writer
      $ mix arbor.hands.capture test-writer --lines 100
      $ mix arbor.hands.capture test-writer --summary

  Also checks for a summary file written by the Hand.

  ## Options

    * `--lines` - Number of lines to capture (default: 50)
    * `--summary` - Show only the summary file, not terminal output
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [lines: :integer, summary: :boolean]
      )

    name = List.first(positional)

    unless name do
      Mix.shell().error("Usage: mix arbor.hands.capture <name> [--lines N] [--summary]")
      exit({:shutdown, 1})
    end

    lines = opts[:lines] || 50

    # Check for summary file first
    case Hands.read_summary(name) do
      {:ok, content} ->
        Mix.shell().info("── Summary (.arbor/hands/#{name}/summary.md) ──")
        Mix.shell().info(content)
        Mix.shell().info("── End Summary ──")

        if opts[:summary] do
          # Only wanted summary, we're done
          :ok
        else
          Mix.shell().info("")
          capture_output(name, lines)
        end

      {:error, :no_summary} ->
        if opts[:summary] do
          Mix.shell().info("No summary file yet for hand '#{name}'.")
        else
          capture_output(name, lines)
        end

      {:error, reason} ->
        Mix.shell().error("Error reading summary: #{inspect(reason)}")
        capture_output(name, lines)
    end
  end

  defp capture_output(name, lines) do
    case Hands.find_hand(name) do
      {:local, %{session: session}} ->
        capture_tmux(session, lines)

      {:sandbox, %{container: container}} ->
        capture_docker(container, lines)

      :not_found ->
        Mix.shell().info("Hand '#{name}' is not running.")

        if Hands.summary_exists?(name) do
          Mix.shell().info("(Summary file exists — the hand may have finished.)")
          Mix.shell().info("Run: mix arbor.hands.capture #{name} --summary")
        end
    end
  end

  defp capture_tmux(session, lines) do
    case System.cmd(
           "tmux",
           [
             "capture-pane",
             "-t",
             session,
             "-p",
             "-S",
             "-#{lines}"
           ], stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info("── Terminal Output ──")
        Mix.shell().info(String.trim(output))
        Mix.shell().info("── End Output ──")

      {error, _} ->
        Mix.shell().error("Failed to capture: #{error}")
    end
  end

  defp capture_docker(container, lines) do
    case System.cmd(
           "docker",
           [
             "exec",
             container,
             "tmux",
             "capture-pane",
             "-t",
             "claude",
             "-p",
             "-S",
             "-#{lines}"
           ], stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info("── Terminal Output ──")
        Mix.shell().info(String.trim(output))
        Mix.shell().info("── End Output ──")

      {error, _} ->
        Mix.shell().error("Failed to capture: #{error}")
    end
  end
end
