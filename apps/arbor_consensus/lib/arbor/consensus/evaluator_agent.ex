defmodule Arbor.Consensus.EvaluatorAgent do
  @moduledoc """
  Persistent GenServer wrapping an Evaluator behaviour.

  An EvaluatorAgent is a long-running process that:
  - Owns a bounded mailbox for proposal envelopes
  - Processes proposals sequentially from its queue
  - Sends evaluation results back to the Coordinator
  - Maintains continuity across proposals (unlike spawn-and-discard)
  - Optionally integrates with a memory adapter for cross-proposal context

  ## Lifecycle

  EvaluatorAgents are started by the EvaluatorAgent.Supervisor and remain
  running for the lifetime of the consensus system. The Coordinator delivers
  proposals to agent mailboxes rather than spawning temporary processes.

  ## Memory Integration

  When a `:memory_adapter` is provided, the agent will:
  1. Before evaluating: recall similar proposals to provide context
  2. After evaluating: store the proposal description and outcome

  Memory is opt-in via dependency injection — no arbor_memory dependency required.
  See `Arbor.Consensus.EvaluatorAgent.MemoryAdapter` for the behaviour.

  ## Mailbox Processing

  The agent processes envelopes in priority order:
  1. High priority (governance proposals) first
  2. Normal priority in FIFO order within class

  Each envelope contains:
  - `:proposal` — the proposal to evaluate
  - `:perspectives` — which perspectives to evaluate from
  - `:reply_to` — where to send results (Coordinator pid)
  - `:deadline` — when the evaluation must complete by

  ## Example

      # Start an agent for a specific evaluator
      {:ok, pid} = EvaluatorAgent.start_link(
        evaluator: MyApp.SecurityEvaluator,
        name: {:via, Registry, {EvaluatorRegistry, :security_advisor}}
      )

      # Start with memory adapter
      {:ok, pid} = EvaluatorAgent.start_link(
        evaluator: MyApp.SecurityEvaluator,
        memory_adapter: MyApp.MemoryAdapter
      )

      # Deliver a proposal envelope
      :ok = EvaluatorAgent.deliver(pid, envelope, :high)
  """

  use GenServer

  alias Arbor.Contracts.Consensus.AgentMailbox

  require Logger

  defstruct [
    :evaluator,
    :name,
    :mailbox,
    :current_envelope,
    :processing_task,
    :memory_adapter,
    evaluations_processed: 0,
    started_at: nil
  ]

  @type envelope :: %{
          proposal: map(),
          perspectives: [atom()],
          reply_to: pid(),
          deadline: DateTime.t() | nil,
          priority: :high | :normal
        }

  @type t :: %__MODULE__{
          evaluator: module(),
          name: atom(),
          mailbox: AgentMailbox.t(),
          current_envelope: envelope() | nil,
          processing_task: reference() | nil,
          memory_adapter: module() | nil,
          evaluations_processed: non_neg_integer(),
          started_at: DateTime.t()
        }

  # =============================================================================
  # Memory Adapter Behaviour
  # =============================================================================

  defmodule MemoryAdapter do
    @moduledoc """
    Behaviour for evaluator agent memory adapters.

    Provides recall and store operations for cross-proposal evaluation context.
    Implementations should handle storage and retrieval of evaluation context.
    The actual adapter lives in a higher-level app (e.g., arbor_memory) to keep
    arbor_consensus at Level 1 without circular dependencies.
    """

    @doc """
    Recall relevant context for a query.

    Returns a list of memory entries that are relevant to the given query.
    Each entry is a map with at least `:content` and `:metadata` keys.
    """
    @callback recall(agent_id :: String.t(), query :: String.t(), opts :: keyword()) ::
                {:ok, [map()]} | {:error, term()}

    @doc """
    Store a memory entry for future recall.

    Returns the ID of the stored entry.
    """
    @callback store(agent_id :: String.t(), content :: String.t(), metadata :: map()) ::
                {:ok, String.t()} | {:error, term()}
  end

  # =============================================================================
  # Client API
  # =============================================================================

  @doc """
  Start an EvaluatorAgent for the given evaluator module.

  ## Options

  - `:evaluator` (required) — module implementing `Arbor.Contracts.Consensus.Evaluator`
  - `:name` — GenServer name (optional)
  - `:mailbox_size` — max mailbox size (default: 100)
  - `:reserved_high_priority` — reserved high priority slots (default: 10)
  - `:memory_adapter` — module implementing `MemoryAdapter` behaviour (optional)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    # Validate that evaluator is provided (will fail in init otherwise)
    _ = Keyword.fetch!(opts, :evaluator)
    name = Keyword.get(opts, :name)
    server_opts = if name, do: [name: name], else: []

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Deliver a proposal envelope to the agent's mailbox.

  Returns `{:error, :mailbox_full}` if the agent cannot accept more work.
  """
  @spec deliver(GenServer.server(), envelope(), AgentMailbox.priority()) ::
          :ok | {:error, :mailbox_full}
  def deliver(server, envelope, priority \\ :normal) do
    GenServer.call(server, {:deliver, envelope, priority})
  end

  @doc """
  Get the agent's current status and capacity information.
  """
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc """
  Get the evaluator module this agent wraps.
  """
  @spec evaluator(GenServer.server()) :: module()
  def evaluator(server) do
    GenServer.call(server, :evaluator)
  end

  @doc """
  Get the perspectives this agent can evaluate from.
  """
  @spec perspectives(GenServer.server()) :: [atom()]
  def perspectives(server) do
    GenServer.call(server, :perspectives)
  end

  # =============================================================================
  # GenServer Callbacks
  # =============================================================================

  @impl true
  def init(opts) do
    evaluator = Keyword.fetch!(opts, :evaluator)
    mailbox_size = Keyword.get(opts, :mailbox_size, 100)
    reserved = Keyword.get(opts, :reserved_high_priority, 10)
    memory_adapter = Keyword.get(opts, :memory_adapter)

    # Get the evaluator's name (used for logging and identity)
    name = evaluator.name()

    # Create the mailbox
    {:ok, mailbox} = AgentMailbox.new(max_size: mailbox_size, reserved_high_priority: reserved)

    state = %__MODULE__{
      evaluator: evaluator,
      name: name,
      mailbox: mailbox,
      memory_adapter: memory_adapter,
      started_at: DateTime.utc_now()
    }

    Logger.debug("EvaluatorAgent started for #{name}")

    {:ok, state}
  end

  @impl true
  def handle_call({:deliver, envelope, priority}, _from, state) do
    case AgentMailbox.enqueue(state.mailbox, envelope, priority) do
      {:ok, new_mailbox} ->
        state = %{state | mailbox: new_mailbox}
        # Trigger processing if not already processing
        state = maybe_process_next(state)
        {:reply, :ok, state}

      {:error, :mailbox_full} = error ->
        Logger.warning("EvaluatorAgent #{state.name} mailbox full, rejecting envelope")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      name: state.name,
      evaluator: state.evaluator,
      perspectives: state.evaluator.perspectives(),
      processing: state.current_envelope != nil,
      evaluations_processed: state.evaluations_processed,
      started_at: state.started_at,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at, :second),
      mailbox: AgentMailbox.capacity_info(state.mailbox),
      memory_adapter: state.memory_adapter
    }

    {:reply, status, state}
  end

  @impl true
  def handle_call(:evaluator, _from, state) do
    {:reply, state.evaluator, state}
  end

  @impl true
  def handle_call(:perspectives, _from, state) do
    {:reply, state.evaluator.perspectives(), state}
  end

  @impl true
  def handle_info({ref, {:evaluation_results, results, proposal_desc}}, state)
      when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    # Send results back to Coordinator
    if state.current_envelope do
      reply_to = state.current_envelope.reply_to
      proposal_id = state.current_envelope.proposal.id

      Enum.each(results, fn
        {:ok, evaluation} ->
          send(reply_to, {:evaluation_complete, proposal_id, evaluation})

        {:error, reason} ->
          Logger.warning("EvaluatorAgent #{state.name} evaluation failed: #{inspect(reason)}")
      end)
    end

    # Store evaluation outcome in memory if adapter is configured
    maybe_store_memory(state, proposal_desc, results)

    state = %{
      state
      | current_envelope: nil,
        processing_task: nil,
        evaluations_processed: state.evaluations_processed + 1
    }

    # Process next envelope if available
    state = maybe_process_next(state)

    {:noreply, state}
  end

  # Legacy handler for tasks that don't include proposal_desc (backward compat)
  @impl true
  def handle_info({ref, {:evaluation_results, results}}, state) when is_reference(ref) do
    # Task completed successfully
    Process.demonitor(ref, [:flush])

    # Send results back to Coordinator
    if state.current_envelope do
      reply_to = state.current_envelope.reply_to
      proposal_id = state.current_envelope.proposal.id

      Enum.each(results, fn
        {:ok, evaluation} ->
          send(reply_to, {:evaluation_complete, proposal_id, evaluation})

        {:error, reason} ->
          Logger.warning("EvaluatorAgent #{state.name} evaluation failed: #{inspect(reason)}")
      end)
    end

    state = %{
      state
      | current_envelope: nil,
        processing_task: nil,
        evaluations_processed: state.evaluations_processed + 1
    }

    # Process next envelope if available
    state = maybe_process_next(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state)
      when ref == state.processing_task do
    # Task crashed
    Logger.error("EvaluatorAgent #{state.name} evaluation task crashed: #{inspect(reason)}")

    # Notify Coordinator of failure if we have an envelope
    if state.current_envelope do
      reply_to = state.current_envelope.reply_to
      proposal_id = state.current_envelope.proposal.id
      send(reply_to, {:evaluation_failed, proposal_id, state.name, reason})
    end

    state = %{state | current_envelope: nil, processing_task: nil}
    state = maybe_process_next(state)

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Some other monitor, ignore
    {:noreply, state}
  end

  # =============================================================================
  # Private Functions
  # =============================================================================

  defp maybe_process_next(%{processing_task: task} = state) when task != nil do
    # Already processing
    state
  end

  defp maybe_process_next(state) do
    case AgentMailbox.dequeue(state.mailbox) do
      {:ok, envelope, new_mailbox} ->
        start_processing(envelope, %{state | mailbox: new_mailbox})

      {:empty, _mailbox} ->
        state
    end
  end

  defp start_processing(envelope, state) do
    %{proposal: proposal} = envelope

    # Check deadline
    if deadline_passed?(envelope.deadline) do
      handle_deadline_passed(envelope, proposal, state)
    else
      start_evaluation_task(envelope, state)
    end
  end

  defp handle_deadline_passed(envelope, proposal, state) do
    Logger.warning(
      "EvaluatorAgent #{state.name} skipping envelope for proposal #{proposal.id} - deadline passed"
    )

    # Notify Coordinator
    if envelope.reply_to do
      send(envelope.reply_to, {:evaluation_failed, proposal.id, state.name, :deadline_passed})
    end

    # Try next envelope
    maybe_process_next(state)
  end

  defp start_evaluation_task(envelope, state) do
    %{proposal: proposal, perspectives: perspectives} = envelope
    evaluator = state.evaluator
    memory_adapter = state.memory_adapter
    agent_name = Atom.to_string(state.name)

    # Recall memory context before evaluation
    memory_context = recall_memory(memory_adapter, agent_name, proposal.description)

    task =
      Task.async(fn ->
        results = evaluate_perspectives(evaluator, proposal, perspectives, memory_context)
        {:evaluation_results, results, proposal.description}
      end)

    %{state | current_envelope: envelope, processing_task: task.ref}
  end

  defp evaluate_perspectives(evaluator, proposal, perspectives, memory_context) do
    Enum.map(perspectives, fn perspective ->
      evaluate_single_perspective(evaluator, proposal, perspective, memory_context)
    end)
  end

  defp evaluate_single_perspective(evaluator, proposal, perspective, memory_context) do
    opts =
      if memory_context != [] do
        [memory_context: memory_context]
      else
        []
      end

    evaluator.evaluate(proposal, perspective, opts)
  rescue
    e ->
      Logger.error("EvaluatorAgent #{evaluator.name()} evaluate/3 raised: #{inspect(e)}")
      {:error, {:exception, e}}
  end

  # =============================================================================
  # Memory Integration
  # =============================================================================

  defp recall_memory(nil, _agent_id, _query), do: []

  defp recall_memory(memory_adapter, agent_id, query) do
    case memory_adapter.recall(agent_id, query, limit: 5) do
      {:ok, memories} ->
        memories

      {:error, reason} ->
        Logger.warning("EvaluatorAgent memory recall failed: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.warning("EvaluatorAgent memory recall error: #{inspect(e)}")
      []
  end

  defp maybe_store_memory(%{memory_adapter: nil}, _description, _results), do: :ok

  defp maybe_store_memory(%{memory_adapter: adapter, name: name}, description, results) do
    agent_id = Atom.to_string(name)

    # Summarize the evaluation outcomes
    summary = summarize_results(results)

    metadata = %{
      type: "evaluation_outcome",
      agent: agent_id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }

    content = "Proposal: #{description}\nOutcome: #{summary}"

    # Store asynchronously to avoid blocking the agent
    Task.start(fn ->
      case adapter.store(agent_id, content, metadata) do
        {:ok, _id} ->
          :ok

        {:error, reason} ->
          Logger.warning("EvaluatorAgent memory store failed: #{inspect(reason)}")
      end
    end)

    :ok
  rescue
    e ->
      Logger.warning("EvaluatorAgent memory store error: #{inspect(e)}")
      :ok
  end

  defp summarize_results(results) do
    {ok_count, error_count} =
      Enum.reduce(results, {0, 0}, fn
        {:ok, _}, {ok, err} -> {ok + 1, err}
        {:error, _}, {ok, err} -> {ok, err + 1}
      end)

    votes =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, eval} -> eval.vote end)
      |> Enum.frequencies()
      |> Enum.map_join(", ", fn {vote, count} -> "#{vote}=#{count}" end)

    "#{ok_count} evaluations (#{votes}), #{error_count} errors"
  end

  defp deadline_passed?(nil), do: false

  defp deadline_passed?(deadline) do
    DateTime.compare(DateTime.utc_now(), deadline) == :gt
  end
end
