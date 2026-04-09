defmodule Arbor.Common.Commands.Clear do
  @moduledoc "Clear session context and start fresh."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "clear"

  @impl true
  def description, do: "Clear session context"

  @impl true
  def usage, do: "/clear"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_session?(ctx)

  @impl true
  def execute(_args, %Context{}) do
    {:ok, Result.action("Session context cleared.", :clear)}
  end
end
