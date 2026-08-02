defmodule Arbor.Voice.ResourceSupervisor do
  @moduledoc """
  Named `DynamicSupervisor` that holds temporary `Arbor.Voice.ResourceOwner`
  children. Supervised independently of the monitored Session owners so an owner
  crash does not kill the resource owner before `:DOWN` cleanup runs.
  """

  @name Arbor.Voice.ResourceSupervisor

  @doc false
  def child_spec(_args) do
    %{
      id: @name,
      start:
        {DynamicSupervisor, :start_link,
         [[name: @name, strategy: :one_for_one, max_restarts: 100, max_seconds: 1]]},
      type: :supervisor
    }
  end
end
