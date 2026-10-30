defmodule Arbor.Security.TemplateAuthorityCapabilityMutationSecurityRegressionTest.CASSandbox do
  @moduledoc false
  use GenServer

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.{Record, Revision}

  # Security-owned, test-only process-lifetime backend. Its owner serializes
  # structured Record generation/revision fencing and delete tombstones; the
  # fault controls exercise ambiguous/conflict regression paths around those
  # real transitions. It survives a CapabilityStore restart because the test
  # keeps this backend + the AuthorityStore alive.

  @default_max_entries 100_000

  @puts_key {__MODULE__, :puts}
  @deletes_key {__MODULE__, :deletes}
  @cas_conflict_key {__MODULE__, :cas_conflict}
  # Post-admission failure injection: armed on a genuine CAS insert success;
  # the next get (the post-admission reobserve inside ack_commit_reobserved)
  # exits to simulate a crash at or after the durable admission boundary.
  @post_admission_key {__MODULE__, :post_admission}
  @poison_get_key {__MODULE__, :poison_get}
  # Mismatched concurrent CAS occupant: the conflict branch admits THIS record
  # (not our replacement) under the id so the acknowledged path must classify
  # :id_conflict without overwriting it.
  @cas_mismatch_key {__MODULE__, :cas_mismatch}
  # No-scan probe: counts full-inventory reads (Store.list/1), which backs the
  # authoritative_entries/authoritative_list fallback. Tests reset this AFTER
  # the store starts (restore's list already ran) and assert it stays 0 during
  # an acknowledged grant.
  @list_calls_key {__MODULE__, :list_calls}
  # Post-delete failure injection: armed on a genuine compare_and_delete
  # success, it exits to simulate a crash at or after a durable revoke
  # admission boundary (durable gone, live retained, outcome unknown).
  @post_delete_key {__MODULE__, :post_delete}
  # One-shot get rewrite: return an otherwise-valid authoritative Record with
  # only Record.key corrupted (physical identity mismatch). Used for C3B4a
  # wrong-key fence gates — structured backends reject putting wrong-key rows.
  @wrong_key_get_key {__MODULE__, :wrong_key_get}
  # Compare-and-delete race: admit a replacement under the key and return
  # conflict so fenced revoke must classify identity_conflict without deleting.
  @cad_replacement_key {__MODULE__, :cad_replacement}

  def fail_puts(n) when is_integer(n) and n >= 0, do: :persistent_term.put(@puts_key, n)
  def fail_deletes(n) when is_integer(n) and n >= 0, do: :persistent_term.put(@deletes_key, n)

  def fail_cas_conflict(n) when is_integer(n) and n >= 0,
    do: :persistent_term.put(@cas_conflict_key, n)

  def fail_post_admission(n) when is_integer(n) and n >= 0,
    do: :persistent_term.put(@post_admission_key, n)

  def fail_post_delete(n) when is_integer(n) and n >= 0,
    do: :persistent_term.put(@post_delete_key, n)

  def inventory_scan_count, do: :persistent_term.get(@list_calls_key, 0)

  def reset_inventory_scan_count, do: :persistent_term.erase(@list_calls_key)

  def seed_cas_conflict_mismatch(%Record{} = record),
    do: :persistent_term.put(@cas_mismatch_key, record)

  def rewrite_next_get_wrong_key,
    do: :persistent_term.put(@wrong_key_get_key, true)

  def seed_compare_delete_replacement(%Record{} = record),
    do: :persistent_term.put(@cad_replacement_key, record)

  def clear do
    :persistent_term.erase(@puts_key)
    :persistent_term.erase(@deletes_key)
    :persistent_term.erase(@cas_conflict_key)
    :persistent_term.erase(@post_admission_key)
    :persistent_term.erase(@poison_get_key)
    :persistent_term.erase(@cas_mismatch_key)
    :persistent_term.erase(@list_calls_key)
    :persistent_term.erase(@post_delete_key)
    :persistent_term.erase(@wrong_key_get_key)
    :persistent_term.erase(@cad_replacement_key)
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def put(key, record, opts) do
    cond do
      Revision.key_mismatch?(key, record) ->
        {:error, :key_mismatch}

      inject?(@puts_key) ->
        {:error, :injected_put_failure}

      true ->
        GenServer.call(store_name!(opts), {:put, key, record})
    end
  end

  @impl true
  def get(key, opts) do
    if consume_poison_get?() do
      # Post-admission crash: admission already committed, the reobserve get
      # (the first read AFTER admission) exits to force :outcome_unknown.
      exit({:post_admission, :timeout})
    else
      case GenServer.call(store_name!(opts), {:get, key}) do
        {:ok, %Record{} = rec} = ok ->
          if consume_wrong_key_get?() do
            {:ok, %{rec | key: rec.key <> "_wrong"}}
          else
            ok
          end

        other ->
          other
      end
    end
  end

  @impl true
  def delete(key, opts) do
    if inject?(@deletes_key) do
      {:error, :injected_delete_failure}
    else
      GenServer.call(store_name!(opts), {:delete, key})
    end
  end

  # Exact incarnation reads/creation use the same owner and fault controls as
  # the existing CAS fixture. A tombstone is never collapsed into fresh absence.
  def authoritative_entry(key, opts) do
    case get(key, opts) do
      {:error, :not_found} -> GenServer.call(store_name!(opts), {:authoritative_entry, key})
      result -> result
    end
  end

  def compare_and_create(key, expected, replacement, opts),
    do: compare_and_swap(key, {:entry, expected}, replacement, opts)

  @impl true
  def list(opts) do
    :persistent_term.put(@list_calls_key, :persistent_term.get(@list_calls_key, 0) + 1)
    GenServer.call(store_name!(opts), {:list, opts})
  end

  @impl true
  def exists?(key, opts), do: GenServer.call(store_name!(opts), {:exists?, key})

  @impl true
  def durability_class(_opts), do: :process_lifetime

  @impl true
  def compare_and_swap(key, expected, replacement, opts) do
    case pop_seeded_mismatch() do
      {:mismatch, mismatch} ->
        # A concurrent writer admitted a MISMATCHED occupant under this id just
        # before our CAS, then reported conflict. The acknowledged path
        # reobserves the mismatched record and must classify :id_conflict
        # without overwriting it.
        _ = put_without_faults(key, mismatch, opts)
        {:error, :conflict}

      :none ->
        cond do
          Revision.cas_operands_key_mismatch?(key, expected, replacement) ->
            {:error, :key_mismatch}

          inject?(@cas_conflict_key) ->
            # Simulate a concurrent writer that admitted the record just before
            # our CAS, then reported conflict. The acknowledged path reobserves
            # and classifies the now-present record (a REAL conflict
            # reobservation).
            _ = put_without_faults(key, replacement, opts)
            {:error, :conflict}

          inject?(@puts_key) ->
            {:error, :injected_put_failure}

          true ->
            case GenServer.call(
                   store_name!(opts),
                   {:compare_and_swap, key, expected, replacement}
                 ) do
              {:ok, _stored} = ok ->
                # Genuine admission succeeded: arm the post-admission poison so
                # the immediately-following reobserve get can be made to crash
                # for the convergence regression.
                :ok = maybe_arm_post_admission()
                ok

              other ->
                other
            end
        end
    end
  end

  @impl true
  def compare_and_delete(key, expected, opts) do
    case inject?(@deletes_key) do
      true ->
        {:error, :injected_delete_failure}

      false ->
        compare_and_delete_after_inject(key, expected, opts)
    end
  end

  # Concurrent replacement between authoritative read and compare-delete.
  # Key must match the store key for structured put admission; backend tokens
  # after put are authoritative (do not trust seed gen/rev). Only report
  # conflict after a successful put — never discard a failed injection as a
  # synthetic conflict.
  defp compare_and_delete_after_inject(key, expected, opts) do
    case pop_seeded_cad_replacement() do
      {:replacement, replacement} ->
        cad_put_replacement_conflict(key, replacement, opts)

      :none ->
        cad_genuine_compare_and_delete(key, expected, opts)
    end
  end

  defp cad_put_replacement_conflict(key, replacement, opts) do
    put_record =
      case replacement do
        %Record{} = rec -> %{rec | key: key}
        other -> other
      end

    case put_without_faults(key, put_record, opts) do
      :ok -> {:error, :conflict}
      {:error, _reason} = error -> error
    end
  end

  defp cad_genuine_compare_and_delete(key, expected, opts) do
    if Revision.key_mismatch?(key, expected) do
      {:error, :key_mismatch}
    else
      case GenServer.call(store_name!(opts), {:compare_and_delete, key, expected}) do
        :ok ->
          # Genuine durable delete committed. If armed, exit to simulate a crash
          # at or after the durable revoke boundary so the caller cannot confirm
          # whether live eviction + signal completed.
          if inject?(@post_delete_key), do: exit({:post_delete, :timeout})
          :ok

        other ->
          other
      end
    end
  end

  defp inject?(key) do
    case :persistent_term.get(key, 0) do
      n when n > 0 ->
        :persistent_term.put(key, n - 1)
        true

      _ ->
        false
    end
  end

  # Atomically pop a seeded mismatch record (only one conflict per seed).
  defp pop_seeded_mismatch do
    case :persistent_term.get(@cas_mismatch_key, :none) do
      :none ->
        :none

      record ->
        :persistent_term.erase(@cas_mismatch_key)
        {:mismatch, record}
    end
  end

  # Arm the post-admission poison flag when a genuine CAS insert succeeds and
  # a post-admission failure is requested. The counter is consumed when the
  # poisoned get actually fires (one-shot).
  defp maybe_arm_post_admission do
    case :persistent_term.get(@post_admission_key, 0) do
      n when n > 0 ->
        :persistent_term.put(@poison_get_key, true)
        :ok

      _ ->
        :ok
    end
  end

  # Consume the post-admission poison flag on the next get; decrement the
  # counter so the failure is one-shot.
  defp consume_poison_get? do
    case :persistent_term.get(@poison_get_key, false) do
      true ->
        :persistent_term.erase(@poison_get_key)

        remaining = :persistent_term.get(@post_admission_key, 0) - 1
        :persistent_term.put(@post_admission_key, remaining)
        true

      _ ->
        false
    end
  end

  defp consume_wrong_key_get? do
    case :persistent_term.get(@wrong_key_get_key, false) do
      true ->
        :persistent_term.erase(@wrong_key_get_key)
        true

      _ ->
        false
    end
  end

  defp pop_seeded_cad_replacement do
    case :persistent_term.get(@cad_replacement_key, :none) do
      :none ->
        :none

      record ->
        :persistent_term.erase(@cad_replacement_key)
        {:replacement, record}
    end
  end

  defp put_without_faults(key, value, opts) do
    if Revision.key_mismatch?(key, value) do
      {:error, :key_mismatch}
    else
      GenServer.call(store_name!(opts), {:put, key, value})
    end
  end

  defp store_name!(opts), do: Keyword.fetch!(opts, :name)

  @impl GenServer
  def init(opts) do
    {:ok, %{entries: %{}, max_entries: Keyword.get(opts, :max_entries, @default_max_entries)}}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, state) do
    reply =
      state.entries
      |> Map.get(key, :absent)
      |> Revision.live_value()
      |> case do
        {:ok, value} -> {:ok, value}
        :not_found -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:authoritative_entry, key}, _from, state),
    do: {:reply, {:ok, Map.get(state.entries, key, :absent)}, state}

  def handle_call({:put, key, value}, _from, state) do
    if at_capacity?(state, key) do
      {:reply, {:error, :store_full}, state}
    else
      current = Map.get(state.entries, key, :absent)

      case Revision.apply_put(current, value) do
        {:ok, stored} ->
          {:reply, :ok, put_in(state.entries[key], stored)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:delete, key}, _from, state) do
    entries =
      case Map.fetch(state.entries, key) do
        {:ok, entry} ->
          case Revision.to_tombstone(entry) do
            :absent -> Map.delete(state.entries, key)
            tombstone -> Map.put(state.entries, key, tombstone)
          end

        :error ->
          state.entries
      end

    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:list, opts}, _from, state) do
    reply =
      with {:ok, limit} <- Revision.authoritative_list_limit(opts) do
        keys =
          for {key, entry} <- state.entries,
              match?({:ok, _value}, Revision.live_value(entry)),
              do: key

        if is_integer(limit) and length(keys) > limit,
          do: {:error, :inventory_limit_exceeded},
          else: {:ok, keys}
      end

    {:reply, reply, state}
  end

  def handle_call({:exists?, key}, _from, state) do
    live_value =
      state.entries
      |> Map.get(key, :absent)
      |> Revision.live_value()

    {:reply, match?({:ok, _value}, live_value), state}
  end

  def handle_call({:compare_and_swap, key, expected, replacement}, _from, state) do
    case apply_compare_and_swap(state, key, expected, replacement) do
      {:ok, stored, new_state} -> {:reply, {:ok, stored}, new_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:compare_and_delete, key, expected}, _from, state) do
    case Map.fetch(state.entries, key) do
      {:ok, current} ->
        if Revision.cas_matches?(current, expected) do
          entries =
            case Revision.to_tombstone(current) do
              :absent -> Map.delete(state.entries, key)
              tombstone -> Map.put(state.entries, key, tombstone)
            end

          {:reply, :ok, %{state | entries: entries}}
        else
          {:reply, {:error, :conflict}, state}
        end

      :error ->
        {:reply, {:error, :conflict}, state}
    end
  end

  defp apply_compare_and_swap(state, key, {:entry, expected}, replacement) do
    if Map.get(state.entries, key, :absent) == expected,
      do: apply_compare_and_swap(state, key, :not_found, replacement),
      else: {:error, :conflict}
  end

  defp apply_compare_and_swap(state, key, :not_found, replacement) do
    current = Map.get(state.entries, key, :absent)

    cond do
      not Revision.absent_for_cas?(current) ->
        {:error, :conflict}

      current == :absent and at_capacity?(state, key) ->
        {:error, :store_full}

      match?({:tombstone, _generation}, current) ->
        {:tombstone, generation} = current

        store_cas_result(
          state,
          key,
          Revision.advance_cas_insert_from_tombstone(generation, replacement)
        )

      true ->
        store_cas_result(state, key, Revision.advance_cas_insert(replacement))
    end
  end

  defp apply_compare_and_swap(state, key, {:value, expected}, replacement) do
    current = Map.get(state.entries, key, :absent)

    if Revision.cas_matches?(current, expected) do
      case {current, replacement} do
        {%Record{} = current_record, %Record{}} ->
          case Revision.advance_cas_update(current_record, replacement) do
            {:ok, stored} -> store_cas_result(state, key, stored)
            {:error, reason} -> {:error, reason}
          end

        {%Record{}, _other} ->
          {:error, :conflict}

        {_plain, %Record{}} ->
          {:error, :conflict}

        {_plain, _other} ->
          store_cas_result(state, key, replacement)
      end
    else
      {:error, :conflict}
    end
  end

  defp store_cas_result(state, key, stored),
    do: {:ok, stored, put_in(state.entries[key], stored)}

  defp at_capacity?(state, key),
    do: map_size(state.entries) >= state.max_entries and not Map.has_key?(state.entries, key)
end
