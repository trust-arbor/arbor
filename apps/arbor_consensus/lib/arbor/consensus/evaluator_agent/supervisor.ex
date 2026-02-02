defmodule Arbor.Consensus.EvaluatorAgent.Supervisor do
  @moduledoc """
  DynamicSupervisor for EvaluatorAgent processes.

  Manages the lifecycle of persistent evaluator agents. Agents can be
  started at system boot (for required evaluators) or dynamically when
  new evaluators are registered via `:topic_governance`.

  ## Usage

      # Start an agent for a specific evaluator
      {:ok, pid} = EvaluatorAgent.Supervisor.start_agent(MyApp.SecurityEvaluator)

      # Get all running agents
      agents = EvaluatorAgent.Supervisor.list_agents()

      # Stop an agent
      :ok = EvaluatorAgent.Supervisor.stop_agent(:security_advisor)
  """

  use DynamicSupervisor

  alias Arbor.Consensus.EvaluatorAgent

  require Logger

  @registry Arbor.Consensus.EvaluatorAgent.Registry

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Start the supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start an evaluator agent under supervision.

  ## Options

  - `:evaluator` (required) — module implementing `Arbor.Contracts.Consensus.Evaluator`
  - `:mailbox_size` — max mailbox size (default: 100)
  - `:reserved_high_priority` — reserved high priority slots (default: 10)

  Returns `{:error, :already_started}` if an agent for this evaluator is already running.
  """
  @spec start_agent(module(), keyword()) ::
          {:ok, pid()} | {:error, :already_started | term()}
  def start_agent(evaluator, opts \\ []) do
    start_agent(__MODULE__, evaluator, opts)
  end

  @doc """
  Start an evaluator agent under a specific supervisor.
  """
  @spec start_agent(Supervisor.supervisor(), module(), keyword()) ::
          {:ok, pid()} | {:error, :already_started | term()}
  def start_agent(supervisor, evaluator, opts) do
    name = evaluator.name()

    # Check if already running
    case lookup_agent(name) do
      {:ok, _pid} ->
        {:error, :already_started}

      :not_found ->
        do_start_agent(supervisor, evaluator, opts)
    end
  end

  @doc """
  Stop an evaluator agent.
  """
  @spec stop_agent(atom()) :: :ok | {:error, :not_found}
  def stop_agent(name) do
    stop_agent(__MODULE__, name)
  end

  @doc """
  Stop an evaluator agent under a specific supervisor.
  """
  @spec stop_agent(Supervisor.supervisor(), atom()) :: :ok | {:error, :not_found}
  def stop_agent(supervisor, name) do
    case lookup_agent(name) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(supervisor, pid)

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  List all running evaluator agents.

  Returns a list of `{name, pid, status}` tuples.
  """
  @spec list_agents() :: [{atom(), pid(), map()}]
  def list_agents do
    list_agents(__MODULE__)
  end

  @doc """
  List all running evaluator agents under a specific supervisor.
  """
  @spec list_agents(Supervisor.supervisor()) :: [{atom(), pid(), map()}]
  def list_agents(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, _} when is_pid(pid) ->
        try do
          status = EvaluatorAgent.status(pid)
          [{status.name, pid, status}]
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end)
  end

  @doc """
  Lookup an agent by name.
  """
  @spec lookup_agent(atom()) :: {:ok, pid()} | :not_found
  def lookup_agent(name) do
    # Try Registry first
    case Registry.lookup(@registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> lookup_agent_by_scan(name)
    end
  rescue
    # Registry might not exist
    ArgumentError -> lookup_agent_by_scan(name)
  end

  @doc """
  Deliver a proposal to an agent by evaluator name.
  """
  @spec deliver_to(atom(), EvaluatorAgent.envelope(), :high | :normal) ::
          :ok | {:error, :agent_not_found | :mailbox_full}
  def deliver_to(name, envelope, priority \\ :normal) do
    case lookup_agent(name) do
      {:ok, pid} ->
        EvaluatorAgent.deliver(pid, envelope, priority)

      :not_found ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Get the count of running agents.
  """
  @spec agent_count() :: non_neg_integer()
  def agent_count do
    agent_count(__MODULE__)
  end

  @doc """
  Get the count of running agents under a specific supervisor.
  """
  @spec agent_count(Supervisor.supervisor()) :: non_neg_integer()
  def agent_count(supervisor) do
    DynamicSupervisor.count_children(supervisor)[:active] || 0
  end

  # =============================================================================
  # Supervisor Callbacks
  # =============================================================================

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp do_start_agent(supervisor, evaluator, opts) do
    name = evaluator.name()

    # Use Registry for name registration if available
    registered_name =
      if registry_available?() do
        {:via, Registry, {@registry, name}}
      else
        nil
      end

    agent_opts =
      opts
      |> Keyword.put(:evaluator, evaluator)
      |> Keyword.put(:name, registered_name)

    child_spec = %{
      id: name,
      start: {EvaluatorAgent, :start_link, [agent_opts]},
      restart: :permanent,
      type: :worker
    }

    case DynamicSupervisor.start_child(supervisor, child_spec) do
      {:ok, pid} ->
        Logger.info("Started EvaluatorAgent for #{name}")
        {:ok, pid}

      {:error, {:already_started, _pid}} ->
        {:error, :already_started}

      {:error, reason} = error ->
        Logger.error("Failed to start EvaluatorAgent for #{name}: #{inspect(reason)}")
        error
    end
  end

  defp lookup_agent_by_scan(name) do
    # Fallback: scan all children (less efficient)
    result =
      __MODULE__
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {:undefined, pid, :worker, _} when is_pid(pid) ->
          try do
            status = EvaluatorAgent.status(pid)

            if status.name == name do
              pid
            end
          catch
            :exit, _ -> nil
          end

        _ ->
          nil
      end)

    case result do
      nil -> :not_found
      pid -> {:ok, pid}
    end
  rescue
    # Supervisor might not be running
    _ -> :not_found
  end

  defp registry_available? do
    case Process.whereis(@registry) do
      nil -> false
      _ -> true
    end
  end
end
