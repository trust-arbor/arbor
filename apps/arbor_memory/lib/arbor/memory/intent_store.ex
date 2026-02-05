defmodule Arbor.Memory.IntentStore do
  @moduledoc """
  Ring buffer storage for agent intents and percepts.

  Maintains a bounded history of recent intents (what the Mind decided to do)
  and percepts (what the Body observed after execution). Uses ETS for fast
  access with a configurable ring buffer size.

  ## Ring Buffer

  Both intents and percepts are stored in bounded ring buffers (default: 100).
  When the buffer is full, the oldest entry is evicted. This keeps memory
  bounded while preserving recent history for context.

  ## Linking

  Percepts are linked to intents via the `intent_id` field on `Percept`.
  Use `get_percept_for_intent/2` to find the outcome of a specific intent.

  ## Signals

  - `{:agent, :intent_formed}` — intent recorded
  - `{:agent, :percept_received}` — percept recorded
  """

  use GenServer

  alias Arbor.Contracts.Memory.Intent
  alias Arbor.Contracts.Memory.Percept
  alias Arbor.Memory.Signals

  require Logger

  @ets_table :arbor_memory_intents
  @default_buffer_size 100

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the IntentStore GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record an intent for an agent.

  The intent is added to the ring buffer. If the buffer is full,
  the oldest intent is evicted.

  ## Examples

      intent = Intent.action(:shell_execute, %{command: "mix test"})
      {:ok, intent} = IntentStore.record_intent("agent_001", intent)
  """
  @spec record_intent(String.t(), Intent.t()) :: {:ok, Intent.t()}
  def record_intent(agent_id, %Intent{} = intent) do
    GenServer.call(server_name(), {:record_intent, agent_id, intent})
  end

  @doc """
  Record a percept for an agent.

  The percept is added to the ring buffer. If it has an `intent_id`,
  it's also indexed for fast intent-to-percept lookup.

  ## Examples

      percept = Percept.success("int_abc", %{exit_code: 0})
      {:ok, percept} = IntentStore.record_percept("agent_001", percept)
  """
  @spec record_percept(String.t(), Percept.t()) :: {:ok, Percept.t()}
  def record_percept(agent_id, %Percept{} = percept) do
    GenServer.call(server_name(), {:record_percept, agent_id, percept})
  end

  @doc """
  Get recent intents for an agent.

  ## Options

  - `:limit` — max intents to return (default: 10)
  - `:type` — filter by intent type (e.g., `:act`, `:think`)
  - `:since` — only intents after this DateTime
  """
  @spec recent_intents(String.t(), keyword()) :: [Intent.t()]
  def recent_intents(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    type = Keyword.get(opts, :type)
    since = Keyword.get(opts, :since)

    get_agent_data(agent_id)
    |> Map.get(:intents, [])
    |> maybe_filter_type(type)
    |> maybe_filter_since(since)
    |> Enum.take(limit)
  end

  @doc """
  Get recent percepts for an agent.

  ## Options

  - `:limit` — max percepts to return (default: 10)
  - `:type` — filter by percept type
  - `:since` — only percepts after this DateTime
  """
  @spec recent_percepts(String.t(), keyword()) :: [Percept.t()]
  def recent_percepts(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    type = Keyword.get(opts, :type)
    since = Keyword.get(opts, :since)

    get_agent_data(agent_id)
    |> Map.get(:percepts, [])
    |> maybe_filter_type(type)
    |> maybe_filter_since(since)
    |> Enum.take(limit)
  end

  @doc """
  Get the percept (outcome) for a specific intent.

  Returns the most recent percept linked to the given intent_id.
  """
  @spec get_percept_for_intent(String.t(), String.t()) ::
          {:ok, Percept.t()} | {:error, :not_found}
  def get_percept_for_intent(agent_id, intent_id) do
    get_agent_data(agent_id)
    |> Map.get(:percepts, [])
    |> Enum.find(&(&1.intent_id == intent_id))
    |> case do
      nil -> {:error, :not_found}
      percept -> {:ok, percept}
    end
  end

  @doc """
  Clear all intents and percepts for an agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) do
    :ets.delete(@ets_table, agent_id)
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    ensure_ets_table()
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    {:ok, %{buffer_size: buffer_size}}
  end

  @impl true
  def handle_call({:record_intent, agent_id, intent}, _from, state) do
    data = get_agent_data(agent_id)
    intents = [intent | Map.get(data, :intents, [])]
    intents = Enum.take(intents, state.buffer_size)

    updated = Map.put(data, :intents, intents)
    :ets.insert(@ets_table, {agent_id, updated})

    Signals.emit_intent_formed(agent_id, intent)
    Logger.debug("Intent recorded for #{agent_id}: #{intent.id} (#{intent.type})")

    {:reply, {:ok, intent}, state}
  end

  @impl true
  def handle_call({:record_percept, agent_id, percept}, _from, state) do
    data = get_agent_data(agent_id)
    percepts = [percept | Map.get(data, :percepts, [])]
    percepts = Enum.take(percepts, state.buffer_size)

    updated = Map.put(data, :percepts, percepts)
    :ets.insert(@ets_table, {agent_id, updated})

    Signals.emit_percept_received(agent_id, percept)
    Logger.debug("Percept recorded for #{agent_id}: #{percept.id} (#{percept.outcome})")

    {:reply, {:ok, percept}, state}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp server_name, do: __MODULE__

  defp ensure_ets_table do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:named_table, :public, :set])
    end
  rescue
    ArgumentError -> :ok
  end

  defp get_agent_data(agent_id) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, data}] -> data
      [] -> %{intents: [], percepts: []}
    end
  end

  defp maybe_filter_type(items, nil), do: items
  defp maybe_filter_type(items, type), do: Enum.filter(items, &(&1.type == type))

  defp maybe_filter_since(items, nil), do: items

  defp maybe_filter_since(items, since) do
    Enum.filter(items, &(DateTime.compare(&1.created_at, since) in [:gt, :eq]))
  end
end
