defmodule Arbor.Security.AuditJournalCore do
  @moduledoc """
  Pure CRC reducer for the v1 Security authority-mutation audit journal.

  Folds admitted append records, enforces prepared -> effect_applied -> delivered
  or prepared -> effect_rejected, exact duplicate/conflict semantics, and
  static-floor capacity accounting.

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
          "intent_sha256" => intent_sha256(op["intent"])
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

  @spec pending_operations(state()) :: [map()]
  def pending_operations(state) when is_map(state) do
    state
    |> show()
    |> Map.get("operations", [])
    |> Enum.filter(&(&1["status"] in @pending_statuses))
    |> Enum.take(AuditJournal.limits().hard_entry_cap)
  end

  def pending_operations(_state), do: []

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
         true <- is_integer(state["byte_count"]) and state["byte_count"] >= 0 do
      :ok
    else
      _ -> {:error, :malformed}
    end
  end

  defp valid_state(_state), do: {:error, :malformed}

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

    case Map.fetch(op["records"], record_type) do
      {:ok, ^bytes} ->
        {:ok, state, :idempotent}

      {:ok, _other} ->
        {:error, :operation_conflict}

      :error ->
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

  defp intent_sha256(intent) when is_map(intent) do
    case AuditJournal.canonical_intent_bytes(intent) do
      {:ok, bytes} ->
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

      {:error, _reason} ->
        String.duplicate("0", 64)
    end
  end

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
