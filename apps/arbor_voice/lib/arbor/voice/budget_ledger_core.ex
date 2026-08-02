defmodule Arbor.Voice.BudgetLedgerCore do
  @moduledoc """
  Pure reserve/consume/release/remaining decisions for the durable daily
  voice budget ledger (VOICE-24 prerequisite — see `Arbor.Voice.BudgetLedger`
  for the imperative shell that calls this core).

  No IO, process, Application-env, or time reads. Time, reservation ids, and
  settlement fingerprints are shell-supplied parameters; `new/4` decodes and
  validates previously-persisted state and `to_data/1` converts state back to
  a JSON-clean map for `Arbor.Contracts.Persistence.Record.data`.
  """

  # Duration bound for internal core arithmetic: ~10 years, generous headroom for
  # a minutes/hours-scale voice budget. Shell callers use a tighter 1-day cap.
  @max_duration_ms 315_360_000_000
  # Absolute-timestamp bound (now/reserved_at/expires_at/settled_at ms, i.e.
  # Unix epoch milliseconds): ~ year 5138. Rejects overflow/DoS-shaped values
  # without rejecting real wall-clock time.
  @max_timestamp_ms 100_000_000_000_000
  @max_ledger_entries 256

  # ISO 8601 date bounds for sanity. Year 2000..3000 covers all reasonable
  # deployment dates while rejecting DoS-shaped values.
  @min_year 2000
  @max_year 3000

  @id_re ~r/^vres_[0-9a-f]{32}$/
  @fingerprint_re ~r/^[0-9a-f]{64}$/

  @type active_entry :: %{
          id: String.t(),
          requested_ms: non_neg_integer(),
          reserved_at_ms: non_neg_integer(),
          expires_at_ms: non_neg_integer(),
          fingerprint: String.t()
        }

  @type settlement_entry :: %{
          id: String.t(),
          kind: :consumed | :released,
          elapsed_ms: non_neg_integer() | nil,
          settled_at_ms: non_neg_integer(),
          fingerprint: String.t(),
          requested_ms: non_neg_integer() | nil
        }

  @type state :: %{
          utc_day: String.t(),
          daily_limit_ms: non_neg_integer(),
          consumed_ms: non_neg_integer(),
          active: [active_entry()],
          settlements: [settlement_entry()]
        }

  @type limit_check :: {:check, pos_integer()} | :skip

  @doc false
  @spec max_ledger_entries() :: pos_integer()
  def max_ledger_entries, do: @max_ledger_entries

  @doc """
  Construct: decode and validate previously-persisted `data` (or bootstrap
  empty state when `data` is `nil`), then prune expired active reservations
  against `now_ms`. Malformed data is rejected and never silently repaired.
  """
  @spec new(map() | nil, String.t(), non_neg_integer(), limit_check()) ::
          {:ok, state()} | {:error, :malformed_state | :conflicting_limit | :invalid_amount}
  def new(data, utc_day, now_ms, limit_check) do
    with true <- valid_utc_day?(utc_day),
         true <- valid_timestamp_ms?(now_ms),
         {:ok, checked_limit} <- validate_limit_check(limit_check) do
      build_state(data, utc_day, now_ms, checked_limit, limit_check)
    else
      false -> {:error, :malformed_state}
      :error -> {:error, :invalid_amount}
    end
  end

  defp validate_limit_check(:skip), do: {:ok, 0}

  defp validate_limit_check({:check, ms})
       when is_integer(ms) and ms > 0 and ms <= @max_duration_ms,
       do: {:ok, ms}

  defp validate_limit_check(_limit_check), do: :error

  defp build_state(nil, utc_day, _now_ms, checked_limit, _limit_check) do
    {:ok,
     %{
       utc_day: utc_day,
       daily_limit_ms: checked_limit,
       consumed_ms: 0,
       active: [],
       settlements: []
     }}
  end

  defp build_state(%{} = data, utc_day, now_ms, _checked_limit, limit_check) do
    case decode(data, utc_day) do
      {:ok, decoded} ->
        case check_limit(decoded.daily_limit_ms, limit_check) do
          :ok -> {:ok, prune_expired(decoded, now_ms)}
          {:error, _} = error -> error
        end

      :error ->
        {:error, :malformed_state}
    end
  end

  defp build_state(_data, _utc_day, _now_ms, _checked_limit, _limit_check),
    do: {:error, :malformed_state}

  @doc """
  Reduce (decision only): admit or reject a new reservation. Does not mutate
  `state` — returns the decided fields for the shell to fingerprint before
  calling `commit_reservation/3`, so the CAS write happens exactly once.
  """
  @spec reserve(state(), String.t(), pos_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, :admitted, map()} | {:error, atom()}
  def reserve(%{} = state, reservation_id, requested_ms, now_ms, grace_ms) do
    cond do
      not valid_id?(reservation_id) ->
        {:error, :invalid_reservation_id}

      not valid_positive_ms?(requested_ms) ->
        {:error, :invalid_amount}

      not valid_timestamp_ms?(now_ms) or not valid_ms?(grace_ms) ->
        {:error, :invalid_amount}

      known_id?(state, reservation_id) ->
        {:error, :duplicate_reservation_id}

      length(state.active) + length(state.settlements) >= @max_ledger_entries ->
        {:error, :capacity_exceeded}

      true ->
        decide_admission(state, reservation_id, requested_ms, now_ms, grace_ms)
    end
  end

  defp decide_admission(state, reservation_id, requested_ms, now_ms, grace_ms) do
    expires_at_ms = now_ms + requested_ms + grace_ms

    cond do
      not valid_timestamp_ms?(expires_at_ms) ->
        {:error, :invalid_amount}

      state.consumed_ms + sum_requested(state.active) + requested_ms > state.daily_limit_ms ->
        {:error, :budget_exhausted}

      true ->
        {:ok, :admitted,
         %{
           id: reservation_id,
           requested_ms: requested_ms,
           reserved_at_ms: now_ms,
           expires_at_ms: expires_at_ms
         }}
    end
  end

  @doc "Reduce: pure insert of an admitted reservation, stamped with its shell-computed fingerprint."
  @spec commit_reservation(state(), map(), String.t()) :: {:ok, state()}
  def commit_reservation(%{} = state, %{id: _} = fields, fingerprint)
      when is_binary(fingerprint) do
    entry = Map.put(fields, :fingerprint, fingerprint)
    {:ok, %{state | active: [entry | state.active]}}
  end

  @doc """
  Reduce: settle `reservation_id` as consumed usage. Idempotent for a replay
  with the same elapsed value. Fails closed on a fingerprint mismatch, a
  larger conflicting replay, elapsed above the reservation, or an unknown id.
  """
  @spec consume(state(), String.t(), non_neg_integer(), String.t(), non_neg_integer()) ::
          {:ok, state()} | {:error, atom()}
  def consume(%{} = state, reservation_id, elapsed_ms, fingerprint, now_ms) do
    cond do
      not valid_ms?(elapsed_ms) -> {:error, :invalid_amount}
      not valid_timestamp_ms?(now_ms) -> {:error, :invalid_amount}
      true -> do_consume(state, reservation_id, elapsed_ms, fingerprint, now_ms)
    end
  end

  defp do_consume(state, reservation_id, elapsed_ms, fingerprint, now_ms) do
    case find_settlement(state, reservation_id) do
      {:ok, %{fingerprint: ^fingerprint, kind: :consumed, elapsed_ms: ^elapsed_ms}} ->
        {:ok, state}

      {:ok, %{fingerprint: ^fingerprint, kind: :consumed}} ->
        {:error, :conflicting_replay}

      {:ok, %{fingerprint: ^fingerprint, kind: :released}} ->
        {:error, :reservation_already_released}

      {:ok, %{fingerprint: _other}} ->
        {:error, :reservation_mismatch}

      :not_found ->
        consume_active(state, reservation_id, elapsed_ms, fingerprint, now_ms)
    end
  end

  defp consume_active(state, reservation_id, elapsed_ms, fingerprint, now_ms) do
    case find_active(state, reservation_id) do
      :not_found ->
        {:error, :reservation_not_found}

      {:ok, %{fingerprint: stored_fp}} when stored_fp != fingerprint ->
        {:error, :reservation_mismatch}

      {:ok, entry} ->
        settle_active(state, entry, elapsed_ms, now_ms)
    end
  end

  defp settle_active(state, entry, elapsed_ms, now_ms) do
    new_consumed = state.consumed_ms + elapsed_ms

    cond do
      elapsed_ms > entry.requested_ms ->
        {:error, :elapsed_exceeds_reservation}

      not valid_ms?(new_consumed) ->
        {:error, :invalid_amount}

      true ->
        settlement = %{
          id: entry.id,
          kind: :consumed,
          elapsed_ms: elapsed_ms,
          settled_at_ms: now_ms,
          fingerprint: entry.fingerprint,
          requested_ms: entry.requested_ms
        }

        {:ok,
         %{
           state
           | consumed_ms: new_consumed,
             active: List.delete(state.active, entry),
             settlements: [settlement | state.settlements]
         }}
    end
  end

  @doc """
  Reduce: release `reservation_id` without consuming any of its allowance.
  Idempotent when already released. Fails closed on a fingerprint mismatch,
  an already-consumed settlement, or an unknown id.
  """
  @spec release(state(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, state()} | {:error, atom()}
  def release(%{} = state, reservation_id, fingerprint, now_ms) do
    if valid_timestamp_ms?(now_ms) do
      do_release(state, reservation_id, fingerprint, now_ms)
    else
      {:error, :invalid_amount}
    end
  end

  defp do_release(state, reservation_id, fingerprint, now_ms) do
    case find_settlement(state, reservation_id) do
      {:ok, %{fingerprint: ^fingerprint, kind: :released}} ->
        {:ok, state}

      {:ok, %{fingerprint: ^fingerprint, kind: :consumed}} ->
        {:error, :reservation_already_consumed}

      {:ok, %{fingerprint: _other}} ->
        {:error, :reservation_mismatch}

      :not_found ->
        release_active(state, reservation_id, fingerprint, now_ms)
    end
  end

  defp release_active(state, reservation_id, fingerprint, now_ms) do
    case find_active(state, reservation_id) do
      :not_found ->
        {:error, :reservation_not_found}

      {:ok, %{fingerprint: stored_fp}} when stored_fp != fingerprint ->
        {:error, :reservation_mismatch}

      {:ok, entry} ->
        settlement = %{
          id: entry.id,
          kind: :released,
          elapsed_ms: nil,
          settled_at_ms: now_ms,
          fingerprint: entry.fingerprint
        }

        {:ok,
         %{
           state
           | active: List.delete(state.active, entry),
             settlements: [settlement | state.settlements]
         }}
    end
  end

  @doc "Reduce (query): allowance remaining after consumed usage and live reservations."
  @spec remaining(state()) :: non_neg_integer()
  def remaining(%{} = state) do
    max(state.daily_limit_ms - state.consumed_ms - sum_requested(state.active), 0)
  end

  @doc "Convert: JSON-clean, closed map for `Arbor.Contracts.Persistence.Record.data`."
  @spec to_data(state()) :: map()
  def to_data(%{} = state) do
    %{
      "version" => 1,
      "utc_day" => state.utc_day,
      "daily_limit_ms" => state.daily_limit_ms,
      "consumed_ms" => state.consumed_ms,
      "active_reservations" => Enum.map(state.active, &encode_active/1),
      "settlements" => Enum.map(state.settlements, &encode_settlement/1)
    }
  end

  # ---------------------------------------------------------------------------
  # Encoding
  # ---------------------------------------------------------------------------

  defp encode_active(entry) do
    %{
      "id" => entry.id,
      "requested_ms" => entry.requested_ms,
      "reserved_at_ms" => entry.reserved_at_ms,
      "expires_at_ms" => entry.expires_at_ms,
      "fingerprint" => entry.fingerprint
    }
  end

  defp encode_settlement(%{kind: :consumed} = s) do
    %{
      "id" => s.id,
      "kind" => "consumed",
      "elapsed_ms" => s.elapsed_ms,
      "settled_at_ms" => s.settled_at_ms,
      "fingerprint" => s.fingerprint,
      "requested_ms" => s.requested_ms
    }
  end

  defp encode_settlement(%{kind: :released} = s) do
    %{
      "id" => s.id,
      "kind" => "released",
      "settled_at_ms" => s.settled_at_ms,
      "fingerprint" => s.fingerprint
    }
  end

  # ---------------------------------------------------------------------------
  # Decoding — closed schema, exact key sets, no silent coercion
  # ---------------------------------------------------------------------------

  @data_keys [
    "version",
    "utc_day",
    "daily_limit_ms",
    "consumed_ms",
    "active_reservations",
    "settlements"
  ]

  defp decode(data, utc_day) do
    with true <- is_map(data) and map_size(data) == length(@data_keys),
         true <- Enum.all?(@data_keys, &Map.has_key?(data, &1)),
         {:ok, 1} <- fetch_version(data),
         {:ok, ^utc_day} <- fetch_utc_day(data),
         {:ok, daily_limit_ms} <- fetch_daily_limit(data),
         {:ok, consumed_ms} <- fetch_consumed(data),
         active_raw = Map.get(data, "active_reservations"),
         settlements_raw = Map.get(data, "settlements"),
         :ok <- bounded_shape_and_count(active_raw, settlements_raw, @max_ledger_entries),
         {:ok, active} <- decode_list(active_raw, &decode_active_entry/1),
         {:ok, settlements} <- decode_list(settlements_raw, &decode_settlement_entry/1),
         :ok <- check_unique_ids(active, settlements),
         :ok <- check_invariants(active, settlements, consumed_ms, daily_limit_ms) do
      {:ok,
       %{
         utc_day: utc_day,
         daily_limit_ms: daily_limit_ms,
         consumed_ms: consumed_ms,
         active: active,
         settlements: settlements
       }}
    else
      _ -> :error
    end
  end

  # Shared bounded cons-cell walk for both lists. No pre-cap is_list/length/Enum
  # traversal; work is O(cap) and stops as soon as the budget is exhausted or
  # an improper tail is seen.
  defp bounded_shape_and_count(active_raw, settlements_raw, cap) do
    case bounded_walk(active_raw, cap) do
      {:ok, after_active} ->
        case bounded_walk(settlements_raw, after_active) do
          {:ok, _after_settlements} ->
            :ok

          :over_limit ->
            :malformed_state

          :improper ->
            :malformed_state
        end

      :over_limit ->
        :malformed_state

      :improper ->
        :malformed_state
    end
  end

  defp bounded_walk([], budget) when budget >= 0, do: {:ok, budget}

  defp bounded_walk([_h | t], budget) when budget > 0 do
    bounded_walk(t, budget - 1)
  end

  defp bounded_walk([_h | _t], 0), do: :over_limit
  defp bounded_walk(_other, _budget), do: :improper

  defp fetch_version(data) do
    case Map.get(data, "version") do
      1 -> {:ok, 1}
      _ -> :error
    end
  end

  defp fetch_utc_day(data) do
    case Map.get(data, "utc_day") do
      v when is_binary(v) -> if valid_utc_day?(v), do: {:ok, v}, else: :error
      _ -> :error
    end
  end

  defp fetch_daily_limit(data) do
    case Map.get(data, "daily_limit_ms") do
      v when is_integer(v) -> if valid_positive_ms?(v), do: {:ok, v}, else: :error
      _ -> :error
    end
  end

  defp fetch_consumed(data) do
    case Map.get(data, "consumed_ms") do
      v when is_integer(v) -> if valid_ms?(v), do: {:ok, v}, else: :error
      _ -> :error
    end
  end

  # decode_list is called only after bounded_shape_and_count has proven both
  # inputs are proper lists and within the combined cap, so Enum use here is safe.
  defp decode_list(list, decoder) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case decoder.(item) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  @active_keys ["id", "requested_ms", "reserved_at_ms", "expires_at_ms", "fingerprint"]

  defp decode_active_entry(entry) when is_map(entry) do
    with true <- map_size(entry) == length(@active_keys),
         true <- Enum.all?(@active_keys, &Map.has_key?(entry, &1)),
         %{
           "id" => id,
           "requested_ms" => req,
           "reserved_at_ms" => rat,
           "expires_at_ms" => eat,
           "fingerprint" => fp
         } <- entry,
         true <- valid_id?(id),
         true <- valid_positive_ms?(req),
         true <- valid_timestamp_ms?(rat),
         true <- valid_timestamp_ms?(eat),
         true <- eat >= rat,
         true <- valid_fingerprint?(fp) do
      {:ok,
       %{id: id, requested_ms: req, reserved_at_ms: rat, expires_at_ms: eat, fingerprint: fp}}
    else
      _ -> :error
    end
  end

  defp decode_active_entry(_), do: :error

  @consumed_keys ["id", "kind", "elapsed_ms", "settled_at_ms", "fingerprint", "requested_ms"]
  @released_keys ["id", "kind", "settled_at_ms", "fingerprint"]

  defp decode_settlement_entry(%{"kind" => "consumed"} = entry) do
    with true <- map_size(entry) == length(@consumed_keys),
         true <- Enum.all?(@consumed_keys, &Map.has_key?(entry, &1)),
         %{
           "id" => id,
           "elapsed_ms" => elapsed_ms,
           "settled_at_ms" => sat,
           "fingerprint" => fp,
           "requested_ms" => requested_ms
         } <- entry,
         true <- valid_id?(id),
         true <- valid_ms?(elapsed_ms),
         true <- valid_positive_ms?(requested_ms),
         true <- elapsed_ms <= requested_ms,
         true <- valid_timestamp_ms?(sat),
         true <- valid_fingerprint?(fp) do
      {:ok,
       %{
         id: id,
         kind: :consumed,
         elapsed_ms: elapsed_ms,
         settled_at_ms: sat,
         fingerprint: fp,
         requested_ms: requested_ms
       }}
    else
      _ -> :error
    end
  end

  defp decode_settlement_entry(%{"kind" => "released"} = entry) do
    with true <- map_size(entry) == length(@released_keys),
         true <- Enum.all?(@released_keys, &Map.has_key?(entry, &1)),
         %{"id" => id, "settled_at_ms" => sat, "fingerprint" => fp} <- entry,
         true <- valid_id?(id),
         true <- valid_timestamp_ms?(sat),
         true <- valid_fingerprint?(fp) do
      {:ok,
       %{
         id: id,
         kind: :released,
         elapsed_ms: nil,
         settled_at_ms: sat,
         fingerprint: fp,
         requested_ms: nil
       }}
    else
      _ -> :error
    end
  end

  defp decode_settlement_entry(_), do: :error

  defp check_unique_ids(active, settlements) do
    all_ids = Enum.map(active, & &1.id) ++ Enum.map(settlements, & &1.id)
    if length(all_ids) == length(Enum.uniq(all_ids)), do: :ok, else: :error
  end

  defp check_invariants(active, settlements, consumed_ms, daily_limit_ms) do
    active_requested_sum = sum_requested(active)

    consumed_sum =
      settlements
      |> Enum.filter(&(&1.kind == :consumed))
      |> Enum.map(& &1.elapsed_ms)
      |> Enum.sum()

    with true <- consumed_ms <= daily_limit_ms,
         true <- consumed_ms + active_requested_sum <= daily_limit_ms,
         true <- consumed_sum == consumed_ms,
         true <- Enum.all?(active, &(&1.expires_at_ms >= &1.reserved_at_ms + &1.requested_ms)) do
      :ok
    else
      _ -> :error
    end
  end

  defp check_limit(_stored, :skip), do: :ok
  defp check_limit(stored, {:check, expected}) when stored == expected, do: :ok
  defp check_limit(_stored, {:check, _expected}), do: {:error, :conflicting_limit}

  @doc false
  @spec valid_id?(String.t()) :: boolean()
  def valid_id?(v), do: is_binary(v) and Regex.match?(@id_re, v)

  @doc false
  @spec valid_utc_day?(String.t()) :: boolean()
  def valid_utc_day?(v) do
    with true <- is_binary(v),
         {:ok, %Date{year: year}} <- Date.from_iso8601(v),
         true <- year >= @min_year,
         true <- year <= @max_year do
      true
    else
      _ -> false
    end
  end

  @doc false
  @spec valid_timestamp_ms?(non_neg_integer()) :: boolean()
  def valid_timestamp_ms?(v), do: is_integer(v) and v >= 0 and v <= @max_timestamp_ms

  @doc false
  @spec valid_ms?(non_neg_integer()) :: boolean()
  def valid_ms?(v), do: is_integer(v) and v >= 0 and v <= @max_duration_ms

  @doc false
  @spec valid_positive_ms?(pos_integer()) :: boolean()
  def valid_positive_ms?(v), do: is_integer(v) and v > 0 and v <= @max_duration_ms

  # ---------------------------------------------------------------------------
  # Bounded, pre-traversal list-shape and count checks
  # ---------------------------------------------------------------------------

  @doc false
  @spec bounded_list_count(term(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :over_limit}
  def bounded_list_count(v, max_count) when is_list(v) do
    bounded_list_count(v, max_count, 0)
  end

  def bounded_list_count(_v, _max_count), do: {:error, :over_limit}

  defp bounded_list_count([], _max_count, n), do: {:ok, n}

  defp bounded_list_count(_rest, max_count, n) when n > max_count,
    do: {:error, :over_limit}

  defp bounded_list_count([_h | t], max_count, n),
    do: bounded_list_count(t, max_count, n + 1)

  # ---------------------------------------------------------------------------
  # Lookups and bounds
  # ---------------------------------------------------------------------------

  defp prune_expired(state, now_ms) do
    %{state | active: Enum.filter(state.active, fn entry -> entry.expires_at_ms > now_ms end)}
  end

  defp known_id?(state, id) do
    Enum.any?(state.active, &(&1.id == id)) or Enum.any?(state.settlements, &(&1.id == id))
  end

  defp find_active(state, id) do
    case Enum.find(state.active, &(&1.id == id)) do
      nil -> :not_found
      entry -> {:ok, entry}
    end
  end

  defp find_settlement(state, id) do
    case Enum.find(state.settlements, &(&1.id == id)) do
      nil -> :not_found
      entry -> {:ok, entry}
    end
  end

  defp sum_requested(entries), do: Enum.reduce(entries, 0, fn e, acc -> acc + e.requested_ms end)

  defp valid_fingerprint?(v), do: is_binary(v) and Regex.match?(@fingerprint_re, v)
end
