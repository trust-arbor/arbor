defmodule Arbor.Agent do
  @moduledoc """
  Agent orchestration framework for Arbor.

  Provides the public API for managing Jido-based agents with durability support.
  Agents are supervised processes that wrap Jido agent structs with:

  - **Supervision** - Automatic restarts on failure via DynamicSupervisor
  - **Registration** - Discovery and lookup via ETS-backed registry
  - **Checkpointing** - State persistence and recovery via pluggable storage
  - **Action execution** - Consistent plan-and-execute pattern

  ## Quick Start

      # Define a Jido agent module
      defmodule MyAgent do
        use Jido.Agent,
          name: "my_agent",
          description: "Example agent",
          actions: [MyApp.Actions.DoWork],
          schema: [counter: [type: :integer, default: 0]]
      end

      # Start an agent
      {:ok, pid} = Arbor.Agent.start("agent-001", MyAgent, %{counter: 0})

      # Execute an action
      {:ok, result} = Arbor.Agent.run_action("agent-001", {MyApp.Actions.DoWork, %{input: "data"}})

      # Get agent state
      {:ok, state} = Arbor.Agent.get_state("agent-001")

      # Stop the agent (saves checkpoint)
      :ok = Arbor.Agent.stop("agent-001")

  ## Checkpointing

  Enable durable state by providing a checkpoint storage backend:

      {:ok, pid} = Arbor.Agent.start("agent-001", MyAgent, %{counter: 0},
        checkpoint_storage: Arbor.Checkpoint.Storage.ETS,
        auto_checkpoint_interval: 30_000
      )

  The agent will automatically:
  - Attempt to restore from checkpoint on startup
  - Save checkpoints at the configured interval
  - Save a final checkpoint on graceful shutdown
  """

  alias Arbor.Agent.{Registry, Server, Supervisor}

  require Logger

  @doc """
  Start a supervised agent.

  ## Parameters

  - `agent_id` - Unique identifier for the agent
  - `agent_module` - The Jido agent module to run
  - `initial_state` - Initial state map (default: %{})
  - `opts` - Additional options

  ## Options

  - `:checkpoint_storage` - Storage backend module (e.g., `Arbor.Checkpoint.Storage.ETS`)
  - `:auto_checkpoint_interval` - Auto-save interval in ms (e.g., 30_000)
  - `:metadata` - Additional metadata map
  - `:restart` - Supervision restart strategy (default: `:transient`)

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start(String.t(), module(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(agent_id, agent_module, initial_state \\ %{}, opts \\ []) do
    server_opts =
      Keyword.merge(opts,
        agent_id: agent_id,
        agent_module: agent_module,
        initial_state: initial_state
      )

    Supervisor.start_agent(server_opts)
  end

  @doc """
  Stop a running agent.

  The agent will save a final checkpoint (if storage is configured)
  before terminating.

  ## Returns

  - `:ok` on success
  - `{:error, :not_found}` if agent is not running
  """
  @spec stop(String.t()) :: :ok | {:error, :not_found}
  def stop(agent_id) do
    Supervisor.stop_agent_by_id(agent_id)
  end

  @doc """
  Execute an action on a running agent.

  ## Parameters

  - `agent_id` - The agent's ID
  - `action` - Action module or `{action_module, params}` tuple
  - `timeout` - Call timeout in ms (default: 5000)

  ## Returns

  - `{:ok, result}` on success
  - `{:error, :not_found}` if agent is not running
  - `{:error, reason}` on action failure
  """
  @spec run_action(String.t(), module() | {module(), map()}, timeout()) ::
          {:ok, any()} | {:error, any()}
  def run_action(agent_id, action, timeout \\ 5000) do
    with {:ok, pid} <- Registry.whereis(agent_id) do
      Server.run_action(pid, action, timeout)
    end
  end

  @doc """
  Get the current state of an agent.

  ## Returns

  - `{:ok, state_map}` on success
  - `{:error, :not_found}` if agent is not running
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(agent_id) do
    with {:ok, pid} <- Registry.whereis(agent_id) do
      Server.get_state(pid)
    end
  end

  @doc """
  Get metadata for a running agent.

  ## Returns

  - `{:ok, metadata_map}` on success
  - `{:error, :not_found}` if agent is not running
  """
  @spec get_metadata(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_metadata(agent_id) do
    with {:ok, pid} <- Registry.whereis(agent_id) do
      {:ok, Server.get_metadata(pid)}
    end
  end

  @doc """
  Manually trigger a checkpoint save for an agent.

  ## Returns

  - `:ok` on success
  - `{:error, :not_found}` if agent is not running
  - `{:error, reason}` on save failure
  """
  @spec checkpoint(String.t()) :: :ok | {:error, term()}
  def checkpoint(agent_id) do
    with {:ok, pid} <- Registry.whereis(agent_id) do
      Server.save_checkpoint(pid)
    end
  end

  @doc """
  Look up an agent by ID.

  ## Returns

  - `{:ok, entry}` with agent info (pid, module, metadata)
  - `{:error, :not_found}` if not registered
  """
  @spec lookup(String.t()) :: {:ok, Registry.agent_entry()} | {:error, :not_found}
  def lookup(agent_id) do
    Registry.lookup(agent_id)
  end

  @doc """
  Get the PID of a running agent.

  ## Returns

  - `{:ok, pid}` if found and alive
  - `{:error, :not_found}` otherwise
  """
  @spec whereis(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(agent_id) do
    Registry.whereis(agent_id)
  end

  @doc """
  List all running agents.

  ## Returns

  - `{:ok, [entry]}` list of agent entries
  """
  @spec list() :: {:ok, [Registry.agent_entry()]}
  def list do
    Registry.list()
  end

  @doc """
  Count running agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    Registry.count()
  end

  @doc """
  Check if an agent is running.
  """
  @spec running?(String.t()) :: boolean()
  def running?(agent_id) do
    case Registry.whereis(agent_id) do
      {:ok, _pid} -> true
      {:error, :not_found} -> false
    end
  end
end
