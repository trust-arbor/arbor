defmodule Arbor.Memory.Thinking do
  @moduledoc """
  Store and retrieve Claude thinking blocks.

  Thinking blocks are the internal reasoning traces from Claude's extended
  thinking feature. This module stores them in a ring buffer per agent,
  enabling retrospective analysis of reasoning patterns.

  ## Storage

  Thinking entries are stored in ETS per-agent with a ring buffer
  (default: 50 entries). Each entry includes:
  - The thinking text
  - A timestamp
  - Optional metadata (e.g., which tool call triggered it)
  - Whether it's been flagged as significant for reflection

  ## Stream Processing

  For streaming integration, `process_stream_chunk/3` accumulates
  partial thinking blocks until they're complete, then stores the
  full text.
  """

  use GenServer

  alias Arbor.Memory.Signals

  require Logger

  @ets_table :arbor_memory_thinking
  @default_buffer_size 50

  # ============================================================================
  # Types
  # ============================================================================

  @type thinking_entry :: %{
          id: String.t(),
          agent_id: String.t(),
          text: String.t(),
          significant: boolean(),
          created_at: DateTime.t(),
          metadata: map()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Thinking GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Record a thinking block for an agent.

  ## Options

  - `:significant` — flag as significant for reflection (default: false)
  - `:metadata` — additional metadata map

  ## Examples

      {:ok, entry} = Thinking.record_thinking("agent_001", "Let me analyze the error...",
        significant: true,
        metadata: %{trigger: "test_failure"}
      )
  """
  @spec record_thinking(String.t(), String.t(), keyword()) :: {:ok, thinking_entry()}
  def record_thinking(agent_id, text, opts \\ []) when is_binary(text) do
    GenServer.call(server_name(), {:record, agent_id, text, opts})
  end

  @doc """
  Get recent thinking entries for an agent.

  ## Options

  - `:limit` — max entries to return (default: 10)
  - `:since` — only entries after this DateTime
  - `:significant_only` — only return significant entries (default: false)

  ## Examples

      entries = Thinking.recent_thinking("agent_001", limit: 5)
      significant = Thinking.recent_thinking("agent_001", significant_only: true)
  """
  @spec recent_thinking(String.t(), keyword()) :: [thinking_entry()]
  def recent_thinking(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    since = Keyword.get(opts, :since)
    significant_only = Keyword.get(opts, :significant_only, false)

    get_agent_entries(agent_id)
    |> maybe_filter_significant(significant_only)
    |> maybe_filter_since(since)
    |> Enum.take(limit)
  end

  @doc """
  Process a streaming thinking chunk.

  Accumulates chunks for an agent until the stream is complete.
  Call with `complete: true` to finalize and store the accumulated text.

  ## Examples

      Thinking.process_stream_chunk("agent_001", "Let me think")
      Thinking.process_stream_chunk("agent_001", " about this...")
      {:ok, entry} = Thinking.process_stream_chunk("agent_001", "", complete: true)
  """
  @spec process_stream_chunk(String.t(), String.t(), keyword()) ::
          :ok | {:ok, thinking_entry()}
  def process_stream_chunk(agent_id, chunk, opts \\ []) do
    GenServer.call(server_name(), {:stream_chunk, agent_id, chunk, opts})
  end

  @doc """
  Clear all thinking entries for an agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) do
    :ets.delete(@ets_table, agent_id)
    :ets.delete(@ets_table, {:stream, agent_id})
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
  def handle_call({:record, agent_id, text, opts}, _from, state) do
    entry = build_entry(agent_id, text, opts)

    entries = [entry | get_agent_entries(agent_id)]
    entries = Enum.take(entries, state.buffer_size)
    :ets.insert(@ets_table, {agent_id, entries})

    Signals.emit_thinking_recorded(agent_id, text)
    Logger.debug("Thinking recorded for #{agent_id}: #{String.slice(text, 0, 50)}...")

    {:reply, {:ok, entry}, state}
  end

  @impl true
  def handle_call({:stream_chunk, agent_id, chunk, opts}, _from, state) do
    complete = Keyword.get(opts, :complete, false)
    stream_key = {:stream, agent_id}

    # Get accumulated text
    accumulated =
      case :ets.lookup(@ets_table, stream_key) do
        [{^stream_key, text}] -> text
        [] -> ""
      end

    if complete do
      # Finalize: store the accumulated text as a thinking entry
      full_text = accumulated <> chunk
      :ets.delete(@ets_table, stream_key)

      if String.trim(full_text) != "" do
        entry = build_entry(agent_id, full_text, opts)

        entries = [entry | get_agent_entries(agent_id)]
        entries = Enum.take(entries, state.buffer_size)
        :ets.insert(@ets_table, {agent_id, entries})

        Signals.emit_thinking_recorded(agent_id, full_text)
        {:reply, {:ok, entry}, state}
      else
        {:reply, :ok, state}
      end
    else
      # Accumulate
      :ets.insert(@ets_table, {stream_key, accumulated <> chunk})
      {:reply, :ok, state}
    end
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

  defp get_agent_entries(agent_id) do
    case :ets.lookup(@ets_table, agent_id) do
      [{^agent_id, entries}] -> entries
      [] -> []
    end
  end

  defp build_entry(agent_id, text, opts) do
    %{
      id: generate_id(),
      agent_id: agent_id,
      text: text,
      significant: Keyword.get(opts, :significant, false),
      created_at: DateTime.utc_now(),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp generate_id do
    "thk_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end

  defp maybe_filter_significant(entries, false), do: entries
  defp maybe_filter_significant(entries, true), do: Enum.filter(entries, & &1.significant)

  defp maybe_filter_since(entries, nil), do: entries

  defp maybe_filter_since(entries, since) do
    Enum.filter(entries, &(DateTime.compare(&1.created_at, since) in [:gt, :eq]))
  end
end
