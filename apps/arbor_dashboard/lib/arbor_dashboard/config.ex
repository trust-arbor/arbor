defmodule Arbor.Dashboard.Config do
  @moduledoc false

  # A public-facade seam for isolated UI contract tests. Browser/session input
  # never selects a collaborator or supplies authorization overrides.
  def conversation_api do
    Application.get_env(:arbor_dashboard, :conversation_api, Arbor.Agent)
  end

  def session_auth_api,
    do: Application.get_env(:arbor_dashboard, :session_auth_api, Arbor.Security)

  def mutation_security_api,
    do: Application.get_env(:arbor_dashboard, :mutation_security_api, Arbor.Security)

  def voice_api, do: Application.get_env(:arbor_dashboard, :voice_api, Arbor.Voice)
  def multimedia_api, do: Application.get_env(:arbor_dashboard, :multimedia_api, Arbor.Multimedia)

  def local_voice_controls?,
    do: Application.get_env(:arbor_dashboard, :local_voice_controls, false) == true
end
