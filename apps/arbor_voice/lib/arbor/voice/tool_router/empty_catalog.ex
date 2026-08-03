defmodule Arbor.Voice.ToolRouter.EmptyCatalog do
  @moduledoc """
  Explicit empty router: no declarations, deterministic no_tools_installed.
  Available for tests/deployments; production defaults to FrontDesk.
  """

  @behaviour Arbor.Voice.ToolRouter

  @impl true
  def tools, do: []

  @impl true
  def invoke(_context, _authority), do: {:error, :no_tools_installed}
end
