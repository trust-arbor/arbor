defmodule Arbor.Common.Commands.Session do
  @moduledoc "Show session info."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "session"

  @impl true
  def description, do: "Show session info"

  @impl true
  def usage, do: "/session"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_session?(ctx) or ctx.session_id != nil

  @impl true
  def execute(_args, %Context{} = ctx) do
    lines =
      if ctx.session_id do
        [
          "Session ID: #{ctx.session_id}",
          if(ctx.turn_count, do: "Turns: #{ctx.turn_count}"),
          if(ctx.model, do: "Model: #{ctx.model}"),
          if(ctx.session_started, do: "Started: #{ctx.session_started}")
        ]
        |> Enum.reject(&is_nil/1)
      else
        ["No active session"]
      end

    {:ok, Result.ok(Enum.join(lines, "\n"))}
  end
end
