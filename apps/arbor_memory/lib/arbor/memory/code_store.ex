defmodule Arbor.Memory.CodeStore do
  @moduledoc """
  Store and retrieve learned code patterns.

  CodeStore maintains a collection of code snippets that an agent has learned
  or found useful. Patterns are stored per-agent in ETS and can be searched
  by purpose/description.

  ## Storage

  Each code pattern includes:
  - `code` — the actual code text
  - `language` — programming language (e.g., "elixir", "python")
  - `purpose` — what the code does / when to use it
  - Optional metadata (source, confidence, tags)

  ## Examples

      {:ok, entry} = CodeStore.store("agent_001", %{
        code: "Enum.map(list, & &1 * 2)",
        language: "elixir",
        purpose: "Double all elements in a list"
      })

      results = CodeStore.find_by_purpose("agent_001", "double")
  """

  use GenServer

  alias Arbor.Memory.MemoryStore

  require Logger

  @ets_table :arbor_memory_code_store

  # ============================================================================
  # Types
  # ============================================================================

  @type code_entry :: %{
          id: String.t(),
          agent_id: String.t(),
          code: String.t(),
          language: String.t(),
          purpose: String.t(),
          created_at: DateTime.t(),
          metadata: map()
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the CodeStore GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Store a code pattern for an agent.

  ## Required Fields

  - `:code` — the code text
  - `:language` — programming language
  - `:purpose` — description of what it does

  ## Optional Fields

  - `:metadata` — additional metadata (tags, source, confidence)

  ## Examples

      {:ok, entry} = CodeStore.store("agent_001", %{
        code: "defmodule Foo do\\n  use GenServer\\nend",
        language: "elixir",
        purpose: "GenServer boilerplate"
      })
  """
  @spec store(String.t(), map()) :: {:ok, code_entry()} | {:error, :missing_fields}
  def store(agent_id, %{code: code, language: language, purpose: purpose} = params)
      when is_binary(code) and is_binary(language) and is_binary(purpose) do
    entry = %{
      id: generate_id(),
      agent_id: agent_id,
      code: code,
      language: language,
      purpose: purpose,
      created_at: DateTime.utc_now(),
      metadata: Map.get(params, :metadata, %{})
    }

    entries = get_agent_entries(agent_id)
    :ets.insert(@ets_table, {agent_id, [entry | entries]})

    persist_entry_async(agent_id, entry)
    MemoryStore.embed_async("code_patterns", "#{agent_id}:#{entry.id}",
      "#{purpose} (#{language}): #{String.slice(code, 0, 200)}",
      agent_id: agent_id, type: :code_pattern)

    Logger.debug("Code pattern stored for #{agent_id}: #{String.slice(purpose, 0, 50)}")
    {:ok, entry}
  end

  def store(_agent_id, _params), do: {:error, :missing_fields}

  @doc """
  Find code patterns by purpose (substring/keyword match).

  Returns patterns whose purpose contains the query string (case-insensitive).

  ## Examples

      results = CodeStore.find_by_purpose("agent_001", "genserver")
  """
  @spec find_by_purpose(String.t(), String.t()) :: [code_entry()]
  def find_by_purpose(agent_id, query) when is_binary(query) do
    downcased_query = String.downcase(query)

    get_agent_entries(agent_id)
    |> Enum.filter(fn entry ->
      String.contains?(String.downcase(entry.purpose), downcased_query)
    end)
  end

  @doc """
  List all code patterns for an agent.

  ## Options

  - `:language` — filter by language
  - `:limit` — max results
  """
  @spec list(String.t(), keyword()) :: [code_entry()]
  def list(agent_id, opts \\ []) do
    language = Keyword.get(opts, :language)
    limit = Keyword.get(opts, :limit)

    entries = get_agent_entries(agent_id)

    entries =
      if language do
        Enum.filter(entries, &(&1.language == language))
      else
        entries
      end

    if limit do
      Enum.take(entries, limit)
    else
      entries
    end
  end

  @doc """
  Get a specific code pattern by ID.

  ## Examples

      {:ok, entry} = CodeStore.get("agent_001", "code_abc123")
      {:error, :not_found} = CodeStore.get("agent_001", "nonexistent")
  """
  @spec get(String.t(), String.t()) :: {:ok, code_entry()} | {:error, :not_found}
  def get(agent_id, entry_id) do
    case Enum.find(get_agent_entries(agent_id), &(&1.id == entry_id)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc """
  Delete a specific code pattern.
  """
  @spec delete(String.t(), String.t()) :: :ok
  def delete(agent_id, entry_id) do
    entries =
      get_agent_entries(agent_id)
      |> Enum.reject(&(&1.id == entry_id))

    :ets.insert(@ets_table, {agent_id, entries})
    MemoryStore.delete("code_patterns", "#{agent_id}:#{entry_id}")
    :ok
  end

  @doc """
  Clear all code patterns for an agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) do
    :ets.delete(@ets_table, agent_id)
    MemoryStore.delete_by_prefix("code_patterns", agent_id)
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    ensure_ets_table()
    load_from_postgres()
    {:ok, %{}}
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

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

  defp generate_id do
    "code_" <> Base.encode32(:crypto.strong_rand_bytes(8), case: :lower, padding: false)
  end

  # ============================================================================
  # Persistence Helpers
  # ============================================================================

  defp persist_entry_async(agent_id, entry) do
    serialized = %{
      "id" => entry.id,
      "agent_id" => entry.agent_id,
      "code" => entry.code,
      "language" => entry.language,
      "purpose" => entry.purpose,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "metadata" => entry.metadata
    }

    MemoryStore.persist_async("code_patterns", "#{agent_id}:#{entry.id}", serialized)
  end

  defp deserialize_entry(map) do
    %{
      id: map["id"],
      agent_id: map["agent_id"],
      code: map["code"],
      language: map["language"],
      purpose: map["purpose"],
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

  defp load_from_postgres do
    if MemoryStore.available?() do
      case MemoryStore.load_all("code_patterns") do
        {:ok, pairs} ->
          # Group by agent_id (keys are "agent_id:entry_id")
          grouped =
            Enum.group_by(pairs, fn {key, _data} ->
              key |> String.split(":", parts: 2) |> List.first()
            end)

          Enum.each(grouped, fn {agent_id, agent_pairs} ->
            entries = Enum.map(agent_pairs, fn {_key, data} -> deserialize_entry(data) end)
            if entries != [], do: :ets.insert(@ets_table, {agent_id, entries})
          end)

          Logger.info("CodeStore: loaded #{length(pairs)} entries from Postgres")

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("CodeStore: failed to load from Postgres: #{inspect(e)}")
  end
end
