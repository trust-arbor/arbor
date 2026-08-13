defmodule Arbor.Memory.PreferencesStore do
  @moduledoc """
  ETS-backed storage for agent preferences with signal emission.

  Stateless module (not a GenServer) — the ETS table is created in
  `Application.start/2`. Owns the full CRUD + signal lifecycle.
  """

  alias Arbor.Memory.{MemoryStore, MutationAdmission, Preferences, Signals}

  require Logger

  @preferences_ets :arbor_preferences
  @namespace "preferences"
  @max_agent_id_bytes 256

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
  # Core CRUD
  # ============================================================================

  @doc """
  Get preferences for an agent. Returns nil if not set.
  """
  @spec get_preferences(String.t()) :: Preferences.t() | nil
  def get_preferences(agent_id) do
    case :ets.lookup(@preferences_ets, agent_id) do
      [{^agent_id, prefs}] -> prefs
      [] -> nil
    end
  end

  @doc """
  Save preferences for an agent.
  """
  @spec save_preferences(String.t(), Preferences.t()) :: :ok | {:error, :store_unavailable}
  def save_preferences(agent_id, prefs) do
    commit_preferences(agent_id, prefs, fn -> :ok end)
  end

  @doc """
  Get or create preferences for an agent.
  """
  @spec get_or_create(String.t()) :: Preferences.t() | {:error, :store_unavailable}
  def get_or_create(agent_id) do
    case get_preferences(agent_id) do
      nil ->
        prefs = Preferences.new(agent_id)

        case commit_preferences(agent_id, prefs, fn -> :ok end) do
          :ok -> prefs
          {:error, :store_unavailable} = error -> error
        end

      prefs ->
        prefs
    end
  end

  # ============================================================================
  # Content-only cleanup (C3I0C2)
  # ============================================================================

  @doc """
  Idempotent content-only deletion for exactly one agent.

  Removes durable preferences content and the exact ETS projection row.
  Retains every Provenance sidecar byte-for-byte.

  C3I2A precondition (caller-owned, not enforced here): C3I1 mutation gate
  must be closed and drained before invoke. This API is not race-free agent
  destruction.
  """
  @spec delete_agent_content(String.t()) :: :ok | {:error, content_cleanup_error()}
  def delete_agent_content(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      delete_authoritative_content_only(agent_id)
    end
  rescue
    _ -> {:error, :delete_failed}
  catch
    _, _ -> {:error, :delete_failed}
  end

  @doc """
  Authoritative absence across durable preferences and ETS projection.
  Returns `{:ok, true}` only when no exact-agent content remains.
  """
  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()} | {:error, content_cleanup_error()}
  def agent_content_absent?(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      do_agent_content_absent?(agent_id)
    end
  rescue
    _ -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  # ============================================================================
  # Preference Operations
  # ============================================================================

  @doc """
  Adjust a cognitive preference for an agent.

  ## Parameters

  - `:decay_rate` - 0.01 to 0.50
  - `:max_pins` - 1 to 200
  - `:retrieval_threshold` - 0.0 to 1.0
  - `:consolidation_interval` - 60,000ms to 3,600,000ms
  - `:attention_focus` - String or nil
  - `:type_quota` - Tuple of {type, quota}
  - `:context_preference` - Tuple of {key, value}
  """
  @spec adjust_preference(String.t(), atom(), term(), keyword()) ::
          {:ok, Preferences.t()} | {:error, term()}
  def adjust_preference(agent_id, param, value, opts \\ []) do
    prefs = current_or_default(agent_id)

    case Preferences.adjust(prefs, param, value, opts) do
      {:ok, updated_prefs} ->
        case commit_preferences(agent_id, updated_prefs, fn ->
               Signals.emit_cognitive_adjustment(agent_id, param, %{
                 old_value: Map.get(prefs, param),
                 new_value: value
               })
             end) do
          :ok -> {:ok, updated_prefs}
          {:error, :store_unavailable} = error -> error
        end

      error ->
        error
    end
  end

  @doc """
  Pin a memory to protect it from decay.
  """
  @spec pin_memory(String.t(), String.t(), keyword()) ::
          {:ok, Preferences.t()} | {:error, :max_pins_reached | :store_unavailable}
  def pin_memory(agent_id, memory_id, opts \\ []) do
    prefs = current_or_default(agent_id)

    case Preferences.pin(prefs, memory_id, opts) do
      {:error, _} = error ->
        error

      updated_prefs ->
        case commit_preferences(agent_id, updated_prefs, fn ->
               Signals.emit_cognitive_adjustment(agent_id, :pin_memory, %{memory_id: memory_id})
             end) do
          :ok -> {:ok, updated_prefs}
          {:error, :store_unavailable} = error -> error
        end
    end
  end

  @doc """
  Unpin a memory, allowing it to decay normally.
  """
  @spec unpin_memory(String.t(), String.t()) ::
          {:ok, Preferences.t()} | {:error, :store_unavailable}
  def unpin_memory(agent_id, memory_id) do
    prefs = current_or_default(agent_id)
    updated_prefs = Preferences.unpin(prefs, memory_id)

    case commit_preferences(agent_id, updated_prefs, fn ->
           Signals.emit_cognitive_adjustment(agent_id, :unpin_memory, %{memory_id: memory_id})
         end) do
      :ok -> {:ok, updated_prefs}
      {:error, :store_unavailable} = error -> error
    end
  end

  @doc """
  Get a summary of current preferences and usage.
  """
  @spec inspect_preferences(String.t()) :: map()
  def inspect_preferences(agent_id) do
    case get_preferences(agent_id) do
      nil -> %{agent_id: agent_id, status: :not_initialized}
      prefs -> Preferences.inspect_preferences(prefs)
    end
  end

  @doc """
  Get an introspection of current preferences.
  """
  @spec introspect_preferences(String.t()) :: map()
  def introspect_preferences(agent_id) do
    case get_preferences(agent_id) do
      nil -> %{agent_id: agent_id, status: :not_initialized}
      prefs -> Preferences.introspect(prefs)
    end
  end

  @doc """
  Set a context preference for prompt building.
  """
  @spec set_context_preference(String.t(), atom(), term()) ::
          {:ok, Preferences.t()} | {:error, :store_unavailable}
  def set_context_preference(agent_id, key, value) do
    prefs = current_or_default(agent_id)
    {:ok, updated_prefs} = Preferences.set_context_preference(prefs, key, value)

    case commit_preferences(agent_id, updated_prefs, fn ->
           Signals.emit_cognitive_adjustment(agent_id, :context_preference, %{
             key: key,
             value: value
           })
         end) do
      :ok -> {:ok, updated_prefs}
      {:error, :store_unavailable} = error -> error
    end
  end

  @doc """
  Get a context preference value.
  """
  @spec get_context_preference(String.t(), atom(), term()) :: term()
  def get_context_preference(agent_id, key, default \\ nil) do
    case get_preferences(agent_id) do
      nil -> default
      prefs -> Preferences.get_context_preference(prefs, key, default)
    end
  end

  @doc """
  Save preferences for an agent (public wrapper for Seed restore).
  """
  @spec save_preferences_for_agent(String.t(), Preferences.t()) ::
          :ok | {:error, :store_unavailable}
  def save_preferences_for_agent(agent_id, prefs) do
    save_preferences(agent_id, prefs)
  end

  @doc """
  Restore persisted preferences into ETS on startup.

  Called from Application.start. Loads all preferences from the
  MemoryStore backend into ETS for fast access.
  """
  @spec restore_from_store() :: :ok
  def restore_from_store do
    if store_available?() do
      case MemoryStore.load_all(@namespace) do
        {:ok, pairs} when pairs != [] ->
          restored = count_projected_pairs(pairs)

          Logger.info("[PreferencesStore] Restored #{restored} preferences from store")

        _ ->
          :ok
      end
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ===========================================================================
  # Private — Persistence
  # ===========================================================================

  defp current_or_default(agent_id) do
    case get_preferences(agent_id) do
      nil -> Preferences.new(agent_id)
      prefs -> prefs
    end
  end

  defp count_projected_pairs(pairs) do
    Enum.count(pairs, &(project_loaded_pair(&1) == :ok))
  end

  defp commit_preferences(agent_id, prefs, after_ets_fun) do
    data = Preferences.serialize(prefs)

    case MemoryStore.reserve_persist_async(@namespace, agent_id, data, agent_id: agent_id) do
      {:ok, reservation} ->
        admit_and_commit(agent_id, prefs, reservation, after_ets_fun)

      {:error, _reason} ->
        {:error, :store_unavailable}
    end
  end

  defp admit_and_commit(agent_id, prefs, reservation, after_ets_fun) do
    case MutationAdmission.acquire(agent_id) do
      {:ok, lease} ->
        try do
          :ets.insert(@preferences_ets, {agent_id, prefs})
          after_ets_fun.()

          case MemoryStore.activate_async(reservation) do
            :ok -> :ok
            {:error, _reason} -> {:error, :store_unavailable}
          end
        catch
          kind, reason ->
            _ = MemoryStore.cancel_async(reservation)
            :erlang.raise(kind, reason, __STACKTRACE__)
        after
          _ = MutationAdmission.release(lease)
        end

      {:error, _reason} ->
        _ = MemoryStore.cancel_async(reservation)
        {:error, :store_unavailable}
    end
  end

  defp project_loaded_pair({key, data}) do
    with agent_id when is_binary(agent_id) <- extract_agent_id(key),
         :ok <- validate_agent_id(agent_id),
         {:ok, prefs} <- safe_deserialize(data),
         true <- prefs.agent_id == agent_id,
         {:ok, %{gate: :open}} <- MutationAdmission.status(agent_id),
         {:ok, lease} <- MutationAdmission.acquire(agent_id) do
      try do
        :ets.insert(@preferences_ets, {agent_id, prefs})
        :ok
      after
        _ = MutationAdmission.release(lease)
      end
    else
      _ -> :skip
    end
  end

  defp safe_deserialize(data) when is_map(data) do
    prefs = Preferences.deserialize(data)

    if is_binary(prefs.agent_id) and prefs.agent_id != "" do
      {:ok, prefs}
    else
      :error
    end
  rescue
    _ -> :error
  end

  defp safe_deserialize(_data), do: :error

  defp store_available? do
    MemoryStore.available?()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp extract_agent_id(key) when is_binary(key) do
    # Keys may be "preferences:agent_id" or just "agent_id"
    case String.split(key, ":", parts: 2) do
      [_ns, agent_id] -> agent_id
      [agent_id] -> agent_id
    end
  end

  defp extract_agent_id(_), do: nil

  # Content-only C3I cleanup: durable first, then confirmed ETS. Never touches sidecars.
  defp delete_authoritative_content_only(agent_id) do
    durable_result =
      case MemoryStore.delete_tainted_authoritative(@namespace, agent_id) do
        :ok -> :ok
        {:error, reason} -> {:error, map_content_backend_error(reason, :delete)}
        _ -> {:error, :delete_failed}
      end

    projection_result = confirm_preferences_ets_evicted(agent_id)

    case {durable_result, projection_result} do
      {:ok, :ok} ->
        :ok

      {{:error, reason}, _} ->
        {:error, normalize_content_delete_error(reason)}

      {:ok, {:error, reason}} ->
        {:error, normalize_content_delete_error(reason)}

      _ ->
        {:error, :delete_failed}
    end
  rescue
    _ -> {:error, :delete_failed}
  catch
    _, _ -> {:error, :delete_failed}
  end

  defp do_agent_content_absent?(agent_id) do
    case MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id) do
      {:ok, _value, _status, _record, _location} ->
        {:ok, false}

      {:error, :not_found} ->
        case preferences_ets_absent?(agent_id) do
          {:ok, true} -> {:ok, true}
          {:ok, false} -> {:ok, false}
          {:error, reason} -> {:error, normalize_content_absence_error(reason)}
        end

      {:error, reason} ->
        {:error, map_content_backend_error(reason, :absence)}

      _ ->
        {:error, :absence_uncertain}
    end
  rescue
    _ -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  # Only initial :undefined is genuine absence; post-defined races fail closed.
  defp confirm_preferences_ets_evicted(agent_id) do
    case :ets.whereis(@preferences_ets) do
      :undefined ->
        :ok

      _tid ->
        true = :ets.delete(@preferences_ets, agent_id)

        case :ets.lookup(@preferences_ets, agent_id) do
          [] -> :ok
          _ -> {:error, :ets_failed}
        end
    end
  rescue
    ArgumentError -> {:error, :ets_failed}
  catch
    _, _ -> {:error, :ets_failed}
  end

  defp preferences_ets_absent?(agent_id) do
    case :ets.whereis(@preferences_ets) do
      :undefined ->
        {:ok, true}

      _tid ->
        case :ets.lookup(@preferences_ets, agent_id) do
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
    if byte_size(agent_id) > 0 and byte_size(agent_id) <= @max_agent_id_bytes and
         String.valid?(agent_id) and String.trim(agent_id) != "" do
      :ok
    else
      {:error, :invalid_agent_id}
    end
  end

  defp validate_agent_id(_agent_id), do: {:error, :invalid_agent_id}

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
    end
  end

  defp map_content_backend_error({:memory_store, :critical, _reason}, :delete), do: :delete_failed

  defp map_content_backend_error({:memory_store, :critical, _reason}, :absence),
    do: :absence_uncertain

  defp map_content_backend_error({:memory_store, :invalid_durable_provenance, _}, :delete),
    do: :invalid_record

  defp map_content_backend_error({:memory_store, :invalid_durable_provenance, _}, :absence),
    do: :invalid_record

  defp map_content_backend_error({:memory_store, :invalid_request, _}, :delete),
    do: :invalid_agent_id

  defp map_content_backend_error({:memory_store, :invalid_request, _}, :absence),
    do: :invalid_agent_id

  defp map_content_backend_error(:not_found, :delete), do: :delete_failed
  defp map_content_backend_error(:not_found, :absence), do: :absence_uncertain
  defp map_content_backend_error(_reason, :delete), do: :delete_failed
  defp map_content_backend_error(_reason, :absence), do: :absence_uncertain
end
