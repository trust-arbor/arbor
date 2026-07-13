defmodule Arbor.Persistence.Store.CASFencingTest do
  @moduledoc """
  Recovery-fencing / CAS concurrency regression.

  Covers one-winner CAS, structured-record ABA via generation tombstones,
  identity mismatches, delimiter-safe keys (in-memory key identity), and
  honest unversioned-value ABA documentation behavior.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Persistence.QueryableStore
  alias Arbor.Persistence.Store

  describe "recovery fencing: simultaneous expected-version claims" do
    test "Store.Agent — exactly one winner under concurrent CAS" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"cas_agent_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.Agent, name: name})

      assert :ok = Store.Agent.put("fence", "v1", name: name)

      parent = self()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, i})

            receive do
              :go -> :ok
            after
              5_000 -> flunk("start barrier timeout")
            end

            Store.Agent.compare_and_swap("fence", {:value, "v1"}, "winner-#{i}", name: name)
          end)
        end

      for _ <- 1..2 do
        assert_receive {:ready, _}, 5_000
      end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert_exactly_one_cas_winner(results)
      assert {:ok, winner} = Store.Agent.get("fence", name: name)
      assert winner in ["winner-1", "winner-2"]
    end

    test "Store.ETS — exactly one winner under concurrent CAS" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"cas_ets_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.ETS, name: name})

      assert :ok = Store.ETS.put("fence", "v1", name: name)

      parent = self()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, i})

            receive do
              :go -> :ok
            after
              5_000 -> flunk("start barrier timeout")
            end

            Store.ETS.compare_and_swap("fence", {:value, "v1"}, "winner-#{i}", name: name)
          end)
        end

      for _ <- 1..2 do
        assert_receive {:ready, _}, 5_000
      end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert_exactly_one_cas_winner(results)
    end

    test "QueryableStore.Agent — generation+revision fencing one-winner" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"cas_qs_agent_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: name})

      assert :ok = QueryableStore.Agent.put("k", Record.new("k", %{"v" => 1}), name: name)

      assert {:ok, %Record{generation: 1, revision: 1} = observed} =
               QueryableStore.Agent.get("k", name: name)

      parent = self()

      tasks =
        for i <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, i})

            receive do
              :go -> :ok
            after
              5_000 -> flunk("start barrier timeout")
            end

            QueryableStore.Agent.compare_and_swap(
              "k",
              {:value, observed},
              Record.new("k", %{"writer" => i}),
              name: name
            )
          end)
        end

      for _ <- 1..2 do
        assert_receive {:ready, _}, 5_000
      end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Enum.map(tasks, &Task.await(&1, 5_000))

      assert_exactly_one_cas_winner(results)

      assert {:ok, %Record{generation: 1, revision: 2, data: data}} =
               QueryableStore.Agent.get("k", name: name)

      assert data["writer"] in [1, 2]
    end
  end

  describe "structured Record ABA / generation tombstones" do
    test "delete then reinsert advances generation; stale CAS conflicts" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"aba_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: name})

      assert :ok = QueryableStore.Agent.put("k", Record.new("k", %{"n" => 1}), name: name)

      assert {:ok, %Record{generation: 1, revision: 1} = gen1} =
               QueryableStore.Agent.get("k", name: name)

      assert :ok = QueryableStore.Agent.delete("k", name: name)
      assert {:error, :not_found} = QueryableStore.Agent.get("k", name: name)

      # Reinsert starts generation 2
      assert :ok = QueryableStore.Agent.put("k", Record.new("k", %{"n" => 2}), name: name)

      assert {:ok, %Record{generation: 2, revision: 1, id: id2}} =
               QueryableStore.Agent.get("k", name: name)

      # Stale CAS against generation 1 must conflict
      assert {:error, :conflict} =
               QueryableStore.Agent.compare_and_swap(
                 "k",
                 {:value, gen1},
                 Record.new("k", %{"n" => 99}),
                 name: name
               )

      assert {:ok, %Record{generation: 2, revision: 1, id: ^id2, data: %{"n" => 2}}} =
               QueryableStore.Agent.get("k", name: name)
    end

    test "Store.Agent Record delete/reinsert ABA protection" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"aba_store_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.Agent, name: name})

      r = Record.new("k", %{"v" => 1})
      assert :ok = Store.Agent.put("k", r, name: name)

      assert {:ok, %Record{generation: 1, revision: 1} = observed} =
               Store.Agent.get("k", name: name)

      assert :ok = Store.Agent.delete("k", name: name)
      assert :ok = Store.Agent.put("k", Record.new("k", %{"v" => 2}), name: name)
      assert {:ok, %Record{generation: 2, revision: 1}} = Store.Agent.get("k", name: name)

      assert {:error, :conflict} =
               Store.Agent.compare_and_swap(
                 "k",
                 {:value, observed},
                 Record.new("k", %{"v" => 3}),
                 name: name
               )
    end

    test "ordinary unversioned value CAS is not ABA-safe across delete/reinsert" do
      # Documented honesty: plain term CAS uses equality only.
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"plain_aba_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.Agent, name: name})

      assert :ok = Store.Agent.put("k", "same", name: name)
      assert :ok = Store.Agent.delete("k", name: name)
      assert :ok = Store.Agent.put("k", "same", name: name)

      # Stale expectation of "same" succeeds after delete/reinsert (ABA).
      assert {:ok, "winner"} =
               Store.Agent.compare_and_swap("k", {:value, "same"}, "winner", name: name)
    end
  end

  describe "identity mismatch" do
    test "put rejects Record.key != store key" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"id_mis_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: name})

      assert {:error, :key_mismatch} =
               QueryableStore.Agent.put("store-key", Record.new("other-key", %{}), name: name)
    end

    test "CAS rejects replacement Record.key != store key" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"cas_mis_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: name})

      assert {:error, :key_mismatch} =
               QueryableStore.Agent.compare_and_swap(
                 "k",
                 :not_found,
                 Record.new("other", %{}),
                 name: name
               )
    end

    test "CAS rejects expected Record from another physical key (token-only match)" do
      # Security regression: cas_matches?/2 compares generation+revision only.
      # An expected Record observed under key "other" with identical tokens must
      # never authorize CAS on store key "k".
      backends = [
        {Store.Agent, Store.Agent},
        {Store.ETS, Store.ETS},
        {QueryableStore.Agent, QueryableStore.Agent},
        {QueryableStore.ETS, QueryableStore.ETS}
      ]

      for {mod, start_mod} <- backends do
        # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
        name = :"cas_exp_key_#{:erlang.unique_integer([:positive])}"
        start_supervised!({start_mod, name: name})

        assert :ok = mod.put("k", Record.new("k", %{"n" => 1}), name: name)

        assert {:ok, %Record{generation: 1, revision: 1} = observed} =
                 mod.get("k", name: name)

        # Fabricate an expected Record claiming a different physical key but the
        # same fencing tokens as the live row under "k".
        expected_other_key = %{observed | key: "other"}

        assert {:error, :key_mismatch} =
                 mod.compare_and_swap(
                   "k",
                   {:value, expected_other_key},
                   Record.new("k", %{"n" => 99}),
                   name: name
                 ),
               "#{inspect(mod)} authorized CAS with expected Record from another key"

        # Live value must be unchanged
        assert {:ok, %Record{generation: 1, revision: 1, data: %{"n" => 1}}} =
                 mod.get("k", name: name)
      end
    end

    test "put preserves logical Record.id across update" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"id_keep_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: name})

      first = Record.new("k", %{"n" => 1}, id: "rec_logical_a")
      assert :ok = QueryableStore.Agent.put("k", first, name: name)

      second = Record.new("k", %{"n" => 2}, id: "rec_logical_b")
      assert :ok = QueryableStore.Agent.put("k", second, name: name)

      assert {:ok, %Record{id: "rec_logical_a", generation: 1, revision: 2, data: %{"n" => 2}}} =
               QueryableStore.Agent.get("k", name: name)
    end
  end

  describe "delimiter-safe store keys (in-memory)" do
    test "keys that would collide under namespace:key concatenation coexist as distinct keys" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"delim_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: name})

      # These are store keys that, when paired with namespaces "a"/"a:b", would
      # collide under the retired "#{namespace}:#{key}" physical id scheme.
      assert :ok =
               QueryableStore.Agent.put("b:c", Record.new("b:c", %{"pair" => "a/b:c"}),
                 name: name
               )

      assert :ok =
               QueryableStore.Agent.put("c", Record.new("c", %{"pair" => "a:b/c"}), name: name)

      assert {:ok, %Record{data: %{"pair" => "a/b:c"}}} =
               QueryableStore.Agent.get("b:c", name: name)

      assert {:ok, %Record{data: %{"pair" => "a:b/c"}}} =
               QueryableStore.Agent.get("c", name: name)
    end
  end

  describe "BufferedStore coherence" do
    test "ETS-only put returns exact caller Record (cache-authoritative, no fencing)" do
      # BufferedStore is a process-lifetime cache wrapper — it does not own CAS
      # tokens. put/get must round-trip the exact caller value.
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buf_#{:erlang.unique_integer([:positive])}"
      start_supervised!({BufferedStore, name: name, backend: nil})

      r1 = Record.new("k", %{"n" => 1})
      assert :ok = BufferedStore.put("k", r1, name: name)
      assert {:ok, ^r1} = BufferedStore.get("k", name: name)

      r2 = Record.new("k", %{"n" => 2})
      assert :ok = BufferedStore.put("k", r2, name: name)
      assert {:ok, ^r2} = BufferedStore.get("k", name: name)
    end

    test "async + backend accepts structured Record values" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      agent = :"buf_agent_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: agent})

      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buf_async_#{:erlang.unique_integer([:positive])}"

      # BufferedStore merges `name: collection` into backend opts; point collection
      # at the Agent registration so async backend writes resolve correctly.
      start_supervised!(
        {BufferedStore,
         name: name,
         backend: QueryableStore.Agent,
         backend_opts: [],
         collection: agent,
         write_mode: :async}
      )

      record = Record.new("k", %{"v" => 1})
      assert :ok = BufferedStore.put("k", record, name: name)
      assert {:ok, ^record} = BufferedStore.get("k", name: name)

      Process.sleep(50)
      assert {:ok, %Record{data: %{"v" => 1}}} = QueryableStore.Agent.get("k", name: agent)
    end

    test "CAS remains unsupported" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buf_cas_#{:erlang.unique_integer([:positive])}"
      start_supervised!({BufferedStore, name: name, backend: nil})

      refute Persistence.supports_compare_and_swap?(BufferedStore)

      assert {:error, :unsupported} =
               Persistence.compare_and_swap(name, BufferedStore, "k", :not_found, "x")
    end
  end

  describe "CAS basic semantics" do
    test "not_found insert succeeds once" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"cas_nf_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.Agent, name: name})

      assert {:ok, "a"} =
               Store.Agent.compare_and_swap("k", :not_found, "a", name: name)

      assert {:error, :conflict} =
               Store.Agent.compare_and_swap("k", :not_found, "b", name: name)

      assert {:ok, "a"} = Store.Agent.get("k", name: name)
    end

    test "durability classes are code-owned" do
      assert Store.Agent.durability_class([]) == :process_lifetime
      assert Store.ETS.durability_class([]) == :process_lifetime
      assert QueryableStore.Agent.durability_class([]) == :process_lifetime
      assert QueryableStore.ETS.durability_class([]) == :process_lifetime
      assert QueryableStore.Postgres.durability_class([]) == :node_restart
      assert BufferedStore.durability_class([]) == :process_lifetime
    end

    test "facade capability helpers and unsupported path" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"facade_cas_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.Agent, name: name})

      assert Persistence.supports_compare_and_swap?(Store.Agent)
      assert Persistence.supports_durability_class?(Store.Agent)
      refute Persistence.supports_compare_and_swap?(BufferedStore)

      assert {:ok, :process_lifetime} =
               Persistence.durability_class(name, Store.Agent)

      assert {:ok, "x"} =
               Persistence.compare_and_swap(name, Store.Agent, "k", :not_found, "x")

      assert {:error, :unsupported} =
               Persistence.compare_and_swap(
                 name,
                 BufferedStore,
                 "k",
                 :not_found,
                 "x"
               )
    end

    test "Record put advances revision and ignores lower caller revision" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"rev_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.Agent, name: name})

      r0 = Record.new("k", %{"n" => 1}, revision: 0, generation: 0)
      assert :ok = QueryableStore.Agent.put("k", r0, name: name)

      assert {:ok, %Record{generation: 1, revision: 1}} =
               QueryableStore.Agent.get("k", name: name)

      # Caller tries to roll revision/generation backward — backend still advances
      r_low = Record.new("k", %{"n" => 2}, revision: 0, generation: 0)
      assert :ok = QueryableStore.Agent.put("k", r_low, name: name)

      assert {:ok, %Record{generation: 1, revision: 2, data: %{"n" => 2}}} =
               QueryableStore.Agent.get("k", name: name)
    end
  end

  defp assert_exactly_one_cas_winner(results) do
    oks = Enum.filter(results, &match?({:ok, _}, &1))
    conflicts = Enum.filter(results, &match?({:error, :conflict}, &1))

    assert length(oks) == 1,
           "expected exactly one CAS winner, got: #{inspect(results)}"

    assert length(conflicts) == length(results) - 1,
           "expected remaining CAS claims to conflict, got: #{inspect(results)}"
  end
end
