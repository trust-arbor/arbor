defmodule Arbor.Agent.Server do
  @moduledoc """
  GenServer wrapper for running Jido agents with durability support.

  Wraps a Jido agent struct in a GenServer process with:

  - Registry-based process registration and discovery
  - State extraction for checkpointing
  - State restoration from checkpoints on startup
  - Auto-checkpoint scheduling
  - Graceful termination with cleanup

  ## Usage

  Start an agent via the Supervisor:

      Arbor.Agent.start("analyzer-001", MyApp.Agents.Analyzer, %{
        working_dir: "/tmp/work"
      })

  Or start directly:

      Arbor.Agent.Server.start_link(
        agent_id: "analyzer-001",
        agent_module: MyApp.Agents.Analyzer,
        initial_state: %{working_dir: "/tmp/work"}
      )

  Execute actions:

      {:ok, result} = Arbor.Agent.Server.run_action(pid, {MyAction, %{param: "value"}})

  """

  use GenServer

  alias Arbor.Agent.{ActionRunner, Registry}

  require Logger

  @type state :: %{
          agent_id: String.t(),
          agent_module: module(),
          jido_agent: struct(),
          metadata: map(),
          checkpoint_storage: module() | nil,
          auto_checkpoint_interval: pos_integer() | nil,
          checkpoint_timer: reference() | nil
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts an Agent.Server process.

  ## Options

  - `:agent_id` - Unique identifier for the agent (required)
  - `:agent_module` - The Jido agent module to run (required)
  - `:initial_state` - Initial state map for the agent (optional, default: %{})
  - `:metadata` - Additional metadata (optional, default: %{})
  - `:checkpoint_storage` - Storage backend module for checkpoints (optional)
  - `:auto_checkpoint_interval` - Auto-checkpoint interval in ms (optional)

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Execute an action on the agent.

  ## Parameters

  - `pid` - The agent process
  - `action` - Action module or `{action_module, params}` tuple
  - `timeout` - Optional timeout (default: 5000ms)

  ## Returns

  - `{:ok, result}` on success
  - `{:error, reason}` on failure
  """
  @spec run_action(pid(), module() | {module(), map()}, timeout()) ::
          {:ok, any()} | {:error, any()}
  def run_action(pid, action, timeout \\ 5000) do
    GenServer.call(pid, {:run_action, action}, timeout)
  end

  @doc """
  Get the current Jido agent state.
  """
  @spec get_state(pid()) :: {:ok, map()}
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @doc """
  Get agent metadata.
  """
  @spec get_metadata(pid()) :: map()
  def get_metadata(pid) do
    GenServer.call(pid, :get_metadata)
  end

  @doc """
  Extract the full checkpoint-ready state from the agent.
  """
  @spec extract_state(pid()) :: {:ok, map()}
  def extract_state(pid) do
    GenServer.call(pid, :extract_state)
  end

  @doc """
  Manually trigger a checkpoint save.
  """
  @spec save_checkpoint(pid()) :: :ok | {:error, term()}
  def save_checkpoint(pid) do
    GenServer.call(pid, :save_checkpoint)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    agent_module = Keyword.fetch!(opts, :agent_module)
    initial_state = Keyword.get(opts, :initial_state, %{})
    metadata = Keyword.get(opts, :metadata, %{})
    checkpoint_storage = Keyword.get(opts, :checkpoint_storage)
    auto_checkpoint_interval = Keyword.get(opts, :auto_checkpoint_interval)

    Logger.debug("Starting Agent.Server for #{agent_id} with #{inspect(agent_module)}")

    case create_jido_agent(agent_module, agent_id, initial_state) do
      {:ok, jido_agent} ->
        state = %{
          agent_id: agent_id,
          agent_module: agent_module,
          jido_agent: jido_agent,
          metadata:
            Map.merge(metadata, %{
              module: agent_module,
              started_at: System.system_time(:millisecond)
            }),
          checkpoint_storage: checkpoint_storage,
          auto_checkpoint_interval: auto_checkpoint_interval,
          checkpoint_timer: nil
        }

        {:ok, state, {:continue, :post_init}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:post_init, state) do
    # Register with the agent registry
    register_result = register_agent(state)

    case register_result do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to register agent #{state.agent_id}: #{inspect(reason)}")
    end

    # Attempt checkpoint restore
    state = maybe_restore_from_checkpoint(state)

    # Schedule auto-checkpoint if configured
    state = maybe_schedule_checkpoint(state)

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:run_action, action}, _from, state) do
    {action_module, params} = normalize_action(action)

    # Inject agent_id into params
    params_with_context = Map.put(params, :agent_id, state.agent_id)

    case ActionRunner.run(state.jido_agent, action_module, params_with_context,
           agent_module: state.agent_module
         ) do
      {:ok, updated_agent, result} ->
        new_state = %{state | jido_agent: updated_agent}
        {:reply, {:ok, result}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    agent_state = get_jido_agent_state(state.jido_agent)
    {:reply, {:ok, agent_state}, state}
  end

  def handle_call(:get_metadata, _from, state) do
    {:reply, state.metadata, state}
  end

  def handle_call(:extract_state, _from, state) do
    extracted = extract_checkpoint_data(state)
    {:reply, {:ok, extracted}, state}
  end

  def handle_call(:save_checkpoint, _from, state) do
    result = do_save_checkpoint(state)
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info(:checkpoint, state) do
    do_save_checkpoint(state)
    state = maybe_schedule_checkpoint(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, state) do
    Logger.debug("Agent.Server terminating: #{state.agent_id}, reason: #{inspect(reason)}")

    # Save final checkpoint before dying
    do_save_checkpoint(state)

    # Unregister from registry
    Registry.unregister(state.agent_id)

    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_jido_agent(agent_module, agent_id, initial_state) do
    Code.ensure_loaded(agent_module)

    opts = %{id: agent_id, state: initial_state}
    agent = agent_module.new(opts)
    {:ok, agent}
  rescue
    e -> {:error, {:agent_creation_failed, Exception.message(e)}}
  end

  defp normalize_action({module, params}) when is_atom(module), do: {module, params}
  defp normalize_action(module) when is_atom(module), do: {module, %{}}

  defp get_jido_agent_state(agent) do
    Map.get(agent, :state, %{})
  end

  defp register_agent(state) do
    metadata = %{
      module: state.agent_module,
      started_at: state.metadata[:started_at],
      type: state.metadata[:type] || :jido_agent
    }

    Registry.register(state.agent_id, self(), metadata)
  end

  defp extract_checkpoint_data(state) do
    %{
      agent_id: state.agent_id,
      agent_module: state.agent_module,
      jido_state: get_jido_agent_state(state.jido_agent),
      metadata: state.metadata,
      extracted_at: System.system_time(:millisecond)
    }
  end

  defp do_save_checkpoint(%{checkpoint_storage: nil}), do: :ok

  defp do_save_checkpoint(state) do
    data = extract_checkpoint_data(state)

    case Arbor.Checkpoint.save(state.agent_id, data, state.checkpoint_storage) do
      :ok ->
        Logger.debug("Checkpoint saved for agent #{state.agent_id}")
        :ok

      {:error, reason} = error ->
        Logger.warning("Failed to save checkpoint for #{state.agent_id}: #{inspect(reason)}")
        error
    end
  end

  defp maybe_restore_from_checkpoint(%{checkpoint_storage: nil} = state), do: state

  defp maybe_restore_from_checkpoint(state) do
    case Arbor.Checkpoint.load(state.agent_id, state.checkpoint_storage, retries: 0) do
      {:ok, checkpoint_data} ->
        Logger.info("Restoring agent #{state.agent_id} from checkpoint")
        restore_from_checkpoint(state, checkpoint_data)

      {:error, :not_found} ->
        state

      {:error, reason} ->
        Logger.warning("Failed to restore checkpoint for #{state.agent_id}: #{inspect(reason)}")

        state
    end
  end

  defp restore_from_checkpoint(state, checkpoint_data) do
    jido_state = Map.get(checkpoint_data, :jido_state, %{})

    case create_jido_agent(state.agent_module, state.agent_id, jido_state) do
      {:ok, restored_agent} ->
        %{
          state
          | jido_agent: restored_agent,
            metadata: Map.put(state.metadata, :restored_at, System.system_time(:millisecond))
        }

      {:error, reason} ->
        Logger.warning("Failed to restore agent from checkpoint: #{inspect(reason)}")
        state
    end
  end

  defp maybe_schedule_checkpoint(%{auto_checkpoint_interval: nil} = state), do: state

  defp maybe_schedule_checkpoint(%{auto_checkpoint_interval: interval} = state)
       when is_integer(interval) and interval > 0 do
    # Cancel existing timer if any
    if state.checkpoint_timer, do: Process.cancel_timer(state.checkpoint_timer)

    timer = Process.send_after(self(), :checkpoint, interval)
    %{state | checkpoint_timer: timer}
  end

  defp maybe_schedule_checkpoint(state), do: state
end
