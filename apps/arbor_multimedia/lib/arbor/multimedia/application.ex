defmodule Arbor.Multimedia.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: Arbor.Multimedia.DriverSupervisor},
      {Arbor.Multimedia.DeviceOwner, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Arbor.Multimedia.Supervisor)
  end
end
