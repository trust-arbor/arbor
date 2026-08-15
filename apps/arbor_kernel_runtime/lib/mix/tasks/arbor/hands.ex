defmodule Mix.Tasks.Arbor.Hands do
  @shortdoc "List active Hands (independent Claude Code sessions)"
  @moduledoc """
  Lists all active Hands — independent Claude Code sessions doing focused work.

      $ mix arbor.hands

  Shows each Hand's name, type (local tmux or Docker sandbox), and whether
  a summary file has been written (indicating the Hand has finished its work).
  """
  use Mix.Task

  alias Mix.Tasks.Arbor.HandsHelpers, as: Hands

  @impl Mix.Task
  def run(_args) do
    hands = Hands.list_all()

    if hands == [] do
      Mix.shell().info("No active hands.")
      Mix.shell().info("")
      Mix.shell().info("Spawn one with: mix arbor.hands.spawn \"task\" --name <name>")
    else
      Mix.shell().info("")

      Enum.each(hands, &print_hand/1)

      Mix.shell().info("")
      Mix.shell().info("Commands:")
      Mix.shell().info("  mix arbor.hands.capture <name>       Capture recent output")
      Mix.shell().info("  mix arbor.hands.send <name> \"msg\"    Send guidance")
      Mix.shell().info("  mix arbor.hands.stop <name>          Stop a hand")
    end
  end

  defp print_hand(hand) do
    type_label = if hand.type == :local, do: "local", else: "sandbox"
    summary = if Hands.summary_exists?(hand.name), do: " [summary ready]", else: ""
    status = Map.get(hand, :status, "")
    status_str = if status != "", do: " (#{status})", else: ""

    Mix.shell().info("  #{hand.name}  [#{type_label}]#{status_str}#{summary}")
  end
end
