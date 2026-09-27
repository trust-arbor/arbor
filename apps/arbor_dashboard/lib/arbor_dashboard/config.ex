defmodule Arbor.Dashboard.Config do
  @moduledoc false

  # A public-facade seam for isolated UI contract tests. Browser/session input
  # never selects a collaborator or supplies authorization overrides.
  def conversation_api do
    Application.get_env(:arbor_dashboard, :conversation_api, Arbor.Agent)
  end
end
