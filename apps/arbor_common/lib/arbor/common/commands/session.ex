defmodule Arbor.Common.Commands.Session do
  @moduledoc "Show session info."
  @behaviour Arbor.Common.Command

  @impl true
  def name, do: "session"

  @impl true
  def description, do: "Show session info"

  @impl true
  def usage, do: "/session"

  @impl true
  def available?(context), do: context[:session_pid] != nil or context[:session_id] != nil

  @impl true
  def execute(_args, context) do
    lines = []

    lines =
      if session_id = context[:session_id],
        do: lines ++ ["Session ID: #{session_id}"],
        else: lines ++ ["No active session"]

    lines =
      if turn_count = context[:turn_count],
        do: lines ++ ["Turns: #{turn_count}"],
        else: lines

    lines =
      if model = context[:model],
        do: lines ++ ["Model: #{model}"],
        else: lines

    lines =
      if started = context[:session_started],
        do: lines ++ ["Started: #{started}"],
        else: lines

    {:ok, Enum.join(lines, "\n")}
  end
end
