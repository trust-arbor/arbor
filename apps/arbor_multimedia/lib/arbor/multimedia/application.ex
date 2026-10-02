defmodule Arbor.Multimedia.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:arbor_multimedia, :start_children, true) do
        [
          {Task.Supervisor, name: Arbor.Multimedia.NativeTaskSupervisor},
          {DynamicSupervisor, strategy: :one_for_one, name: Arbor.Multimedia.NativeSupervisor},
          {DynamicSupervisor, strategy: :one_for_one, name: Arbor.Multimedia.DriverSupervisor},
          {Arbor.Multimedia.DeviceOwner, []}
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Multimedia.Supervisor)
  end
end
