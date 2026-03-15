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
        checkpoint_storage: Arbor.Persistence.Checkpoint.Store.ETS,
        auto_checkpoint_interval: 30_000
      )

  The agent will automatically:
  - Attempt to restore from checkpoint on startup
  - Save checkpoints at the configured interval
  - Save a final checkpoint on graceful shutdown
  """

  alias Arbor.Agent.{Lifecycle, ProfileStore, Registry, Supervisor}

  require Logger

  # ===========================================================================
  # Public API — Agent Lifecycle (Phase 4: Seed/Host)
  # ===========================================================================

  @doc """
  Create a new agent from a template or options.

  ## Examples

      {:ok, profile} = Arbor.Agent.create_agent("scout-1",
        template: Arbor.Agent.Templates.Scout)

      {:ok, profile} = Arbor.Agent.create_agent("custom",
        character: Character.new(name: "My Agent"),
        trust_tier: :probationary)
  """
  defdelegate create_agent(agent_id, opts \\ []), to: Lifecycle, as: :create

  @doc "Restore an agent from a persisted profile."
  defdelegate restore_agent(agent_id), to: Lifecycle, as: :restore

  @doc "Start an agent's executor (subscribe to intents, begin processing)."
  defdelegate start_agent(agent_id, opts \\ []), to: Lifecycle, as: :start

  @doc "Stop an agent's executor cleanly."
  defdelegate stop_agent(agent_id), to: Lifecycle, as: :stop

  @doc "List all persisted agent profiles."
  defdelegate list_agents(), to: Lifecycle

  @doc "List all running agents across the cluster via `:pg` process groups."
  defdelegate list_cluster(), to: Registry, as: :list_cluster

  @doc "Find a specific agent across the cluster by agent_id."
  defdelegate whereis_cluster(agent_id), to: Registry, as: :whereis_cluster

  @doc "Delete an agent and all its data."
  defdelegate destroy_agent(agent_id), to: Lifecycle, as: :destroy

  @doc "Load a single agent profile by ID."
  defdelegate load_profile(agent_id), to: ProfileStore

  @doc "Store an agent profile."
  defdelegate store_profile(profile), to: ProfileStore

  @doc "List all profiles with auto_start: true."
  defdelegate list_auto_start_profiles(), to: ProfileStore

  @doc "Set auto_start flag on an agent's persisted profile."
  defdelegate set_auto_start(agent_id, enabled), to: Arbor.Agent.Manager

  @doc "Update an agent's display name."
  defdelegate set_display_name(agent_id, name), to: Arbor.Agent.Manager

  @doc "Set MCP server configuration for an agent."
  defdelegate set_mcp_config(agent_id, servers), to: Arbor.Agent.Manager

  @doc "Connect to MCP servers configured in an agent's profile."
  defdelegate connect_mcp_servers(agent_id), to: Arbor.Agent.Manager

  # ===========================================================================
  # Public API — Authorized versions (for callers that need capability checks)
  # ===========================================================================

  @doc """
  Start a supervised agent with authorization check.

  Verifies the caller has the `arbor://agent/spawn` capability before
  creating the agent. Use this when spawning agents on behalf of another
  agent or external request.

  ## Parameters

  - `caller_id` - The ID of the entity requesting agent spawn
  - `agent_id` - Unique identifier for the new agent
  - `agent_module` - The Jido agent module to run
  - `initial_state` - Initial state map (default: %{})
  - `opts` - Additional options (same as `start/4`)

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, :unauthorized}` if caller lacks capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other failure
  """
  @spec authorize_spawn(String.t(), String.t(), module(), map(), keyword()) ::
          {:ok, pid()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | term()}
  def authorize_spawn(caller_id, agent_id, agent_module, initial_state \\ %{}, opts \\ []) do
    resource = "arbor://agent/spawn"

    case Arbor.Security.authorize(caller_id, resource, :spawn) do
      {:ok, :authorized} ->
        start(agent_id, agent_module, initial_state, opts)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Execute an action on a running agent with authorization check.

  Verifies the caller has the canonical facade capability (e.g. `arbor://fs/read`)
  before executing. Use this when an agent is executing actions on behalf of
  another agent or external request.

  ## Parameters

  - `caller_id` - The ID of the entity requesting action execution
  - `agent_id` - The target agent's ID
  - `action` - Action module or `{action_module, params}` tuple
  - `timeout` - Call timeout in ms (default: 5000)

  ## Returns

  - `{:ok, result}` on success
  - `{:error, :unauthorized}` if caller lacks capability
  - `{:ok, :pending_approval, proposal_id}` if escalation needed
  - `{:error, reason}` on other failure
  """
  @spec authorize_action(String.t(), String.t(), module() | {module(), map()}, timeout()) ::
          {:ok, any()}
          | {:ok, :pending_approval, String.t()}
          | {:error, :unauthorized | :not_found | any()}
  def authorize_action(caller_id, agent_id, action, timeout \\ 5000) do
    action_module = extract_action_module(action)
    resource = Arbor.Actions.canonical_uri_for(action_module, %{})

    case Arbor.Security.authorize(caller_id, resource, :execute) do
      {:ok, :authorized} ->
        run_action(agent_id, action, timeout)

      {:ok, :pending_approval, proposal_id} ->
        {:ok, :pending_approval, proposal_id}

      {:error, _reason} ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Stop a running agent with authorization check.

  Verifies the caller has the `arbor://agent/stop/{agent_id}` capability
  before stopping the agent.

  ## Parameters

  - `caller_id` - The ID of the entity requesting the stop
  - `agent_id` - The agent to stop

  ## Returns

  - `:ok` on success
  - `{:error, {:unauthorized, reason}}` if caller lacks capability
  - `{:error, :not_found}` if agent is not running
  """
  @spec authorize_stop(String.t(), String.t()) ::
          :ok | {:error, {:unauthorized, term()} | :not_found}
  def authorize_stop(caller_id, agent_id) do
    resource = "arbor://agent/stop/#{agent_id}"

    case authorize(caller_id, resource, :stop) do
      :ok -> stop(agent_id)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Create an agent with authorization check.

  Verifies the caller has the `arbor://agent/lifecycle/create` capability.

  ## Parameters

  - `caller_id` - The ID of the entity creating the agent
  - `agent_id` - The new agent's ID
  - `opts` - Options passed to `create_agent/2`
  """
  @spec authorize_create(String.t(), String.t(), keyword()) ::
          {:ok, term()} | {:error, {:unauthorized, term()} | term()}
  def authorize_create(caller_id, agent_id, opts \\ []) do
    resource = "arbor://agent/lifecycle/create"

    case authorize(caller_id, resource, :create) do
      :ok -> create_agent(agent_id, opts)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Destroy an agent with authorization check.

  Verifies the caller has the `arbor://agent/lifecycle/destroy` capability.
  This is a high-privilege operation that deletes all agent data.

  ## Parameters

  - `caller_id` - The ID of the entity requesting destruction
  - `agent_id` - The agent to destroy
  """
  @spec authorize_destroy(String.t(), String.t()) ::
          :ok | {:error, {:unauthorized, term()} | term()}
  def authorize_destroy(caller_id, agent_id) do
    resource = "arbor://agent/lifecycle/destroy"

    case authorize(caller_id, resource, :destroy) do
      :ok -> destroy_agent(agent_id)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  @doc """
  Restore an agent with authorization check.

  Verifies the caller has the `arbor://agent/lifecycle/restore` capability.

  ## Parameters

  - `caller_id` - The ID of the entity requesting the restore
  - `agent_id` - The agent to restore
  """
  @spec authorize_restore(String.t(), String.t()) ::
          {:ok, term()} | {:error, {:unauthorized, term()} | term()}
  def authorize_restore(caller_id, agent_id) do
    resource = "arbor://agent/lifecycle/restore"

    case authorize(caller_id, resource, :restore) do
      :ok -> restore_agent(agent_id)
      {:error, reason} -> {:error, {:unauthorized, reason}}
    end
  end

  # ===========================================================================
  # Public API — Unchecked versions (for system-level callers)
  # ===========================================================================

  @doc """
  Start a supervised agent.

  ## Parameters

  - `agent_id` - Unique identifier for the agent
  - `agent_module` - The Jido agent module to run
  - `initial_state` - Initial state map (default: %{})
  - `opts` - Additional options

  ## Options

  - `:checkpoint_storage` - Storage backend module (e.g., `Arbor.Persistence.Checkpoint.Store.ETS`)
  - `:auto_checkpoint_interval` - Auto-save interval in ms (e.g., 30_000)
  - `:metadata` - Additional metadata map
  - `:restart` - Supervision restart strategy (default: `:transient`)

  ## Returns

  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start(String.t(), module(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(_agent_id, _agent_module, _initial_state \\ %{}, _opts \\ []) do
    # Legacy Jido agent path — Agent.Server was removed.
    # Use Lifecycle.create + Lifecycle.start for all agent creation.
    Logger.warning("Arbor.Agent.start/4 is deprecated. Use Lifecycle.create + Lifecycle.start instead.")
    {:error, :deprecated_use_lifecycle}
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
  def run_action(agent_id, action, _timeout \\ 5000) do
    # Route through APIAgent.execute_action if host is running
    case Arbor.Agent.BranchSupervisor.child_pids(agent_id) do
      %{host: pid} when is_pid(pid) ->
        {action_module, params} =
          case action do
            {mod, p} -> {mod, p}
            mod when is_atom(mod) -> {mod, %{}}
          end

        Arbor.Agent.APIAgent.execute_action(pid, action_module, params)

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Get the current state of an agent.

  Returns the agent's metadata from the registry.
  """
  @spec get_state(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_state(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.metadata}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Get metadata for a running agent.
  """
  @spec get_metadata(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_metadata(agent_id) do
    case Registry.lookup(agent_id) do
      {:ok, entry} -> {:ok, entry.metadata}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  Manually trigger a checkpoint save for an agent.
  """
  @spec checkpoint(String.t()) :: :ok | {:error, term()}
  def checkpoint(_agent_id) do
    # Checkpointing is now handled by Session persistence, not Agent.Server
    :ok
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

  # ===========================================================================
  # Template Management
  # ===========================================================================

  @doc "List all available agent templates."
  @spec list_templates() :: [map()]
  defdelegate list_templates(), to: Arbor.Agent.TemplateStore, as: :list

  @doc "Get a template by name."
  @spec get_template(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_template(name), to: Arbor.Agent.TemplateStore, as: :get

  @doc "Store a template by name."
  @spec put_template(String.t(), map()) :: :ok | {:error, term()}
  defdelegate put_template(name, data), to: Arbor.Agent.TemplateStore, as: :put

  @doc "Delete a template by name."
  @spec delete_template(String.t()) :: :ok | {:error, :builtin_protected}
  defdelegate delete_template(name), to: Arbor.Agent.TemplateStore, as: :delete

  @doc "Create a template from keyword options."
  @spec create_template(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate create_template(name, opts), to: Arbor.Agent.TemplateStore, as: :create_from_opts

  @doc "Reload all templates from disk."
  @spec reload_templates() :: :ok
  defdelegate reload_templates(), to: Arbor.Agent.TemplateStore, as: :reload

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  # Shared authorization helper for new lifecycle wrappers.
  # Guards against CapabilityStore not running (e.g., in unit tests
  # that don't start the full security supervision tree).
  defp authorize(caller_id, resource, action) do
    if security_available?() do
      case Arbor.Security.authorize(caller_id, resource, action) do
        {:ok, :authorized} -> :ok
        {:ok, :pending_approval, _proposal_id} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp security_available? do
    Process.whereis(Arbor.Security.CapabilityStore) != nil
  end

  # Extract the action module from an action spec (module or {module, params} tuple)
  defp extract_action_module({action_module, _params}) when is_atom(action_module) do
    action_module
  end

  defp extract_action_module(action_module) when is_atom(action_module) do
    action_module
  end
end
