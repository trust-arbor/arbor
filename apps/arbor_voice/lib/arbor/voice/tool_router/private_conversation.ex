defmodule Arbor.Voice.ToolRouter.PrivateConversation do
  @moduledoc """
  Private conversation catalog: one source-fenced `consult_agent` tool.

  Managed coding dispatch remains available through an explicitly selected
  `FrontDesk` router. It is outside the private conversation continuity profile
  until its source admission also supports the pinned engagement fence.
  """

  @behaviour Arbor.Voice.ToolRouter

  alias Arbor.Voice.ToolRouter.FrontDesk

  @impl true
  def tools, do: Enum.filter(FrontDesk.catalog(), &(&1["name"] == "consult_agent"))

  @impl true
  def invoke(%{name: "consult_agent"} = context, authority),
    do: FrontDesk.invoke(context, authority)

  def invoke(_, _), do: {:error, :unknown_tool}
end
