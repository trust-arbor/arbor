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

  alias Arbor.Memory.MemoryStore
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
    MemoryStore.delete("thinking", agent_id)
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    ensure_ets_table()
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    load_from_postgres(buffer_size)
    {:ok, %{buffer_size: buffer_size}}
  end

  @impl true
  def handle_call({:record, agent_id, text, opts}, _from, state) do
    entry = build_entry(agent_id, text, opts)

    entries = [entry | get_agent_entries(agent_id)]
    entries = Enum.take(entries, state.buffer_size)
    :ets.insert(@ets_table, {agent_id, entries})
    persist_entries_async(agent_id, entries)

    MemoryStore.embed_async("thinking", "#{agent_id}:#{entry.id}", text,
      agent_id: agent_id, type: :thought)

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
        persist_entries_async(agent_id, entries)

        MemoryStore.embed_async("thinking", "#{agent_id}:#{entry.id}", full_text,
          agent_id: agent_id, type: :thought)

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

  # ============================================================================
  # Persistence Helpers
  # ============================================================================

  defp persist_entries_async(agent_id, entries) do
    serialized = %{"entries" => Enum.map(entries, &serialize_entry/1)}
    MemoryStore.persist_async("thinking", agent_id, serialized)
  end

  defp serialize_entry(entry) do
    %{
      "id" => entry.id,
      "agent_id" => entry.agent_id,
      "text" => entry.text,
      "significant" => entry.significant,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "metadata" => entry.metadata
    }
  end

  defp deserialize_entry(map) do
    %{
      id: map["id"],
      agent_id: map["agent_id"],
      text: map["text"],
      significant: map["significant"] || false,
      created_at: parse_dt(map["created_at"]),
      metadata: map["metadata"] || %{}
    }
  end

  defp parse_dt(nil), do: DateTime.utc_now()
  defp parse_dt(%DateTime{} = dt), do: dt
  defp parse_dt(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp load_from_postgres(buffer_size) do
    if MemoryStore.available?() do
      case MemoryStore.load_all("thinking") do
        {:ok, pairs} ->
          Enum.each(pairs, &load_agent_thinking(&1, buffer_size))
          Logger.info("Thinking: loaded #{length(pairs)} agent records from Postgres")

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("Thinking: failed to load from Postgres: #{inspect(e)}")
  end

  defp load_agent_thinking({agent_id, data}, buffer_size) do
    entries =
      (data["entries"] || [])
      |> Enum.map(&deserialize_entry/1)
      |> Enum.take(buffer_size)

    if entries != [], do: :ets.insert(@ets_table, {agent_id, entries})
  end

  # ============================================================================
  # Multi-Provider Extraction (ported from Seed ThinkingBlockProcessor)
  # ============================================================================

  @doc """
  Extract thinking content from an LLM response.

  Supports multiple providers:
  - `:anthropic` — content blocks with `"type" => "thinking"`
  - `:deepseek` — `reasoning_content` field
  - `:openai` — explicitly returns `{:none, :hidden_reasoning}` (o1/o3 hide reasoning)
  - `:generic` — fallback chain: anthropic → deepseek → XML `<thinking>` tags

  ## Options

  - `:fallback_to_generic` — try generic extraction on failure (default: false)

  ## Returns

  - `{:ok, text}` — extracted thinking text
  - `{:none, reason}` — no thinking found
  """
  @spec extract(map(), atom(), keyword()) :: {:ok, String.t()} | {:none, atom()}
  def extract(response, provider, opts \\ [])

  def extract(response, :anthropic, opts) do
    case extract_anthropic_thinking(response) do
      {:ok, _} = ok -> ok
      {:none, _} = none ->
        if Keyword.get(opts, :fallback_to_generic, false),
          do: extract(response, :generic, []),
          else: none
    end
  end

  def extract(response, :deepseek, opts) do
    case extract_deepseek_reasoning(response) do
      {:ok, _} = ok -> ok
      {:none, _} = none ->
        if Keyword.get(opts, :fallback_to_generic, false),
          do: extract(response, :generic, []),
          else: none
    end
  end

  def extract(_response, :openai, _opts) do
    {:none, :hidden_reasoning}
  end

  def extract(response, :generic, _opts) do
    extract_generic_thinking(response)
  end

  def extract(response, _unknown_provider, _opts) do
    extract_generic_thinking(response)
  end

  @doc """
  Extract thinking from an LLM response and record it for the agent.

  Combines `extract/3` and `record_thinking/3`. Automatically flags
  identity-affecting thinking as significant.
  """
  @spec extract_and_record(String.t(), map(), atom(), keyword()) ::
          {:ok, thinking_entry()} | {:none, atom()}
  def extract_and_record(agent_id, response, provider, opts \\ []) do
    case extract(response, provider, opts) do
      {:ok, text} ->
        significant = identity_affecting?(text)
        metadata = Keyword.get(opts, :metadata, %{})
        record_thinking(agent_id, text, significant: significant, metadata: metadata)

      {:none, reason} ->
        {:none, reason}
    end
  end

  @doc """
  Returns true if the thinking text contains identity-affecting patterns.

  Checks for goal-related, learning, self-reflection, and constraint keywords.
  """
  @spec identity_affecting?(String.t()) :: boolean()
  def identity_affecting?(text) when is_binary(text) do
    downcased = String.downcase(text)

    goal_patterns = ["my goal", "i should", "i want to", "i need to"]
    learning_patterns = ["i learned", "i realize", "i understand now", "i discovered"]
    self_patterns = ["i am", "my purpose", "my role", "my values"]
    constraint_patterns = ["i cannot", "i must not", "my constraints"]

    Enum.any?(goal_patterns ++ learning_patterns ++ self_patterns ++ constraint_patterns, fn pattern ->
      String.contains?(downcased, pattern)
    end)
  end

  def identity_affecting?(_), do: false

  # ============================================================================
  # Provider-Specific Extraction
  # ============================================================================

  defp extract_anthropic_thinking(response) do
    blocks = get_content_blocks(response)

    thinking_texts =
      blocks
      |> Enum.filter(&(is_map(&1) and (&1["type"] == "thinking" or &1[:type] == "thinking")))
      |> Enum.map(&(&1["thinking"] || &1[:thinking] || ""))
      |> Enum.reject(&(&1 == ""))

    case thinking_texts do
      [] -> {:none, :no_thinking_blocks}
      texts -> {:ok, Enum.join(texts, "\n\n")}
    end
  end

  defp extract_deepseek_reasoning(response) do
    reasoning =
      get_nested(response, ["reasoning_content"]) ||
        get_nested(response, [:reasoning_content])

    case reasoning do
      nil -> {:none, :no_reasoning_content}
      "" -> {:none, :no_reasoning_content}
      text when is_binary(text) -> {:ok, text}
      _ -> {:none, :no_reasoning_content}
    end
  end

  defp extract_generic_thinking(response) do
    with :not_found <- try_anthropic_thinking(response),
         :not_found <- try_deepseek_reasoning(response),
         :not_found <- try_thinking_field(response) do
      extract_xml_thinking(response)
    end
  end

  defp try_anthropic_thinking(response) do
    case extract_anthropic_thinking(response) do
      {:ok, _} = ok -> ok
      _ -> :not_found
    end
  end

  defp try_deepseek_reasoning(response) do
    case extract_deepseek_reasoning(response) do
      {:ok, _} = ok -> ok
      _ -> :not_found
    end
  end

  defp try_thinking_field(response) do
    thinking = get_nested(response, ["thinking"]) || get_nested(response, [:thinking])

    case thinking do
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> :not_found
    end
  end

  defp extract_xml_thinking(response) do
    text = extract_text_content(response)

    case Regex.run(~r/<thinking>(.*?)<\/thinking>/s, text) do
      [_, captured] when captured != "" -> {:ok, String.trim(captured)}
      _ -> {:none, :no_thinking_found}
    end
  end

  defp extract_text_content(response) when is_binary(response), do: response

  defp extract_text_content(response) when is_map(response) do
    cond do
      is_binary(response["content"]) -> response["content"]
      is_binary(response[:content]) -> response[:content]
      true -> extract_text_from_blocks(response)
    end
  end

  defp extract_text_content(_response), do: ""

  defp extract_text_from_blocks(response) do
    response
    |> get_content_blocks()
    |> Enum.filter(&(is_map(&1) and (&1["type"] == "text" or &1[:type] == "text")))
    |> Enum.map_join("\n", &(&1["text"] || &1[:text] || ""))
  end

  defp get_content_blocks(response) when is_map(response) do
    cond do
      is_list(response["content"]) -> response["content"]
      is_list(response[:content]) -> response[:content]
      true -> []
    end
  end

  defp get_content_blocks(_), do: []

  defp get_nested(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case acc do
        %{^key => value} -> {:halt, value}
        _ -> {:halt, nil}
      end
    end)
  end

  defp get_nested(_, _), do: nil
end
