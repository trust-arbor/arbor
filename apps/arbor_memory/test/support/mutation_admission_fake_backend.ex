defmodule Arbor.Memory.Test.MutationAdmissionFakeBackend do
  @moduledoc """
  Deterministic node_restart CAS fake for MutationAdmission tests.

  Startup-injected via start_link target opts — does not mutate Application env.

  Sync barriers (`arm_sync/3`, `await_sync/2`, `release_sync/1`) force multiple
  authorities to observe the same revision before proceeding past get/CAS.
  """

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record

  defstruct records: %{},
            force_conflicts: %{},
            fail_next: %{},
            corrupt_next: %{},
            hang_ms: %{},
            # Tombstone reinsert: next :not_found CAS uses this generation (then resets to 1).
            next_insert_gen: 1,
            # After this many successful CAS admits, every further CAS conflicts
            # (`nil` = disabled). Used to keep a post-handoff root blocked.
            cas_success_budget: nil,
            # Post-dispatch: after a successful CAS is recorded, withhold the reply
            # until release_withheld_cas_reply/1 (or the caller is killed on timeout).
            withhold_cas_reply: %{mode: :off},
            history: [],
            sync: %{mode: :off}

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, {:already_started, pid()}}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :agent_name)
    # Ordinary Agent semantics only — do not silently reuse/reset an already-started
    # named backend (that erases another live test's state and hides owner leaks).
    # Tests must use unique names and explicit on_exit Fake.stop/1 cleanup.
    Agent.start_link(fn -> %__MODULE__{} end, name: name)
  end

  def stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  def force_conflicts(name, key, count) do
    Agent.update(name, fn s ->
      %{s | force_conflicts: Map.put(s.force_conflicts, key, count)}
    end)
  end

  def set_conflict_count(name, count) do
    Agent.update(name, fn s ->
      %{s | force_conflicts: %{"__all__" => count}}
    end)
  end

  def fail_next(name, kind, reason) do
    Agent.update(name, fn s ->
      %{s | fail_next: Map.put(s.fail_next, kind, reason)}
    end)
  end

  @doc """
  Next `kind` (`:get` | `:compare_and_swap`) returns a malformed applied success.
  For CAS, the write is applied first then a corrupt receipt is returned.
  """
  def corrupt_next(name, kind, mode \\ :malformed_record) do
    Agent.update(name, fn s ->
      %{s | corrupt_next: Map.put(s.corrupt_next, kind, mode)}
    end)
  end

  @doc """
  Pre-dispatch hang: next operation of `kind` sleeps `ms` **before** any
  mutation is attempted (proves timeout with no durable effect).
  """
  def hang_next(name, kind, ms) when is_integer(ms) and ms > 0 do
    Agent.update(name, fn s ->
      %{s | hang_ms: Map.put(s.hang_ms, kind, ms)}
    end)
  end

  @doc """
  Post-dispatch withhold: the next successful CAS is fully applied and recorded,
  then the backend signals `{:cas_applied, key, ref, stored}` to `tester` and
  blocks the reply until `release_withheld_cas_reply/1` (or the unlinked worker
  is killed by the shell deadline). Proves durable effect without a public handle.
  """
  def arm_withhold_cas_reply(name, tester \\ self()) do
    Agent.update(name, fn s ->
      %{
        s
        | withhold_cas_reply: %{
            mode: :armed,
            tester: tester,
            waiting: []
          }
      }
    end)
  end

  @doc "Unblock any CAS callers parked after apply-then-withhold."
  def release_withheld_cas_reply(name) do
    waiters =
      Agent.get_and_update(name, fn s ->
        case s.withhold_cas_reply do
          %{waiting: w} = wr ->
            {w, %{s | withhold_cas_reply: %{mode: :off, waiting: [], tester: nil}}}

          _ ->
            {[], s}
        end
      end)

    Enum.each(waiters, fn {pid, ref} -> send(pid, {:withhold_go, ref}) end)
    :ok
  end

  @doc """
  Next insert (`expected == :not_found`) returns generation `gen` with revision 1
  (simulates reinsert after a hidden tombstone; gen may be > 1).
  """
  def set_next_insert_generation(name, gen) when is_integer(gen) and gen >= 1 do
    Agent.update(name, fn s -> %{s | next_insert_gen: gen} end)
  end

  @doc """
  Allow the next `n` successful CAS admits, then conflict every subsequent CAS
  until cleared. `n = 0` conflicts all further CAS immediately.
  """
  def set_cas_success_budget(name, n) when is_integer(n) and n >= 0 do
    Agent.update(name, fn s -> %{s | cas_success_budget: n} end)
  end

  def clear_cas_success_budget(name) do
    Agent.update(name, fn s -> %{s | cas_success_budget: nil} end)
  end

  def history(name) do
    Agent.get(name, fn s -> Enum.reverse(s.history) end)
  end

  def peek(name, key) do
    Agent.get(name, fn s -> Map.get(s.records, key) end)
  end

  def clear_history(name) do
    Agent.update(name, fn s -> %{s | history: []} end)
  end

  @doc """
  Arm a barrier: the next `count` operations of `events` (`:get` and/or `:cas`)
  park until `release_sync/1`. Notifies `tester` with `{:sync_arrived, event, ref}`.
  """
  def arm_sync(name, events, count, tester \\ self())
      when is_list(events) and is_integer(count) and count > 0 do
    event_set = MapSet.new(events)

    Agent.update(name, fn s ->
      %{
        s
        | sync: %{
            mode: :armed,
            events: event_set,
            need: count,
            arrived: 0,
            waiting: [],
            tester: tester
          }
      }
    end)
  end

  @doc "Wait until `count` sync arrivals (or timeout)."
  def await_sync(count, timeout \\ 2_000) do
    await_sync_loop(count, timeout, System.monotonic_time(:millisecond))
  end

  defp await_sync_loop(0, _timeout, _start), do: :ok

  defp await_sync_loop(left, timeout, start) do
    remaining = timeout - (System.monotonic_time(:millisecond) - start)

    if remaining <= 0 do
      {:error, :sync_timeout}
    else
      receive do
        {:sync_arrived, _event, _ref} ->
          await_sync_loop(left - 1, timeout, start)
      after
        remaining ->
          {:error, :sync_timeout}
      end
    end
  end

  @doc "Release all parked backend callers."
  def release_sync(name) do
    waiters =
      Agent.get_and_update(name, fn s ->
        case s.sync do
          %{waiting: w} = sync ->
            {w, %{s | sync: %{sync | mode: :off, waiting: [], arrived: 0, need: 0}}}

          _ ->
            {[], s}
        end
      end)

    Enum.each(waiters, fn {pid, ref} -> send(pid, {:sync_go, ref}) end)
    :ok
  end

  @impl true
  def durability_class(_opts), do: :node_restart

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :agent_name)
    maybe_hang(name, :get)

    {result, park} =
      Agent.get_and_update(name, fn state ->
        case pop_fail(state, :get) do
          {nil, state} ->
            case pop_corrupt(state, :get) do
              {nil, state} ->
                state = append_history(state, :get, key, nil, nil)
                lookup_result = lookup(state, key)
                {park, state} = note_sync(state, :get)
                {{lookup_result, park}, state}

              {mode, state} when is_atom(mode) ->
                # Malformed loaded Record (or non-Record) — table-tested bind failures.
                {{{:ok, corrupt_loaded(key, Map.get(state.records, key), mode)}, :cont}, state}
            end

          {reason, state} ->
            {{{:error, reason}, :cont}, state}
        end
      end)

    maybe_park(park)
    result
  end

  @impl true
  def compare_and_swap(key, expected, %Record{} = replacement, opts) do
    name = Keyword.fetch!(opts, :agent_name)

    # Pre-dispatch hang: sleep before any CAS mutation (no durable effect yet).
    maybe_hang(name, :compare_and_swap)

    # Park *before* the CAS mutation so both authorities can decide from the
    # same pre-CAS revision, then race the write.
    park =
      Agent.get_and_update(name, fn state ->
        note_sync(state, :cas)
      end)

    maybe_park(park)

    {result, withhold} =
      Agent.get_and_update(name, fn state ->
        case pop_fail(state, :compare_and_swap) do
          {nil, state} ->
            case do_cas(state, key, expected, replacement) do
              {{:ok, stored}, state} ->
                case pop_corrupt(state, :compare_and_swap) do
                  {nil, state} ->
                    {wh, state} = note_withhold(state, key, stored)
                    {{{:ok, stored}, wh}, state}

                  {mode, state} when is_atom(mode) ->
                    {{{:ok, corrupt_stored(stored, mode)}, :cont}, state}
                end

              {{:error, reason}, state} ->
                {{{:error, reason}, :cont}, state}
            end

          {reason, state} ->
            # Unapplied error — no durable mutation.
            {{{:error, reason}, :cont}, state}
        end
      end)

    # Post-dispatch withhold: CAS already applied+recorded; block reply so the
    # shell deadline can kill the worker while durable state has changed.
    maybe_withhold_reply(withhold)
    result
  end

  @impl true
  def put(key, value, opts) do
    name = Keyword.fetch!(opts, :agent_name)
    Agent.update(name, fn s -> %{s | records: Map.put(s.records, key, value)} end)
    :ok
  end

  @impl true
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :agent_name)
    Agent.update(name, fn s -> %{s | records: Map.delete(s.records, key)} end)
    :ok
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :agent_name)
    {:ok, Agent.get(name, fn s -> Map.keys(s.records) end)}
  end

  defp note_sync(
         %{sync: %{mode: :armed, events: events, need: need, arrived: arrived} = sync} = state,
         event
       ) do
    if MapSet.member?(events, event) and arrived < need do
      ref = make_ref()
      tester = sync.tester
      send(tester, {:sync_arrived, event, ref})

      sync = %{
        sync
        | arrived: arrived + 1,
          waiting: [{self(), ref} | sync.waiting]
      }

      {{:park, ref}, %{state | sync: sync}}
    else
      {:cont, state}
    end
  end

  defp note_sync(state, _event), do: {:cont, state}

  defp maybe_park({:park, ref}) do
    receive do
      {:sync_go, ^ref} -> :ok
    after
      5_000 -> :ok
    end
  end

  defp maybe_park(:cont), do: :ok

  defp lookup(state, key) do
    case Map.get(state.records, key) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp pop_fail(state, kind) do
    case Map.pop(state.fail_next, kind) do
      {nil, _} -> {nil, state}
      {reason, rest} -> {reason, %{state | fail_next: rest}}
    end
  end

  defp pop_corrupt(state, kind) do
    case Map.pop(state.corrupt_next, kind) do
      {nil, _} -> {nil, state}
      {mode, rest} -> {mode, %{state | corrupt_next: rest}}
    end
  end

  defp maybe_hang(name, kind) do
    ms =
      Agent.get_and_update(name, fn state ->
        case Map.pop(state.hang_ms, kind) do
          {nil, _} -> {nil, state}
          {hang, rest} -> {hang, %{state | hang_ms: rest}}
        end
      end)

    if is_integer(ms) and ms > 0, do: Process.sleep(ms)
    :ok
  end

  # After successful CAS: signal tester and park this caller until released.
  defp note_withhold(
         %{withhold_cas_reply: %{mode: :armed, tester: tester, waiting: waiting} = wr} = state,
         key,
         stored
       )
       when is_pid(tester) do
    ref = make_ref()
    send(tester, {:cas_applied, key, ref, stored})
    wr = %{wr | mode: :holding, waiting: [{self(), ref} | waiting]}
    {{:withhold, ref}, %{state | withhold_cas_reply: wr}}
  end

  defp note_withhold(state, _key, _stored), do: {:cont, state}

  defp maybe_withhold_reply({:withhold, ref}) do
    receive do
      {:withhold_go, ^ref} -> :ok
    after
      # Long enough that the shell's bounded op deadline (2s) always wins first
      # when the test does not release the withheld reply.
      60_000 -> :ok
    end
  end

  defp maybe_withhold_reply(:cont), do: :ok
  defp maybe_withhold_reply(_), do: :ok

  defp do_cas(state, key, :not_found, replacement) do
    case Map.get(state.records, key) do
      nil ->
        gen = state.next_insert_gen
        state = %{state | next_insert_gen: 1}
        admit(state, key, :not_found, replacement, gen, 1)

      _ ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, key, {:value, %Record{generation: g, revision: r}}, replacement) do
    case Map.get(state.records, key) do
      %Record{generation: ^g, revision: ^r} = current ->
        admit(
          state,
          key,
          {:value, current},
          replacement,
          current.generation,
          current.revision + 1
        )

      _ ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, _, _, _), do: {{:error, :conflict}, state}

  defp admit(state, key, expected, replacement, gen, rev) do
    cond do
      Map.get(state.force_conflicts, key, 0) > 0 ->
        {{:error, :conflict},
         %{state | force_conflicts: Map.update!(state.force_conflicts, key, &max(&1 - 1, 0))}}

      Map.get(state.force_conflicts, "__all__", 0) > 0 ->
        {{:error, :conflict},
         %{
           state
           | force_conflicts: Map.update!(state.force_conflicts, "__all__", &max(&1 - 1, 0))
         }}

      state.cas_success_budget == 0 ->
        {{:error, :conflict}, state}

      true ->
        # Admission schema stores closed empty metadata only.
        stored = %{replacement | generation: gen, revision: rev, metadata: %{}}
        state = decrement_success_budget(state)
        new_state = %{state | records: Map.put(state.records, key, stored)}
        {{:ok, stored}, append_history(new_state, :compare_and_swap, key, expected, stored)}
    end
  end

  defp decrement_success_budget(%{cas_success_budget: n} = state) when is_integer(n) and n > 0 do
    %{state | cas_success_budget: n - 1}
  end

  defp decrement_success_budget(state), do: state

  # Applied write + corrupt receipt (table-tested bind failures).
  defp corrupt_stored(stored, :bad_revision), do: %{stored | revision: 0}
  defp corrupt_stored(stored, :wrong_revision), do: %{stored | revision: stored.revision + 5}
  defp corrupt_stored(stored, :wrong_generation), do: %{stored | generation: 0}
  defp corrupt_stored(stored, :wrong_id), do: %{stored | id: "rec_wrong_id_for_bind"}
  defp corrupt_stored(stored, :wrong_key), do: %{stored | key: stored.key <> "_x"}

  defp corrupt_stored(stored, :wrong_data),
    do: %{stored | data: Map.put(stored.data, "gate", "nope")}

  defp corrupt_stored(stored, :nonempty_metadata), do: %{stored | metadata: %{"x" => 1}}
  defp corrupt_stored(stored, :wrong_metadata), do: %{stored | metadata: %{"extra" => true}}

  defp corrupt_stored(stored, :oversized_id),
    do: %{stored | id: String.duplicate("i", 200)}

  defp corrupt_stored(stored, :invalid_timestamps),
    do: %{stored | inserted_at: nil, updated_at: nil}

  defp corrupt_stored(stored, :retrograde_timestamps) do
    earlier = DateTime.add(stored.inserted_at, -60, :second)
    %{stored | updated_at: earlier}
  end

  defp corrupt_stored(stored, :inserted_at_mismatch) do
    # Update receipt: inserted_at must equal prior; shift it to fail the bind.
    %{stored | inserted_at: DateTime.add(stored.inserted_at, -3_600, :second)}
  end

  defp corrupt_stored(_stored, :not_a_record), do: :not_a_record
  defp corrupt_stored(_stored, _mode), do: :not_a_record

  # Malformed loaded Record for get bind table tests.
  defp corrupt_loaded(_key, nil, :not_a_record), do: :not_a_record
  defp corrupt_loaded(_key, %Record{} = base, :not_a_record), do: :not_a_record

  defp corrupt_loaded(key, nil, mode) do
    now = DateTime.utc_now()

    base = %Record{
      id: "rec_load_seed",
      key: key,
      data: %{
        "v" => 1,
        "gate" => "open",
        "gate_gen" => 1,
        "roots" => %{},
        "fence_gen" => 0,
        "fence_hash" => nil
      },
      metadata: %{},
      generation: 1,
      revision: 1,
      inserted_at: now,
      updated_at: now
    }

    corrupt_loaded(key, base, mode)
  end

  defp corrupt_loaded(key, %Record{} = base, :wrong_key), do: %{base | key: key <> "_x"}
  defp corrupt_loaded(_key, %Record{} = base, :empty_id), do: %{base | id: ""}

  defp corrupt_loaded(_key, %Record{} = base, :oversized_id),
    do: %{base | id: String.duplicate("i", 200)}

  defp corrupt_loaded(_key, %Record{} = base, :nonempty_metadata),
    do: %{base | metadata: %{"x" => 1}}

  defp corrupt_loaded(_key, %Record{} = base, :wrong_generation), do: %{base | generation: 0}
  defp corrupt_loaded(_key, %Record{} = base, :wrong_revision), do: %{base | revision: 0}

  defp corrupt_loaded(_key, %Record{} = base, :invalid_timestamps),
    do: %{base | inserted_at: nil, updated_at: nil}

  defp corrupt_loaded(_key, %Record{} = base, :retrograde_timestamps) do
    earlier = DateTime.add(base.inserted_at, -60, :second)
    %{base | updated_at: earlier}
  end

  defp corrupt_loaded(_key, %Record{} = base, _), do: base

  defp append_history(state, kind, key, expected, record) do
    entry = %{kind: kind, key: key, cas_expected: expected, record: record}
    %{state | history: [entry | state.history]}
  end
end

defmodule Arbor.Memory.Test.MutationAdmissionNoCasBackend do
  @behaviour Arbor.Contracts.Persistence.Store
  def get(_, _), do: {:error, :not_found}
  def put(_, _, _), do: :ok
  def delete(_, _), do: :ok
  def list(_), do: {:ok, []}
  def durability_class(_), do: :node_restart
end

defmodule Arbor.Memory.Test.MutationAdmissionNoDurabilityBackend do
  @behaviour Arbor.Contracts.Persistence.Store
  alias Arbor.Contracts.Persistence.Record
  def get(_, _), do: {:error, :not_found}
  def put(_, _, _), do: :ok
  def delete(_, _), do: :ok
  def list(_), do: {:ok, []}
  def compare_and_swap(_, _, %Record{} = r, _), do: {:ok, r}
end

defmodule Arbor.Memory.Test.MutationAdmissionWeakDurabilityBackend do
  @behaviour Arbor.Contracts.Persistence.Store
  alias Arbor.Contracts.Persistence.Record
  def get(_, _), do: {:error, :not_found}
  def put(_, _, _), do: :ok
  def delete(_, _), do: :ok
  def list(_), do: {:ok, []}
  def compare_and_swap(_, _, %Record{} = r, _), do: {:ok, r}
  def durability_class(_), do: :process_lifetime
end
