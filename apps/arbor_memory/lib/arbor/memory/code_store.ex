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

  alias Arbor.Contracts.Security.TaintedValue
  alias Arbor.Memory.MemoryStore

  require Logger

  @ets_table :arbor_memory_code_store
  @namespace "code_patterns"
  @max_agent_id_bytes 256
  @max_entry_id_bytes 256
  @required_payload_fields ~w(id agent_id code language purpose created_at metadata)
  # Only these statuses may proceed to delete. Malformed tainted authority
  # (:invalid_durable_provenance) fails closed before any content deletion.
  @admissible_inventory_statuses [:verified, :legacy_unlabeled]

  @content_delete_errors [
    :invalid_agent_id,
    :delete_failed,
    :outcome_unknown,
    :durable_unavailable,
    :insufficient_durability,
    :invalid_record,
    :ambiguous_record,
    :conflict,
    :inventory_limit_exceeded,
    :ets_failed,
    :store_unavailable
  ]

  @content_absence_errors [
    :invalid_agent_id,
    :absence_uncertain,
    :durable_unavailable,
    :insufficient_durability,
    :invalid_record,
    :ambiguous_record,
    :inventory_limit_exceeded,
    :store_unavailable
  ]

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

  @type content_cleanup_error ::
          :invalid_agent_id
          | :delete_failed
          | :outcome_unknown
          | :durable_unavailable
          | :insufficient_durability
          | :invalid_record
          | :ambiguous_record
          | :conflict
          | :inventory_limit_exceeded
          | :ets_failed
          | :store_unavailable
          | :absence_uncertain

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

    MemoryStore.embed_async(
      @namespace,
      "#{agent_id}:#{entry.id}",
      "#{purpose} (#{language}): #{String.slice(code, 0, 200)}",
      agent_id: agent_id,
      type: :code_pattern
    )

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
    MemoryStore.delete(@namespace, "#{agent_id}:#{entry_id}")
    :ok
  end

  @doc """
  Clear all code patterns for an agent.
  """
  @spec clear(String.t()) :: :ok
  def clear(agent_id) do
    :ets.delete(@ets_table, agent_id)
    MemoryStore.delete_by_prefix(@namespace, agent_id)
    :ok
  end

  @doc """
  Idempotent content-only deletion of learned code patterns for exactly one agent.

  Inventories the segment-aware logical prefix `agent_id <> ":"`, validates every
  key and complete payload shape before any delete, removes durable records one
  fenced key at a time, then evicts only the target agent's ETS projection.
  Retains every Provenance sidecar. Does not delete embeddings or Index state.

  C3I2A precondition (caller-owned, not enforced here): C3I1 mutation gate
  must be closed and drained before invoke. This API is not race-free agent
  destruction.
  """
  @spec delete_agent_content(String.t()) :: :ok | {:error, content_cleanup_error()}
  def delete_agent_content(agent_id) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, entry_ids} <- load_validated_code_entry_ids(agent_id) do
      case delete_code_records(agent_id, entry_ids) do
        :ok ->
          # Initial inventory is not absence proof: re-observe exact-agent
          # durable inventory and require confirmed emptiness before success.
          case confirm_durable_inventory_empty(agent_id) do
            :ok ->
              confirm_code_ets_evicted(agent_id)

            {:error, reason} ->
              # May still drop projection conservatively, but never claim success.
              _ = confirm_code_ets_evicted(agent_id)
              {:error, normalize_content_delete_error(reason)}
          end

        {:error, reason} ->
          # Partial durable progress is retryable: still attempt projection
          # eviction, but return the durable uncertainty/error.
          _ = confirm_code_ets_evicted(agent_id)
          {:error, normalize_content_delete_error(reason)}
      end
    else
      {:error, reason} ->
        # Inventory/validation failure: never report success and do not wipe
        # the projection while durable authority remains untrusted.
        {:error, normalize_content_delete_error(reason)}
    end
  rescue
    _ -> {:error, :delete_failed}
  catch
    _, _ -> {:error, :delete_failed}
  end

  @doc """
  Authoritative absence across durable code patterns and ETS projection.
  Returns `{:ok, true}` only when no exact-agent content remains.
  """
  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()} | {:error, content_cleanup_error()}
  def agent_content_absent?(agent_id) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, entry_ids} <- load_validated_code_entry_ids(agent_id) do
      case code_ets_absent?(agent_id) do
        {:ok, true} when entry_ids == [] -> {:ok, true}
        {:ok, _} -> {:ok, false}
        {:error, reason} -> {:error, normalize_content_absence_error(reason)}
      end
    else
      {:error, reason} -> {:error, normalize_content_absence_error(reason)}
    end
  rescue
    _ -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
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

    MemoryStore.persist_async(@namespace, "#{agent_id}:#{entry.id}", serialized)
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
      case MemoryStore.load_all(@namespace) do
        {:ok, pairs} ->
          restore_code_entries(pairs)
          Logger.info("CodeStore: loaded #{length(pairs)} entries from Postgres")

        _ ->
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("CodeStore: failed to load from Postgres: #{inspect(e)}")
  end

  defp restore_code_entries(pairs) do
    # Group by agent_id (keys are "agent_id:entry_id")
    grouped =
      Enum.group_by(pairs, fn {key, _data} ->
        key |> String.split(":", parts: 2) |> List.first()
      end)

    Enum.each(grouped, fn {agent_id, agent_pairs} ->
      entries = Enum.map(agent_pairs, fn {_key, data} -> deserialize_entry(data) end)
      if entries != [], do: :ets.insert(@ets_table, {agent_id, entries})
    end)
  end

  # ---------------------------------------------------------------------------
  # Content-only C3I cleanup
  # ---------------------------------------------------------------------------

  defp load_validated_code_entry_ids(agent_id) do
    prefix = agent_id <> ":"

    case MemoryStore.load_by_prefix_tainted_authoritative(@namespace, prefix) do
      {:ok, entries} when is_list(entries) ->
        validate_code_inventory(agent_id, entries)

      {:error, reason} ->
        {:error, map_content_backend_error(reason, :inventory)}

      _ ->
        {:error, :store_unavailable}
    end
  rescue
    _ -> {:error, :store_unavailable}
  catch
    _, _ -> {:error, :store_unavailable}
  end

  defp validate_code_inventory(agent_id, entries) when is_list(entries) do
    validate_code_inventory_entries(entries, agent_id, [], MapSet.new())
  end

  defp validate_code_inventory(_agent_id, _entries), do: {:error, :invalid_record}

  defp validate_code_inventory_entries([], _agent_id, entry_ids, _seen),
    do: {:ok, Enum.reverse(entry_ids)}

  defp validate_code_inventory_entries(
         [{logical_key, %TaintedValue{} = value, status} | rest],
         agent_id,
         entry_ids,
         seen
       )
       when status in @admissible_inventory_statuses do
    with {:ok, entry_id} <- validate_code_inventory_entry(agent_id, logical_key, value),
         false <- MapSet.member?(seen, entry_id) do
      validate_code_inventory_entries(
        rest,
        agent_id,
        [entry_id | entry_ids],
        MapSet.put(seen, entry_id)
      )
    else
      true -> {:error, :ambiguous_record}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_record}
    end
  end

  # :invalid_durable_provenance and any other status fail closed before delete.
  defp validate_code_inventory_entries(
         [{_logical_key, %TaintedValue{}, :invalid_durable_provenance} | _rest],
         _agent_id,
         _entry_ids,
         _seen
       ),
       do: {:error, :invalid_record}

  defp validate_code_inventory_entries(_entries, _agent_id, _entry_ids, _seen),
    do: {:error, :invalid_record}

  # Post-delete absence proof: re-observe exact-agent inventory. Empty and
  # fully admissible inventory is required before cleanup success.
  defp confirm_durable_inventory_empty(agent_id) do
    case load_validated_code_entry_ids(agent_id) do
      {:ok, []} ->
        :ok

      {:ok, _remaining} ->
        # Newly observed or not-yet-deleted durable rows; retryable.
        {:error, :outcome_unknown}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Bind by exact equality with agent_id <> ":" <> payload entry id — never
  # split a bounded agent id out of the logical key.
  defp validate_code_inventory_entry(agent_id, logical_key, %TaintedValue{value: payload}) do
    with :ok <- validate_complete_code_pattern_shape(payload),
         {:ok, entry_id} <- payload_string_field(payload, "id"),
         {:ok, payload_agent_id} <- payload_string_field(payload, "agent_id"),
         true <- payload_agent_id == agent_id,
         true <- logical_key == agent_id <> ":" <> entry_id,
         true <- valid_entry_id?(entry_id) do
      {:ok, entry_id}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp validate_complete_code_pattern_shape(payload)
       when is_map(payload) and not is_struct(payload) do
    with true <- Enum.all?(@required_payload_fields, &Map.has_key?(payload, &1)),
         {:ok, id} <- payload_string_field(payload, "id"),
         true <- valid_entry_id?(id),
         {:ok, agent_id} <- payload_string_field(payload, "agent_id"),
         true <- valid_agent_id_string?(agent_id),
         {:ok, code} <- payload_string_field(payload, "code"),
         true <- byte_size(code) > 0 and String.valid?(code),
         {:ok, language} <- payload_string_field(payload, "language"),
         true <- byte_size(language) > 0 and String.valid?(language),
         {:ok, purpose} <- payload_string_field(payload, "purpose"),
         true <- byte_size(purpose) > 0 and String.valid?(purpose),
         :ok <- validate_created_at_field(Map.get(payload, "created_at")),
         true <- is_map(Map.get(payload, "metadata")) do
      :ok
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp validate_complete_code_pattern_shape(_payload), do: {:error, :invalid_record}

  defp validate_created_at_field(%DateTime{}), do: :ok

  defp validate_created_at_field(value) when is_binary(value) do
    # Persisted code patterns store ISO-8601 timestamps; reject any other string.
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{}, _offset} -> :ok
      _ -> {:error, :invalid_record}
    end
  end

  defp validate_created_at_field(_), do: {:error, :invalid_record}

  defp payload_string_field(payload, key) when is_map(payload) do
    case Map.get(payload, key) do
      value when is_binary(value) and byte_size(value) > 0 ->
        # String.valid?/1 is not guard-safe; check in the clause body.
        if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_record}

      _ ->
        {:error, :invalid_record}
    end
  end

  defp delete_code_records(_agent_id, []), do: :ok

  defp delete_code_records(agent_id, [entry_id | rest]) do
    logical_key = agent_id <> ":" <> entry_id

    case MemoryStore.delete_tainted_authoritative(@namespace, logical_key) do
      :ok ->
        delete_code_records(agent_id, rest)

      {:error, reason} ->
        {:error, map_content_backend_error(reason, :delete)}

      _ ->
        {:error, :delete_failed}
    end
  end

  # Only initial :undefined is genuine absence; post-defined races fail closed.
  defp confirm_code_ets_evicted(agent_id) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        :ok

      _tid ->
        true = :ets.delete(@ets_table, agent_id)

        case :ets.lookup(@ets_table, agent_id) do
          [] -> :ok
          _ -> {:error, :ets_failed}
        end
    end
  rescue
    ArgumentError -> {:error, :ets_failed}
  catch
    _, _ -> {:error, :ets_failed}
  end

  # Only a missing ETS key proves projection absence. A present row whose value
  # is an empty list is still a projected row and must return false.
  defp code_ets_absent?(agent_id) do
    case :ets.whereis(@ets_table) do
      :undefined ->
        {:ok, true}

      _tid ->
        case :ets.lookup(@ets_table, agent_id) do
          [] -> {:ok, true}
          _ -> {:ok, false}
        end
    end
  rescue
    ArgumentError -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    if valid_agent_id_string?(agent_id), do: :ok, else: {:error, :invalid_agent_id}
  end

  defp validate_agent_id(_agent_id), do: {:error, :invalid_agent_id}

  defp valid_agent_id_string?(agent_id) when is_binary(agent_id) do
    byte_size(agent_id) > 0 and byte_size(agent_id) <= @max_agent_id_bytes and
      String.valid?(agent_id) and String.trim(agent_id) != ""
  end

  defp valid_agent_id_string?(_), do: false

  defp valid_entry_id?(entry_id) when is_binary(entry_id) do
    byte_size(entry_id) > 0 and byte_size(entry_id) <= @max_entry_id_bytes and
      String.valid?(entry_id) and String.trim(entry_id) != ""
  end

  defp valid_entry_id?(_), do: false

  defp normalize_content_delete_error(reason) when reason in @content_delete_errors, do: reason
  defp normalize_content_delete_error(:invalid_request), do: :invalid_agent_id
  defp normalize_content_delete_error(:not_found), do: :delete_failed
  defp normalize_content_delete_error(:absence_uncertain), do: :store_unavailable
  defp normalize_content_delete_error(_reason), do: :delete_failed

  defp normalize_content_absence_error(reason) when reason in @content_absence_errors, do: reason
  defp normalize_content_absence_error(:invalid_request), do: :invalid_agent_id
  defp normalize_content_absence_error(:not_found), do: :absence_uncertain
  defp normalize_content_absence_error(:delete_failed), do: :store_unavailable
  defp normalize_content_absence_error(:ets_failed), do: :absence_uncertain
  defp normalize_content_absence_error(:outcome_unknown), do: :absence_uncertain
  defp normalize_content_absence_error(:conflict), do: :absence_uncertain
  defp normalize_content_absence_error(_reason), do: :absence_uncertain

  defp map_content_backend_error({:memory_store, :critical, reason}, mode)
       when reason in [
              :conflict,
              :outcome_unknown,
              :durable_unavailable,
              :insufficient_durability,
              :inventory_limit_exceeded,
              :invalid_record,
              :ambiguous_record
            ] do
    case mode do
      :delete -> normalize_content_delete_error(reason)
      :absence -> normalize_content_absence_error(reason)
      :inventory -> normalize_content_delete_error(reason)
    end
  end

  defp map_content_backend_error({:memory_store, :critical, _reason}, :delete), do: :delete_failed

  defp map_content_backend_error({:memory_store, :critical, _reason}, :inventory),
    do: :store_unavailable

  defp map_content_backend_error({:memory_store, :invalid_durable_provenance, _}, _mode),
    do: :invalid_record

  defp map_content_backend_error({:memory_store, :invalid_request, _}, _mode),
    do: :invalid_agent_id

  defp map_content_backend_error(:not_found, :delete), do: :delete_failed
  defp map_content_backend_error(:not_found, :inventory), do: :store_unavailable
  defp map_content_backend_error(_reason, :delete), do: :delete_failed
  defp map_content_backend_error(_reason, :inventory), do: :store_unavailable
end
