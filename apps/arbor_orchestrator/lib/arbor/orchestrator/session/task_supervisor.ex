defmodule Arbor.Orchestrator.Session.TaskSupervisor do
  @moduledoc """
  Task.Supervisor for heartbeat and background tasks spawned by Sessions.

  Sessions can use this supervisor instead of bare `Task.start/1` to get
  OTP supervision, monitoring, and graceful shutdown of in-flight work.

  ## Example

      Task.Supervisor.start_child(
        Arbor.Orchestrator.Session.TaskSupervisor,
        fn -> do_heartbeat_work() end
      )
  """

  def start_link(opts \\ []) do
    Task.Supervisor.start_link(Keyword.merge([name: __MODULE__], opts))
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end
end
