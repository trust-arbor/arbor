defmodule Arbor.Voice.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Arbor.Voice.Registry},
      Arbor.Voice.ResourceCleanupTaskSupervisor,
      # Dedicated acceptance-seam Task.Supervisor for speech_output callbacks
      # (VP-04E2R1). Not ResourceCleanupTaskSupervisor — separate ownership.
      Supervisor.child_spec(
        {Task.Supervisor, name: Arbor.Voice.SpeechOutputTaskSupervisor},
        id: Arbor.Voice.SpeechOutputTaskSupervisor
      ),
      Arbor.Voice.ResourceSupervisor,
      Arbor.Voice.SessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: Arbor.Voice.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
