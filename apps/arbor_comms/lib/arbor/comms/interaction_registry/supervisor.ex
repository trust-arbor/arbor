defmodule Arbor.Comms.InteractionRegistry.Supervisor do
  @moduledoc false

  use Supervisor

  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Comms.InteractionRegistry.Authority
  alias Arbor.Comms.InteractionRegistry.Dispatcher

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    children = [
      %{
        id: InteractionRegistry.Tracker,
        start: {InteractionRegistry, :start_tracker, [opts]},
        type: :worker
      },
      %{
        id: Authority,
        start: {Authority, :start_link, [Keyword.put_new(opts, :tracker, InteractionRegistry)]},
        type: :worker
      },
      %{
        id: Arbor.Comms.InteractionRegistry.DeliverySupervisor,
        start:
          {Task.Supervisor, :start_link,
           [[name: Arbor.Comms.InteractionRegistry.DeliverySupervisor]]},
        type: :supervisor
      },
      %{
        id: Dispatcher,
        start: {Dispatcher, :start_link, [opts]},
        type: :worker
      }
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
