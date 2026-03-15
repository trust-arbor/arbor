defmodule Arbor.Agent.UserSupervisor do
  @moduledoc """
  Per-user process isolation via on-demand DynamicSupervisors.

  Creates a DynamicSupervisor for each principal ID on first use.
  Agents started with a `principal_id` are supervised under their user's
  supervisor, providing:

  1. **Process isolation** — one user's agent crash doesn't affect another user
  2. **Process quotas** — configurable max agents per user
  3. **Clean shutdown** — terminate all agents for a specific user

  When no principal_id is provided, agents fall through to the global
  `Arbor.Agent.Supervisor` (backward compatible with single-user mode).

  ## Architecture

      Arbor.Agent.UserSupervisor (this module, DynamicSupervisor)
        ├── user_sup:human_abc123 (DynamicSupervisor)
        │     ├── agent_001 (Agent.Server)
        │     └── agent_002 (Agent.Server)
        └── user_sup:human_def456 (DynamicSupervisor)
              └── agent_003 (Agent.Server)

  ## Usage

      # Start agent under user's supervisor
      UserSupervisor.start_child(
        agent_id: "agent_001",
        module: Arbor.Agent.Server,
        principal_id: "human_abc123"
      )

      # List agents for a user
      UserSupervisor.which_agents("human_abc123")

      # Stop all agents for a user
      UserSupervisor.terminate_user("human_abc123")
  """

  use DynamicSupervisor

  require Logger

  @default_max_agents 10

  # ── Supervision ─────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl DynamicSupervisor
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start a child process under a user's supervisor.

  Creates the user's DynamicSupervisor on first use. Enforces per-user
  process quotas.

  ## Options

  - `:agent_id` — required, unique identifier
  - `:module` — required, the GenServer module to start
  - `:principal_id` — required, the user's principal ID
  - `:start_opts` — keyword list passed to `module.start_link/1`
  - `:metadata` — map registered alongside the agent
  - `:restart` — restart strategy (default: `:transient`)
  """
  @spec start_child(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_child(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    module = Keyword.fetch!(opts, :module)
    principal_id = Keyword.fetch!(opts, :principal_id)
    start_opts = Keyword.get(opts, :start_opts, [])
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, user_sup} <- ensure_user_supervisor(principal_id),
         :ok <- check_quota(user_sup, principal_id) do
      child_spec = %{
        id: agent_id,
        start: {module, :start_link, [start_opts]},
        restart: Keyword.get(opts, :restart, :transient),
        type: :worker
      }

      case DynamicSupervisor.start_child(user_sup, child_spec) do
        {:ok, pid} ->
          # Register in the global registry with principal_id metadata
          Arbor.Agent.Registry.register(
            agent_id,
            pid,
            Map.merge(metadata, %{module: module, principal_id: principal_id})
          )

          Logger.info(
            "Agent started under user supervisor: #{agent_id} " <>
              "(#{inspect(module)}, principal: #{principal_id})"
          )

          {:ok, pid}

        {:error, reason} = error ->
          Logger.error("Failed to start agent #{agent_id}: #{inspect(reason)}")
          error
      end
    end
  end

  @doc """
  Start a raw child spec under a user's supervisor (for BranchSupervisor).

  Unlike `start_child/1`, this accepts a pre-built child spec and does NOT
  register in Agent.Registry (registration is handled by the caller).
  """
  @spec start_child_spec(String.t(), map()) :: {:ok, pid()} | {:error, term()}
  def start_child_spec(principal_id, child_spec) do
    with {:ok, user_sup} <- ensure_user_supervisor(principal_id),
         :ok <- check_quota(user_sup, principal_id) do
      DynamicSupervisor.start_child(user_sup, child_spec)
    end
  end

  @doc """
  List all agent PIDs supervised under a specific user.
  """
  @spec which_agents(String.t()) :: [pid()]
  def which_agents(principal_id) do
    case lookup_user_supervisor(principal_id) do
      {:ok, user_sup} ->
        DynamicSupervisor.which_children(user_sup)
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
        |> Enum.filter(&is_pid/1)

      {:error, :not_found} ->
        []
    end
  end

  @doc """
  Count agents for a specific user.
  """
  @spec count_agents(String.t()) :: non_neg_integer()
  def count_agents(principal_id) do
    case lookup_user_supervisor(principal_id) do
      {:ok, user_sup} ->
        DynamicSupervisor.count_children(user_sup)
        |> Map.get(:active, 0)

      {:error, :not_found} ->
        0
    end
  end

  @doc """
  Terminate all agents for a user and remove their supervisor.
  """
  @spec terminate_user(String.t()) :: :ok
  def terminate_user(principal_id) do
    case lookup_user_supervisor(principal_id) do
      {:ok, user_sup} ->
        DynamicSupervisor.terminate_child(__MODULE__, user_sup)
        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  List all principal IDs that have active supervisors.
  """
  @spec active_users() :: [String.t()]
  def active_users do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_id, pid, _type, _modules} ->
      if is_pid(pid), do: process_principal_id(pid)
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Get the maximum number of agents allowed per user.
  """
  @spec max_agents_per_user() :: non_neg_integer()
  def max_agents_per_user do
    Application.get_env(:arbor_agent, :max_agents_per_user, @default_max_agents)
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp ensure_user_supervisor(principal_id) do
    case lookup_user_supervisor(principal_id) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        create_user_supervisor(principal_id)
    end
  end

  defp create_user_supervisor(principal_id) do
    name = user_supervisor_name(principal_id)

    child_spec = %{
      id: name,
      start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: name]]},
      restart: :transient,
      type: :supervisor
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        # Store principal_id in process dictionary for reverse lookup
        # (the DynamicSupervisor process is already started, so we use
        # the registered name for lookups instead)
        Logger.info("Created user supervisor for #{principal_id}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to create user supervisor for #{principal_id}: #{inspect(reason)}")
        error
    end
  end

  defp lookup_user_supervisor(principal_id) do
    name = user_supervisor_name(principal_id)

    case Process.whereis(name) do
      nil -> {:error, :not_found}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp check_quota(user_sup, principal_id) do
    max = max_agents_per_user()
    current = DynamicSupervisor.count_children(user_sup) |> Map.get(:active, 0)

    if current < max do
      :ok
    else
      Logger.warning("User #{principal_id} has reached agent quota (#{max})")
      {:error, {:quota_exceeded, max}}
    end
  end

  defp user_supervisor_name(principal_id) do
    # Use a deterministic atom for the supervisor name
    # Safe because principal_ids are system-generated (human_<hash>)
    :"user_sup:#{principal_id}"
  end

  defp process_principal_id(pid) do
    name = Process.info(pid, :registered_name)

    case name do
      {:registered_name, name} when is_atom(name) ->
        name_str = Atom.to_string(name)

        if String.starts_with?(name_str, "user_sup:") do
          String.replace_prefix(name_str, "user_sup:", "")
        end

      _ ->
        nil
    end
  end
end
