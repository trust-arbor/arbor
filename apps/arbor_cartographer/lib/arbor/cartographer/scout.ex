defmodule Arbor.Cartographer.Scout do
  @moduledoc """
  Per-node hardware introspection and capability registration agent.

  The Scout runs on each node and is responsible for:
  - Detecting hardware capabilities on startup
  - Registering capabilities with the local registry
  - Periodically updating load metrics
  - Re-detecting hardware on configuration changes

  ## Configuration

  - `:introspection_interval` - How often to re-detect hardware (default: 5 min)
  - `:load_update_interval` - How often to update load score (default: 30 sec)
  - `:custom_tags` - Additional capability tags to register

  ## Examples

      # Start with default options
      {:ok, _pid} = Arbor.Cartographer.Scout.start_link()

      # Start with custom tags
      {:ok, _pid} = Arbor.Cartographer.Scout.start_link(
        custom_tags: [:production, :gpu_optimized]
      )

      # Get current hardware info
      {:ok, hardware} = Arbor.Cartographer.Scout.hardware_info()
  """

  use GenServer

  require Logger

  alias Arbor.Cartographer.Hardware
  alias Arbor.Cartographer.CapabilityRegistry
  alias Arbor.Contracts.Libraries.Cartographer, as: Contract

  @type hardware_info :: Contract.hardware_info()

  @default_introspection_interval :timer.minutes(5)
  @default_load_update_interval :timer.seconds(30)

  # ==========================================================================
  # Client API
  # ==========================================================================

  @doc """
  Start the Scout agent.

  ## Options

  - `:introspection_interval` - Hardware re-detection interval (ms)
  - `:load_update_interval` - Load metric update interval (ms)
  - `:custom_tags` - Additional capability tags to register
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current hardware info.
  """
  @spec hardware_info() :: {:ok, hardware_info()}
  def hardware_info do
    GenServer.call(__MODULE__, :hardware_info)
  end

  @doc """
  Get all detected capability tags.
  """
  @spec capability_tags() :: {:ok, [atom()]}
  def capability_tags do
    GenServer.call(__MODULE__, :capability_tags)
  end

  @doc """
  Force hardware re-detection.
  """
  @spec refresh() :: :ok
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc """
  Add custom capability tags.
  """
  @spec add_custom_tags([atom()]) :: :ok
  def add_custom_tags(tags) do
    GenServer.call(__MODULE__, {:add_custom_tags, tags})
  end

  @doc """
  Remove custom capability tags.
  """
  @spec remove_custom_tags([atom()]) :: :ok
  def remove_custom_tags(tags) do
    GenServer.call(__MODULE__, {:remove_custom_tags, tags})
  end

  @doc """
  Get current load score (0-100).
  """
  @spec current_load() :: float()
  def current_load do
    GenServer.call(__MODULE__, :current_load)
  end

  # ==========================================================================
  # GenServer Callbacks
  # ==========================================================================

  @impl true
  def init(opts) do
    introspection_interval =
      Keyword.get(opts, :introspection_interval, @default_introspection_interval)

    load_update_interval =
      Keyword.get(opts, :load_update_interval, @default_load_update_interval)

    custom_tags = Keyword.get(opts, :custom_tags, [])

    state = %{
      hardware: nil,
      hardware_tags: [],
      custom_tags: custom_tags,
      load: 0.0,
      introspection_interval: introspection_interval,
      load_update_interval: load_update_interval,
      registered_at: nil
    }

    # Perform initial hardware detection
    {:ok, state, {:continue, :initial_detection}}
  end

  @impl true
  def handle_continue(:initial_detection, state) do
    state = detect_and_register(state)

    # Schedule periodic updates
    schedule_introspection(state.introspection_interval)
    schedule_load_update(state.load_update_interval)

    {:noreply, state}
  end

  @impl true
  def handle_call(:hardware_info, _from, state) do
    {:reply, {:ok, state.hardware}, state}
  end

  @impl true
  def handle_call(:capability_tags, _from, state) do
    all_tags = state.hardware_tags ++ state.custom_tags
    {:reply, {:ok, all_tags}, state}
  end

  @impl true
  def handle_call({:add_custom_tags, tags}, _from, state) do
    new_custom_tags = Enum.uniq(state.custom_tags ++ tags)
    state = %{state | custom_tags: new_custom_tags}

    # Update registry
    CapabilityRegistry.add_tags(Node.self(), tags)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_custom_tags, tags}, _from, state) do
    new_custom_tags = state.custom_tags -- tags
    state = %{state | custom_tags: new_custom_tags}

    # Update registry
    CapabilityRegistry.remove_tags(Node.self(), tags)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:current_load, _from, state) do
    {:reply, state.load, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    state = detect_and_register(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:introspect, state) do
    state = detect_and_register(state)
    schedule_introspection(state.introspection_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:update_load, state) do
    load = calculate_load()
    state = %{state | load: load}

    # Update registry
    CapabilityRegistry.update_load(Node.self(), load)

    schedule_load_update(state.load_update_interval)
    {:noreply, state}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp detect_and_register(state) do
    {:ok, hardware} = Hardware.detect()
    hardware_tags = Hardware.to_capability_tags(hardware)
    all_tags = Enum.uniq(hardware_tags ++ state.custom_tags)
    load = calculate_load()
    now = DateTime.utc_now()

    capabilities = %{
      node: Node.self(),
      tags: all_tags,
      hardware: hardware,
      load: load,
      registered_at: now
    }

    # Register with local registry
    :ok = CapabilityRegistry.register(Node.self(), capabilities)

    Logger.info(
      "[Cartographer.Scout] Registered node #{Node.self()} with tags: #{inspect(all_tags)}"
    )

    %{state | hardware: hardware, hardware_tags: hardware_tags, load: load, registered_at: now}
  end

  defp calculate_load do
    # Combined CPU and memory load score (0-100)
    cpu_load = calculate_cpu_load()
    memory_load = calculate_memory_load()

    # Weighted average: 60% CPU, 40% memory
    Float.round(cpu_load * 0.6 + memory_load * 0.4, 1)
  end

  defp calculate_cpu_load do
    # Use run queue to estimate CPU load
    # The run queue shows how many processes are waiting to run
    run_queue_load()
  end

  defp run_queue_load do
    # Estimate load from run queue length
    total_run_queue = :erlang.statistics(:run_queue)
    schedulers = System.schedulers_online()

    # Normalize: 0 = empty, 100 = 2x schedulers
    min(100, total_run_queue / schedulers * 50)
  end

  defp calculate_memory_load do
    memory = :erlang.memory()
    total = memory[:total]

    # Use system total if available, otherwise estimate
    system_total =
      case :os.type() do
        {:unix, _} ->
          case Hardware.detect_memory_gb() do
            gb when gb > 0 -> round(gb * 1024 * 1024 * 1024)
            _ -> total * 2
          end

        _ ->
          total * 2
      end

    # Memory usage percentage
    min(100, total / system_total * 100)
  end

  defp schedule_introspection(interval) do
    Process.send_after(self(), :introspect, interval)
  end

  defp schedule_load_update(interval) do
    Process.send_after(self(), :update_load, interval)
  end
end
