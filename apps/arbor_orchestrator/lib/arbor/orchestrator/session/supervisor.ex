defmodule Arbor.Orchestrator.Session.Supervisor do
  @moduledoc """
  DynamicSupervisor for managing Session GenServer lifecycle.

  Sessions are started under this supervisor and registered in
  `Arbor.Orchestrator.SessionRegistry` for lookup by session_id.

  ## Example

      {:ok, pid} = Supervisor.start_session(
        session_id: "session-1",
        agent_id: "agent_abc",
        trust_tier: :established,
        turn_dot: "specs/pipelines/session/turn.dot",
        heartbeat_dot: "specs/pipelines/session/heartbeat.dot"
      )

      Supervisor.list_sessions()
      #=> [{"session-1", #PID<0.123.0>}]
  """

  use DynamicSupervisor

  alias Arbor.Orchestrator.Session

  @registry Arbor.Orchestrator.SessionRegistry

  # ── Startup ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Public API ──────────────────────────────────────────────────────

  @doc """
  Start a Session child under this supervisor.

  Takes the same opts as `Session.start_link/1`. The session is
  automatically registered in the SessionRegistry under its session_id.
  """
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    # Register in the SessionRegistry for session_id -> pid lookup
    opts = Keyword.put(opts, :name, {:via, Registry, {@registry, session_id}})

    DynamicSupervisor.start_child(__MODULE__, {Session, opts})
  end

  @doc """
  Terminate a session by pid or session_id.
  """
  @spec stop_session(pid() | String.t()) :: :ok | {:error, :not_found}
  def stop_session(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  def stop_session(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> stop_session(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all active sessions as `{session_id, pid}` tuples.
  """
  @spec list_sessions() :: [{String.t(), pid()}]
  def list_sessions do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Return the number of active sessions.
  """
  @spec count() :: non_neg_integer()
  def count do
    %{active: active} = DynamicSupervisor.count_children(__MODULE__)
    active
  end
end
