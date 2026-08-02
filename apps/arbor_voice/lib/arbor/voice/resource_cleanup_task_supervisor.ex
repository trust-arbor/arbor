defmodule Arbor.Voice.ResourceCleanupTaskSupervisor do
  @moduledoc """
  Named `Task.Supervisor` used only for bounded cleanup callbacks run by
  `Arbor.Voice.ResourceOwner`.
  """

  @name Arbor.Voice.ResourceCleanupTaskSupervisor

  @doc false
  def child_spec(_args) do
    %{
      id: @name,
      start: {Task.Supervisor, :start_link, [[name: @name, max_restarts: 100, max_seconds: 1]]},
      type: :supervisor
    }
  end
end
