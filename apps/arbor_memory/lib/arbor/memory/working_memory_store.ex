defmodule Arbor.Memory.WorkingMemoryStore do
  @moduledoc """
  ETS-backed working-memory storage with durable, per-item provenance.

  Compatibility reads return only `WorkingMemory`. Taint-aware reads expose an
  aggregate `TaintedValue` and explicit per-item provenance statuses without
  adding labels to working-memory content or prompt projections.
  """

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope, TaintedValue}
  alias Arbor.Memory.{MemoryStore, Provenance, Signals, WorkingMemory}

  @working_memory_ets :arbor_working_memory
  @namespace "working_memory"
  @wrapper_version 1
  @max_agent_id_bytes 256
  @max_item_id_bytes 128
  @base_domain :working_memory_base
  @aggregate_domain :working_memory_aggregate
  @base_sidecar_id "base"
  @aggregate_sidecar_id "aggregate"

  # These caps stay below the C0 envelope's worst-case node budget even when
  # every label carries the maximum provenance chain.
  @collection_specs [
    {:recent_thoughts, "recent_thoughts", :working_memory_thought, 64},
    {:active_goals, "active_goals", :working_memory_goal, 24},
    {:active_skills, "active_skills", :working_memory_skill, 8}
  ]

  @wrapper_keys ["payload", "provenance", "version"]
  @provenance_keys [
    "active_goals",
    "active_skills",
    "aggregate",
    "base",
    "recent_thoughts"
  ]
  @entry_keys ["envelope", "status"]
  @statuses [:verified, :legacy_unlabeled, :invalid_durable_provenance]

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
            active_skills: [tainted_item()]
          }
        }

  @doc "Returns the current raw working memory or nil when absent."
  @spec get_working_memory(String.t()) :: WorkingMemory.t() | nil
  def get_working_memory(agent_id) do
    case lookup_raw(agent_id) do
      {:ok, wm} -> WorkingMemory.migrate(wm)
      :not_found -> nil
    end
  end

  @doc """
  Return live working memory with aggregate and per-item provenance.

  Missing live sidecar entries resolve as legacy-unlabeled. Payload-mismatched
  or malformed entries resolve as invalid durable provenance.
  """
  @spec get_working_memory_tainted(String.t()) ::
          {:ok, tainted_read()} | {:error, term()}
  def get_working_memory_tainted(agent_id) do
    with {:ok, wm} <- lookup_raw_result(agent_id),
         {:ok, prepared} <- prepare_working_memory(agent_id, wm) do
      {:ok, prepared |> resolve_live_snapshot() |> public_read()}
    end
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

  A sidecar restart is repaired from the durable wrapper when its exact payload
  still matches ETS. Legacy raw records are migrated once with stable IDs and
  conservative labels. Invalid durable records never restore permissive labels.
  """
  @spec load_working_memory_tainted(String.t(), keyword()) ::
          {:ok, tainted_read()} | {:error, term()}
  def load_working_memory_tainted(agent_id, opts \\ []) do
    with :ok <- validate_agent_id(agent_id),
         true <- Keyword.keyword?(opts) do
      case lookup_raw(agent_id) do
        {:ok, wm} -> load_with_live_value(agent_id, wm)
        :not_found -> load_without_live_value(agent_id, opts)
      end
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
      {:ok, %{value: %TaintedValue{value: %WorkingMemory{} = wm}}} -> wm
      {:error, _reason} -> fresh_working_memory(agent_id, opts)
    end
  end

  @doc """
  Delete working memory and only the sidecar entries owned by this domain.
  """
  @spec delete_working_memory(String.t()) :: :ok
  def delete_working_memory(agent_id) do
    snapshots = deletion_snapshots(agent_id)

    :ok = MemoryStore.delete(@namespace, agent_id)
    safe_ets_delete(agent_id)

    snapshots
    |> Enum.flat_map(&sidecar_keys/1)
    |> Enum.uniq()
    |> Enum.each(fn {domain, item_id} ->
      _ = Provenance.delete(domain, agent_id, item_id)
    end)

    # Reserved entries exist even for an empty working memory.
    _ = Provenance.delete(@base_domain, agent_id, @base_sidecar_id)
    _ = Provenance.delete(@aggregate_domain, agent_id, @aggregate_sidecar_id)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # -- Save --------------------------------------------------------------------

  defp do_save(agent_id, working_memory, supplied_taint) do
    with :ok <- validate_agent_id(agent_id),
         {:ok, prepared} <- prepare_working_memory(agent_id, working_memory),
         {:ok, previous} <- previous_snapshot(agent_id),
         {:ok, snapshot} <- reconcile_snapshot(prepared, previous, supplied_taint),
         {:ok, wrapper} <- build_wrapper(snapshot),
         :ok <- persist_wrapper(agent_id, wrapper, snapshot.aggregate.taint),
         :ok <- install_snapshot(agent_id, snapshot, previous) do
      Signals.emit_working_memory_saved(agent_id, WorkingMemory.stats(snapshot.prepared.wm))
      :ok
    else
      {:error, _reason} = error -> error
      _ -> error(:save_failed)
    end
  rescue
    _ -> error(:save_failed)
  catch
    _, _ -> error(:save_failed)
  end

  defp previous_snapshot(agent_id) do
    case lookup_raw(agent_id) do
      {:ok, wm} ->
        case prepare_working_memory(agent_id, wm) do
          {:ok, prepared} ->
            live = resolve_live_snapshot(prepared)

            if live.sidecar_absent? do
              case load_durable_snapshot(agent_id) do
                {:ok, snapshot, _source} when snapshot.prepared.payload == prepared.payload ->
                  {:ok, snapshot}

                {:ok, _snapshot, :invalid} ->
                  {:ok, fallback_snapshot(prepared, TaintEnvelope.invalid_fallback())}

                {:ok, _snapshot, _source} ->
                  {:ok, live}

                :not_found ->
                  {:ok, live}

                {:error, {:working_memory_store, :durable_unavailable}} ->
                  {:ok, live}

                {:error, _reason} = error ->
                  error
              end
            else
              {:ok, live}
            end

          {:error, _reason} ->
            {:ok, invalid_previous_snapshot(agent_id)}
        end

      :not_found ->
        case load_durable_snapshot(agent_id) do
          {:ok, snapshot, _source} -> {:ok, snapshot}
          :not_found -> {:ok, nil}
          {:error, {:working_memory_store, :durable_unavailable}} -> {:ok, nil}
          {:error, _reason} = error -> error
        end
    end
  end

  defp invalid_previous_snapshot(agent_id) do
    prepared = blank_prepared(agent_id)
    fallback_snapshot(prepared, TaintEnvelope.invalid_fallback())
  end

  defp reconcile_snapshot(prepared, previous, supplied_taint) do
    supplied = label_record(supplied_taint, status_for_taint(supplied_taint))
    base = reconcile_base(prepared, previous, supplied)

    items =
      Map.new(@collection_specs, fn {field, _durable_key, _domain, _max} ->
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

  defp persist_wrapper(agent_id, wrapper, aggregate_taint) do
    case MemoryStore.persist(@namespace, agent_id, wrapper, taint: aggregate_taint) do
      :ok -> :ok
      {:error, _reason} -> error(:persistence_failed)
      _ -> error(:persistence_failed)
    end
  end

  # -- Load --------------------------------------------------------------------

  defp load_with_live_value(agent_id, wm) do
    with {:ok, prepared} <- prepare_working_memory(agent_id, wm) do
      live = resolve_live_snapshot(prepared)

      if live.sidecar_absent? do
        case load_durable_snapshot(agent_id) do
          {:ok, durable, source} when durable.prepared.payload == prepared.payload ->
            restore_snapshot(agent_id, durable, source, :silent)

          {:ok, _durable, :invalid} ->
            prepared
            |> fallback_snapshot(TaintEnvelope.invalid_fallback())
            |> then(&restore_snapshot(agent_id, &1, :invalid, :silent))

          {:error, _reason} = error ->
            error

          _ ->
            {:ok, public_read(live)}
        end
      else
        {:ok, public_read(live)}
      end
    end
  end

  defp load_without_live_value(agent_id, opts) do
    case load_durable_snapshot(agent_id) do
      {:ok, snapshot, source} ->
        restore_snapshot(agent_id, snapshot, source, :restored)

      :not_found ->
        wm = WorkingMemory.new(agent_id, opts)

        case save_working_memory(agent_id, wm) do
          :ok ->
            Signals.emit_working_memory_loaded(agent_id, :created)
            get_working_memory_tainted(agent_id)

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp restore_snapshot(agent_id, snapshot, source, signal_mode) do
    with :ok <- maybe_persist_legacy(agent_id, snapshot, source),
         :ok <- install_snapshot(agent_id, snapshot, current_snapshot(agent_id)) do
      if signal_mode == :restored do
        Signals.emit_working_memory_loaded(agent_id, :restored)
      end

      {:ok, public_read(resolve_live_snapshot(snapshot.prepared))}
    else
      {:error, _reason} = error -> error
    end
  end

  defp maybe_persist_legacy(agent_id, snapshot, :legacy) do
    with {:ok, wrapper} <- build_wrapper(snapshot) do
      persist_wrapper(agent_id, wrapper, snapshot.aggregate.taint)
    end
  end

  defp maybe_persist_legacy(_agent_id, _snapshot, _source), do: :ok

  defp current_snapshot(agent_id) do
    case lookup_raw(agent_id) do
      {:ok, wm} ->
        case prepare_working_memory(agent_id, wm) do
          {:ok, prepared} -> resolve_live_snapshot(prepared)
          {:error, _reason} -> nil
        end

      :not_found ->
        nil
    end
  end

  defp load_durable_snapshot(agent_id) do
    if MemoryStore.available?() do
      do_load_durable_snapshot(agent_id)
    else
      error(:durable_unavailable)
    end
  end

  defp do_load_durable_snapshot(agent_id) do
    case MemoryStore.load_tainted_with_status(@namespace, agent_id) do
      {:ok, %TaintedValue{value: data, taint: outer_taint}, :verified} ->
        case decode_wrapper(agent_id, data, outer_taint) do
          {:ok, snapshot} -> {:ok, snapshot, :verified}
          {:error, _reason} -> {:ok, fallback_from_data(agent_id, data, :invalid), :invalid}
        end

      {:ok, %TaintedValue{value: data}, :legacy_unlabeled} ->
        {:ok, fallback_from_data(agent_id, data, :legacy), :legacy}

      {:ok, %TaintedValue{value: data}, :invalid_durable_provenance} ->
        {:ok, fallback_from_data(agent_id, data, :invalid), :invalid}

      {:error, :not_found} ->
        :not_found

      {:error, _reason} ->
        error(:durable_load_failed)

      _ ->
        error(:durable_load_failed)
    end
  rescue
    _ -> error(:durable_load_failed)
  catch
    _, _ -> error(:durable_load_failed)
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
    Enum.reduce_while(@collection_specs, {:ok, %{}}, fn {field, durable_key, _domain, _max},
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
         true <- data["version"] == @wrapper_version,
         payload when is_map(payload) <- data["payload"],
         provenance when is_map(provenance) <- data["provenance"],
         true <- exact_string_keys?(provenance, @provenance_keys),
         {:ok, prepared} <- prepare_exact_payload(agent_id, payload),
         {:ok, base} <- decode_entry(provenance["base"], prepared.base_payload),
         {:ok, items} <- decode_collection_entries(prepared, provenance),
         {:ok, aggregate} <- decode_entry(provenance["aggregate"], prepared.payload),
         component_aggregate <- aggregate_label(base, items),
         true <- label_dominates?(aggregate, component_aggregate),
         true <- outer_taint == aggregate.taint do
      {:ok,
       %{
         prepared: prepared,
         base: base,
         items: items,
         aggregate: aggregate,
         sidecar_absent?: false
       }}
    else
      _ -> error(:invalid_wrapper)
    end
  rescue
    _ -> error(:invalid_wrapper)
  catch
    _, _ -> error(:invalid_wrapper)
  end

  defp decode_collection_entries(prepared, provenance) do
    Enum.reduce_while(@collection_specs, {:ok, %{}}, fn {field, durable_key, _domain, _max},
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
      Map.new(@collection_specs, fn {field, _durable_key, _domain, _max} ->
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

  # -- Live sidecar ------------------------------------------------------------

  defp resolve_live_snapshot(prepared) do
    base =
      resolve_sidecar(
        @base_domain,
        prepared.wm.agent_id,
        @base_sidecar_id,
        prepared.base_payload
      )

    items =
      Map.new(@collection_specs, fn {field, _durable_key, domain, _max} ->
        labelled =
          Enum.map(prepared.collections[field].items, fn item ->
            label = resolve_sidecar(domain, prepared.wm.agent_id, item.id, item.payload)
            Map.put(item, :label, label)
          end)

        {field, labelled}
      end)

    expected = aggregate_label(base, items)

    stored_aggregate =
      resolve_sidecar(
        @aggregate_domain,
        prepared.wm.agent_id,
        @aggregate_sidecar_id,
        prepared.payload
      )

    aggregate = resolve_live_aggregate(expected, stored_aggregate)

    labels =
      [base, stored_aggregate] ++
        Enum.flat_map(@collection_specs, fn {field, _key, _domain, _max} ->
          Enum.map(items[field], & &1.label)
        end)

    %{
      prepared: prepared,
      base: base,
      items: items,
      aggregate: aggregate,
      sidecar_absent?: Enum.all?(labels, &(&1.raw_status == :legacy_unlabeled))
    }
  end

  defp resolve_sidecar(domain, agent_id, item_id, payload) do
    case Provenance.resolve(domain, agent_id, item_id, payload) do
      {:ok, taint, raw_status} ->
        label_record(taint, effective_status(taint, raw_status), raw_status)

      _ ->
        label_record(
          TaintEnvelope.invalid_fallback(),
          :invalid_durable_provenance,
          :invalid_durable_provenance
        )
    end
  end

  defp resolve_live_aggregate(expected, stored) do
    cond do
      stored.raw_status == :verified and label_dominates?(stored, expected) ->
        stored

      stored.raw_status == :legacy_unlabeled ->
        join_label_records([expected, stored])

      true ->
        label_record(
          TaintEnvelope.invalid_fallback(),
          :invalid_durable_provenance,
          stored.raw_status
        )
    end
  end

  defp install_snapshot(agent_id, snapshot, previous) do
    case put_snapshot_sidecars(agent_id, snapshot) do
      :ok ->
        case safe_ets_insert(agent_id, snapshot.prepared.wm) do
          :ok ->
            delete_stale_sidecars(agent_id, previous, snapshot)

          {:error, _reason} = error ->
            clear_snapshot_sidecars(agent_id, previous, snapshot)
            error
        end

      {:error, _reason} = error ->
        clear_snapshot_sidecars(agent_id, previous, snapshot)
        error
    end
  end

  defp put_snapshot_sidecars(agent_id, snapshot) do
    entries =
      [
        {@base_domain, @base_sidecar_id, snapshot.prepared.base_payload, snapshot.base.taint}
      ] ++
        Enum.flat_map(@collection_specs, fn {field, _key, domain, _max} ->
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

  defp delete_stale_sidecars(_agent_id, nil, _snapshot), do: :ok

  defp delete_stale_sidecars(agent_id, previous, snapshot) do
    current = MapSet.new(sidecar_keys(snapshot))

    previous
    |> sidecar_keys()
    |> Enum.reject(&MapSet.member?(current, &1))
    |> Enum.each(fn {domain, item_id} ->
      _ = Provenance.delete(domain, agent_id, item_id)
    end)

    :ok
  end

  defp clear_snapshot_sidecars(agent_id, previous, snapshot) do
    [previous, snapshot]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&sidecar_keys/1)
    |> Enum.uniq()
    |> Enum.each(fn {domain, item_id} ->
      _ = Provenance.delete(domain, agent_id, item_id)
    end)

    :ok
  end

  defp sidecar_keys(snapshot) do
    [
      {@base_domain, @base_sidecar_id},
      {@aggregate_domain, @aggregate_sidecar_id}
    ] ++
      Enum.flat_map(@collection_specs, fn {field, _key, domain, _max} ->
        Enum.map(snapshot.items[field], &{domain, &1.id})
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
         base_payload: Map.drop(payload, ["recent_thoughts", "active_goals", "active_skills"]),
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
    Enum.reduce_while(@collection_specs, {:ok, %{}}, fn {field, durable_key, domain, max},
                                                        {:ok, acc} ->
      values = Map.get(wm, field)
      serialized = Map.get(payload, durable_key)

      valid_shape =
        is_list(values) and is_list(serialized) and length(values) == length(serialized) and
          length(values) <= max

      if valid_shape do
        items =
          Enum.zip(values, serialized)
          |> Enum.map(fn {value, item_payload} ->
            %{id: Map.get(value, :id), value: value, payload: item_payload, domain: domain}
          end)

        case validate_prepared_items(items) do
          :ok -> {:cont, {:ok, Map.put(acc, field, %{domain: domain, items: items})}}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:halt, error(:collection_limit_exceeded)}
      end
    end)
  end

  defp validate_prepared_items(items) do
    ids = Enum.map(items, & &1.id)

    valid =
      Enum.all?(items, fn item ->
        valid_item_id?(item.id) and is_map(item.payload) and item.payload["id"] == item.id
      end) and length(ids) == MapSet.size(MapSet.new(ids))

    if valid, do: :ok, else: error(:invalid_item_identity)
  end

  defp valid_item_id?(item_id) when is_binary(item_id) do
    byte_size(item_id) <= @max_item_id_bytes and String.valid?(item_id) and
      String.trim(item_id) != ""
  end

  defp valid_item_id?(_item_id), do: false

  defp aggregate_label(base, items) do
    labels =
      [base] ++
        Enum.flat_map(@collection_specs, fn {field, _key, _domain, _max} ->
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

  defp label_record(taint, status, raw_status \\ :verified) do
    %{taint: taint, status: status, raw_status: raw_status}
  end

  defp status_for_taint(taint) do
    labels = [taint.source | taint.chain]

    cond do
      taint == TaintEnvelope.invalid_fallback() -> :invalid_durable_provenance
      "legacy_unlabeled" in labels -> :legacy_unlabeled
      true -> :verified
    end
  end

  defp effective_status(taint, raw_status) do
    worst_status([status_for_taint(taint), normalize_status(raw_status)])
  end

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(_status), do: :invalid_durable_provenance

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
      Map.new(@collection_specs, fn {field, _key, _domain, _max} ->
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

  # -- Bounded compatibility helpers -----------------------------------------

  defp deletion_snapshots(agent_id) do
    live =
      case lookup_raw(agent_id) do
        {:ok, wm} ->
          case prepare_working_memory(agent_id, wm) do
            {:ok, prepared} -> [fallback_snapshot(prepared, TaintEnvelope.missing_fallback())]
            {:error, _reason} -> []
          end

        :not_found ->
          []
      end

    durable =
      case load_durable_snapshot(agent_id) do
        {:ok, snapshot, _source} -> [snapshot]
        :not_found -> []
        {:error, _reason} -> []
      end

    live ++ durable
  end

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

  defp lookup_raw(agent_id) do
    case :ets.lookup(@working_memory_ets, agent_id) do
      [{^agent_id, %WorkingMemory{} = wm}] -> {:ok, wm}
      _ -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  defp lookup_raw_result(agent_id) do
    case lookup_raw(agent_id) do
      {:ok, wm} -> {:ok, wm}
      :not_found -> {:error, :not_found}
    end
  end

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
  end

  defp error(reason), do: {:error, {:working_memory_store, reason}}
end
