defmodule Arbor.Common.Commands.Compact do
  @moduledoc "Trigger context compaction for the current session."
  @behaviour Arbor.Common.Command

  alias Arbor.Contracts.Commands.{Context, Result}

  @impl true
  def name, do: "compact"

  @impl true
  def description, do: "Compact session context to free token space"

  @impl true
  def usage, do: "/compact"

  @impl true
  def available?(%Context{} = ctx), do: Context.has_session?(ctx)

  @impl true
  def execute(_args, %Context{}) do
    {:ok, Result.action("Compacting context...", :compact)}
  end
end
