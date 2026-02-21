defmodule Arbor.Sandbox.ExecSession do
  @moduledoc """
  Persistent per-agent code execution sandbox backed by Dune.

  Wraps `Dune.Session` in a GenServer to provide stateful code evaluation
  where variable bindings and module definitions persist across evaluations.

  ## Usage

      {:ok, pid} = ExecSession.start_link(agent_id: "agent_001")
      {:ok, "2"} = ExecSession.eval(pid, "1 + 1")
      {:ok, "42"} = ExecSession.eval(pid, "x = 42")
      {:ok, "43"} = ExecSession.eval(pid, "x + 1")

  ## Safety

  Dune provides sandboxing by default:
  - Restricted module access (no File, System, etc.)
  - Memory limits via max_heap_size
  - CPU limits via max_reductions
  - Timeout per evaluation
  - No atom leaks
  """

  use GenServer

  require Logger

  @default_timeout 5_000
  @default_max_reductions 100_000
  @default_max_heap_size 100_000

  # ── Public API ──────────────────────────────────────────────

  @doc """
  Start an ExecSession linked to the calling process.

  ## Options

  - `:agent_id` (required) — the owning agent's ID
  - `:timeout` — per-eval timeout in ms (default: #{@default_timeout})
  - `:max_reductions` — CPU limit (default: #{@default_max_reductions})
  - `:max_heap_size` — memory limit (default: #{@default_max_heap_size})
  - `:name` — GenServer name (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, {agent_id, opts}, gen_opts)
  end

  @doc """
  Evaluate Elixir code in the session.

  Variable bindings persist across evaluations. If evaluation fails,
  the session state is preserved (Dune rolls back on failure).

  ## Options

  - `:timeout` — override the session default timeout

  ## Returns

  - `{:ok, result_string}` — the inspected result
  - `{:ok, result_string, stdio}` — result with captured stdout
  - `{:error, message}` — evaluation failed
  """
  @spec eval(GenServer.server(), String.t(), keyword()) ::
          {:ok, String.t()} | {:ok, String.t(), String.t()} | {:error, String.t()}
  def eval(pid, code, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 10_000)
    GenServer.call(pid, {:eval, code, opts}, timeout)
  end

  @doc """
  Reset the session, clearing all bindings and modules.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(pid) do
    GenServer.call(pid, :reset)
  end

  @doc """
  Get session statistics.

  Returns a map with:
  - `:agent_id` — owning agent
  - `:execution_count` — number of evaluations run
  - `:created_at` — when the session was created
  - `:uptime_seconds` — seconds since creation
  """
  @spec stats(GenServer.server()) :: map()
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  # ── GenServer callbacks ─────────────────────────────────────

  @impl true
  def init({agent_id, opts}) do
    state = %{
      agent_id: agent_id,
      session: Dune.Session.new(),
      execution_count: 0,
      created_at: System.monotonic_time(:second),
      eval_opts: build_eval_opts(opts)
    }

    Logger.debug("[ExecSession] Started for agent #{agent_id}")
    {:ok, state}
  end

  @impl true
  def handle_call({:eval, code, call_opts}, _from, state) do
    opts = merge_eval_opts(state.eval_opts, call_opts)

    dune_opts = [
      timeout: opts.timeout,
      max_reductions: opts.max_reductions,
      max_heap_size: opts.max_heap_size
    ]

    new_session = Dune.Session.eval_string(state.session, code, dune_opts)

    case new_session.last_result do
      %Dune.Success{inspected: inspected, stdio: stdio} ->
        state = %{state | session: new_session, execution_count: state.execution_count + 1}

        if stdio != "" do
          {:reply, {:ok, inspected, stdio}, state}
        else
          {:reply, {:ok, inspected}, state}
        end

      %Dune.Failure{message: message} ->
        # Dune preserves prior state on failure, so session stays valid
        state = %{state | session: new_session, execution_count: state.execution_count + 1}
        {:reply, {:error, message}, state}
    end
  end

  def handle_call(:reset, _from, state) do
    Logger.debug("[ExecSession] Reset for agent #{state.agent_id}")

    {:reply, :ok, %{state | session: Dune.Session.new(), execution_count: 0}}
  end

  def handle_call(:stats, _from, state) do
    now = System.monotonic_time(:second)

    stats = %{
      agent_id: state.agent_id,
      execution_count: state.execution_count,
      created_at: state.created_at,
      uptime_seconds: now - state.created_at
    }

    {:reply, stats, state}
  end

  # ── Private ─────────────────────────────────────────────────

  defp build_eval_opts(opts) do
    %{
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      max_reductions: Keyword.get(opts, :max_reductions, @default_max_reductions),
      max_heap_size: Keyword.get(opts, :max_heap_size, @default_max_heap_size)
    }
  end

  defp merge_eval_opts(defaults, call_opts) do
    %{
      timeout: Keyword.get(call_opts, :timeout, defaults.timeout),
      max_reductions: Keyword.get(call_opts, :max_reductions, defaults.max_reductions),
      max_heap_size: Keyword.get(call_opts, :max_heap_size, defaults.max_heap_size)
    }
  end
end
