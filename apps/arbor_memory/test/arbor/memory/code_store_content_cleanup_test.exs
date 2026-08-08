defmodule Arbor.Memory.CodeStoreContentCleanupTest do
  @moduledoc """
  Content-only CodeStore cleanup primitives (VP-05D2C3I0C2 / VOICE-17).
  """

  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.Taint
  alias Arbor.Memory.{CodeStore, MemoryStore, Provenance}
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag spec: "VOICE-17"
  @moduletag voice_packet: "VP-05D2C3I0C2"
  @store_name :arbor_memory_durable
  @ets_table :arbor_memory_code_store
  @namespace "code_patterns"
  @backend_state :code_store_content_cleanup_backend

  @delete_errors [
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

  @absence_errors [
    :invalid_agent_id,
    :absence_uncertain,
    :durable_unavailable,
    :insufficient_durability,
    :invalid_record,
    :ambiguous_record,
    :inventory_limit_exceeded,
    :store_unavailable
  ]

  # Self-contained Agent-backed Store fake. Does not import Persistence
  # internal modules (e.g. QueryableStore.ETS); only the public Store behaviour
  # and contracts Record type.
  defmodule DeterministicBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Contracts.Persistence.Record

    @impl true
    def put(key, value, opts) do
      update_state(opts, fn state ->
        stored = advance_put(Map.get(state.records, key), value)
        {:ok, put_in(state, [:records, key], stored)}
      end)
    end

    @impl true
    def get(key, opts) do
      update_state(opts, fn state ->
        case Map.fetch(state.records, key) do
          {:ok, value} -> {{:ok, value}, state}
          :error -> {{:error, :not_found}, state}
        end
      end)
    end

    @impl true
    def delete(key, opts) do
      update_state(opts, fn state ->
        {:ok, %{state | records: Map.delete(state.records, key)}}
      end)
    end

    @impl true
    def list(opts) do
      update_state(opts, fn state ->
        if state.force_inventory_overflow? do
          {{:error, :inventory_limit_exceeded}, state}
        else
          {{:ok, Map.keys(state.records)}, state}
        end
      end)
    end

    @impl true
    def query(_filter, opts) do
      update_state(opts, fn state ->
        if state.force_inventory_overflow? do
          {{:error, :inventory_limit_exceeded}, state}
        else
          records = state.records |> Map.values() |> Enum.sort_by(& &1.key)
          {{:ok, records}, state}
        end
      end)
    end

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      update_state(opts, fn state ->
        case apply_cas(Map.get(state.records, key), expected, replacement) do
          {:ok, stored} ->
            {{:ok, stored}, put_in(state, [:records, key], stored)}

          {:error, _reason} = error ->
            {error, state}
        end
      end)
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      update_state(opts, fn state ->
        current = Map.get(state.records, key)

        cond do
          state.force_outcome_unknown? ->
            {{:error, :outcome_unknown}, %{state | force_outcome_unknown?: false}}

          is_integer(state.fail_after) and state.successes >= state.fail_after ->
            {{:error, :forced_compare_delete_failure}, state}

          record_matches?(current, expected) ->
            successes = state.successes + 1
            records = Map.delete(state.records, key)

            {records, ghost} =
              case state.ghost do
                %{after_successes: n, key: gkey, record: grec} when successes >= n ->
                  {Map.put(records, gkey, grec), nil}

                other ->
                  {records, other}
              end

            next = %{state | records: records, successes: successes, ghost: ghost}
            {:ok, next}

          true ->
            {{:error, :conflict}, state}
        end
      end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart

    def initial_state do
      %{
        records: %{},
        successes: 0,
        fail_after: nil,
        force_outcome_unknown?: false,
        force_inventory_overflow?: false,
        ghost: nil
      }
    end

    def fail_after(name, n) when is_integer(n) and n >= 0 do
      Agent.update(name, fn state ->
        %{state | fail_after: n, successes: 0}
      end)
    end

    def allow_all(name) do
      Agent.update(name, fn state ->
        %{
          state
          | fail_after: nil,
            successes: 0,
            force_outcome_unknown?: false,
            force_inventory_overflow?: false,
            ghost: nil
        }
      end)
    end

    def force_outcome_unknown_once(name) do
      Agent.update(name, fn state ->
        %{state | force_outcome_unknown?: true}
      end)
    end

    def force_inventory_overflow(name) do
      Agent.update(name, fn state ->
        %{state | force_inventory_overflow?: true}
      end)
    end

    @doc """
    After `n` successful compare-and-deletes, inject `record` under `key` so
    post-delete re-inventory observes a newly present durable row.
    """
    def inject_ghost_after_successes(name, n, key, %Record{} = record)
        when is_integer(n) and n >= 1 and is_binary(key) do
      Agent.update(name, fn state ->
        %{state | ghost: %{after_successes: n, key: key, record: record}, successes: 0}
      end)
    end

    defp update_state(opts, fun) do
      opts
      |> Keyword.fetch!(:name)
      |> Agent.get_and_update(fun)
    end

    defp advance_put(nil, %Record{} = replacement),
      do: %{replacement | generation: 1, revision: 1}

    defp advance_put(%Record{} = current, %Record{} = replacement) do
      %{
        replacement
        | id: current.id,
          generation: current.generation,
          revision: current.revision + 1,
          inserted_at: current.inserted_at
      }
    end

    defp advance_put(_current, value), do: value

    defp apply_cas(nil, :not_found, %Record{} = replacement) do
      {:ok, %{replacement | generation: 1, revision: 1}}
    end

    defp apply_cas(%Record{} = current, {:value, %Record{} = expected}, %Record{} = replacement) do
      if record_matches?(current, expected) do
        {:ok,
         %{
           replacement
           | id: current.id,
             generation: current.generation,
             revision: current.revision + 1,
             inserted_at: current.inserted_at
         }}
      else
        {:error, :conflict}
      end
    end

    defp apply_cas(_current, _expected, _replacement), do: {:error, :conflict}

    defp record_matches?(%Record{} = current, %Record{} = expected) do
      current.key == expected.key and current.generation == expected.generation and
        current.revision == expected.revision
    end

    defp record_matches?(current, expected), do: current == expected
  end

  setup do
    ensure_durable_store!()
    ensure_code_store!()
    ensure_provenance!()

    uid = System.unique_integer([:positive])
    target = "agent_a_#{uid}"
    child = "agent_a_#{uid}_child"
    survivor = "agent_b_#{uid}"

    for agent <- [target, child, survivor] do
      _ = CodeStore.clear(agent)
      _ = Provenance.delete_agent(agent)
    end

    on_exit(fn ->
      ensure_provenance!()
      ensure_code_store!()

      for agent <- [target, child, survivor] do
        _ = Provenance.delete_agent(agent)
      end

      if MemoryStore.available?() do
        for agent <- [target, child, survivor] do
          _ = CodeStore.clear(agent)
        end
      end
    end)

    %{target: target, child: child, survivor: survivor}
  end

  test "delete_agent_content removes multiple target entries, preserves survivor and child", %{
    target: target,
    child: child,
    survivor: survivor
  } do
    assert {:ok, e1} = store_pattern(target, "map list", "elixir")
    assert {:ok, e2} = store_pattern(target, "reduce list", "elixir")
    assert {:ok, e3} = store_pattern(target, "filter list", "elixir")
    assert {:ok, child_entry} = store_pattern(child, "child pattern", "elixir")
    assert {:ok, survivor_entry} = store_pattern(survivor, "survivor pattern", "python")

    await_durable!(@namespace, "#{target}:#{e1.id}")
    await_durable!(@namespace, "#{target}:#{e2.id}")
    await_durable!(@namespace, "#{target}:#{e3.id}")
    await_durable!(@namespace, "#{child}:#{child_entry.id}")
    await_durable!(@namespace, "#{survivor}:#{survivor_entry.id}")

    assert {:ok, _, _, _, _} =
             child_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{child}:#{child_entry.id}"
             )

    assert {:ok, _, _, _, _} =
             survivor_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{survivor}:#{survivor_entry.id}"
             )

    taint = taint(:trusted, :internal, "code_content_cleanup")

    for entry <- [e1, e2, e3] do
      payload = serialize_entry(entry)
      assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    end

    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)
    assert e1.id in ids_before
    assert e2.id in ids_before
    assert e3.id in ids_before

    assert {:ok, false} = CodeStore.agent_content_absent?(target)

    assert :ok = CodeStore.delete_agent_content(target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)
    assert :ok = CodeStore.delete_agent_content(target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)

    assert [] = CodeStore.list(target)
    assert [] = :ets.lookup(@ets_table, target)

    for entry <- [e1, e2, e3] do
      assert {:error, :not_found} =
               MemoryStore.load_tainted_authoritative_with_status(
                 @namespace,
                 "#{target}:#{entry.id}"
               )
    end

    assert {:ok, ^child_entry} = CodeStore.get(child, child_entry.id)
    assert {:ok, ^survivor_entry} = CodeStore.get(survivor, survivor_entry.id)
    assert {:ok, false} = CodeStore.agent_content_absent?(child)
    assert {:ok, false} = CodeStore.agent_content_absent?(survivor)

    assert ^child_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{child}:#{child_entry.id}"
             )

    assert ^survivor_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{survivor}:#{survivor_entry.id}"
             )

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)

    assert {:ok, ^taint, :verified} =
             Provenance.resolve(:code_item, target, e1.id, serialize_entry(e1))

    hostile_payload = %{"hostile" => true, "id" => "hostile-code"}
    hostile = taint(:hostile, :restricted, "hostile_code")
    assert :ok = Provenance.put(:code_item, target, "hostile-code", hostile_payload, hostile)
    assert :ok = CodeStore.delete_agent_content(target)

    assert {:ok, ^hostile, :verified} =
             Provenance.resolve(:code_item, target, "hostile-code", hostile_payload)
  end

  test "partial durable progress is retryable and exact-fenced", %{
    target: target,
    survivor: survivor
  } do
    control = use_deterministic_backend!()

    assert {:ok, e1} = store_pattern(target, "first", "elixir")
    assert {:ok, e2} = store_pattern(target, "second", "elixir")
    assert {:ok, e3} = store_pattern(target, "third", "elixir")
    assert {:ok, survivor_entry} = store_pattern(survivor, "keep me", "elixir")

    await_durable!(@namespace, "#{target}:#{e1.id}")
    await_durable!(@namespace, "#{target}:#{e2.id}")
    await_durable!(@namespace, "#{target}:#{e3.id}")
    await_durable!(@namespace, "#{survivor}:#{survivor_entry.id}")

    payload = serialize_entry(e1)
    taint = taint(:trusted, :internal, "code_partial_progress")
    assert :ok = Provenance.put(:code_item, target, e1.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    # fail_after: 1 allows exactly one successful fenced delete, then fails.
    # No conflict-retry: with 3 target rows, exactly 2 durable rows remain.
    DeterministicBackend.fail_after(control, 1)

    assert {:error, del_reason} = CodeStore.delete_agent_content(target)
    assert del_reason in @delete_errors

    remaining =
      [e1, e2, e3]
      |> Enum.count(fn entry ->
        match?(
          {:ok, _, _, _, _},
          MemoryStore.load_tainted_authoritative_with_status(
            @namespace,
            "#{target}:#{entry.id}"
          )
        )
      end)

    assert remaining == 2

    assert {:ok, ^survivor_entry} = CodeStore.get(survivor, survivor_entry.id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)
    # Partial progress is not absence.
    assert {:ok, false} = CodeStore.agent_content_absent?(target)

    DeterministicBackend.allow_all(control)
    assert :ok = CodeStore.delete_agent_content(target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)
    assert {:ok, ^survivor_entry} = CodeStore.get(survivor, survivor_entry.id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)
  end

  test "malformed key/payload/ownership fails closed before any delete", %{
    target: target,
    survivor: survivor
  } do
    assert {:ok, good} = store_pattern(target, "good pattern", "elixir")
    assert {:ok, survivor_entry} = store_pattern(survivor, "survivor", "elixir")
    await_durable!(@namespace, "#{target}:#{good.id}")
    await_durable!(@namespace, "#{survivor}:#{survivor_entry.id}")

    payload = serialize_entry(good)
    taint = taint(:trusted, :internal, "code_malformed")
    assert :ok = Provenance.put(:code_item, target, good.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    assert {:ok, _, _, _, _} =
             good_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{target}:#{good.id}"
             )

    assert {:ok, _, _, _, _} =
             survivor_durable_before =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{survivor}:#{survivor_entry.id}"
             )

    base_payload = %{
      "id" => "code_base",
      "agent_id" => target,
      "code" => "IO.puts(:nope)",
      "language" => "elixir",
      "purpose" => "malformed fixture",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "metadata" => %{}
    }

    oversized_id = String.duplicate("x", 257)

    malformed_cases = [
      {"cross-owner payload", "#{target}:code_cross_owner",
       %{base_payload | "id" => "code_cross_owner", "agent_id" => survivor}},
      {"payload id disagrees with key", "#{target}:code_key_id",
       %{base_payload | "id" => "code_payload_id"}},
      {"missing required field", "#{target}:code_incomplete",
       base_payload
       |> Map.put("id", "code_incomplete")
       |> Map.delete("metadata")},
      {"malformed timestamp", "#{target}:code_bad_ts",
       %{base_payload | "id" => "code_bad_ts", "created_at" => "not-a-timestamp"}},
      {"empty key entry id", "#{target}:", %{base_payload | "id" => "code_nonempty"}},
      {"oversized entry id", "#{target}:#{oversized_id}", %{base_payload | "id" => oversized_id}}
    ]

    Enum.each(malformed_cases, fn {label, logical_key, malformed_payload} ->
      assert {:ok, %Record{}} =
               MemoryStore.compare_and_swap_tainted(
                 @namespace,
                 logical_key,
                 :not_found,
                 malformed_payload,
                 taint: taint
               ),
             label

      assert {:error, :invalid_record} = CodeStore.delete_agent_content(target), label
      assert {:error, :invalid_record} = CodeStore.agent_content_absent?(target), label
      refute match?({:ok, true}, CodeStore.agent_content_absent?(target)), label

      assert ^good_durable_before =
               MemoryStore.load_tainted_authoritative_with_status(
                 @namespace,
                 "#{target}:#{good.id}"
               ),
             label

      assert ^survivor_durable_before =
               MemoryStore.load_tainted_authoritative_with_status(
                 @namespace,
                 "#{survivor}:#{survivor_entry.id}"
               ),
             label

      assert {:ok, ^survivor_entry} = CodeStore.get(survivor, survivor_entry.id), label
      assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target), label

      assert :ok = MemoryStore.delete_tainted_authoritative(@namespace, logical_key), label
    end)
  end

  test "invalid_durable_provenance inventory fails closed before any delete", %{
    target: target,
    survivor: survivor
  } do
    assert {:ok, good} = store_pattern(target, "good pattern", "elixir")
    assert {:ok, survivor_entry} = store_pattern(survivor, "survivor", "elixir")
    await_durable!(@namespace, "#{target}:#{good.id}")
    await_durable!(@namespace, "#{survivor}:#{survivor_entry.id}")

    payload = serialize_entry(good)
    taint = taint(:trusted, :internal, "code_invalid_prov")
    assert :ok = Provenance.put(:code_item, target, good.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    # Shape-valid payload under the target prefix, but malformed taint metadata
    # so authoritative inventory reports :invalid_durable_provenance.
    bad_id = "code_invalid_prov"

    bad_payload = %{
      "id" => bad_id,
      "agent_id" => target,
      "code" => "fn -> :ok end",
      "language" => "elixir",
      "purpose" => "invalid provenance",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "metadata" => %{}
    }

    physical_key = "#{@namespace}:#{target}:#{bad_id}"

    record =
      Record.new(physical_key, bad_payload,
        id: "memory:#{physical_key}",
        metadata: %{"taint" => %{"version" => 1}}
      )

    assert :ok = BufferedStore.put(physical_key, record, name: @store_name)

    # Authoritative inventory surfaces the malformed tainted status (not just
    # the compatibility load path).
    assert {:ok, inv} =
             MemoryStore.load_by_prefix_tainted_authoritative(@namespace, target <> ":")

    assert Enum.any?(inv, fn {logical_key, _value, status} ->
             logical_key == "#{target}:#{bad_id}" and status == :invalid_durable_provenance
           end)

    assert {:error, :invalid_record} = CodeStore.delete_agent_content(target)
    assert {:error, :invalid_record} = CodeStore.agent_content_absent?(target)
    refute match?({:ok, true}, CodeStore.agent_content_absent?(target))

    # Good content and sidecars preserved; no delete success.
    assert match?(
             {:ok, _, _, _, _},
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{target}:#{good.id}"
             )
           )

    assert {:ok, ^survivor_entry} = CodeStore.get(survivor, survivor_entry.id)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)
    assert {:ok, ^taint, :verified} = Provenance.resolve(:code_item, target, good.id, payload)
  end

  test "post-delete re-inventory must be empty before cleanup success", %{target: target} do
    control = use_deterministic_backend!()

    assert {:ok, entry} = store_pattern(target, "reobserve", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    payload = serialize_entry(entry)
    taint = taint(:trusted, :internal, "code_reobserve")
    assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    ghost_id = "code_ghost_#{System.unique_integer([:positive])}"

    ghost_payload = %{
      "id" => ghost_id,
      "agent_id" => target,
      "code" => "fn -> :ghost end",
      "language" => "elixir",
      "purpose" => "post-delete ghost",
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "metadata" => %{}
    }

    ghost_key = "#{@namespace}:#{target}:#{ghost_id}"

    ghost_record =
      Record.new(ghost_key, ghost_payload,
        id: "memory:#{ghost_key}",
        generation: 1,
        revision: 1
      )

    # After the sole fenced delete succeeds, inject a newly observed durable row
    # so re-inventory cannot report empty and cleanup must fail closed.
    DeterministicBackend.inject_ghost_after_successes(control, 1, ghost_key, ghost_record)

    assert {:error, del_reason} = CodeStore.delete_agent_content(target)
    assert del_reason in @delete_errors
    assert del_reason == :outcome_unknown

    # Original entry deleted; ghost remains — not full success/absence.
    assert {:error, :not_found} =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{target}:#{entry.id}"
             )

    assert match?(
             {:ok, _, _, _, _},
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{target}:#{ghost_id}"
             )
           )

    assert {:ok, false} = CodeStore.agent_content_absent?(target)
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)

    # Retry after clearing the ghost injection path is still possible once the
    # remaining durable row is removed (retryable partial progress).
    DeterministicBackend.allow_all(control)
    assert :ok = MemoryStore.delete_tainted_authoritative(@namespace, "#{target}:#{ghost_id}")
    assert :ok = CodeStore.delete_agent_content(target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)
  end

  test "uncertain CAS delete fails closed and never reports true absence while durable remains",
       %{target: target} do
    control = use_deterministic_backend!()

    assert {:ok, entry} = store_pattern(target, "uncertain", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    payload = serialize_entry(entry)
    taint = taint(:trusted, :internal, "code_uncertain_delete")
    assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    DeterministicBackend.force_outcome_unknown_once(control)

    assert {:error, :outcome_unknown} = CodeStore.delete_agent_content(target)

    # Uncertain delete does not remove the durable row.
    assert {:ok, _value, _status, _record, _location} =
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{target}:#{entry.id}"
             )

    # Fresh absence query: {:ok, false} is legitimate while durable remains.
    # {:ok, true} is forbidden unless both durable and projection are absent.
    assert {:ok, false} = CodeStore.agent_content_absent?(target)
    refute match?({:ok, true}, CodeStore.agent_content_absent?(target))
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)

    DeterministicBackend.allow_all(control)
    assert :ok = CodeStore.delete_agent_content(target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)
  end

  test "mixed durable/projection presence never reports true absence", %{target: target} do
    assert {:ok, entry} = store_pattern(target, "mixed", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    true = :ets.delete(@ets_table, target)
    assert {:ok, false} = CodeStore.agent_content_absent?(target)
    refute match?({:ok, true}, CodeStore.agent_content_absent?(target))

    assert :ok =
             MemoryStore.delete_tainted_authoritative(@namespace, "#{target}:#{entry.id}")

    true = :ets.insert(@ets_table, {target, [entry]})
    assert {:ok, false} = CodeStore.agent_content_absent?(target)
    refute match?({:ok, true}, CodeStore.agent_content_absent?(target))

    true = :ets.delete(@ets_table, target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)
  end

  test "empty ETS list row is still projected and blocks true absence", %{target: target} do
    # Durable fully absent, but a projected ETS key remains with an empty list.
    # Only :ets.lookup(...) == [] proves projection absence.
    true = :ets.insert(@ets_table, {target, []})

    assert {:ok, false} = CodeStore.agent_content_absent?(target)
    refute match?({:ok, true}, CodeStore.agent_content_absent?(target))

    assert :ok = CodeStore.delete_agent_content(target)
    assert [] = :ets.lookup(@ets_table, target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)
  end

  test "inventory overflow fails closed and never reports absence", %{target: target} do
    control = use_deterministic_backend!()

    assert {:ok, entry} = store_pattern(target, "overflow", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    payload = serialize_entry(entry)
    taint = taint(:trusted, :internal, "code_inventory_overflow")
    assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    DeterministicBackend.force_inventory_overflow(control)

    assert {:error, del_reason} = CodeStore.delete_agent_content(target)
    assert del_reason in @delete_errors
    assert del_reason == :inventory_limit_exceeded

    assert {:error, abs_reason} = CodeStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors
    assert abs_reason == :inventory_limit_exceeded
    refute match?({:ok, true}, CodeStore.agent_content_absent?(target))

    # Content and sidecars retained under overflow.
    DeterministicBackend.allow_all(control)

    assert match?(
             {:ok, _, _, _, _},
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{target}:#{entry.id}"
             )
           )

    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)
  end

  test "initially undefined ETS with durable present never reports true absence", %{
    target: target
  } do
    assert {:ok, entry} = store_pattern(target, "ets undefined", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    payload = serialize_entry(entry)
    taint = taint(:trusted, :internal, "code_ets_undefined")
    assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    # Owner lifecycle only: terminate the supervised CodeStore so its named ETS
    # table is gone (initially :undefined). This is not a post-whereis race;
    # production still fail-closes ArgumentError after a table was observed.
    assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, CodeStore)
    assert Process.whereis(CodeStore) == nil
    assert :ets.whereis(@ets_table) == :undefined

    assert match?(
             {:ok, _, _, _, _},
             MemoryStore.load_tainted_authoritative_with_status(
               @namespace,
               "#{target}:#{entry.id}"
             )
           )

    # Genuine projection absence + durable present => not authoritative absence.
    assert {:ok, false} = CodeStore.agent_content_absent?(target)
    refute match?({:ok, true}, CodeStore.agent_content_absent?(target))
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)

    # Content cleanup still deletes durable; undefined ETS is accepted projection absence.
    assert :ok = CodeStore.delete_agent_content(target)
    assert {:ok, true} = CodeStore.agent_content_absent?(target)

    # Restore the supervised CodeStore owner (and its table) for later tests/on_exit.
    ensure_code_store!()
  end

  test "malformed bare durable inventory fails closed", %{target: target} do
    assert {:ok, entry} = store_pattern(target, "bare bad", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    payload = serialize_entry(entry)
    taint = taint(:trusted, :internal, "code_bare")
    assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    bare_key = "#{target}:code_bare"
    bare = %{"not" => "a_record"}

    assert {:ok, ^bare} =
             Arbor.Persistence.buffered_store_acknowledged_put(
               @store_name,
               "#{@namespace}:#{bare_key}",
               bare
             )

    assert {:error, del_reason} = CodeStore.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = CodeStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)
  end

  test "public cleanup when durable store is stopped returns closed errors", %{target: target} do
    assert {:ok, entry} = store_pattern(target, "stopped", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    payload = serialize_entry(entry)
    taint = taint(:trusted, :internal, "code_store_stopped")
    assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)

    assert :ok = stop_supervised(BufferedStore)
    refute MemoryStore.available?()

    assert {:error, del_reason} = CodeStore.delete_agent_content(target)
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = CodeStore.agent_content_absent?(target)
    assert abs_reason in @absence_errors

    ensure_durable_store!()
    assert MemoryStore.available?()
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)
  end

  test "cleanup public errors are always closed atoms" do
    assert {:error, del_reason} = CodeStore.delete_agent_content("")
    assert del_reason in @delete_errors

    assert {:error, abs_reason} = CodeStore.agent_content_absent?(String.duplicate("z", 300))
    assert abs_reason in @absence_errors
  end

  test "compatibility clear still purges durable prefix (legacy behavior)", %{target: target} do
    assert {:ok, entry} = store_pattern(target, "clear me", "elixir")
    await_durable!(@namespace, "#{target}:#{entry.id}")

    payload = serialize_entry(entry)
    taint = taint(:trusted, :internal, "code_clear_compat")
    assert :ok = Provenance.put(:code_item, target, entry.id, payload, taint)
    assert {:ok, ids_before} = Provenance.list_item_ids(:code_item, target)
    assert entry.id in ids_before

    assert :ok = CodeStore.clear(target)
    assert [] = CodeStore.list(target)

    # Compatibility clear does not touch provenance sidecars (domain-owned cleanup
    # is the content-only path). Sidecars remain until C3I2A.
    assert {:ok, ^ids_before} = Provenance.list_item_ids(:code_item, target)
  end

  defp store_pattern(agent_id, purpose, language) do
    CodeStore.store(agent_id, %{
      code: "fn x -> x end # #{purpose}",
      language: language,
      purpose: purpose
    })
  end

  defp serialize_entry(entry) do
    %{
      "id" => entry.id,
      "agent_id" => entry.agent_id,
      "code" => entry.code,
      "language" => entry.language,
      "purpose" => entry.purpose,
      "created_at" => DateTime.to_iso8601(entry.created_at),
      "metadata" => entry.metadata
    }
  end

  defp use_deterministic_backend! do
    if Process.whereis(@store_name) do
      _ = stop_supervised(BufferedStore)
    end

    case Process.whereis(@backend_state) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end

    start_supervised!(%{
      id: @backend_state,
      start:
        {Agent, :start_link,
         [
           fn -> DeterministicBackend.initial_state() end,
           [name: @backend_state]
         ]}
    })

    assert is_pid(
             start_supervised!(
               {BufferedStore,
                name: @store_name,
                backend: DeterministicBackend,
                collection: @backend_state,
                write_mode: :sync,
                ack_mode: :backend}
             )
           )

    assert MemoryStore.available?()
    @backend_state
  end

  defp ensure_durable_store! do
    case Process.whereis(@store_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        assert is_pid(
                 start_supervised!(
                   {BufferedStore, name: @store_name, backend: nil, write_mode: :sync}
                 )
               )

        :ok
    end

    assert MemoryStore.available?()
  end

  # Restore only via the supervised CodeStore owner. Never create the named
  # ETS table from the test process (that would steal ownership and drop the
  # table when the test process exits).
  defp ensure_code_store! do
    case Process.whereis(CodeStore) do
      pid when is_pid(pid) ->
        if :ets.whereis(@ets_table) == :undefined do
          # Inconsistent owner without table: restart the supervised child.
          assert :ok = Supervisor.terminate_child(Arbor.Memory.Supervisor, CodeStore)
          restart_code_store_child!()
        else
          :ok
        end

      nil ->
        restart_code_store_child!()
    end
  end

  defp restart_code_store_child! do
    case Supervisor.restart_child(Arbor.Memory.Supervisor, CodeStore) do
      {:ok, _pid} ->
        assert is_pid(Process.whereis(CodeStore))
        assert :ets.whereis(@ets_table) != :undefined
        :ok

      {:error, {:already_started, _pid}} ->
        assert is_pid(Process.whereis(CodeStore))
        assert :ets.whereis(@ets_table) != :undefined
        :ok

      other ->
        flunk("failed to restart CodeStore: #{inspect(other)}")
    end
  end

  defp ensure_provenance! do
    case Process.whereis(Provenance) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Memory.Supervisor, Provenance) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          other -> flunk("failed to restart Provenance: #{inspect(other)}")
        end
    end
  end

  defp await_durable!(namespace, key) do
    assert eventually(fn ->
             match?(
               {:ok, _, _, _, _},
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)
             )
           end)
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false

  defp taint(level, sensitivity, source) do
    {:ok, taint} =
      Taint.new(%{
        level: level,
        sensitivity: sensitivity,
        sanitizations: 0,
        confidence: :verified,
        source: source,
        chain: []
      })

    taint
  end
end
