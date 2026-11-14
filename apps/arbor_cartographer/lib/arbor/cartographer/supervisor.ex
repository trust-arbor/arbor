defmodule Arbor.Cartographer.Supervisor do
  @moduledoc """
  Main supervisor for Arbor.Cartographer.

  Supervises the core components:
  - CapabilityRegistry - ETS-backed capability storage (always started)
  - Scout - Hardware introspection and capability registration
  - ClusterKeeper - Auto-reconnection of known cluster nodes

  ## Supervision Strategy

  Uses `rest_for_one` strategy:
  - CapabilityRegistry must start first (Scout depends on it)
  - If Registry crashes, Scout is restarted to re-register

  ## Options

  - `:introspection_interval` - Passed to Scout
  - `:load_update_interval` - Passed to Scout
  - `:custom_tags` - Passed to Scout
  - `:scout_enabled` - Start Scout (default: `config :arbor_cartographer,
    scout_enabled:`, else `true`)
  - `:cluster_keeper_enabled` - Start ClusterKeeper (default:
    `config :arbor_cartographer, cluster_keeper_enabled:`, else `true`)
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

    cluster_keeper_opts =
      opts
      |> Keyword.take([:reconnect_interval])

    # Scout and ClusterKeeper do periodic work (hardware scans, node redials)
    # that only matters on a cluster, so a single-node install can switch them
    # off. The facade's Scout-backed calls fall back to on-demand detection.
    children =
      [
        # Registry must start first - Scout depends on it
        {Arbor.Cartographer.CapabilityRegistry, []}
      ] ++
        if(enabled?(opts, :scout_enabled),
          # Scout for hardware introspection
          do: [{Arbor.Cartographer.Scout, scout_opts}],
          else: []
        ) ++
        if(enabled?(opts, :cluster_keeper_enabled),
          # ClusterKeeper for auto-reconnection of known nodes
          do: [{Arbor.Cartographer.ClusterKeeper, cluster_keeper_opts}],
          else: []
        )

    # rest_for_one: if Registry crashes, restart Scout too
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp enabled?(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value != false
      :error -> Application.get_env(:arbor_cartographer, key, true) != false
    end
  end
end
