defmodule Arbor.Memory.Lifecycle do
  @moduledoc """
  Agent lifecycle callbacks for memory management.

  Provides hooks for agent start/stop/heartbeat to manage memory state.
  Called by agent supervisors or gateway when agents start and stop.

  ## Usage

  When an agent starts:

      {:ok, state} = Arbor.Memory.Lifecycle.on_agent_start("agent_001")
      # state.working_memory contains the loaded/created working memory

  When an agent stops:

      :ok = Arbor.Memory.Lifecycle.on_agent_stop("agent_001")
      # Working memory is persisted to ETS

  Heartbeat (placeholder for Phase 4):

      :ok = Arbor.Memory.Lifecycle.on_heartbeat("agent_001")
  """

  alias Arbor.Memory
  alias Arbor.Memory.Signals

  require Logger

  @doc """
  Called when an agent starts.

  Initializes memory for the agent if not already initialized,
  and loads any existing working memory from persistence.

  ## Options

  - All options are passed through to `Memory.init_for_agent/2`

  ## Returns

  - `{:ok, %{working_memory: wm}}` — Working memory loaded/created
  - `{:ok, %{working_memory: nil}}` — No working memory available

  ## Examples

      {:ok, %{working_memory: wm}} = Lifecycle.on_agent_start("agent_001")
  """
  @spec on_agent_start(String.t(), keyword()) :: {:ok, map()}
  def on_agent_start(agent_id, opts \\ []) do
    Logger.debug("Lifecycle: agent #{agent_id} starting")

    # Initialize memory if not already done
    unless Memory.initialized?(agent_id) do
      Memory.init_for_agent(agent_id, opts)
    end

    # Load working memory (creates new if none exists)
    working_memory = Memory.load_working_memory(agent_id, opts)

    Logger.debug("Lifecycle: agent #{agent_id} started with working memory")

    {:ok, %{working_memory: working_memory}}
  end

  @doc """
  Called when an agent stops.

  Persists the current working memory to ETS and emits a stopped signal.

  ## Examples

      :ok = Lifecycle.on_agent_stop("agent_001")
  """
  @spec on_agent_stop(String.t()) :: :ok
  def on_agent_stop(agent_id) do
    Logger.debug("Lifecycle: agent #{agent_id} stopping")

    # Get current working memory and save it
    case Memory.get_working_memory(agent_id) do
      nil ->
        Logger.debug("Lifecycle: no working memory to persist for agent #{agent_id}")

      wm ->
        Memory.save_working_memory(agent_id, wm)
        Logger.debug("Lifecycle: persisted working memory for agent #{agent_id}")
    end

    # Emit agent stopped signal
    Signals.emit_agent_stopped(agent_id)

    :ok
  end

  @doc """
  Called on agent heartbeat.

  Placeholder for Phase 4 background checks (e.g., memory consolidation,
  working memory pruning, etc.).

  Currently just emits a heartbeat signal.

  ## Examples

      :ok = Lifecycle.on_heartbeat("agent_001")
  """
  @spec on_heartbeat(String.t()) :: :ok
  def on_heartbeat(agent_id) do
    Signals.emit_heartbeat(agent_id)
    :ok
  end
end
