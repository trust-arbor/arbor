defmodule Arbor.Memory.WorkingMemoryStore do
  @moduledoc """
  ETS-backed working-memory storage with durable, per-item provenance.

  Compatibility reads return only `WorkingMemory`. Taint-aware reads expose an
  aggregate `TaintedValue` and explicit per-item provenance statuses without
  adding labels to working-memory content or prompt projections.
  """

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}
  alias Arbor.Memory.{MemoryStore, MutationAdmission, Provenance, Signals, WorkingMemory}

  @working_memory_ets :arbor_working_memory
  @namespace "working_memory"
  @wrapper_version 2
  @legacy_wrapper_version 1
  @provenance_snapshot_kind "arbor_working_memory_provenance"
  @provenance_snapshot_version 1
  @max_agent_id_bytes 256
  @max_item_id_bytes 128
  @max_cas_attempts 12
  @transition_lock_retries 50
  @base_domain :working_memory_base
  @aggregate_domain :working_memory_aggregate
  @base_sidecar_id "base"
  @aggregate_sidecar_id "aggregate"

  # These caps stay below the C0 envelope's worst-case node budget even when
  # every label carries the maximum provenance chain.
  @collection_specs [
    {:recent_thoughts, "recent_thoughts", :working_memory_thought, 64, nil},
    {:active_goals, "active_goals", :working_memory_goal, 24, nil},
    {:active_skills, "active_skills", :working_memory_skill, 8, nil},
    {:concerns, "concerns", :working_memory_concern, 16, :concern_ids},
    {:curiosity, "curiosity", :working_memory_curiosity, 32, :curiosity_ids}
  ]
  @itemized_payload_keys Enum.map(@collection_specs, &elem(&1, 1)) ++
                           ["concern_ids", "curiosity_ids"]
  @working_memory_domains [@base_domain, @aggregate_domain] ++
                            Enum.map(@collection_specs, &elem(&1, 2))

  @wrapper_keys ["payload", "provenance", "version"]
  @provenance_keys [
    "active_goals",
    "active_skills",
    "aggregate",
    "base",
    "concerns",
    "curiosity",
    "recent_thoughts"
  ]
  @legacy_provenance_keys [
    "active_goals",
    "active_skills",
    "aggregate",
    "base",
    "recent_thoughts"
  ]
  @entry_keys ["envelope", "status"]
  @provenance_snapshot_keys [
    "outer_envelope",
    "snapshot_kind",
    "snapshot_version",
    "working_memory"
  ]

  @type provenance_status ::
          :verified | :legacy_unlabeled | :invalid_durable_provenance

  @type tainted_item :: %{
          id: String.t(),
          value: TaintedValue.t(),
          provenance_status: provenance_status()
        }

  @type tainted_read :: %{
          value: TaintedValue.t(),
          provenance_status: provenance_status(),
          items: %{
            recent_thoughts: [tainted_item()],
            active_goals: [tainted_item()],
            active_skills: [tainted_item()],
            concerns: [tainted_item()],
            curiosity: [tainted_item()]
          }
        }

  @doc "Returns the current raw working memory or nil when absent."
  @spec get_working_memory(String.t()) :: WorkingMemory.t() | nil
  def get_working_memory(agent_id) do
    case get_working_memory_tainted(agent_id) do
      {:ok, %{value: %TaintedValue{value: %WorkingMemory{} = wm}}} -> wm
      {:error, _reason} -> nil
    end
  end

  @doc """
  Return authoritative working memory with aggregate and per-item provenance.

  The durable wrapper is the inventory authority. A successful read refreshes
  the ETS and sidecar projection; malformed or mismatched durable provenance
  fails closed.
  """
  @spec get_working_memory_tainted(String.t()) ::
          {:ok, tainted_read()} | {:error, term()}
  def get_working_memory_tainted(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      with_admitted_agent_transition(agent_id, fn ->
        authoritative_read(agent_id, :existing, [])
      end)
    end
  rescue
    _ -> error(:load_failed)
  catch
    _, _ -> error(:load_failed)
  end

  @doc """
  Save through the raw compatibility boundary.

  Existing unchanged item labels are retained. New or changed items without an
  explicit label are conservatively joined with the legacy-unlabeled fallback.
  """
  @spec save_working_memory(String.t(), WorkingMemory.t()) :: :ok | {:error, term()}
  def save_working_memory(agent_id, %WorkingMemory{} = working_memory) do
    do_save(agent_id, working_memory, TaintEnvelope.missing_fallback())
  end

  def save_working_memory(_agent_id, _working_memory),
    do: error(:invalid_working_memory)

  @doc """
  Save working memory with an explicit label for this mutation.

  The supplied label applies to new items and is monotonically joined into
  changed surviving items and changed non-item payload. Unchanged item labels
  remain exact. The label is fully validated before ETS, sidecar, or durable
  effects occur.
  """
  @spec save_working_memory_tainted(String.t(), WorkingMemory.t(), Taint.t()) ::
          :ok | {:error, term()}
  def save_working_memory_tainted(agent_id, %WorkingMemory{} = working_memory, taint) do
    case Taint.canonicalize(taint) do
      {:ok, canonical} -> do_save(agent_id, working_memory, canonical)
      {:error, _reason} -> error(:invalid_provenance)
    end
  end

  def save_working_memory_tainted(_agent_id, _working_memory, _taint),
    do: error(:invalid_working_memory)

  @doc """
  Load working memory with aggregate and per-item provenance.

  A successful authoritative read repairs ETS and sidecars from the durable
  wrapper. Legacy raw records are migrated once with stable IDs and conservative
  labels. Invalid durable records never restore permissive labels.
  """
  @spec load_working_memory_tainted(String.t(), keyword()) ::
          {:ok, tainted_read()} | {:error, term()}
  def load_working_memory_tainted(agent_id, opts \\ []) do
    with :ok <- validate_agent_id(agent_id),
         true <- Keyword.keyword?(opts) do
      with_admitted_agent_transition(agent_id, fn ->
        authoritative_read(agent_id, :create, opts)
      end)
    else
      _ -> error(:invalid_request)
    end
  rescue
    _ -> error(:load_failed)
  catch
    _, _ -> error(:load_failed)
  end

  @doc """
  Load raw working memory, preserving the compatibility return shape.
  """
  @spec load_working_memory(String.t(), keyword()) :: WorkingMemory.t()
  def load_working_memory(agent_id, opts \\ []) do
    case load_working_memory_tainted(agent_id, opts) do
      {:ok, %{value: %TaintedValue{value: %WorkingMemory{} = wm}}} ->
        wm

      {:error, _reason} ->
        fresh_working_memory(agent_id, opts)
    end
  end

  @doc """
  Delete working memory and only the sidecar entries owned by this domain.
  """
  @spec delete_working_memory(String.t()) :: :ok | {:error, term()}
  def delete_working_memory(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      with_admitted_agent_transition(agent_id, fn -> delete_authoritative(agent_id) end)
    end
  rescue
    _ -> error(:delete_failed)
  catch
    _, _ -> error(:delete_failed)
  end

  # Runtime-enforced closed sets for content-cleanup public APIs.
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
    :transition_busy,
    :transition_failed,
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
    :transition_busy,
    :transition_failed,
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
          | :transition_busy
          | :transition_failed
          | :ets_failed
          | :store_unavailable
          | :absence_uncertain

  @doc """
  Idempotent content-only deletion for exactly one agent.

  Removes durable working-memory aggregate content and ETS projection.
  Retains every Provenance sidecar byte-for-byte.

  C3I2A precondition (caller-owned, not enforced here): C3I1 mutation gate
  must be closed and drained before invoke. This API is not race-free agent
  destruction.
  """
  @spec delete_agent_content(String.t()) :: :ok | {:error, content_cleanup_error()}
  def delete_agent_content(agent_id) do
    with :ok <- validate_agent_id_flat(agent_id) do
      agent_id
      |> with_agent_transition_flat(fn ->
        delete_authoritative_content_only(agent_id)
      end)
      |> normalize_content_delete_result()
    else
      {:error, reason} -> {:error, normalize_content_delete_error(reason)}
    end
  rescue
    _ -> {:error, :delete_failed}
  catch
    _, _ -> {:error, :delete_failed}
  end

  @doc """
  Authoritative absence across durable working memory and ETS projection.
  Returns `{:ok, true}` only when no exact-agent content remains.
  """
  @spec agent_content_absent?(String.t()) ::
          {:ok, boolean()} | {:error, content_cleanup_error()}
  def agent_content_absent?(agent_id) do
    with :ok <- validate_agent_id_flat(agent_id) do
      agent_id
      |> with_agent_transition_flat(fn -> do_agent_content_absent?(agent_id) end)
      |> normalize_content_absence_result()
    else
      {:error, reason} -> {:error, normalize_content_absence_error(reason)}
    end
  rescue
    _ -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  @doc "Export the exact versioned durable WorkingMemory provenance snapshot."
  @spec export_working_memory_provenance_snapshot(String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def export_working_memory_provenance_snapshot(agent_id) do
    with :ok <- validate_agent_id(agent_id) do
      with_admitted_agent_transition(agent_id, fn ->
        export_authoritative_snapshot(agent_id)
      end)
    end
  rescue
    _ -> error(:snapshot_export_failed)
  catch
    _, _ -> error(:snapshot_export_failed)
  end

  @doc "Validate an exact provenance snapshot without reading or mutating memory state."
  @spec validate_working_memory_provenance_snapshot(String.t(), term()) ::
          :ok | {:error, term()}
  def validate_working_memory_provenance_snapshot(agent_id, exported) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, _snapshot} <- decode_provenance_snapshot(agent_id, exported) do
      :ok
    end
  rescue
    _ -> error(:invalid_provenance_snapshot)
  catch
    _, _ -> error(:invalid_provenance_snapshot)
  end

  @doc "Import a versioned, payload-bound WorkingMemory provenance snapshot."
  @spec import_working_memory_provenance_snapshot(String.t(), term()) ::
          :ok | {:error, term()}
  def import_working_memory_provenance_snapshot(agent_id, exported) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, imported} <- decode_provenance_snapshot(agent_id, exported) do
      with_admitted_agent_transition(agent_id, fn ->
        import_authoritative_snapshot(agent_id, imported, @max_cas_attempts)
      end)
    end
  rescue
    _ -> error(:snapshot_import_failed)
  catch
    _, _ -> error(:snapshot_import_failed)
  end

  @doc "Return true when a map declares or resembles the provenance snapshot format."
  @spec working_memory_provenance_snapshot?(term()) :: boolean()
  def working_memory_provenance_snapshot?(value) when is_map(value) and not is_struct(value) do
    Enum.any?(
      [
        "snapshot_kind",
        "snapshot_version",
        "working_memory",
        "outer_envelope",
        :snapshot_kind,
        :snapshot_version,
        :working_memory,
        :outer_envelope
      ],
      &Map.has_key?(value, &1)
    )
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def working_memory_provenance_snapshot?(_value), do: false

  # -- Save --------------------------------------------------------------------

  defp do_save(agent_id, working_memory, supplied_taint) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, prepared} <- prepare_working_memory(agent_id, working_memory) do
      with_admitted_agent_transition(agent_id, fn ->
        result = save_authoritative(agent_id, prepared, supplied_taint, @max_cas_attempts)

        case result do
          {:ok, snapshot} ->
            safe_emit_working_memory_saved(agent_id, snapshot)
            :ok

          {:error, _reason} = error ->
            error
        end
      end)
    else
      {:error, _reason} = error -> error
      _ -> error(:save_failed)
    end
  rescue
    _ -> error(:save_failed)
  catch
    _, _ -> error(:save_failed)
  end

  defp save_authoritative(_agent_id, _prepared, _supplied_taint, 0),
    do: error(:conflict)

  defp save_authoritative(agent_id, prepared, supplied_taint, attempts) do
    case load_durable_snapshot(agent_id) do
      {:ok, previous, _source, reference} ->
        commit_authoritative_snapshot(
          agent_id,
          prepared,
          previous,
          reference.record,
          supplied_taint,
          attempts
        )

      :not_found ->
        commit_authoritative_snapshot(
          agent_id,
          prepared,
          nil,
          :not_found,
          supplied_taint,
          attempts
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp commit_authoritative_snapshot(
         agent_id,
         prepared,
         previous,
         expected_record,
         supplied_taint,
         attempts
       ) do
    with {:ok, snapshot} <- reconcile_snapshot(prepared, previous, supplied_taint),
         {:ok, wrapper} <- build_wrapper(snapshot) do
      case MemoryStore.compare_and_swap_tainted(
             @namespace,
             agent_id,
             expected_record,
             wrapper,
             taint: snapshot.aggregate.taint
           ) do
        {:ok, %Record{}} ->
          best_effort_install_snapshot(agent_id, snapshot)
          {:ok, snapshot}

        {:error, {:memory_store, :critical, :conflict}} ->
          save_authoritative(agent_id, prepared, supplied_taint, attempts - 1)

        {:error, _reason} = error ->
          map_memory_store_error(error)

        _ ->
          error(:persistence_failed)
      end
    end
  end

  defp reconcile_snapshot(prepared, previous, supplied_taint) do
    supplied = label_record(supplied_taint, status_for_taint(supplied_taint))
    base = reconcile_base(prepared, previous, supplied)

    items =
      Map.new(@collection_specs, fn {field, _durable_key, _domain, _max, _id_field} ->
        previous_items = previous_items_by_id(previous, field)

        labelled =
          prepared.collections[field].items
          |> Enum.map(fn item ->
            previous_item = Map.get(previous_items, item.id)
            Map.put(item, :label, reconcile_item(item, previous_item, supplied))
          end)

        {field, labelled}
      end)

    component_aggregate = aggregate_label(base, items)

    aggregate =
      reconcile_aggregate(prepared, previous, supplied, component_aggregate)

    {:ok,
     %{
       prepared: prepared,
       base: base,
       items: items,
       aggregate: aggregate,
       sidecar_absent?: false
     }}
  end

  defp reconcile_base(_prepared, nil, supplied), do: supplied

  defp reconcile_base(prepared, previous, supplied) do
    if prepared.base_payload == previous.prepared.base_payload do
      previous.base
    else
      join_label_records([previous.base, supplied])
    end
  end

  defp reconcile_item(_item, nil, supplied), do: supplied

  defp reconcile_item(item, previous_item, supplied) do
    if item.payload == previous_item.payload do
      previous_item.label
    else
      join_label_records([previous_item.label, supplied])
    end
  end

  defp reconcile_aggregate(_prepared, nil, _supplied, component_aggregate),
    do: component_aggregate

  defp reconcile_aggregate(prepared, previous, supplied, component_aggregate) do
    if prepared.payload == previous.prepared.payload do
      previous.aggregate
    else
      join_label_records([previous.aggregate, supplied, component_aggregate])
    end
  end

  defp previous_items_by_id(nil, _field), do: %{}

  defp previous_items_by_id(previous, field) do
    Map.new(previous.items[field], &{&1.id, &1})
  end

  # -- Portable provenance snapshots ------------------------------------------

  defp export_authoritative_snapshot(agent_id) do
    case authoritative_read(agent_id, :existing, []) do
      {:ok, _read} -> package_authoritative_snapshot(agent_id)
      {:error, {:working_memory_store, :not_found}} -> {:ok, nil}
      {:error, _reason} = error -> error
      _ -> error(:snapshot_export_failed)
    end
  end

  defp package_authoritative_snapshot(agent_id) do
    case load_durable_snapshot(agent_id) do
      {:ok, snapshot, :verified, %{record: %Record{data: wrapper, metadata: metadata}}}
      when is_map(metadata) ->
        outer_envelope = Map.get(metadata, "taint")

        with @wrapper_version <- wrapper["version"],
             {:ok, outer} <- TaintEnvelope.verify(outer_envelope, wrapper),
             true <- outer.taint == snapshot.aggregate.taint,
             {:ok, _decoded} <- decode_wrapper(agent_id, wrapper, outer.taint) do
          {:ok,
           %{
             "snapshot_kind" => @provenance_snapshot_kind,
             "snapshot_version" => @provenance_snapshot_version,
             "working_memory" => wrapper,
             "outer_envelope" => outer_envelope
           }}
        else
          _ -> error(:invalid_provenance_snapshot)
        end

      :not_found ->
        {:ok, nil}

      {:error, _reason} = error ->
        error

      _ ->
        error(:invalid_provenance_snapshot)
    end
  end

  defp decode_provenance_snapshot(agent_id, exported) do
    with true <- exact_string_keys?(exported, @provenance_snapshot_keys),
         @provenance_snapshot_kind <- exported["snapshot_kind"],
         @provenance_snapshot_version <- exported["snapshot_version"],
         wrapper when is_map(wrapper) <- exported["working_memory"],
         @wrapper_version <- wrapper["version"],
         {:ok, outer} <- TaintEnvelope.verify(exported["outer_envelope"], wrapper),
         {:ok, snapshot} <- decode_wrapper(agent_id, wrapper, outer.taint) do
      {:ok, snapshot}
    else
      _ -> error(:invalid_provenance_snapshot)
    end
  rescue
    _ -> error(:invalid_provenance_snapshot)
  catch
    _, _ -> error(:invalid_provenance_snapshot)
  end

  defp import_authoritative_snapshot(_agent_id, _imported, 0), do: error(:conflict)

  defp import_authoritative_snapshot(agent_id, imported, attempts) do
    case load_durable_snapshot(agent_id) do
      {:ok, current, _source, reference} ->
        imported
        |> merge_imported_snapshot(current)
        |> commit_imported_snapshot(agent_id, reference.record, attempts)

      :not_found ->
        commit_imported_snapshot(imported, agent_id, :not_found, attempts)

      {:error, _reason} = error ->
        error
    end
  end

  defp commit_imported_snapshot(snapshot, agent_id, expected_record, attempts) do
    with {:ok, wrapper} <- build_wrapper(snapshot) do
      case MemoryStore.compare_and_swap_tainted(
             @namespace,
             agent_id,
             expected_record,
             wrapper,
             taint: snapshot.aggregate.taint
           ) do
        {:ok, %Record{}} ->
          best_effort_install_snapshot(agent_id, snapshot)
          safe_emit_working_memory_loaded(agent_id, :restored)
          :ok

        {:error, {:memory_store, :critical, :conflict}} ->
          import_authoritative_snapshot(agent_id, snapshot, attempts - 1)

        {:error, _reason} = error ->
          map_memory_store_error(error)

        _ ->
          error(:persistence_failed)
      end
    end
  end

  defp merge_imported_snapshot(imported, current) do
    base = join_label_records([current.base, imported.base])

    items =
      Map.new(@collection_specs, fn {field, _durable_key, _domain, _max, _id_field} ->
        current_items = previous_items_by_id(current, field)

        imported_items =
          Enum.map(imported.items[field], fn item ->
            case Map.get(current_items, item.id) do
              nil ->
                item

              current_item ->
                Map.update!(item, :label, &join_label_records([current_item.label, &1]))
            end
          end)

        {field, imported_items}
      end)

    component_aggregate = aggregate_label(base, items)

    aggregate =
      join_label_records([current.aggregate, imported.aggregate, component_aggregate])

    %{imported | base: base, items: items, aggregate: aggregate}
  end

  # -- Load --------------------------------------------------------------------

  defp authoritative_read(agent_id, mode, opts) do
    authoritative_read(agent_id, mode, opts, @max_cas_attempts)
  end

  defp authoritative_read(_agent_id, _mode, _opts, 0), do: error(:conflict)

  defp authoritative_read(agent_id, mode, opts, attempts) do
    case load_durable_snapshot(agent_id) do
      {:ok, snapshot, source, reference} ->
        restore_authoritative_snapshot(
          agent_id,
          snapshot,
          source,
          reference,
          mode,
          opts,
          attempts
        )

      :not_found ->
        best_effort_clear_projection(agent_id)

        case mode do
          :existing -> error(:not_found)
          :create -> create_authoritative_snapshot(agent_id, opts, attempts)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp create_authoritative_snapshot(agent_id, opts, attempts) do
    with %WorkingMemory{} = wm <- fresh_working_memory(agent_id, opts),
         {:ok, prepared} <- prepare_working_memory(agent_id, wm),
         {:ok, snapshot} <-
           reconcile_snapshot(prepared, nil, TaintEnvelope.missing_fallback()),
         {:ok, wrapper} <- build_wrapper(snapshot) do
      case MemoryStore.compare_and_swap_tainted(
             @namespace,
             agent_id,
             :not_found,
             wrapper,
             taint: snapshot.aggregate.taint
           ) do
        {:ok, %Record{}} ->
          best_effort_install_snapshot(agent_id, snapshot)
          safe_emit_working_memory_loaded(agent_id, :created)
          {:ok, public_read(snapshot)}

        {:error, {:memory_store, :critical, :conflict}} ->
          authoritative_read(agent_id, :create, opts, attempts - 1)

        {:error, _reason} = error ->
          map_memory_store_error(error)

        _ ->
          error(:persistence_failed)
      end
    else
      {:error, _reason} = error -> error
      _ -> error(:load_failed)
    end
  end

  defp restore_authoritative_snapshot(
         agent_id,
         snapshot,
         :invalid,
         _reference,
         _mode,
         _opts,
         _attempts
       ) do
    best_effort_install_snapshot(agent_id, snapshot)
    safe_emit_working_memory_loaded(agent_id, :restored)
    {:ok, public_read(snapshot)}
  end

  defp restore_authoritative_snapshot(
         agent_id,
         snapshot,
         source,
         reference,
         mode,
         opts,
         attempts
       ) do
    if source == :verified do
      best_effort_install_snapshot(agent_id, snapshot)
      {:ok, public_read(snapshot)}
    else
      migrate_authoritative_snapshot(agent_id, snapshot, reference, mode, opts, attempts)
    end
  end

  defp migrate_authoritative_snapshot(agent_id, snapshot, reference, mode, opts, attempts) do
    with {:ok, wrapper} <- build_wrapper(snapshot) do
      case MemoryStore.compare_and_swap_tainted(
             @namespace,
             agent_id,
             reference.record,
             wrapper,
             taint: snapshot.aggregate.taint
           ) do
        {:ok, %Record{}} ->
          best_effort_install_snapshot(agent_id, snapshot)
          safe_emit_working_memory_loaded(agent_id, :restored)
          {:ok, public_read(snapshot)}

        {:error, {:memory_store, :critical, :conflict}} ->
          authoritative_read(agent_id, mode, opts, attempts - 1)

        {:error, _reason} = error ->
          map_memory_store_error(error)

        _ ->
          error(:persistence_failed)
      end
    end
  end

  defp load_durable_snapshot(agent_id) do
    case MemoryStore.load_tainted_authoritative_with_status(@namespace, agent_id) do
      {:ok, %TaintedValue{value: data, taint: outer_taint}, status, %Record{} = record, location} ->
        reference = %{record: record, location: location}
        decode_durable_value(agent_id, data, outer_taint, status, reference)

      {:error, :not_found} ->
        :not_found

      {:error, _reason} = error ->
        map_memory_store_error(error)

      _ ->
        error(:durable_load_failed)
    end
  rescue
    _ -> error(:durable_load_failed)
  catch
    _, _ -> error(:durable_load_failed)
  end

  defp decode_durable_value(agent_id, data, outer_taint, :verified, reference) do
    case decode_wrapper(agent_id, data, outer_taint) do
      {:ok, snapshot} ->
        source = if data["version"] == @wrapper_version, do: :verified, else: :legacy_wrapper
        {:ok, snapshot, source, reference}

      {:error, _reason} ->
        {:ok, fallback_from_data(agent_id, data, :invalid), :invalid, reference}
    end
  end

  defp decode_durable_value(agent_id, data, _outer_taint, :legacy_unlabeled, reference) do
    if wrapper_shaped?(data) do
      case decode_wrapper(agent_id, data, :ignore) do
        {:ok, snapshot} ->
          {:ok, conservative_inner_snapshot(snapshot), :legacy_inner, reference}

        {:error, _reason} ->
          {:ok, fallback_from_data(agent_id, data, :invalid), :invalid, reference}
      end
    else
      {:ok, fallback_from_data(agent_id, data, :legacy), :legacy_payload, reference}
    end
  end

  defp decode_durable_value(agent_id, data, _outer_taint, :invalid_durable_provenance, reference) do
    {:ok, fallback_from_data(agent_id, data, :invalid), :invalid, reference}
  end

  defp decode_durable_value(agent_id, data, _outer_taint, _status, reference) do
    {:ok, fallback_from_data(agent_id, data, :invalid), :invalid, reference}
  end

  # -- Durable wrapper ---------------------------------------------------------

  defp build_wrapper(snapshot) do
    with {:ok, base_entry} <- encode_entry(snapshot.prepared.base_payload, snapshot.base),
         {:ok, aggregate_entry} <-
           encode_entry(snapshot.prepared.payload, snapshot.aggregate),
         {:ok, collection_entries} <- encode_collection_entries(snapshot) do
      provenance =
        collection_entries
        |> Map.put("base", base_entry)
        |> Map.put("aggregate", aggregate_entry)

      wrapper = %{
        "version" => @wrapper_version,
        "payload" => snapshot.prepared.payload,
        "provenance" => provenance
      }

      case TaintEnvelope.new(wrapper, snapshot.aggregate.taint) do
        {:ok, _outer_envelope} -> {:ok, wrapper}
        {:error, _reason} -> error(:wrapper_limit_exceeded)
      end
    else
      {:error, _reason} -> error(:invalid_wrapper)
    end
  end

  defp encode_collection_entries(snapshot) do
    Enum.reduce_while(@collection_specs, {:ok, %{}}, fn {field, durable_key, _domain, _max,
                                                         _id_field},
                                                        {:ok, acc} ->
      result =
        Enum.reduce_while(snapshot.items[field], {:ok, %{}}, fn item, {:ok, entries} ->
          case encode_entry(item.payload, item.label) do
            {:ok, entry} -> {:cont, {:ok, Map.put(entries, item.id, entry)}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      case result do
        {:ok, entries} -> {:cont, {:ok, Map.put(acc, durable_key, entries)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp encode_entry(payload, label) do
    with {:ok, envelope} <- TaintEnvelope.new(payload, label.taint),
         {:ok, persisted} <- TaintEnvelope.to_map(envelope) do
      {:ok, %{"envelope" => persisted, "status" => Atom.to_string(label.status)}}
    end
  end

  defp decode_wrapper(agent_id, data, outer_taint) do
    with true <- exact_string_keys?(data, @wrapper_keys),
         payload when is_map(payload) <- data["payload"],
         provenance when is_map(provenance) <- data["provenance"] do
      case data["version"] do
        @wrapper_version ->
          decode_current_wrapper(agent_id, payload, provenance, outer_taint)

        @legacy_wrapper_version ->
          decode_legacy_wrapper(agent_id, payload, provenance, outer_taint)

        _ ->
          error(:invalid_wrapper)
      end
    else
      _ -> error(:invalid_wrapper)
    end
  rescue
    _ -> error(:invalid_wrapper)
  catch
    _, _ -> error(:invalid_wrapper)
  end

  defp decode_current_wrapper(agent_id, payload, provenance, outer_taint) do
    with true <- exact_string_keys?(provenance, @provenance_keys),
         {:ok, prepared} <- prepare_exact_payload(agent_id, payload),
         {:ok, base} <- decode_entry(provenance["base"], prepared.base_payload),
         {:ok, items} <- decode_collection_entries(prepared, provenance, @collection_specs),
         {:ok, aggregate} <- decode_entry(provenance["aggregate"], prepared.payload),
         component_aggregate <- aggregate_label(base, items),
         true <- label_dominates?(aggregate, component_aggregate),
         true <- outer_taint_matches?(outer_taint, aggregate.taint) do
      {:ok, snapshot(prepared, base, items, aggregate)}
    else
      _ -> error(:invalid_wrapper)
    end
  end

  defp decode_legacy_wrapper(agent_id, payload, provenance, outer_taint) do
    legacy_specs = Enum.take(@collection_specs, 3)

    with true <- exact_string_keys?(provenance, @legacy_provenance_keys),
         {:ok, prepared} <- prepare_legacy_payload(agent_id, payload),
         legacy_base_payload <-
           Map.drop(payload, ["recent_thoughts", "active_goals", "active_skills"]),
         {:ok, base} <- decode_entry(provenance["base"], legacy_base_payload),
         {:ok, legacy_items} <- decode_collection_entries(prepared, provenance, legacy_specs),
         items <- add_legacy_scalar_items(prepared, legacy_items, base),
         {:ok, aggregate} <- decode_entry(provenance["aggregate"], payload),
         component_aggregate <- aggregate_label(base, items),
         true <- label_dominates?(aggregate, component_aggregate),
         true <- outer_taint_matches?(outer_taint, aggregate.taint) do
      {:ok, snapshot(prepared, base, items, aggregate)}
    else
      _ -> error(:invalid_wrapper)
    end
  end

  defp snapshot(prepared, base, items, aggregate) do
    %{
      prepared: prepared,
      base: base,
      items: items,
      aggregate: aggregate,
      sidecar_absent?: false
    }
  end

  defp add_legacy_scalar_items(prepared, items, base) do
    Enum.reduce([:concerns, :curiosity], items, fn field, acc ->
      labelled = Enum.map(prepared.collections[field].items, &Map.put(&1, :label, base))
      Map.put(acc, field, labelled)
    end)
  end

  defp prepare_legacy_payload(agent_id, payload) do
    wm = WorkingMemory.deserialize(payload)

    with {:ok, prepared} <- prepare_working_memory(agent_id, wm),
         true <- Map.drop(prepared.payload, ["concern_ids", "curiosity_ids"]) == payload do
      {:ok, prepared}
    else
      _ -> error(:invalid_wrapper)
    end
  end

  defp decode_collection_entries(prepared, provenance, specs) do
    Enum.reduce_while(specs, {:ok, %{}}, fn {field, durable_key, _domain, _max, _id_field},
                                            {:ok, acc} ->
      persisted = provenance[durable_key]
      expected_ids = Enum.map(prepared.collections[field].items, & &1.id)

      valid_keys =
        is_map(persisted) and not is_struct(persisted) and
          Enum.all?(Map.keys(persisted), &is_binary/1) and
          MapSet.new(Map.keys(persisted)) == MapSet.new(expected_ids) and
          map_size(persisted) == length(expected_ids)

      if valid_keys do
        result =
          Enum.reduce_while(
            prepared.collections[field].items,
            {:ok, []},
            fn item, {:ok, entries} ->
              case decode_entry(persisted[item.id], item.payload) do
                {:ok, label} -> {:cont, {:ok, [Map.put(item, :label, label) | entries]}}
                {:error, _reason} = error -> {:halt, error}
              end
            end
          )

        case result do
          {:ok, entries} ->
            {:cont, {:ok, Map.put(acc, field, Enum.reverse(entries))}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      else
        {:halt, error(:invalid_wrapper)}
      end
    end)
  end

  defp decode_entry(entry, payload) do
    with true <- exact_string_keys?(entry, @entry_keys),
         {:ok, envelope} <- TaintEnvelope.verify(entry["envelope"], payload),
         {:ok, status} <- decode_status(entry["status"]),
         true <- status == status_for_taint(envelope.taint) do
      {:ok, label_record(envelope.taint, status)}
    else
      _ -> error(:invalid_wrapper)
    end
  end

  defp prepare_exact_payload(agent_id, payload) do
    wm = WorkingMemory.deserialize(payload)

    with {:ok, prepared} <- prepare_working_memory(agent_id, wm),
         true <- prepared.payload == payload do
      {:ok, prepared}
    else
      _ -> error(:invalid_wrapper)
    end
  end

  defp outer_taint_matches?(:ignore, _aggregate_taint), do: true
  defp outer_taint_matches?(outer_taint, aggregate_taint), do: outer_taint == aggregate_taint

  defp wrapper_shaped?(data) when is_map(data) do
    Enum.any?(["payload", "provenance", :payload, :provenance], &Map.has_key?(data, &1))
  end

  defp wrapper_shaped?(_data), do: false

  defp fallback_from_data(agent_id, data, kind) do
    prepared = fallback_prepared(agent_id, data)

    taint =
      case kind do
        :legacy -> TaintEnvelope.missing_fallback()
        :invalid -> TaintEnvelope.invalid_fallback()
      end

    fallback_snapshot(prepared, taint)
  end

  defp fallback_prepared(agent_id, data) do
    candidate =
      case data do
        %{"payload" => payload} when is_map(payload) -> payload
        payload when is_map(payload) -> payload
        _ -> %{}
      end

    wm = WorkingMemory.deserialize(candidate)

    wm =
      cond do
        is_nil(wm.agent_id) -> %{wm | agent_id: agent_id}
        wm.agent_id == agent_id -> wm
        true -> WorkingMemory.deserialize(%{"agent_id" => agent_id})
      end

    case prepare_working_memory(agent_id, wm) do
      {:ok, prepared} -> prepared
      {:error, _reason} -> blank_prepared(agent_id)
    end
  end

  defp fallback_snapshot(prepared, taint) do
    label = label_record(taint, status_for_taint(taint))

    items =
      Map.new(@collection_specs, fn {field, _durable_key, _domain, _max, _id_field} ->
        {field, Enum.map(prepared.collections[field].items, &Map.put(&1, :label, label))}
      end)

    %{
      prepared: prepared,
      base: label,
      items: items,
      aggregate: aggregate_label(label, items),
      sidecar_absent?: false
    }
  end

  defp conservative_inner_snapshot(snapshot) do
    missing =
      TaintEnvelope.missing_fallback()
      |> then(&label_record(&1, status_for_taint(&1)))

    base = join_label_records([snapshot.base, missing])

    items =
      Map.new(@collection_specs, fn {field, _durable_key, _domain, _max, _id_field} ->
        labelled =
          Enum.map(snapshot.items[field], fn item ->
            Map.update!(item, :label, &join_label_records([&1, missing]))
          end)

        {field, labelled}
      end)

    component_aggregate = aggregate_label(base, items)
    aggregate = join_label_records([snapshot.aggregate, missing, component_aggregate])

    %{snapshot | base: base, items: items, aggregate: aggregate}
  end

  defp install_snapshot(agent_id, snapshot) do
    with :ok <- put_snapshot_sidecars(agent_id, snapshot),
         :ok <- delete_stale_sidecars(agent_id, snapshot),
         :ok <- safe_ets_insert(agent_id, snapshot.prepared.wm) do
      :ok
    else
      {:error, _reason} = error ->
        _ = clear_working_memory_sidecars(agent_id)
        _ = safe_ets_delete(agent_id)
        error

      _ ->
        _ = clear_working_memory_sidecars(agent_id)
        _ = safe_ets_delete(agent_id)
        error(:sidecar_unavailable)
    end
  end

  defp best_effort_install_snapshot(agent_id, snapshot) do
    _ = install_snapshot(agent_id, snapshot)
    :ok
  rescue
    _ -> best_effort_clear_projection(agent_id)
  catch
    _, _ -> best_effort_clear_projection(agent_id)
  end

  defp best_effort_clear_projection(agent_id) do
    _ = safe_ets_delete(agent_id)
    _ = clear_working_memory_sidecars(agent_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp safe_emit_working_memory_saved(agent_id, snapshot) do
    try do
      Signals.emit_working_memory_saved(agent_id, WorkingMemory.stats(snapshot.prepared.wm))
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp safe_emit_working_memory_loaded(agent_id, status) do
    try do
      Signals.emit_working_memory_loaded(agent_id, status)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp put_snapshot_sidecars(agent_id, snapshot) do
    entries =
      [
        {@base_domain, @base_sidecar_id, snapshot.prepared.base_payload, snapshot.base.taint}
      ] ++
        Enum.flat_map(@collection_specs, fn {field, _key, domain, _max, _id_field} ->
          Enum.map(snapshot.items[field], &{domain, &1.id, &1.payload, &1.label.taint})
        end) ++
        [
          {@aggregate_domain, @aggregate_sidecar_id, snapshot.prepared.payload,
           snapshot.aggregate.taint}
        ]

    Enum.reduce_while(entries, :ok, fn {domain, item_id, payload, taint}, :ok ->
      case Provenance.put(domain, agent_id, item_id, payload, taint) do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, error(:sidecar_unavailable)}
        _ -> {:halt, error(:sidecar_unavailable)}
      end
    end)
  end

  defp delete_stale_sidecars(agent_id, snapshot) do
    Enum.reduce_while(sidecar_inventory(snapshot), :ok, fn {domain, expected_ids}, :ok ->
      case Provenance.list_item_ids(domain, agent_id) do
        {:ok, existing_ids} ->
          expected = MapSet.new(expected_ids)

          result =
            Enum.reduce_while(existing_ids, :ok, fn item_id, :ok ->
              if MapSet.member?(expected, item_id) do
                {:cont, :ok}
              else
                case Provenance.delete(domain, agent_id, item_id) do
                  :ok -> {:cont, :ok}
                  {:error, _reason} -> {:halt, error(:sidecar_unavailable)}
                  _ -> {:halt, error(:sidecar_unavailable)}
                end
              end
            end)

          case result do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        {:error, _reason} ->
          {:halt, error(:sidecar_unavailable)}

        _ ->
          {:halt, error(:sidecar_unavailable)}
      end
    end)
  end

  defp sidecar_inventory(snapshot) do
    [
      {@base_domain, [@base_sidecar_id]},
      {@aggregate_domain, [@aggregate_sidecar_id]}
    ] ++
      Enum.map(@collection_specs, fn {field, _key, domain, _max, _id_field} ->
        {domain, Enum.map(snapshot.items[field], & &1.id)}
      end)
  end

  defp clear_working_memory_sidecars(agent_id) do
    Enum.reduce(@working_memory_domains, :ok, fn domain, result ->
      case Provenance.delete_domain_agent(domain, agent_id) do
        :ok -> result
        {:error, _reason} -> error(:sidecar_unavailable)
        _ -> error(:sidecar_unavailable)
      end
    end)
  end

  # -- Preparation and labels -------------------------------------------------

  defp prepare_working_memory(agent_id, %WorkingMemory{} = working_memory) do
    wm = WorkingMemory.migrate(working_memory)

    with true <- wm.agent_id == agent_id,
         payload <- WorkingMemory.serialize(wm),
         {:ok, collections} <- prepare_collections(wm, payload),
         {:ok, _digest} <- TaintEnvelope.payload_sha256(payload) do
      {:ok,
       %{
         wm: wm,
         payload: payload,
         base_payload: Map.drop(payload, @itemized_payload_keys),
         collections: collections
       }}
    else
      {:error, _reason} = error -> error
      _ -> error(:invalid_working_memory)
    end
  rescue
    _ -> error(:invalid_working_memory)
  catch
    _, _ -> error(:invalid_working_memory)
  end

  defp prepare_working_memory(_agent_id, _working_memory),
    do: error(:invalid_working_memory)

  defp prepare_collections(wm, payload) do
    Enum.reduce_while(@collection_specs, {:ok, %{}}, fn {field, durable_key, domain, max,
                                                         id_field},
                                                        {:ok, acc} ->
      values = Map.get(wm, field)
      serialized = Map.get(payload, durable_key)
      ids = collection_ids(wm, values, id_field)

      valid_shape =
        is_list(values) and is_list(serialized) and is_list(ids) and
          length(values) == length(serialized) and length(values) == length(ids) and
          length(values) <= max

      if valid_shape do
        items =
          Enum.zip([values, serialized, ids])
          |> Enum.map(fn {value, item_payload, id} ->
            payload = bind_item_payload(id, item_payload, id_field)
            %{id: id, value: value, payload: payload, domain: domain}
          end)

        case validate_prepared_items(items, id_field) do
          :ok -> {:cont, {:ok, Map.put(acc, field, %{domain: domain, items: items})}}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:halt, error(:collection_limit_exceeded)}
      end
    end)
  end

  defp collection_ids(_wm, values, nil) when is_list(values) do
    Enum.map(values, fn
      value when is_map(value) -> Map.get(value, :id)
      _ -> nil
    end)
  end

  defp collection_ids(wm, _values, id_field), do: Map.get(wm, id_field)

  defp validate_prepared_items(items, id_field) do
    ids = Enum.map(items, & &1.id)

    valid =
      Enum.all?(items, fn item ->
        valid_item_id?(item.id) and valid_item_payload_identity?(item, id_field)
      end) and length(ids) == MapSet.size(MapSet.new(ids))

    if valid, do: :ok, else: error(:invalid_item_identity)
  end

  defp valid_item_payload_identity?(item, nil) do
    is_map(item.payload) and item.payload["id"] == item.id
  end

  defp valid_item_payload_identity?(item, _id_field) do
    exact_string_keys?(item.payload, ["id", "value"]) and item.payload["id"] == item.id
  end

  defp bind_item_payload(_id, item_payload, nil), do: item_payload
  defp bind_item_payload(id, item_payload, _id_field), do: %{"id" => id, "value" => item_payload}

  defp valid_item_id?(item_id) when is_binary(item_id) do
    byte_size(item_id) <= @max_item_id_bytes and String.valid?(item_id) and
      String.trim(item_id) != ""
  end

  defp valid_item_id?(_item_id), do: false

  defp aggregate_label(base, items) do
    labels =
      [base] ++
        Enum.flat_map(@collection_specs, fn {field, _key, _domain, _max, _id_field} ->
          Enum.map(items[field], & &1.label)
        end)

    join_label_records(labels)
  end

  defp label_dominates?(candidate, minimum) do
    case Taint.join(candidate.taint, minimum.taint) do
      {:ok, joined} ->
        joined == candidate.taint and
          worst_status([candidate.status, minimum.status]) == candidate.status

      {:error, _reason} ->
        false
    end
  end

  defp join_label_records(records) do
    taints = Enum.map(records, & &1.taint)

    case Taint.join_many(taints) do
      {:ok, taint} ->
        status =
          records
          |> Enum.map(& &1.status)
          |> Kernel.++([status_for_taint(taint)])
          |> worst_status()

        label_record(taint, status)

      {:error, _reason} ->
        label_record(TaintEnvelope.invalid_fallback(), :invalid_durable_provenance)
    end
  end

  defp label_record(taint, status), do: %{taint: taint, status: status}

  defp status_for_taint(taint) do
    labels = [taint.source | taint.chain]

    cond do
      taint == TaintEnvelope.invalid_fallback() -> :invalid_durable_provenance
      "legacy_unlabeled" in labels -> :legacy_unlabeled
      true -> :verified
    end
  end

  defp worst_status(statuses) do
    cond do
      :invalid_durable_provenance in statuses -> :invalid_durable_provenance
      :legacy_unlabeled in statuses -> :legacy_unlabeled
      true -> :verified
    end
  end

  defp decode_status("verified"), do: {:ok, :verified}
  defp decode_status("legacy_unlabeled"), do: {:ok, :legacy_unlabeled}

  defp decode_status("invalid_durable_provenance"),
    do: {:ok, :invalid_durable_provenance}

  defp decode_status(_status), do: error(:invalid_wrapper)

  defp public_read(snapshot) do
    items =
      Map.new(@collection_specs, fn {field, _key, _domain, _max, _id_field} ->
        values =
          Enum.map(snapshot.items[field], fn item ->
            %{
              id: item.id,
              value: TaintedValue.wrap(item.value, item.label.taint),
              provenance_status: item.label.status
            }
          end)

        {field, values}
      end)

    %{
      value: TaintedValue.wrap(snapshot.prepared.wm, snapshot.aggregate.taint),
      provenance_status: snapshot.aggregate.status,
      items: items
    }
  end

  # -- Bounded process and compatibility helpers -----------------------------

  defp delete_authoritative(agent_id) do
    case MemoryStore.delete_tainted_authoritative(@namespace, agent_id) do
      :ok ->
        best_effort_clear_projection(agent_id)
        :ok

      {:error, _reason} = error ->
        map_memory_store_error(error)

      _ ->
        error(:delete_failed)
    end
  end

  # Content-only C3I cleanup: durable first, then confirmed ETS. Never touches sidecars.
  # Returns only closed flat atoms (or nested tuples that public normalizers whitelist).
  defp delete_authoritative_content_only(agent_id) do
    durable_result =
      case MemoryStore.delete_tainted_authoritative(@namespace, agent_id) do
        :ok -> :ok
        {:error, reason} -> {:error, map_content_backend_error(reason, :delete)}
        _ -> {:error, :delete_failed}
      end

    projection_result = confirm_working_memory_ets_evicted(agent_id)

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
        case working_memory_ets_absent?(agent_id) do
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
    _ ->
      {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  defp normalize_content_delete_result(:ok), do: :ok

  defp normalize_content_delete_result({:error, reason}),
    do: {:error, normalize_content_delete_error(reason)}

  defp normalize_content_delete_result(_), do: {:error, :delete_failed}

  defp normalize_content_absence_result({:ok, present?}) when is_boolean(present?),
    do: {:ok, present?}

  defp normalize_content_absence_result({:error, reason}),
    do: {:error, normalize_content_absence_error(reason)}

  defp normalize_content_absence_result(_), do: {:error, :absence_uncertain}

  defp normalize_content_delete_error(reason) when reason in @content_delete_errors, do: reason

  defp normalize_content_delete_error({:working_memory_store, reason}),
    do: normalize_content_delete_error(reason)

  defp normalize_content_delete_error(:invalid_provenance), do: :invalid_record
  defp normalize_content_delete_error(:invalid_request), do: :invalid_agent_id
  defp normalize_content_delete_error(:not_found), do: :delete_failed
  defp normalize_content_delete_error(:durable_load_failed), do: :durable_unavailable
  defp normalize_content_delete_error(:absence_uncertain), do: :store_unavailable
  defp normalize_content_delete_error(_reason), do: :delete_failed

  defp normalize_content_absence_error(reason) when reason in @content_absence_errors, do: reason

  defp normalize_content_absence_error({:working_memory_store, reason}),
    do: normalize_content_absence_error(reason)

  defp normalize_content_absence_error(:invalid_provenance), do: :invalid_record
  defp normalize_content_absence_error(:invalid_request), do: :invalid_agent_id
  defp normalize_content_absence_error(:not_found), do: :absence_uncertain
  defp normalize_content_absence_error(:durable_load_failed), do: :durable_unavailable
  defp normalize_content_absence_error(:delete_failed), do: :store_unavailable
  defp normalize_content_absence_error(:ets_failed), do: :absence_uncertain
  defp normalize_content_absence_error(:outcome_unknown), do: :absence_uncertain
  defp normalize_content_absence_error(:conflict), do: :absence_uncertain
  defp normalize_content_absence_error(:inventory_limit_exceeded), do: :store_unavailable
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

  defp map_content_backend_error({:memory_store, :critical, _reason}, :delete),
    do: :delete_failed

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

  # Only initial :undefined is genuine absence; post-defined races fail closed.
  defp confirm_working_memory_ets_evicted(agent_id) do
    case :ets.whereis(@working_memory_ets) do
      :undefined ->
        :ok

      _tid ->
        true = :ets.delete(@working_memory_ets, agent_id)

        case :ets.lookup(@working_memory_ets, agent_id) do
          [] -> :ok
          _ -> {:error, :ets_failed}
        end
    end
  rescue
    ArgumentError -> {:error, :ets_failed}
  catch
    _, _ -> {:error, :ets_failed}
  end

  defp working_memory_ets_absent?(agent_id) do
    case :ets.whereis(@working_memory_ets) do
      :undefined ->
        {:ok, true}

      _tid ->
        case :ets.lookup(@working_memory_ets, agent_id) do
          [] -> {:ok, true}
          _ -> {:ok, false}
        end
    end
  rescue
    ArgumentError -> {:error, :absence_uncertain}
  catch
    _, _ -> {:error, :absence_uncertain}
  end

  defp validate_agent_id_flat(agent_id) do
    case validate_agent_id(agent_id) do
      :ok -> :ok
      _ -> {:error, :invalid_agent_id}
    end
  end

  defp with_agent_transition_flat(agent_id, fun) do
    case with_agent_transition(agent_id, fun) do
      :ok -> :ok
      {:ok, present?} when is_boolean(present?) -> {:ok, present?}
      {:error, {:working_memory_store, reason}} -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :delete_failed}
    end
  end

  # Acquire in the public caller before :global.trans so lock wait remains
  # visible to drain. Release the exact lease after every synchronous result.
  defp with_admitted_agent_transition(agent_id, fun) when is_function(fun, 0) do
    case MutationAdmission.acquire(agent_id) do
      {:ok, lease} ->
        try do
          with_agent_transition(agent_id, fun)
        after
          _ = MutationAdmission.release(lease)
        end

      {:error, _reason} ->
        error(:store_unavailable)
    end
  end

  # The local lock serializes same-node projection transitions. Multi-node
  # writers are fenced by the authoritative Record generation+revision CAS;
  # every conflict restarts from a fresh durable observation.
  defp with_agent_transition(agent_id, fun) when is_function(fun, 0) do
    lock_id = {{__MODULE__, agent_id}, self()}

    case :global.trans(lock_id, fun, [node()], @transition_lock_retries) do
      :aborted -> error(:transition_busy)
      {:aborted, _reason} -> error(:transition_busy)
      result -> result
    end
  rescue
    _ -> error(:transition_failed)
  catch
    :exit, _ -> error(:transition_failed)
    _, _ -> error(:transition_failed)
  end

  defp map_memory_store_error({:error, {:memory_store, :critical, reason}})
       when reason in [
              :conflict,
              :outcome_unknown,
              :durable_unavailable,
              :insufficient_durability,
              :inventory_limit_exceeded,
              :invalid_record,
              :ambiguous_record
            ],
       do: error(reason)

  defp map_memory_store_error({:error, {:memory_store, :invalid_durable_provenance, _reason}}),
    do: error(:invalid_provenance)

  defp map_memory_store_error({:error, {:memory_store, :invalid_request, _reason}}),
    do: error(:invalid_request)

  defp map_memory_store_error({:error, :not_found}), do: error(:not_found)
  defp map_memory_store_error({:error, _reason}), do: error(:durable_load_failed)
  defp map_memory_store_error(_other), do: error(:durable_load_failed)

  defp blank_prepared(agent_id) do
    {:ok, prepared} =
      agent_id
      |> then(&WorkingMemory.deserialize(%{"agent_id" => &1}))
      |> then(&prepare_working_memory(agent_id, &1))

    prepared
  end

  defp fresh_working_memory(agent_id, opts) do
    if is_binary(agent_id) and is_list(opts) and Keyword.keyword?(opts) do
      WorkingMemory.new(agent_id, opts)
    else
      WorkingMemory.deserialize(%{"agent_id" => agent_id})
    end
  rescue
    _ -> WorkingMemory.deserialize(%{"agent_id" => agent_id})
  end

  defp validate_agent_id(agent_id) when is_binary(agent_id) do
    if byte_size(agent_id) <= @max_agent_id_bytes and String.valid?(agent_id) and
         String.trim(agent_id) != "" do
      :ok
    else
      error(:invalid_agent_id)
    end
  end

  defp validate_agent_id(_agent_id), do: error(:invalid_agent_id)

  defp exact_string_keys?(value, keys) when is_map(value) and not is_struct(value) do
    map_size(value) == length(keys) and Enum.all?(Map.keys(value), &is_binary/1) and
      Enum.sort(Map.keys(value)) == Enum.sort(keys)
  end

  defp exact_string_keys?(_value, _keys), do: false

  defp safe_ets_insert(agent_id, wm) do
    if :ets.insert(@working_memory_ets, {agent_id, wm}), do: :ok, else: error(:ets_failed)
  rescue
    ArgumentError -> error(:ets_failed)
  end

  defp safe_ets_delete(agent_id) do
    :ets.delete(@working_memory_ets, agent_id)
    :ok
  rescue
    ArgumentError -> :ok
    _ -> error(:ets_failed)
  catch
    _, _ -> error(:ets_failed)
  end

  defp error(reason), do: {:error, {:working_memory_store, reason}}
end
