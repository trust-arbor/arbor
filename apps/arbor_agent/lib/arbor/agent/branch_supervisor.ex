defmodule Arbor.Agent.BranchSupervisor do
  @moduledoc """
  Per-agent supervisor that groups all agent sub-processes.

  Uses `rest_for_one` strategy so that if a foundational process
  crashes, all processes that depend on it are restarted too:

  1. **APIAgent host** — the query interface. If it dies, restart executor + session.
  2. **Executor** — intent execution. If it dies, restart session (depends on executor for percepts).
  3. **Session** — DOT pipeline execution. Restarted independently if it crashes alone.

  Started under `Arbor.Agent.Supervisor` (DynamicSupervisor) by `Lifecycle.start`.

  ## Usage

      BranchSupervisor.start_link(
        agent_id: "agent_abc123",
        host_opts: [id: "agent_abc123", model: "gemini-3-flash", provider: :openrouter],
        executor_opts: [agent_id: "agent_abc123", trust_tier: :established],
        session_opts: [session_id: "agent-session-abc123", ...]
      )
  """

  use Supervisor

  require Logger

  alias Arbor.Agent.{APIAgent, Executor}

  @session_module Arbor.Orchestrator.Session

  @doc """
  Start the branch supervisor for an agent.

  ## Options

  - `:agent_id` — required, the agent's unique ID
  - `:host_opts` — keyword list for APIAgent.start_link
  - `:executor_opts` — keyword list for Executor.start_link
  - `:session_opts` — keyword list for Session init (nil to skip session)
  - `:start_session` — whether to start a session (default: true)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    name = via(agent_id)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Look up the branch supervisor PID for an agent.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(agent_id) do
    case Registry.lookup(Arbor.Agent.ExecutorRegistry, {:branch, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Get the PIDs of all child processes for an agent.

  Returns a map with keys :host, :executor, :session (session may be nil).
  """
  @spec child_pids(String.t()) :: %{
          host: pid() | nil,
          executor: pid() | nil,
          session: pid() | nil
        }
  def child_pids(agent_id) do
    case whereis(agent_id) do
      nil ->
        %{host: nil, executor: nil, session: nil}

      sup_pid ->
        children = Supervisor.which_children(sup_pid)

        %{
          host: find_child_pid(children, :host),
          executor: find_child_pid(children, :executor),
          session: find_child_pid(children, :session)
        }
    end
  end

  # ── Supervisor callback ────────────────────────────────────────────

  @impl true
  def init(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    host_opts = Keyword.get(opts, :host_opts, [])
    executor_opts = Keyword.get(opts, :executor_opts, [])
    session_opts = Keyword.get(opts, :session_opts)
    heartbeat_opts = Keyword.get(opts, :heartbeat_opts)
    start_session = Keyword.get(opts, :start_session, true)

    children =
      [
        # Child 1: APIAgent host — query interface
        host_child_spec(agent_id, host_opts),
        # Child 2: Executor — intent processing
        executor_child_spec(agent_id, executor_opts)
      ]
      |> maybe_add_session(agent_id, session_opts, start_session)
      # Child 4 (optional): HeartbeatService — autonomous heartbeat cycles.
      # MUST be AFTER Session in the child list. With rest_for_one:
      #   Session crash → HeartbeatService also dies + restarts (no orphans)
      #   HeartbeatService crash → only HeartbeatService restarts (doesn't kill Session)
      |> maybe_add_heartbeat_service(agent_id, heartbeat_opts, session_opts)

    Logger.info("[BranchSupervisor] Starting for #{agent_id} with #{length(children)} children")

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 5, max_seconds: 60)
  end

  # ── Child specs ────────────────────────────────────────────────────

  defp host_child_spec(agent_id, host_opts) do
    # Ensure the host registers in ExecutorRegistry under {:host, agent_id}
    # Skip executor creation in AgentSeed — BranchSupervisor manages it as a separate child
    host_opts =
      host_opts
      |> Keyword.put_new(:id, agent_id)
      |> Keyword.put(:name, {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:host, agent_id}}})
      |> Keyword.put(:skip_executor, true)

    %{
      id: :host,
      start: {APIAgent, :start_link, [host_opts]},
      restart: :permanent,
      type: :worker
    }
  end

  defp executor_child_spec(agent_id, executor_opts) do
    # Executor registers itself via {:via, Registry, {ExecutorRegistry, agent_id}}
    %{
      id: :executor,
      start: {Executor, :start_link, [agent_id, executor_opts]},
      restart: :permanent,
      type: :worker
    }
  end

  defp maybe_add_session(children, _agent_id, _session_opts, false), do: children
  defp maybe_add_session(children, _agent_id, nil, _), do: children

  defp maybe_add_session(children, _agent_id, session_opts, true) do
    if Code.ensure_loaded?(@session_module) do
      child = %{
        id: :session,
        start: {GenServer, :start_link, [@session_module, session_opts, []]},
        restart: :permanent,
        type: :worker
      }

      children ++ [child]
    else
      children
    end
  end

  defp maybe_add_heartbeat_service(children, _agent_id, nil, _session_opts), do: children

  defp maybe_add_heartbeat_service(children, _agent_id, heartbeat_opts, session_opts) do
    heartbeat_config = Keyword.get(heartbeat_opts, :heartbeat_config, %{})
    enabled = Map.get(heartbeat_config, :enabled, true)

    if enabled and Code.ensure_loaded?(Arbor.Orchestrator.HeartbeatService) do
      # HeartbeatService receives the same agent_id, signer, trust_tier
      # as Session — extracted from the shared session_opts.
      service_opts =
        heartbeat_opts
        |> Keyword.put_new(:heartbeat_dot, session_opts[:heartbeat_dot])

      child = %{
        id: :heartbeat_service,
        start: {Arbor.Orchestrator.HeartbeatService, :start_link, [service_opts]},
        restart: :permanent,
        type: :worker
      }

      children ++ [child]
    else
      children
    end
  end

  defp find_child_pid(children, id) do
    case Enum.find(children, fn {child_id, _, _, _} -> child_id == id end) do
      {_, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp via(agent_id) do
    {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, agent_id}}}
  end
end
