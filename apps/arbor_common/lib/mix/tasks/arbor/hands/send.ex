defmodule Mix.Tasks.Arbor.Hands.Send do
  @shortdoc "Send a message to a running Hand"
  @moduledoc """
  Sends a message to a running Hand's Claude session.

      $ mix arbor.hands.send test-writer "also cover the edge cases"
      $ mix arbor.hands.send refactor "stop and write your summary"

  Best used with Hands spawned with `--interactive`. For autonomous Hands
  (default), the message is typed into the terminal but Claude may not
  be waiting for input.

  After sending, captures recent output to show the response.
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.Hands.Capture
  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @impl Mix.Task
  def run(args) do
    {_opts, positional, _} = OptionParser.parse(args, strict: [])

    case positional do
      [name | message_parts] when message_parts != [] ->
        message = Enum.join(message_parts, " ")
        send_message(name, message)

      [_name] ->
        Mix.shell().error("No message provided.")
        Mix.shell().error("Usage: mix arbor.hands.send <name> \"message\"")
        exit({:shutdown, 1})

      _ ->
        Mix.shell().error("Usage: mix arbor.hands.send <name> \"message\"")
        exit({:shutdown, 1})
    end
  end

  defp send_message(name, message) do
    case Hands.find_hand(name) do
      {:local, %{session: session}} ->
        send_to_tmux(session, message)
        Process.sleep(2_000)
        capture_recent(name)

      {:sandbox, %{container: container}} ->
        send_to_docker(container, message)
        Process.sleep(2_000)
        capture_recent(name)

      :not_found ->
        Mix.shell().error("Hand '#{name}' is not running.")
        exit({:shutdown, 1})
    end
  end

  defp send_to_tmux(session, message) do
    System.cmd("tmux", ["send-keys", "-t", session, message, "Enter"], stderr_to_stdout: true)
  end

  defp send_to_docker(container, message) do
    System.cmd(
      "docker",
      [
        "exec",
        container,
        "tmux",
        "send-keys",
        "-t",
        "claude",
        message,
        "Enter"
      ], stderr_to_stdout: true)
  end

  defp capture_recent(name) do
    Mix.shell().info("")
    Capture.run([name, "--lines", "20"])
  end
end
