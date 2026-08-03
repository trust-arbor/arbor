defmodule Arbor.Voice.ToolRouter.EmptyCatalog do
  @moduledoc """
  Production default router: empty catalog, deterministic no_tools_installed.
  """

  @behaviour Arbor.Voice.ToolRouter

  @impl true
  def invoke(_context), do: {:error, :no_tools_installed}
end
