defmodule Arbor.Security.AuditJournalCore do
  @moduledoc """
  Pure CRC reducer for the v1 Security authority-mutation audit journal.

  Folds admitted append records, enforces prepared -> effect_applied -> delivered
  or prepared -> effect_rejected, exact duplicate/conflict semantics, static-floor
  capacity accounting, and pure snapshot compact/restore.

  Returns data and errors only. No effects, IO, time, processes, ETS, logging,
  signals, or store/facade calls.
  """

  alias Arbor.Security.Contracts.AuditJournal

  @version 1
  @terminals ["effect_rejected", "delivered"]
  @pending_statuses ["prepared", "effect_applied"]
  @max_pending_age_seconds 31_536_000

  @type state :: %{
          required(String.t()) => term()
        }

  @type fold_error ::
          :malformed
          | :out_of_order
          | :illegal_transition
          | :post_terminal
          | :operation_conflict
          | :cross_operation
          | :record_too_large
          | :soft_capacity_exhausted
          | :capacity_exhausted
          | :pending_mismatch

  @spec new() :: {:ok, state()}
  def new do
    {:ok, empty_state()}
  end

  @spec append(term(), term()) ::
          {:ok, state()} | {:ok, state(), :idempotent} | {:error, fold_error()}
  def append(state, raw) do
    with :ok <- valid_state(state),
         {:ok, record} <- map_admit(AuditJournal.admit_record(raw)),
         {:ok, bytes} <- map_bytes(AuditJournal.canonical_record_bytes(record)) do
      transition(state, record, bytes)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec fold(term()) :: {:ok, state()} | {:error, fold_error()}
  def fold(records), do: fold(empty_state(), records)

  @spec fold(term(), term()) :: {:ok, state()} | {:error, fold_error()}
  def fold(state, records) do
    with :ok <- valid_state(state) do
      fold_records(state, records, 0, AuditJournal.limits().max_fold_records)
    end
  end

  defp fold_records(state, [], _count, _max_records), do: {:ok, state}

  defp fold_records(_state, [_record | _tail], count, max_records)
       when count >= max_records,
       do: {:error, :malformed}

  defp fold_records(state, [record | tail], count, max_records) do
    case append(state, record) do
      {:ok, next} -> fold_records(next, tail, count + 1, max_records)
      {:ok, next, :idempotent} -> fold_records(next, tail, count + 1, max_records)
      {:error, _} = err -> err
    end
  end

  defp fold_records(_state, _improper_tail, _count, _max_records), do: {:error, :malformed}

  @spec compact(term(), term()) ::
          {:ok, state(), map(), [map()]} | {:error, fold_error()}
  def compact(state, source) do
    with :ok <- valid_state(state),
         {:ok, snapshot, pending, operations} <- build_compact_snapshot(state, source),
         {:ok, snap_bytes} <- map_bytes(AuditJournal.canonical_snapshot_bytes(snapshot)) do
      finish_compact(state, snapshot, pending, operations, snap_bytes)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec restore(term(), term()) :: {:ok, state()} | {:error, fold_error()}
  def restore(snapshot, pending_records) do
    with {:ok, admitted} <- map_admit(AuditJournal.admit_snapshot(snapshot)),
         {:ok, snap_bytes} <- map_bytes(AuditJournal.canonical_snapshot_bytes(admitted)),
         {:ok, supplied} <- admit_pending_list(pending_records),
         :ok <- match_pending_entries(supplied, admitted) do
      install_restored(admitted, supplied, snap_bytes)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec show(state()) :: map()
  def show(state) when is_map(state) do
    operations =
      state
      |> Map.get("operations", %{})
      |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
      |> Enum.map(fn {operation_id, op} ->
        %{
          "operation_id" => operation_id,
          "status" => op["status"],
          "effect_class" => op["effect_class"],
          "intent_sha256" => op_intent_sha256(op)
        }
      end)

    %{
      "version" => @version,
      "entry_count" => Map.get(state, "entry_count", 0),
      "byte_count" => Map.get(state, "byte_count", 0),
      "operations" => operations
    }
  end

  @spec capacity(state()) :: map()
  def capacity(state) when is_map(state) do
    limits = AuditJournal.limits()
    used_entries = Map.get(state, "entry_count", 0)
    used_bytes = Map.get(state, "byte_count", 0)

    %{
      "used_entries" => used_entries,
      "used_bytes" => used_bytes,
      "hard_entry_cap" => limits.hard_entry_cap,
      "hard_byte_cap" => limits.hard_byte_cap,
      "soft_entry_cap" => limits.soft_entry_cap,
      "soft_byte_cap" => limits.soft_byte_cap,
      "reserve_entries" => limits.reserve_entries,
      "reserve_bytes" => limits.reserve_bytes,
      "remaining_soft_entries" => max(0, limits.soft_entry_cap - used_entries),
      "remaining_soft_bytes" => max(0, limits.soft_byte_cap - used_bytes),
      "remaining_hard_entries" => max(0, limits.hard_entry_cap - used_entries),
      "remaining_hard_bytes" => max(0, limits.hard_byte_cap - used_bytes)
    }
  end

  @spec pending_summary(term(), term()) :: {:ok, map()} | {:error, :malformed}
  def pending_summary(state, now) do
    with :ok <- valid_state(state),
         {:ok, now_unix} <- unix_from_timestamp(now),
         {:ok, pending} <- pending_ops(state) do
      ages = Enum.map(pending, &pending_age(&1, now_unix))

      if Enum.any?(ages, &(&1 == :malformed)) do
        {:error, :malformed}
      else
        {:ok,
         %{
           "pending_count" => length(pending),
           "oldest_pending_age_seconds" => Enum.max(ages, fn -> 0 end),
           "operations" => project_pending(pending)
         }}
      end
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  defp empty_state do
    %{
      "version" => @version,
      "operations" => %{},
      "entry_count" => 0,
      "byte_count" => 0
    }
  end

  defp valid_state(state) when is_map(state) and not is_struct(state) do
    with true <- state["version"] == @version,
         true <- is_map(state["operations"]),
         true <- is_integer(state["entry_count"]) and state["entry_count"] >= 0,
         true <- is_integer(state["byte_count"]) and state["byte_count"] >= 0,
         :ok <- valid_snapshot_fields(state) do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_state(_state), do: {:error, :malformed}

  defp valid_snapshot_fields(state) do
    case Map.fetch(state, "snapshot") do
      :error ->
        :ok

      {:ok, snapshot} when is_map(snapshot) and not is_struct(snapshot) ->
        case state["snapshot_bytes"] do
          bytes when is_integer(bytes) and bytes >= 0 -> :ok
          _invalid -> {:error, :malformed}
        end

      _invalid ->
        {:error, :malformed}
    end
  end

  defp map_admit({:ok, record}), do: {:ok, record}
  defp map_admit({:error, :cross_operation}), do: {:error, :cross_operation}
  defp map_admit({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_admit({:error, _reason}), do: {:error, :malformed}

  defp map_bytes({:ok, bytes}), do: {:ok, bytes}
  defp map_bytes({:error, :record_too_large}), do: {:error, :record_too_large}
  defp map_bytes({:error, _reason}), do: {:error, :malformed}

  defp transition(state, record, bytes) do
    limits = AuditJournal.limits()

    if byte_size(bytes) > limits.max_record_bytes do
      {:error, :record_too_large}
    else
      apply_transition(state, record, bytes, limits)
    end
  end

  defp apply_transition(state, record, bytes, limits) do
    operation_id = record["operation_id"]
    record_type = record["record_type"]
    operations = state["operations"]
    existing = Map.get(operations, operation_id)

    case {existing, record_type} do
      {nil, "prepared"} ->
        with :ok <- check_capacity(state, record, bytes, limits) do
          {:ok, put_new_prepared(state, record, bytes)}
        end

      {nil, _type} ->
        {:error, :out_of_order}

      {op, _type} ->
        continue_operation(state, op, record, bytes, limits)
    end
  end

  defp continue_operation(state, op, record, bytes, limits) do
    record_type = record["record_type"]

    case stored_identity(op, record_type, bytes) do
      :idempotent ->
        {:ok, state, :idempotent}

      :conflict ->
        {:error, :operation_conflict}

      :absent ->
        cond do
          op["status"] in @terminals ->
            {:error, :post_terminal}

          not legal_next?(op["status"], record_type) ->
            {:error, :illegal_transition}

          record_type == "effect_applied" and not after_match?(op, record) ->
            {:error, :malformed}

          true ->
            with :ok <- check_capacity(state, record, bytes, limits) do
              {:ok, put_next(state, op, record, bytes)}
            end
        end
    end
  end

  defp stored_identity(op, record_type, bytes) do
    records = Map.get(op, "records", %{})
    fingerprints = Map.get(op, "fingerprints", %{})

    cond do
      Map.has_key?(records, record_type) ->
        if records[record_type] == bytes, do: :idempotent, else: :conflict

      Map.has_key?(fingerprints, record_type) ->
        fingerprint_identity(fingerprints[record_type], bytes)

      true ->
        :absent
    end
  end

  defp fingerprint_identity(stored, bytes) do
    case AuditJournal.record_fingerprint(bytes) do
      {:ok, ^stored} -> :idempotent
      {:ok, _other} -> :conflict
      {:error, _reason} -> :conflict
    end
  end

  defp legal_next?("prepared", "effect_applied"), do: true
  defp legal_next?("prepared", "effect_rejected"), do: true
  defp legal_next?("effect_applied", "delivered"), do: true
  defp legal_next?(_status, _type), do: false

  defp after_match?(op, record) do
    op["intent"]["after_fingerprint"] === record["observation"]["after_fingerprint"]
  end

  defp check_capacity(state, record, bytes, limits) do
    used_entries = state["entry_count"]
    used_bytes = state["byte_count"]
    cost_bytes = byte_size(bytes)

    cond do
      cost_bytes > limits.max_record_bytes ->
        {:error, :record_too_large}

      used_entries + 1 > limits.hard_entry_cap or used_bytes + cost_bytes > limits.hard_byte_cap ->
        {:error, :capacity_exhausted}

      capacity_class(record) == :soft and
          (used_entries + 1 > limits.soft_entry_cap or
             used_bytes + cost_bytes > limits.soft_byte_cap) ->
        {:error, :soft_capacity_exhausted}

      true ->
        :ok
    end
  end

  defp capacity_class(%{"record_type" => "prepared", "intent" => intent}) do
    case intent["effect_class"] do
      "authority_increase" -> :soft
      _ -> :reserve
    end
  end

  defp capacity_class(_record), do: :reserve

  defp put_new_prepared(state, record, bytes) do
    intent = record["intent"]
    operation_id = record["operation_id"]

    op = %{
      "status" => "prepared",
      "effect_class" => intent["effect_class"],
      "intent" => intent,
      "records" => %{record["record_type"] => bytes}
    }

    %{
      state
      | "operations" => Map.put(state["operations"], operation_id, op),
        "entry_count" => state["entry_count"] + 1,
        "byte_count" => state["byte_count"] + byte_size(bytes)
    }
  end

  defp put_next(state, op, record, bytes) do
    operation_id = record["operation_id"]
    record_type = record["record_type"]

    updated = %{
      op
      | "status" => record_type,
        "records" => Map.put(op["records"], record_type, bytes)
    }

    %{
      state
      | "operations" => Map.put(state["operations"], operation_id, updated),
        "entry_count" => state["entry_count"] + 1,
        "byte_count" => state["byte_count"] + byte_size(bytes)
    }
  end

  defp op_intent_sha256(%{"intent_sha256" => sha256}) when is_binary(sha256), do: sha256
  defp op_intent_sha256(%{"intent" => intent}), do: intent_sha256(intent)
  defp op_intent_sha256(_op), do: String.duplicate("0", 64)

  defp intent_sha256(intent) when is_map(intent) do
    case AuditJournal.canonical_intent_bytes(intent) do
      {:ok, bytes} ->
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      {:error, _reason} ->
        String.duplicate("0", 64)
    end
  end

  defp intent_sha256(_intent), do: String.duplicate("0", 64)

  defp build_compact_snapshot(state, source) do
    with {:ok, pending_ops, terminal_ops} <- partition_operations(state["operations"]),
         {:ok, pending_manifest, pending_records} <- compact_pending(pending_ops),
         {:ok, terminals, compacted_terminals} <- compact_terminals(terminal_ops) do
      snapshot = %{
        "version" => @version,
        "kind" => AuditJournal.snapshot_kind(),
        "source" => source,
        "pending_manifest" => pending_manifest,
        "terminals" => terminals
      }

      case map_admit(AuditJournal.admit_snapshot(snapshot)) do
        {:ok, admitted} ->
          operations = Map.merge(pending_ops, compacted_terminals)
          {:ok, admitted, pending_records, operations}

        {:error, _} = err ->
          err
      end
    end
  end

  defp finish_compact(_state, snapshot, pending, operations, snap_bytes) do
    limits = AuditJournal.limits()
    pending_n = length(pending)

    case sum_record_bytes(pending) do
      {:ok, pending_bytes} ->
        used_entries = 1 + pending_n
        used_bytes = snap_bytes + pending_bytes

        finish_compact_occupancy(
          snapshot,
          pending,
          operations,
          snap_bytes,
          used_entries,
          used_bytes,
          limits
        )

      {:error, _} = err ->
        err
    end
  end

  defp finish_compact_occupancy(
         snapshot,
         pending,
         operations,
         snap_bytes,
         used_entries,
         used_bytes,
         limits
       ) do
    if occupancy_exceeded?(used_entries, used_bytes, limits) do
      {:error, :capacity_exhausted}
    else
      next = %{
        "version" => @version,
        "operations" => operations,
        "entry_count" => used_entries,
        "byte_count" => used_bytes,
        "snapshot" => snapshot,
        "snapshot_bytes" => snap_bytes
      }

      {:ok, next, snapshot, pending}
    end
  end

  defp sum_record_bytes(records) do
    Enum.reduce_while(records, {:ok, 0}, fn record, {:ok, acc} ->
      case AuditJournal.canonical_record_bytes(record) do
        {:ok, bytes} -> {:cont, {:ok, acc + byte_size(bytes)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp partition_operations(operations) when is_map(operations) do
    sorted = Enum.sort_by(operations, fn {operation_id, _op} -> operation_id end)

    Enum.reduce_while(sorted, {:ok, %{}, %{}}, fn {operation_id, op}, {:ok, pending, terminals} ->
      case op["status"] do
        status when status in @pending_statuses ->
          {:cont, {:ok, Map.put(pending, operation_id, op), terminals}}

        status when status in @terminals ->
          {:cont, {:ok, pending, Map.put(terminals, operation_id, op)}}

        _other ->
          {:halt, {:error, :malformed}}
      end
    end)
  end

  defp compact_pending(pending_ops) do
    pending_ops
    |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
    |> Enum.reduce_while({:ok, %{}, []}, fn {operation_id, op}, {:ok, manifest, records} ->
      case compact_pending_op(operation_id, op) do
        {:ok, compact, decoded} ->
          {:cont, {:ok, Map.put(manifest, operation_id, compact), records ++ decoded}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp compact_pending_op(operation_id, op) do
    with :ok <- require_pending_shape(op),
         {:ok, decoded, fingerprints} <- decode_pending_records(operation_id, op),
         :ok <- validate_pending_lifecycle(operation_id, op, decoded),
         {:ok, compact} <- pending_compact_string(op["status"], fingerprints) do
      {:ok, compact, decoded}
    end
  end

  defp require_pending_shape(%{"intent" => intent, "records" => records} = op)
       when is_map(intent) and is_map(records) do
    required = pending_record_types(op["status"])
    stored = records |> Map.keys() |> Enum.sort()

    if stored == Enum.sort(required) and Enum.all?(required, &is_binary(records[&1])) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp require_pending_shape(_op), do: {:error, :malformed}

  defp pending_record_types("prepared"), do: ["prepared"]
  defp pending_record_types("effect_applied"), do: ["prepared", "effect_applied"]
  defp pending_record_types(_status), do: []

  defp decode_pending_records(operation_id, op) do
    types = pending_record_types(op["status"])

    case Enum.reduce_while(types, {:ok, {[], %{}}}, fn type, acc ->
           decode_pending_type(operation_id, op, type, acc)
         end) do
      {:ok, {records, fingerprints}} -> {:ok, records, fingerprints}
      {:error, _} = err -> err
    end
  end

  defp decode_pending_type(operation_id, op, type, {:ok, {records, fingerprints}}) do
    case decode_bound_record(operation_id, type, op["records"][type]) do
      {:ok, record, fingerprint} ->
        next_records = records ++ [record]
        next_fingerprints = Map.put(fingerprints, type, fingerprint)
        {:cont, {:ok, {next_records, next_fingerprints}}}

      {:error, _} = err ->
        {:halt, err}
    end
  end

  defp validate_pending_lifecycle(operation_id, op, decoded) do
    prepared = Enum.find(decoded, &(&1["record_type"] == "prepared"))

    with true <- is_map(prepared),
         :ok <- bind_decoded_record(operation_id, "prepared", prepared),
         :ok <- bind_intent(op, prepared) do
      validate_pending_status(op, prepared, decoded)
    else
      {:error, _} = err -> err
      _other -> {:error, :malformed}
    end
  end

  defp validate_pending_status(%{"status" => "prepared"}, _prepared, _decoded), do: :ok

  defp validate_pending_status(%{"status" => "effect_applied"}, prepared, decoded) do
    applied = Enum.find(decoded, &(&1["record_type"] == "effect_applied"))

    if is_map(applied) and after_match_record?(prepared, applied) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_pending_status(_op, _prepared, _decoded), do: {:error, :malformed}

  defp pending_compact_string("prepared", %{"prepared" => prepared}) do
    {:ok, "prepared:" <> prepared}
  end

  defp pending_compact_string("effect_applied", %{
         "prepared" => prepared,
         "effect_applied" => applied
       }) do
    {:ok, "prepared:" <> prepared <> "|effect_applied:" <> applied}
  end

  defp pending_compact_string(_status, _fingerprints), do: {:error, :malformed}

  defp compact_terminals(terminal_ops) do
    terminal_ops
    |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {operation_id, op}, {:ok, manifest, compacted} ->
      case compact_terminal_op(operation_id, op) do
        {:ok, compact, next_op} ->
          next_manifest = Map.put(manifest, operation_id, compact)
          next_ops = Map.put(compacted, operation_id, next_op)
          {:cont, {:ok, next_manifest, next_ops}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  defp compact_terminal_op(operation_id, op) do
    with :ok <- require_terminal_status(op),
         {:ok, fingerprints, intent_sha256} <- terminal_identity(operation_id, op),
         {:ok, compact} <-
           terminal_compact_string(
             op["status"],
             op["effect_class"],
             intent_sha256,
             fingerprints
           ) do
      next = %{
        "status" => op["status"],
        "effect_class" => op["effect_class"],
        "intent_sha256" => intent_sha256,
        "fingerprints" => fingerprints
      }

      {:ok, compact, next}
    end
  end

  defp require_terminal_status(%{"status" => status, "effect_class" => effect_class})
       when status in @terminals and
              effect_class in ["authority_increase", "authority_reduce"],
       do: :ok

  defp require_terminal_status(_op), do: {:error, :malformed}

  defp terminal_record_types("delivered"), do: ["prepared", "effect_applied", "delivered"]
  defp terminal_record_types("effect_rejected"), do: ["prepared", "effect_rejected"]
  defp terminal_record_types(_status), do: []

  defp terminal_identity(operation_id, %{"records" => records} = op) when is_map(records) do
    types = terminal_record_types(op["status"])

    with :ok <- require_exact_types(records, types),
         {:ok, decoded, fingerprints} <- decode_terminal_records(operation_id, records, types),
         :ok <- validate_terminal_lifecycle(op, decoded),
         {:ok, intent_sha256} <- intent_sha256_from_prepared(op, decoded) do
      {:ok, fingerprints, intent_sha256}
    end
  end

  defp terminal_identity(_operation_id, %{"fingerprints" => fingerprints} = op)
       when is_map(fingerprints) do
    with :ok <- require_exact_types(fingerprints, terminal_record_types(op["status"])),
         :ok <- require_fingerprint_values(fingerprints),
         {:ok, intent_sha256} <- terminal_intent_sha256(op) do
      {:ok, fingerprints, intent_sha256}
    end
  end

  defp terminal_identity(_operation_id, _op), do: {:error, :malformed}

  defp decode_terminal_records(operation_id, records, types) do
    Enum.reduce_while(types, {:ok, {%{}, %{}}}, fn type, {:ok, {decoded, fingerprints}} ->
      case decode_bound_record(operation_id, type, records[type]) do
        {:ok, record, fingerprint} ->
          next_decoded = Map.put(decoded, type, record)
          next_fingerprints = Map.put(fingerprints, type, fingerprint)
          {:cont, {:ok, {next_decoded, next_fingerprints}}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, {decoded, fingerprints}} -> {:ok, decoded, fingerprints}
      {:error, _} = err -> err
    end
  end

  defp validate_terminal_lifecycle(op, decoded) do
    prepared = decoded["prepared"]

    with true <- is_map(prepared),
         :ok <- bind_intent(op, prepared) do
      validate_terminal_status(op["status"], prepared, decoded)
    else
      {:error, _} = err -> err
      _other -> {:error, :malformed}
    end
  end

  defp validate_terminal_status("delivered", prepared, decoded) do
    applied = decoded["effect_applied"]
    delivered = decoded["delivered"]

    if is_map(applied) and is_map(delivered) and after_match_record?(prepared, applied) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_terminal_status("effect_rejected", _prepared, decoded) do
    if is_map(decoded["effect_rejected"]) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp validate_terminal_status(_status, _prepared, _decoded), do: {:error, :malformed}

  defp intent_sha256_from_prepared(op, decoded) do
    prepared = decoded["prepared"]

    with true <- is_map(prepared),
         :ok <- bind_intent(op, prepared),
         {:ok, bytes} <- AuditJournal.canonical_intent_bytes(prepared["intent"]) do
      {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
    else
      {:error, _} = err -> err
      _other -> {:error, :malformed}
    end
  end

  defp require_exact_types(map, expected) when is_map(map) do
    actual = map |> Map.keys() |> Enum.sort()

    if actual == Enum.sort(expected) and Enum.all?(expected, &is_binary(Map.get(map, &1))) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp require_exact_types(_map, _expected), do: {:error, :malformed}

  defp require_fingerprint_values(fingerprints) do
    if Enum.all?(fingerprints, fn {_type, sha} -> valid_fingerprint?(sha) end) do
      :ok
    else
      {:error, :malformed}
    end
  end

  defp valid_fingerprint?(sha) when is_binary(sha) and byte_size(sha) == 64 do
    Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)
  end

  defp valid_fingerprint?(_sha), do: false

  defp decode_bound_record(operation_id, type, bytes) do
    with {:ok, record, canonical} <- decode_stored_record(bytes),
         :ok <- bind_decoded_record(operation_id, type, record),
         {:ok, fingerprint} <- AuditJournal.record_fingerprint(canonical) do
      {:ok, record, fingerprint}
    end
  end

  defp bind_decoded_record(operation_id, type, record) when is_map(record) do
    cond do
      record["operation_id"] != operation_id -> {:error, :cross_operation}
      record["record_type"] != type -> {:error, :malformed}
      true -> :ok
    end
  end

  defp bind_decoded_record(_operation_id, _type, _record), do: {:error, :malformed}

  defp bind_intent(op, prepared) do
    intent = prepared["intent"]

    cond do
      not is_map(intent) -> {:error, :malformed}
      intent["effect_class"] != op["effect_class"] -> {:error, :malformed}
      true -> bind_stored_intent(op["intent"], intent)
    end
  end

  defp bind_stored_intent(stored, decoded) when is_map(stored) do
    with {:ok, left} <- AuditJournal.canonical_intent_bytes(stored),
         {:ok, right} <- AuditJournal.canonical_intent_bytes(decoded) do
      if left == right, do: :ok, else: {:error, :malformed}
    else
      {:error, _} -> {:error, :malformed}
    end
  end

  defp bind_stored_intent(nil, _decoded), do: :ok
  defp bind_stored_intent(_stored, _decoded), do: {:error, :malformed}

  defp after_match_record?(prepared, applied) do
    get_in(prepared, ["intent", "after_fingerprint"]) ===
      get_in(applied, ["observation", "after_fingerprint"])
  end

  defp terminal_intent_sha256(%{"intent_sha256" => sha256})
       when is_binary(sha256) and byte_size(sha256) == 64,
       do: {:ok, sha256}

  defp terminal_intent_sha256(%{"intent" => intent}) when is_map(intent) do
    case AuditJournal.canonical_intent_bytes(intent) do
      {:ok, bytes} -> {:ok, Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp terminal_intent_sha256(_op), do: {:error, :malformed}

  defp terminal_compact_string(
         "delivered",
         effect_class,
         intent_sha256,
         %{
           "prepared" => prepared,
           "effect_applied" => applied,
           "delivered" => delivered
         }
       )
       when effect_class in ["authority_increase", "authority_reduce"] do
    {:ok,
     "delivered|" <>
       effect_class <>
       "|" <>
       intent_sha256 <>
       "|prepared:" <> prepared <> "|effect_applied:" <> applied <> "|delivered:" <> delivered}
  end

  defp terminal_compact_string(
         "effect_rejected",
         effect_class,
         intent_sha256,
         %{
           "prepared" => prepared,
           "effect_rejected" => rejected
         }
       )
       when effect_class in ["authority_increase", "authority_reduce"] do
    {:ok,
     "effect_rejected|" <>
       effect_class <>
       "|" <> intent_sha256 <> "|prepared:" <> prepared <> "|effect_rejected:" <> rejected}
  end

  defp terminal_compact_string(_status, _effect_class, _intent_sha256, _fingerprints),
    do: {:error, :malformed}

  defp decode_stored_record(bytes) when is_binary(bytes) do
    with {:ok, decoded} <- decode_json(bytes),
         {:ok, record} <- map_admit(AuditJournal.admit_record(decoded)),
         {:ok, canonical} <- map_bytes(AuditJournal.canonical_record_bytes(record)),
         true <- canonical == bytes do
      {:ok, record, canonical}
    else
      false -> {:error, :malformed}
      {:error, _} = err -> err
    end
  end

  defp decode_stored_record(_bytes), do: {:error, :malformed}

  defp decode_json(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp admit_pending_list(records) when is_list(records) do
    max = AuditJournal.limits().hard_entry_cap
    admit_pending_members(records, [], 0, max, MapSet.new())
  end

  defp admit_pending_list(_records), do: {:error, :malformed}

  defp admit_pending_members([], acc, _count, _max, _seen), do: {:ok, Enum.reverse(acc)}

  defp admit_pending_members(_records, _acc, count, max, _seen) when count >= max,
    do: {:error, :malformed}

  defp admit_pending_members([record | tail], acc, count, max, seen) do
    with {:ok, admitted} <- map_admit(AuditJournal.admit_record(record)),
         {:ok, bytes} <- map_bytes(AuditJournal.canonical_record_bytes(admitted)),
         :ok <- require_pending_type(admitted),
         {:ok, seen} <- remember_pending(seen, admitted) do
      admit_pending_members(tail, [{admitted, bytes} | acc], count + 1, max, seen)
    end
  end

  defp admit_pending_members(_improper, _acc, _count, _max, _seen), do: {:error, :malformed}

  defp require_pending_type(%{"record_type" => type}) when type in ["prepared", "effect_applied"],
    do: :ok

  defp require_pending_type(_record), do: {:error, :pending_mismatch}

  defp remember_pending(seen, record) do
    key = {record["operation_id"], record["record_type"]}

    if MapSet.member?(seen, key) do
      {:error, :pending_mismatch}
    else
      {:ok, MapSet.put(seen, key)}
    end
  end

  defp match_pending_entries(supplied, snapshot) do
    expected =
      snapshot
      |> AuditJournal.snapshot_pending_entries()
      |> Enum.map(&pending_tuple/1)

    supplied_tuples =
      Enum.map(supplied, fn {record, bytes} ->
        fingerprint =
          case AuditJournal.record_fingerprint(bytes) do
            {:ok, sha256} -> sha256
            {:error, _reason} -> nil
          end

        {record["operation_id"], record["record_type"], fingerprint}
      end)

    compare_pending_tuples(supplied_tuples, expected)
  end

  defp pending_tuple(entry) do
    {entry["operation_id"], entry["record_type"], entry["sha256"]}
  end

  defp compare_pending_tuples(supplied, expected) do
    cond do
      supplied == expected ->
        :ok

      length(supplied) != length(expected) ->
        {:error, :pending_mismatch}

      MapSet.new(supplied) == MapSet.new(expected) ->
        {:error, :pending_mismatch}

      true ->
        zip_pending_tuples(supplied, expected)
    end
  end

  defp zip_pending_tuples(supplied, expected) do
    supplied
    |> Enum.zip(expected)
    |> Enum.reduce_while(:ok, fn
      {{oid, type, sha}, {oid, type, sha}}, :ok ->
        {:cont, :ok}

      {{oid, type, _sha}, {oid, type, _other}}, :ok ->
        {:halt, {:error, :pending_mismatch}}

      {{oid, _type, _sha}, {expected_oid, _expected_type, _expected_sha}}, :ok
      when oid != expected_oid ->
        {:halt, {:error, :cross_operation}}

      {_supplied, _expected}, :ok ->
        {:halt, {:error, :pending_mismatch}}
    end)
  end

  defp occupancy_exceeded?(used_entries, used_bytes, limits) do
    used_entries > limits.hard_entry_cap or used_bytes > limits.hard_byte_cap
  end

  defp install_restored(snapshot, supplied, snap_bytes) do
    pending_n = length(supplied)

    pending_bytes =
      Enum.reduce(supplied, 0, fn {_record, bytes}, acc -> acc + byte_size(bytes) end)

    used_entries = 1 + pending_n
    used_bytes = snap_bytes + pending_bytes
    limits = AuditJournal.limits()

    if occupancy_exceeded?(used_entries, used_bytes, limits) do
      {:error, :capacity_exhausted}
    else
      finish_restore(snapshot, supplied, snap_bytes, used_entries, used_bytes)
    end
  end

  defp finish_restore(snapshot, supplied, snap_bytes, used_entries, used_bytes) do
    with {:ok, state} <- install_terminals(empty_state(), snapshot),
         {:ok, state} <- install_pending(state, supplied) do
      {:ok,
       state
       |> Map.put("entry_count", used_entries)
       |> Map.put("byte_count", used_bytes)
       |> Map.put("snapshot", snapshot)
       |> Map.put("snapshot_bytes", snap_bytes)}
    end
  end

  defp install_terminals(state, snapshot) do
    snapshot
    |> AuditJournal.snapshot_terminal_entries()
    |> Enum.reduce_while({:ok, state}, fn entry, {:ok, acc} ->
      op = %{
        "status" => entry["status"],
        "effect_class" => entry["effect_class"],
        "intent_sha256" => entry["intent_sha256"],
        "fingerprints" => entry["fingerprints"]
      }

      next = put_in(acc, ["operations", entry["operation_id"]], op)
      {:cont, {:ok, next}}
    end)
  end

  defp install_pending(state, supplied) do
    Enum.reduce_while(supplied, {:ok, state}, fn {record, bytes}, {:ok, acc} ->
      case install_pending_record(acc, record, bytes) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp install_pending_record(state, %{"record_type" => "prepared"} = record, bytes) do
    {:ok, put_new_prepared(state, record, bytes)}
  end

  defp install_pending_record(state, %{"record_type" => "effect_applied"} = record, bytes) do
    op = Map.get(state["operations"], record["operation_id"])

    if is_map(op) and after_match?(op, record) do
      {:ok, put_next(state, op, record, bytes)}
    else
      {:error, :malformed}
    end
  end

  defp install_pending_record(_state, _record, _bytes), do: {:error, :pending_mismatch}

  defp pending_ops(state) do
    ops =
      state
      |> Map.get("operations", %{})
      |> Enum.sort_by(fn {operation_id, _op} -> operation_id end)
      |> Enum.filter(fn {_id, op} -> op["status"] in @pending_statuses end)
      |> Enum.take(AuditJournal.limits().hard_entry_cap)

    {:ok, ops}
  end

  defp project_pending(ops) do
    Enum.map(ops, fn {operation_id, op} ->
      %{
        "operation_id" => operation_id,
        "status" => op["status"],
        "effect_class" => op["effect_class"],
        "intent_sha256" => intent_sha256(op["intent"])
      }
    end)
  end

  defp pending_age({_id, op}, now_unix) do
    case unix_from_timestamp(get_in(op, ["intent", "prepared_at"])) do
      {:ok, prepared_unix} ->
        diff = now_unix - prepared_unix
        age = if diff < 0, do: 0, else: diff
        min(age, @max_pending_age_seconds)

      {:error, _} ->
        :malformed
    end
  end

  defp unix_from_timestamp(
         <<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2), "T",
           hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), "Z">>
       ) do
    with {yi, ""} <- Integer.parse(year),
         {mo, ""} <- Integer.parse(month),
         {da, ""} <- Integer.parse(day),
         {ho, ""} <- Integer.parse(hour),
         {mi, ""} <- Integer.parse(minute),
         {se, ""} <- Integer.parse(second),
         true <- Calendar.ISO.valid_date?(yi, mo, da),
         true <- Calendar.ISO.valid_time?(ho, mi, se, {0, 0}),
         {:ok, naive} <- NaiveDateTime.new(yi, mo, da, ho, mi, se),
         {:ok, dt} <- DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, DateTime.to_unix(dt)}
    else
      _ -> {:error, :malformed}
    end
  end

  defp unix_from_timestamp(_value), do: {:error, :malformed}
end
