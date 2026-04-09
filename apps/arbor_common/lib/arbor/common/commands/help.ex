defmodule Arbor.Common.Commands.Help do
  @moduledoc "Lists available slash commands."
  @behaviour Arbor.Common.Command

  alias Arbor.Common.CommandRouter
  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "help"

  @impl true
  def aliases, do: ["h", "?"]

  @impl true
  def description, do: "List available commands"

  @impl true
  def usage, do: "/help [command]"

  @impl true
  def available?(%Context{}), do: true

  @impl true
  def execute("", %Context{} = context) do
    commands = CommandRouter.list_commands(context)

    lines =
      Enum.map(commands, fn {cmd_name, desc, _usage} ->
        "  /#{String.pad_trailing(cmd_name, 12)} #{desc}"
      end)

    text =
      "Available commands:\n" <>
        Enum.join(lines, "\n") <>
        "\n\nType /help <command> for details."

    {:ok, Result.ok(text)}
  end

  def execute(command_name, %Context{}) do
    name = String.trim(command_name)
    commands = CommandRouter.command_map_public()

    case Map.get(commands, name) do
      nil ->
        {:ok, Result.error("Unknown command: /#{name}")}

      module ->
        text = "/#{module.name()} — #{module.description()}\nUsage: #{module.usage()}"
        {:ok, Result.ok(text)}
    end
  end
end
