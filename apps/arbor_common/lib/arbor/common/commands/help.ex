defmodule Arbor.Common.Commands.Help do
  @moduledoc "Lists available slash commands."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "help"

  @impl true
  def aliases, do: ["h", "?"]

  @impl true
  def description, do: "List available commands"

  @impl true
  def usage, do: "/help [command]"

  @impl true
  def available?(_context), do: true

  @impl true
  def execute("", context) do
    commands = Arbor.Common.CommandRouter.list_commands(context)

    lines =
      Enum.map(commands, fn {cmd_name, desc, _usage} ->
        "  /#{String.pad_trailing(cmd_name, 12)} #{desc}"
      end)

    {:ok, "Available commands:\n" <> Enum.join(lines, "\n") <> "\n\nType /help <command> for details."}
  end

  def execute(command_name, _context) do
    name = String.trim(command_name)
    commands = Arbor.Common.CommandRouter.command_map_public()

    case Map.get(commands, name) do
      nil ->
        {:ok, "Unknown command: /#{name}"}

      module ->
        {:ok, "/#{module.name()} — #{module.description()}\nUsage: #{module.usage()}"}
    end
  end
end
