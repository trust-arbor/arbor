defmodule Arbor.Agent.Supervisor do
  @moduledoc """
  DynamicSupervisor for agent processes.

  Manages the lifecycle of agent server processes. Agents are started
  as children of this supervisor and benefit from OTP supervision
  (automatic restarts on failure).

  For distributed deployments, this can be swapped for a Horde-based
  supervisor without changing the agent code.

  ## Usage

      # Start an agent under supervision
      {:ok, pid} = Arbor.Agent.Supervisor.start_agent(
        agent_id: "agent-001",
        agent_module: MyAgent,
        initial_state: %{value: 0}
      )

      # Stop a supervised agent
      :ok = Arbor.Agent.Supervisor.stop_agent(pid)

      # List supervised agents
      children = Arbor.Agent.Supervisor.which_agents()
  """

  use DynamicSupervisor

  require Logger

  @doc """
  Start the agent supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start an agent under this supervisor.

  ## Options

  All options are passed through to `Arbor.Agent.Server.start_link/1`.
  See that module for available options.

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_agent(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_agent(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    Logger.debug("Supervisor starting agent: #{agent_id}")

    child_spec = %{
      id: agent_id,
      start: {Arbor.Agent.Server, :start_link, [opts]},
      restart: Keyword.get(opts, :restart, :transient),
      type: :worker
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        Logger.info("Agent started: #{agent_id} (pid: #{inspect(pid)})")
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to start agent #{agent_id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Start any GenServer module as a supervised child.

  Unlike `start_agent/1` which is hardcoded to `Arbor.Agent.Server`,
  this function accepts an arbitrary module and start opts. Used by
  AgentManager to supervise Claude CLI agents, API agents, etc.

  ## Options

  - `:agent_id` — required, unique identifier
  - `:module` — required, the GenServer module to start
  - `:start_opts` — keyword list passed to `module.start_link/1` (default: `[]`)
  - `:metadata` — map registered alongside the agent (default: `%{}`)
  - `:restart` — restart strategy (default: `:transient`)

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, :already_running}` if agent_id is already registered with a live process
  - `{:error, reason}` on failure
  """
  @spec start_child(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_child(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    module = Keyword.fetch!(opts, :module)
    start_opts = Keyword.get(opts, :start_opts, [])
    metadata = Keyword.get(opts, :metadata, %{})

    case Arbor.Agent.Registry.whereis(agent_id) do
      {:ok, _pid} ->
        {:error, :already_running}

      {:error, :not_found} ->
        child_spec = %{
          id: agent_id,
          start: {module, :start_link, [start_opts]},
          restart: Keyword.get(opts, :restart, :transient),
          type: :worker
        }

        case DynamicSupervisor.start_child(__MODULE__, child_spec) do
          {:ok, pid} ->
            Arbor.Agent.Registry.register(
              agent_id,
              pid,
              Map.merge(metadata, %{module: module})
            )

            Logger.info("Child started: #{agent_id} (#{inspect(module)}, pid: #{inspect(pid)})")
            {:ok, pid}

          {:error, reason} = error ->
            Logger.error("Failed to start child #{agent_id}: #{inspect(reason)}")
            error
        end
    end
  end

  @doc """
  Stop a supervised agent process.

  Terminates the agent gracefully, allowing it to save a final checkpoint.

  ## Returns

  - `:ok` on success
  - `{:error, :not_found}` if the process is not supervised
  """
  @spec stop_agent(pid()) :: :ok | {:error, :not_found}
  def stop_agent(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Stop an agent by its agent ID.

  Looks up the agent in the registry and terminates it.
  """
  @spec stop_agent_by_id(String.t()) :: :ok | {:error, :not_found}
  def stop_agent_by_id(agent_id) do
    case Arbor.Agent.Registry.whereis(agent_id) do
      {:ok, pid} -> stop_agent(pid)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  List all supervised agent PIDs.
  """
  @spec which_agents() :: [pid()]
  def which_agents do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @doc """
  Count supervised agents.
  """
  @spec count() :: non_neg_integer()
  def count do
    DynamicSupervisor.count_children(__MODULE__)
    |> Map.get(:active, 0)
  end
end
