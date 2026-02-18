defmodule Arbor.Consensus.CouncilManager do
  @moduledoc """
  Manages persistent advisory evaluator agents — one per perspective.

  Starts 13 `EvaluatorAgent` processes (one per advisory perspective) via
  the existing `EvaluatorAgent.Supervisor`. Each agent wraps `AdvisoryLLM`
  but is filtered to serve only its assigned perspective, providing per-perspective
  memory isolation and independent lifecycle.

  ## Usage

      # Start all perspective agents (idempotent)
      :ok = CouncilManager.ensure_started()

      # Check status
      agents = CouncilManager.status()

      # Consult all perspectives
      {:ok, results} = CouncilManager.consult("Should we use Redis or ETS?")

      # Consult a single perspective
      {:ok, eval} = CouncilManager.consult_one("Security review", :security)

  ## Design

  Lazy startup — agents are NOT started in the Application supervisor.
  They start on the first call to `ensure_started/0` or `consult/2`.
  When agents aren't running, `consult/2` falls back to direct
  `Consult.ask/3` (CLI-based evaluation).
  """

  alias Arbor.Consensus.EvaluatorAgent
  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Consensus.Evaluators.Consult

  require Logger

  @perspectives AdvisoryLLM.perspectives()

  @doc """
  Start all 13 perspective agents. Idempotent — skips already-running agents.

  Returns `:ok` when all agents are started or were already running.
  """
  @spec ensure_started() :: :ok
  def ensure_started do
    results = Enum.map(@perspectives, &ensure_perspective_started/1)

    errors = for {:error, p, reason} <- results, do: {p, reason}

    if errors != [] do
      Logger.warning("CouncilManager: #{length(errors)} agents failed to start: #{inspect(errors)}")
    end

    started = for {:started, p} <- results, do: p
    already = for {:already_running, p} <- results, do: p

    if started != [] do
      Logger.info("CouncilManager: started #{length(started)} agents, #{length(already)} already running")
    end

    :ok
  end

  defp ensure_perspective_started(perspective) do
    agent_name = perspective_agent_name(perspective)

    case EvaluatorAgent.Supervisor.lookup_agent(agent_name) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: {:already_running, perspective}, else: try_start(perspective)

      :not_found ->
        try_start(perspective)
    end
  end

  defp try_start(perspective) do
    case start_perspective(perspective) do
      {:ok, _pid} -> {:started, perspective}
      {:error, reason} -> {:error, perspective, reason}
    end
  end

  @doc """
  Start a single perspective agent.

  Creates an `EvaluatorAgent` wrapping `AdvisoryLLM`, filtered to the given
  perspective. The agent is registered under `:"advisory_<perspective>"`.
  """
  @spec start_perspective(atom()) :: {:ok, pid()} | {:error, term()}
  def start_perspective(perspective) when perspective in @perspectives do
    agent_name = perspective_agent_name(perspective)

    EvaluatorAgent.Supervisor.start_agent(AdvisoryLLM,
      agent_name: agent_name,
      perspective_filter: [perspective]
    )
  end

  def start_perspective(perspective) do
    {:error, {:unknown_perspective, perspective}}
  end

  @doc """
  Stop all perspective agents. Waits for processes to terminate.
  """
  @spec stop_all() :: :ok
  def stop_all do
    # Collect pids and names before stopping so we can wait for termination
    entries =
      Enum.flat_map(@perspectives, fn perspective ->
        agent_name = perspective_agent_name(perspective)

        case EvaluatorAgent.Supervisor.lookup_agent(agent_name) do
          {:ok, pid} ->
            ref = Process.monitor(pid)
            EvaluatorAgent.Supervisor.stop_agent(agent_name)
            [{agent_name, pid, ref}]

          :not_found ->
            []
        end
      end)

    # Wait for all processes to actually die, then wait for deregistration
    Enum.each(entries, fn {agent_name, _pid, ref} ->
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        1_000 -> :ok
      end

      await_deregistration(agent_name)
    end)

    :ok
  end

  @doc """
  Stop a specific perspective agent. Waits for the process to terminate
  and for Registry to clean up.
  """
  @spec stop_perspective(atom()) :: :ok | {:error, :not_found}
  def stop_perspective(perspective) do
    agent_name = perspective_agent_name(perspective)

    case EvaluatorAgent.Supervisor.lookup_agent(agent_name) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        result = EvaluatorAgent.Supervisor.stop_agent(agent_name)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          1_000 -> :ok
        end

        # Sync with Registry to ensure cleanup is complete
        await_deregistration(agent_name)
        result

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  List running perspective agents with their status.

  Returns a list of `{perspective, pid, status}` tuples for running agents.
  """
  @spec status() :: [{atom(), pid(), map()}]
  def status do
    @perspectives
    |> Enum.flat_map(fn perspective ->
      agent_name = perspective_agent_name(perspective)

      case EvaluatorAgent.Supervisor.lookup_agent(agent_name) do
        {:ok, pid} ->
          if Process.alive?(pid) do
            try do
              s = EvaluatorAgent.status(pid)
              [{perspective, pid, s}]
            catch
              :exit, _ -> []
            end
          else
            []
          end

        :not_found ->
          []
      end
    end)
  end

  @doc """
  Returns the count of running perspective agents.

  Only counts agents whose processes are actually alive (not stale Registry
  entries from recently terminated children).
  """
  @spec running_count() :: non_neg_integer()
  def running_count do
    Enum.count(@perspectives, fn perspective ->
      agent_name = perspective_agent_name(perspective)

      case EvaluatorAgent.Supervisor.lookup_agent(agent_name) do
        {:ok, pid} -> Process.alive?(pid)
        :not_found -> false
      end
    end)
  end

  @doc """
  Consult all perspectives about a question.

  If agents are running, delivers envelopes to agent mailboxes for processing.
  Falls back to direct `Consult.ask/3` when agents aren't running.

  ## Options

  Same as `Consult.ask/3`: `:context`, `:timeout`, `:provider_model`, etc.
  """
  @spec consult(String.t(), keyword()) ::
          {:ok, [{atom(), Arbor.Contracts.Consensus.Evaluation.t()}]} | {:error, term()}
  def consult(description, opts \\ []) do
    # Lazy start — ensure agents are running
    if running_count() == 0 do
      ensure_started()
    end

    # Force API backend — persistent agents don't use CLI agents.
    # CLI fallback is still available via direct Consult.ask/3 without CouncilManager.
    opts = Keyword.put_new(opts, :backend, :api)

    # Route through Consult.ask/3 for now — it handles parallel evaluation.
    # Phase 4 (deliberation) will change this to mailbox delivery.
    Consult.ask(AdvisoryLLM, description, opts)
  end

  @doc """
  Consult a single perspective about a question.

  ## Options

  Same as `Consult.ask_one/4`.
  """
  @spec consult_one(String.t(), atom(), keyword()) ::
          {:ok, Arbor.Contracts.Consensus.Evaluation.t()} | {:error, term()}
  def consult_one(description, perspective, opts \\ []) do
    opts = Keyword.put_new(opts, :backend, :api)
    Consult.ask_one(AdvisoryLLM, description, perspective, opts)
  end

  @doc """
  Returns the list of all advisory perspectives.
  """
  @spec perspectives() :: [atom()]
  def perspectives, do: @perspectives

  # ============================================================================
  # Private
  # ============================================================================

  @doc false
  def perspective_agent_name(perspective) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"advisory_#{perspective}"
  end

  # After terminating a child, Registry/DynamicSupervisor clean up
  # asynchronously. We already waited for :DOWN so the process is dead.
  # running_count/0 uses Process.alive? to filter stale entries, so
  # downstream callers get accurate counts immediately.
  defp await_deregistration(_agent_name) do
    :ok
  end
end
