defmodule Arbor.Scheduler.Config do
  @moduledoc false

  def orchestrator,
    do: Application.get_env(:arbor_scheduler, :orchestrator_module, Arbor.Orchestrator)
end
