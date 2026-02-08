defmodule Arbor.Cartographer.Supervisor do
  @moduledoc """
  Main supervisor for Arbor.Cartographer.

  Supervises the core components:
  - CapabilityRegistry - ETS-backed capability storage
  - Scout - Hardware introspection and capability registration

  ## Supervision Strategy

  Uses `rest_for_one` strategy:
  - CapabilityRegistry must start first (Scout depends on it)
  - If Registry crashes, Scout is restarted to re-register

  ## Options

  - `:introspection_interval` - Passed to Scout
  - `:load_update_interval` - Passed to Scout
  - `:custom_tags` - Passed to Scout
  """

  use Supervisor

  @doc """
  Start the Cartographer supervisor.

  ## Options

  - `:introspection_interval` - How often to re-detect hardware (default: 5 min)
  - `:load_update_interval` - How often to update load score (default: 30 sec)
  - `:custom_tags` - Additional capability tags to register
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Extract Scout options
    scout_opts =
      opts
      |> Keyword.take([:introspection_interval, :load_update_interval, :custom_tags])

    children = [
      # Registry must start first - Scout depends on it
      {Arbor.Cartographer.CapabilityRegistry, []},

      # Scout for hardware introspection
      {Arbor.Cartographer.Scout, scout_opts}
    ]

    # rest_for_one: if Registry crashes, restart Scout too
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
