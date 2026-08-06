defmodule Arbor.PersistenceTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Persistence.{AppendOperation, Filter, Record}
  alias Arbor.Persistence
  alias Arbor.Persistence.{BufferedStore, Event}
  alias Arbor.Persistence.EventLog
  alias Arbor.Persistence.QueryableStore
  alias Arbor.Persistence.Store

  defmodule CriticalFailingBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: {:error, :forced_failure}

    @impl true
    def get(_key, _opts), do: {:error, :forced_failure}

    @impl true
    def delete(_key, _opts), do: {:error, :forced_failure}

    @impl true
    def list(_opts), do: {:error, :forced_failure}

    @impl true
    def compare_and_swap(_key, _expected, _replacement, _opts),
      do: {:error, :forced_failure}

    @impl true
    def compare_and_delete(_key, _expected, _opts), do: {:error, :forced_failure}

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule InventoryResponseBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok

    @impl true
    def get(_key, _opts), do: {:error, :not_found}

    @impl true
    def delete(_key, _opts), do: :ok

    @impl true
    def list(opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :name), fn
        %{initial?: true} = state -> {{:ok, []}, %{state | initial?: false}}
        %{response: response} = state -> {{:ok, response}, state}
      end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule AuthoritativeGetResponseBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok

    @impl true
    def get(_key, opts), do: Agent.get(Keyword.fetch!(opts, :name), & &1)

    @impl true
    def delete(_key, _opts), do: :ok

    @impl true
    def list(_opts), do: {:ok, []}

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule PutThenUnreadableBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(key, value, opts) do
      Agent.update(Keyword.fetch!(opts, :name), &Map.put(&1, key, value))
      :ok
    end

    @impl true
    def get(_key, _opts), do: {:error, :forced_confirmation_failure}

    @impl true
    def delete(key, opts) do
      Agent.update(Keyword.fetch!(opts, :name), &Map.delete(&1, key))
      :ok
    end

    @impl true
    def list(opts), do: {:ok, Agent.get(Keyword.fetch!(opts, :name), &Map.keys/1)}

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule CountingNonQueryableBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(key, value, opts) do
      Agent.update(Keyword.fetch!(opts, :name), fn state ->
        put_in(state, [:records, key], value)
      end)

      :ok
    end

    @impl true
    def get(key, opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :name), fn state ->
        state = update_in(state, [:calls, :get], &(&1 + 1))
        {Map.fetch(state.records, key), state}
      end)
      |> case do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def delete(key, opts) do
      Agent.update(Keyword.fetch!(opts, :name), fn state ->
        %{state | records: Map.delete(state.records, key)}
      end)

      :ok
    end

    @impl true
    def list(opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :name), fn state ->
        state = update_in(state, [:calls, :list], &(&1 + 1))
        {{:ok, Map.keys(state.records)}, state}
      end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule CountingQueryableBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Contracts.Persistence.Filter

    @impl true
    def put(key, value, opts) do
      Agent.update(Keyword.fetch!(opts, :name), fn state ->
        put_in(state, [:records, key], value)
      end)

      :ok
    end

    @impl true
    def get(key, opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :name), fn state ->
        state = update_in(state, [:calls, :get], &(&1 + 1))
        {Map.fetch(state.records, key), state}
      end)
      |> case do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def delete(key, opts) do
      Agent.update(Keyword.fetch!(opts, :name), fn state ->
        %{state | records: Map.delete(state.records, key)}
      end)

      :ok
    end

    @impl true
    def list(opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :name), fn state ->
        state = update_in(state, [:calls, :list], &(&1 + 1))
        {{:ok, Map.keys(state.records)}, state}
      end)
    end

    @impl true
    def query(%Filter{} = filter, opts) do
      Agent.get_and_update(Keyword.fetch!(opts, :name), fn state ->
        state =
          state
          |> update_in([:calls, :query], &(&1 + 1))
          |> Map.put(:last_filter, filter)

        response =
          Map.get(state, :query_response, Filter.apply(filter, Map.values(state.records)))

        {{:ok, response}, state}
      end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule AmbiguousMutationBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts) do
      key |> ETS.put(value, opts) |> after_mutation(:put, opts)
    end

    @impl true
    def get(key, opts), do: ETS.get(key, opts)

    @impl true
    def delete(key, opts) do
      key |> ETS.delete(opts) |> after_mutation(:delete, opts)
    end

    @impl true
    def list(opts), do: ETS.list(opts)

    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      key
      |> ETS.compare_and_swap(expected, replacement, opts)
      |> after_mutation(:compare_and_swap, opts)
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      key
      |> ETS.compare_and_delete(expected, opts)
      |> after_mutation(:compare_and_delete, opts)
    end

    @impl true
    def durability_class(_opts), do: :node_restart

    defp after_mutation(result, operation, opts) do
      selected = Keyword.get(opts, :operation, :compare_and_swap)

      if selected == operation and successful_mutation?(operation, result) do
        Agent.update(Keyword.fetch!(opts, :counter), &(&1 + 1))

        case Keyword.fetch!(opts, :failure) do
          :raise -> raise "post-commit backend failure"
          :exit -> exit(:post_commit_backend_failure)
          :throw -> throw(:post_commit_backend_failure)
          :kill_owner -> Process.exit(self(), :kill)
          :return_error -> {:error, :transport_lost}
        end
      else
        result
      end
    end

    defp successful_mutation?(:compare_and_swap, {:ok, _stored}), do: true
    defp successful_mutation?(_operation, :ok), do: true
    defp successful_mutation?(_operation, _result), do: false
  end

  describe "Store facade" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"facade_store_#{:erlang.unique_integer([:positive])}"
      start_supervised!({Store.ETS, name: name})
      {:ok, name: name, backend: Store.ETS}
    end

    test "put/get/delete/list/exists?", %{name: name, backend: backend} do
      assert :ok = Persistence.put(name, backend, "k1", "v1")
      assert {:ok, "v1"} = Persistence.get(name, backend, "k1")
      assert Persistence.exists?(name, backend, "k1")
      assert {:ok, ["k1"]} = Persistence.list(name, backend)
      assert :ok = Persistence.delete(name, backend, "k1")
      assert {:error, :not_found} = Persistence.get(name, backend, "k1")
    end

    test "compare-and-delete reports support and fences the observed value", %{
      name: name,
      backend: backend
    } do
      assert Persistence.supports_compare_and_delete?(backend)
      assert :ok = Persistence.put(name, backend, "k1", "v1")
      assert {:error, :conflict} = Persistence.compare_and_delete(name, backend, "k1", "stale")
      assert :ok = Persistence.compare_and_delete(name, backend, "k1", "v1")
      assert {:error, :not_found} = Persistence.get(name, backend, "k1")
    end
  end

  describe "named BufferedStore authority facade" do
    test "preflight absence is store unavailable rather than outcome unknown" do
      missing = unique_name(:missing_buffered_authority)

      assert {:error, :store_unavailable} =
               Persistence.buffered_store_authoritative_get(missing, "k")

      assert {:error, :store_unavailable} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 missing,
                 "k",
                 :not_found,
                 Record.new("k")
               )
    end

    test "deliberate backend nil mode provides acknowledged ephemeral CAS" do
      name = unique_name(:buffered_ephemeral_authority)
      start_supervised!({BufferedStore, name: name, backend: nil})

      assert {:ok, :ephemeral} = Persistence.buffered_store_authority_mode(name)
      assert {:error, :not_found} = Persistence.buffered_store_authoritative_get(name, "k")

      initial = Record.new("k", %{"value" => "one"})

      assert {:ok, %Record{revision: 1} = stored} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 :not_found,
                 initial
               )

      assert stored.generation > 0

      replacement = Record.update(stored, %{"value" => "two"})

      assert {:ok, %Record{revision: 2} = updated} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 {:value, stored},
                 replacement
               )

      assert updated.generation == stored.generation

      assert {:ok, ^updated} = Persistence.buffered_store_authoritative_get(name, "k")
      assert {:ok, ["k"]} = Persistence.buffered_store_authoritative_list(name)

      assert {:ok, [{"k", ^updated}]} =
               Persistence.buffered_store_authoritative_entries(name)

      assert {:ok, ["k"]} =
               Persistence.buffered_store_authoritative_list_by_prefix(name, "k")

      assert {:ok, []} =
               Persistence.buffered_store_authoritative_list_by_prefix(name, "missing")

      assert {:error, :conflict} =
               Persistence.buffered_store_acknowledged_compare_and_delete(name, "k", stored)

      assert :ok =
               Persistence.buffered_store_acknowledged_compare_and_delete(name, "k", updated)

      assert {:error, :not_found} = Persistence.buffered_store_authoritative_get(name, "k")

      assert {:ok, %Record{revision: 1} = reinserted} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 :not_found,
                 Record.new("k", %{"value" => "new-incarnation"})
               )

      assert reinserted.generation > updated.generation
    end

    test "security regression: ephemeral structured incarnations fence plain transitions" do
      name = unique_name(:buffered_ephemeral_plain_transition)
      start_supervised!({BufferedStore, name: name, backend: nil})

      assert {:ok, %Record{} = first} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 :not_found,
                 Record.new("k", %{"incarnation" => 1})
               )

      assert :ok = BufferedStore.put("k", :plain_compatibility_value, name: name)
      assert :ok = BufferedStore.put("k", Record.new("k", %{"incarnation" => 2}), name: name)

      assert {:ok, %Record{} = second} =
               Persistence.buffered_store_authoritative_get(name, "k")

      assert second.generation > first.generation

      assert {:error, :conflict} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 {:value, first},
                 Record.update(first, %{"stale" => true})
               )

      assert {:ok, ^second} = Persistence.buffered_store_authoritative_get(name, "k")
    end

    test "security regression: ephemeral owner restart preserves ABA fencing in the BEAM" do
      name = unique_name(:buffered_ephemeral_restart)
      start_supervised!({BufferedStore, name: name, backend: nil})

      assert {:ok, %Record{} = before_restart} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 :not_found,
                 Record.new("k", %{"incarnation" => 1})
               )

      stop_supervised!(BufferedStore)
      start_supervised!({BufferedStore, name: name, backend: nil})

      assert {:ok, %Record{} = after_restart} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 :not_found,
                 Record.new("k", %{"incarnation" => 2})
               )

      assert after_restart.generation > before_restart.generation

      assert {:error, :conflict} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 {:value, before_restart},
                 Record.update(before_restart, %{"stale" => true})
               )

      assert {:ok, ^after_restart} = Persistence.buffered_store_authoritative_get(name, "k")
    end

    test "configured backend CAS returns backend-owned record before cache projection" do
      backend_name = unique_name(:buffered_authority_backend)
      store_name = unique_name(:buffered_authority_store)

      start_supervised!({QueryableStore.ETS, name: backend_name})

      start_supervised!(
        {BufferedStore,
         name: store_name,
         backend: QueryableStore.ETS,
         collection: backend_name,
         write_mode: :async,
         ack_mode: :cache}
      )

      assert {:ok, {:backend, :process_lifetime}} =
               Persistence.buffered_store_authority_mode(store_name)

      record = Record.new("k", %{"value" => "durable"})

      assert {:ok, %Record{generation: 1, revision: 1} = stored} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 store_name,
                 "k",
                 :not_found,
                 record
               )

      assert {:ok, ^stored} = BufferedStore.get("k", name: store_name)
      assert {:ok, ^stored} = QueryableStore.ETS.get("k", name: backend_name)
      assert {:ok, ["k"]} = Persistence.buffered_store_authoritative_list(store_name)

      assert :ok =
               Persistence.buffered_store_acknowledged_compare_and_delete(
                 store_name,
                 "k",
                 stored
               )

      assert {:error, :not_found} = QueryableStore.ETS.get("k", name: backend_name)
      assert {:error, :not_found} = BufferedStore.get("k", name: store_name)
    end

    test "security regression: invalid authoritative point reads evict stale projections" do
      backend_name = unique_name(:authoritative_get_response_backend)
      store_name = unique_name(:authoritative_get_response_store)
      stale = Record.new("k", %{"value" => "stale-projection"})

      start_supervised!(%{
        id: backend_name,
        start:
          {Agent, :start_link,
           [
             fn -> {:ok, Record.new("different-key", %{"value" => "mismatch"})} end,
             [name: backend_name]
           ]}
      })

      start_supervised!(
        {BufferedStore,
         name: store_name, backend: AuthoritativeGetResponseBackend, collection: backend_name}
      )

      true = :ets.insert(store_name, {"k", stale})

      assert {:error, :invalid_backend_record} =
               Persistence.buffered_store_authoritative_get(store_name, "k")

      assert {:error, :not_found} = BufferedStore.get("k", name: store_name)

      true = :ets.insert(store_name, {"k", stale})
      Agent.update(backend_name, fn _ -> :invalid_backend_response end)

      assert {:error, :invalid_backend_response} =
               Persistence.buffered_store_authoritative_get(store_name, "k")

      assert {:error, :not_found} = BufferedStore.get("k", name: store_name)

      true = :ets.insert(store_name, {"k", stale})
      Agent.update(backend_name, fn _ -> {:error, :forced_outage} end)

      assert {:error, :backend_unavailable} =
               Persistence.buffered_store_authoritative_get(store_name, "k")

      assert {:ok, ^stale} = BufferedStore.get("k", name: store_name)
    end

    test "security regression: configured conflicts evict projections proven stale" do
      backend_name = unique_name(:buffered_conflict_backend)
      store_name = unique_name(:buffered_conflict_store)

      start_supervised!({QueryableStore.ETS, name: backend_name})

      start_supervised!(
        {BufferedStore, name: store_name, backend: QueryableStore.ETS, collection: backend_name}
      )

      assert {:ok, %Record{} = local} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 store_name,
                 "k",
                 :not_found,
                 Record.new("k", %{"value" => "local"})
               )

      assert {:ok, %Record{} = remote} =
               QueryableStore.ETS.compare_and_swap(
                 "k",
                 {:value, local},
                 Record.update(local, %{"value" => "remote"}),
                 name: backend_name
               )

      assert {:error, :conflict} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 store_name,
                 "k",
                 {:value, local},
                 Record.update(local, %{"value" => "stale-local"})
               )

      assert {:error, :not_found} = BufferedStore.get("k", name: store_name)
      assert {:ok, ^remote} = Persistence.buffered_store_authoritative_get(store_name, "k")
      assert {:ok, ^remote} = BufferedStore.get("k", name: store_name)

      assert {:ok, %Record{} = remote_updated} =
               QueryableStore.ETS.compare_and_swap(
                 "k",
                 {:value, remote},
                 Record.update(remote, %{"value" => "remote-updated"}),
                 name: backend_name
               )

      assert {:error, :conflict} =
               Persistence.buffered_store_acknowledged_compare_and_delete(
                 store_name,
                 "k",
                 remote
               )

      assert {:error, :not_found} = BufferedStore.get("k", name: store_name)

      assert {:ok, ^remote_updated} =
               Persistence.buffered_store_authoritative_get(store_name, "k")
    end

    test "security regression: configured backend failure cannot mutate acknowledged cache" do
      name = unique_name(:buffered_authority_failure)

      start_supervised!(
        {BufferedStore,
         name: name, backend: CriticalFailingBackend, write_mode: :async, ack_mode: :cache}
      )

      cached = Record.new("k", %{"value" => "trusted-cache"})
      assert :ok = BufferedStore.put("k", cached, name: name)
      assert {:ok, ^cached} = BufferedStore.get("k", name: name)

      hostile = Record.new("k", %{"value" => "hostile-update"})

      assert {:error, :backend_unavailable} =
               Persistence.buffered_store_authoritative_get(name, "k")

      assert {:error, :backend_unavailable} =
               Persistence.buffered_store_authoritative_list(name)

      assert {:error, :backend_unavailable} =
               Persistence.buffered_store_authoritative_list_by_prefix(name, "k")

      assert {:error, :unsupported} =
               Persistence.buffered_store_authoritative_entries(name)

      assert {:error, :outcome_unknown} =
               Persistence.buffered_store_acknowledged_put(name, "k", hostile)

      assert {:error, :outcome_unknown} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 {:value, cached},
                 hostile
               )

      assert {:error, :outcome_unknown} =
               Persistence.buffered_store_acknowledged_delete(name, "k")

      assert {:error, :outcome_unknown} =
               Persistence.buffered_store_acknowledged_compare_and_delete(name, "k", cached)

      assert {:error, :not_found} = BufferedStore.get("k", name: name)
    end

    test "put success followed by confirmation failure reports outcome unknown" do
      backend_name = unique_name(:buffered_put_unknown_backend)
      store_name = unique_name(:buffered_put_unknown_store)

      start_supervised!(%{
        id: backend_name,
        start: {Agent, :start_link, [fn -> %{} end, [name: backend_name]]}
      })

      start_supervised!(
        {BufferedStore,
         name: store_name,
         backend: PutThenUnreadableBackend,
         collection: backend_name,
         write_mode: :async,
         ack_mode: :cache}
      )

      cached = Record.new("k", %{"value" => "old-cache"})
      committed = Record.new("k", %{"value" => "committed-but-unconfirmed"})
      true = :ets.insert(store_name, {"k", cached})

      assert {:error, :outcome_unknown} =
               Persistence.buffered_store_acknowledged_put(store_name, "k", committed)

      assert {:error, :not_found} = BufferedStore.get("k", name: store_name)
      assert ^committed = Agent.get(backend_name, &Map.fetch!(&1, "k"))
    end

    test "security regression: ambiguous acknowledged mutations evict stale projection" do
      for operation <- [:put, :delete, :compare_and_swap, :compare_and_delete] do
        backend_name = unique_name(:ambiguous_projection_backend)
        store_name = unique_name(:ambiguous_projection_store)
        counter = unique_name(:ambiguous_projection_counter)
        baseline = Record.new("k", %{"value" => "baseline"})

        start_supervised!(%{
          id: backend_name,
          start: {QueryableStore.ETS, :start_link, [[name: backend_name]]}
        })

        assert :ok = QueryableStore.ETS.put("k", baseline, name: backend_name)
        assert {:ok, %Record{} = observed} = QueryableStore.ETS.get("k", name: backend_name)

        start_supervised!(%{
          id: counter,
          start: {Agent, :start_link, [fn -> 0 end, [name: counter]]}
        })

        start_supervised!(%{
          id: store_name,
          start:
            {BufferedStore, :start_link,
             [
               [
                 name: store_name,
                 backend: AmbiguousMutationBackend,
                 backend_opts: [counter: counter, failure: :raise, operation: operation],
                 collection: backend_name
               ]
             ]}
        })

        assert {:ok, ^observed} = BufferedStore.get("k", name: store_name)

        result =
          case operation do
            :put ->
              Persistence.buffered_store_acknowledged_put(
                store_name,
                "k",
                Record.new("k", %{"value" => "put"})
              )

            :delete ->
              Persistence.buffered_store_acknowledged_delete(store_name, "k")

            :compare_and_swap ->
              Persistence.buffered_store_acknowledged_compare_and_swap(
                store_name,
                "k",
                {:value, observed},
                Record.update(observed, %{"value" => "cas"})
              )

            :compare_and_delete ->
              Persistence.buffered_store_acknowledged_compare_and_delete(
                store_name,
                "k",
                observed
              )
          end

        assert {:error, :outcome_unknown} = result
        assert {:error, :not_found} = BufferedStore.get("k", name: store_name)
        assert Agent.get(counter, & &1) == 1
      end
    end

    test "security regression: exceptional post-commit backend outcomes remain unknown" do
      for failure <- [:raise, :exit, :throw] do
        backend_name = unique_name(:ambiguous_mutation_backend)
        store_name = unique_name(:ambiguous_mutation_store)
        counter = unique_name(:ambiguous_mutation_counter)

        start_supervised!(%{
          id: backend_name,
          start: {QueryableStore.ETS, :start_link, [[name: backend_name]]}
        })

        start_supervised!(%{
          id: counter,
          start: {Agent, :start_link, [fn -> 0 end, [name: counter]]}
        })

        start_supervised!(%{
          id: store_name,
          start:
            {BufferedStore, :start_link,
             [
               [
                 name: store_name,
                 backend: AmbiguousMutationBackend,
                 backend_opts: [counter: counter, failure: failure],
                 collection: backend_name
               ]
             ]}
        })

        assert {:error, :outcome_unknown} =
                 Persistence.buffered_store_acknowledged_compare_and_swap(
                   store_name,
                   "k",
                   :not_found,
                   Record.new("k", %{"failure" => to_string(failure)})
                 )

        assert Agent.get(counter, & &1) == 1
        assert {:ok, %Record{revision: 1}} = QueryableStore.ETS.get("k", name: backend_name)
        assert Process.alive?(Process.whereis(store_name))
      end
    end

    test "security regression: returned transport error after commit remains outcome unknown" do
      backend_name = unique_name(:returned_error_backend)
      store_name = unique_name(:returned_error_store)
      counter = unique_name(:returned_error_counter)

      start_supervised!({QueryableStore.ETS, name: backend_name})

      start_supervised!(%{
        id: counter,
        start: {Agent, :start_link, [fn -> 0 end, [name: counter]]}
      })

      start_supervised!(
        {BufferedStore,
         name: store_name,
         backend: AmbiguousMutationBackend,
         backend_opts: [counter: counter, failure: :return_error],
         collection: backend_name}
      )

      replacement = Record.new("k", %{"value" => "committed"})

      assert {:error, :outcome_unknown} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 store_name,
                 "k",
                 :not_found,
                 replacement
               )

      assert Agent.get(counter, & &1) == 1
      assert {:error, :not_found} = BufferedStore.get("k", name: store_name)

      assert {:ok, %Record{generation: 1, revision: 1, data: %{"value" => "committed"}}} =
               QueryableStore.ETS.get("k", name: backend_name)
    end

    test "security regression: owner death after backend commit reports outcome unknown once" do
      backend_name = unique_name(:owner_death_backend)
      store_name = unique_name(:owner_death_store)
      counter = unique_name(:owner_death_counter)

      start_supervised!(%{
        id: backend_name,
        start: {QueryableStore.ETS, :start_link, [[name: backend_name]]}
      })

      start_supervised!(%{
        id: counter,
        start: {Agent, :start_link, [fn -> 0 end, [name: counter]]}
      })

      start_supervised!(%{
        id: store_name,
        start:
          {BufferedStore, :start_link,
           [
             [
               name: store_name,
               backend: AmbiguousMutationBackend,
               backend_opts: [counter: counter, failure: :kill_owner],
               collection: backend_name
             ]
           ]}
      })

      assert {:error, :outcome_unknown} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 store_name,
                 "k",
                 :not_found,
                 Record.new("k", %{"committed" => true})
               )

      assert Agent.get(counter, & &1) == 1
      assert {:ok, %Record{revision: 1}} = QueryableStore.ETS.get("k", name: backend_name)
    end

    test "security regression: public ETS cannot forge or erase ephemeral authority" do
      name = unique_name(:buffered_private_ephemeral_authority)
      start_supervised!({BufferedStore, name: name, backend: nil})

      initial = Record.new("k", %{"value" => "owner"})

      assert {:ok, %Record{revision: 1} = stored} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 :not_found,
                 initial
               )

      assert stored.generation > 0

      forged = Record.new("k", %{"value" => "forged"}, generation: 99, revision: 99)
      true = :ets.insert(name, {"k", forged})
      true = :ets.delete(name, "k")
      true = :ets.insert(name, {123, :malformed})

      forged_rows = for index <- 1..10_001, do: {"forged-#{index}", index}
      true = :ets.insert(name, forged_rows)

      assert {:ok, ^stored} = Persistence.buffered_store_authoritative_get(name, "k")
      assert {:ok, ^stored} = BufferedStore.get("k", name: name)
      assert {:ok, ["k"]} = Persistence.buffered_store_authoritative_list(name)
      assert {:ok, [{"k", ^stored}]} = Persistence.buffered_store_authoritative_entries(name)

      replacement = Record.update(stored, %{"value" => "updated"})

      assert {:ok, %Record{revision: 2} = updated} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 {:value, stored},
                 replacement
               )

      assert updated.generation == stored.generation

      true = :ets.insert(name, {"k", forged})

      assert {:error, :conflict} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 {:value, stored},
                 Record.update(stored, %{"value" => "stale-cas"})
               )

      assert {:ok, ^updated} = BufferedStore.get("k", name: name)
      true = :ets.insert(name, {"k", forged})

      assert {:error, :conflict} =
               Persistence.buffered_store_acknowledged_compare_and_delete(name, "k", stored)

      assert {:ok, ^updated} = BufferedStore.get("k", name: name)

      assert :ok =
               Persistence.buffered_store_acknowledged_compare_and_delete(name, "k", updated)

      true = :ets.insert(name, {"k", forged})
      assert {:error, :not_found} = Persistence.buffered_store_authoritative_get(name, "k")
      assert {:error, :not_found} = BufferedStore.get("k", name: name)

      assert {:ok, %Record{revision: 1} = reinserted} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 name,
                 "k",
                 :not_found,
                 Record.new("k", %{"value" => "new incarnation"})
               )

      assert reinserted.generation > updated.generation

      assert :ok =
               BufferedStore.put("compat", Record.new("compat", %{"owner" => true}), name: name)

      assert {:ok, %Record{revision: 1, data: %{"owner" => true}} = compatibility} =
               Persistence.buffered_store_authoritative_get(name, "compat")

      assert compatibility.generation > 0

      true = :ets.delete(name, "compat")
      assert :ok = BufferedStore.delete("compat", name: name)
      assert {:error, :not_found} = Persistence.buffered_store_authoritative_get(name, "compat")
    end

    test "ephemeral authoritative inventory bounds owner-mediated state" do
      oversized = unique_name(:buffered_authority_oversized)
      start_supervised!({BufferedStore, name: oversized, backend: nil})

      for index <- 1..10_000 do
        assert :ok = BufferedStore.put("key-#{index}", index, name: oversized)
      end

      true = :ets.insert(oversized, {"key-10001", :forged_overflow})

      assert {:error, :inventory_limit_exceeded} =
               BufferedStore.put("key-10001", 10_001, name: oversized)

      assert {:error, :not_found} = BufferedStore.get("key-10001", name: oversized)

      true = :ets.insert(oversized, {"key-10001", :forged_overflow})

      assert {:error, :inventory_limit_exceeded} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 oversized,
                 "key-10001",
                 :not_found,
                 Record.new("key-10001")
               )

      assert {:error, :not_found} = BufferedStore.get("key-10001", name: oversized)

      assert :ok = BufferedStore.put("key-1", :replacement, name: oversized)

      assert {:ok, keys} = Persistence.buffered_store_authoritative_list(oversized)
      assert length(keys) == 10_000

      assert {:ok, entries} = Persistence.buffered_store_authoritative_entries(oversized)
      assert length(entries) == 10_000

      assert :ok = BufferedStore.delete("key-2", name: oversized)
      assert :ok = BufferedStore.put("key-10001", 10_001, name: oversized)

      malformed = unique_name(:buffered_authority_malformed)

      start_supervised!(%{
        id: malformed,
        start: {BufferedStore, :start_link, [[name: malformed, backend: nil]]}
      })

      assert :ok = BufferedStore.put(123, :invalid_key, name: malformed)

      assert {:error, :invalid_cache_state} =
               Persistence.buffered_store_authoritative_list(malformed)

      assert {:error, :invalid_cache_state} =
               Persistence.buffered_store_authoritative_entries(malformed)
    end

    test "authoritative entries use one bounded query without list/get N+1 calls" do
      backend_name = unique_name(:buffered_snapshot_backend)
      store_name = unique_name(:buffered_snapshot_store)

      records = %{
        "b" => Record.new("b", %{"value" => 2}),
        "a" => Record.new("a", %{"value" => 1})
      }

      start_supervised!(%{
        id: backend_name,
        start:
          {Agent, :start_link,
           [
             fn ->
               %{
                 records: records,
                 calls: %{get: 0, list: 0, query: 0},
                 last_filter: nil
               }
             end,
             [name: backend_name]
           ]}
      })

      start_supervised!(%{
        id: store_name,
        start:
          {BufferedStore, :start_link,
           [
             [
               name: store_name,
               backend: CountingQueryableBackend,
               collection: backend_name
             ]
           ]}
      })

      assert %{calls: %{query: 1, list: 0, get: 0}, last_filter: startup_filter} =
               Agent.get(backend_name, & &1)

      assert %Filter{order_by: {:key, :asc}, limit: 10_001, offset: 0} = startup_filter
      assert {:ok, %Record{key: "a"}} = BufferedStore.get("a", name: store_name)
      assert {:ok, %Record{key: "b"}} = BufferedStore.get("b", name: store_name)

      forged = Record.new("forged", %{"value" => "caller-writable"})
      true = :ets.insert(store_name, {"forged", forged})
      true = :ets.delete(store_name, "a")

      Agent.update(backend_name, fn state ->
        %{state | calls: %{get: 0, list: 0, query: 0}, last_filter: nil}
      end)

      assert {:ok, [{"a", %Record{key: "a"}}, {"b", %Record{key: "b"}}]} =
               Persistence.buffered_store_authoritative_entries(store_name)

      assert %{calls: %{query: 1, list: 0, get: 0}, last_filter: filter} =
               Agent.get(backend_name, & &1)

      assert %Filter{order_by: {:key, :asc}, limit: 10_001, offset: 0} = filter
      assert {:ok, %Record{key: "a"}} = BufferedStore.get("a", name: store_name)
      assert {:error, :not_found} = BufferedStore.get("forged", name: store_name)

      retained = Record.new("retained", %{"value" => "projection"})
      true = :ets.insert(store_name, {"retained", retained})

      Agent.update(backend_name, fn state ->
        Map.put(state, :query_response, [records["a"] | :improper_tail])
      end)

      assert {:error, :invalid_backend_response} =
               Persistence.buffered_store_authoritative_entries(store_name)

      assert {:ok, ^retained} = BufferedStore.get("retained", name: store_name)
    end

    test "security regression: non-query backend inventory is rejected without N+1 reads" do
      backend_name = unique_name(:buffered_non_query_backend)
      store_name = unique_name(:buffered_non_query_store)
      record = Record.new("one", %{"value" => 1})

      start_supervised!(%{
        id: backend_name,
        start:
          {Agent, :start_link,
           [
             fn -> %{records: %{"one" => record}, calls: %{get: 0, list: 0}} end,
             [name: backend_name]
           ]}
      })

      start_supervised!(
        {BufferedStore,
         name: store_name, backend: CountingNonQueryableBackend, collection: backend_name}
      )

      Agent.update(backend_name, fn state -> %{state | calls: %{get: 0, list: 0}} end)

      assert {:ok, ^record} =
               Persistence.buffered_store_authoritative_get(store_name, "one")

      assert %{calls: %{get: 1, list: 0}} = Agent.get(backend_name, & &1)
      Agent.update(backend_name, fn state -> %{state | calls: %{get: 0, list: 0}} end)

      assert {:error, :unsupported} =
               Persistence.buffered_store_authoritative_entries(store_name)

      assert %{calls: %{get: 0, list: 0}} = Agent.get(backend_name, & &1)
    end

    test "authoritative backend inventory rejects oversized and improper lists total" do
      oversized_response = Enum.map(1..10_001, &"key-#{&1}")

      for {suffix, response, expected_error} <- [
            {:oversized, oversized_response, :inventory_limit_exceeded},
            {:improper, ["key" | :improper_tail], :invalid_backend_response}
          ] do
        backend_name = unique_name(:buffered_inventory_backend)
        store_name = unique_name(suffix)

        start_supervised!(%{
          id: backend_name,
          start:
            {Agent, :start_link,
             [fn -> %{initial?: true, response: response} end, [name: backend_name]]}
        })

        start_supervised!(%{
          id: store_name,
          start:
            {BufferedStore, :start_link,
             [
               [
                 name: store_name,
                 backend: InventoryResponseBackend,
                 collection: backend_name
               ]
             ]}
        })

        assert {:error, ^expected_error} =
                 Persistence.buffered_store_authoritative_list(store_name)
      end
    end
  end

  describe "QueryableStore facade" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"facade_qs_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.ETS, name: name})
      {:ok, name: name, backend: QueryableStore.ETS}
    end

    test "put/query/count", %{name: name, backend: backend} do
      r1 = Record.new("a", %{type: "x"})
      r2 = Record.new("b", %{type: "y"})

      Persistence.put(name, backend, "a", r1)
      Persistence.put(name, backend, "b", r2)

      filter = Filter.new() |> Filter.where(:key, :eq, "a")
      {:ok, results} = Persistence.query(name, backend, filter)
      assert length(results) == 1

      {:ok, count} = Persistence.count(name, backend, Filter.new())
      assert count == 2
    end

    test "Queryable Agent and ETS bound internal authoritative list traversal" do
      for backend <- [QueryableStore.Agent, QueryableStore.ETS] do
        name = unique_name(:queryable_bounded_list)
        start_supervised!(%{id: name, start: {backend, :start_link, [[name: name]]}})

        for key <- ["a", "b", "c"] do
          assert :ok = backend.put(key, Record.new(key), name: name)
        end

        assert {:ok, ordinary_keys} = backend.list(name: name)
        assert Enum.sort(ordinary_keys) == ["a", "b", "c"]

        assert {:error, :inventory_limit_exceeded} =
                 backend.list(name: name, authoritative_limit: 2)

        assert {:error, :invalid_authoritative_limit} =
                 backend.list(name: name, authoritative_limit: 10_002)
      end
    end

    test "aggregate", %{name: name, backend: backend} do
      for {key, val} <- [{"a", 10}, {"b", 20}] do
        record = Record.new(key, %{}) |> Map.put(:score, val)
        Persistence.put(name, backend, key, record)
      end

      {:ok, sum} = Persistence.aggregate(name, backend, Filter.new(), :score, :sum)
      assert sum == 30
    end
  end

  defp unique_name(prefix) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end

  describe "EventLog facade" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"facade_el_#{:erlang.unique_integer([:positive])}"
      start_supervised!({EventLog.ETS, name: name})
      {:ok, name: name, backend: EventLog.ETS}
    end

    test "append/read_stream/read_all", %{name: name, backend: backend} do
      event = Event.new("s1", "test_type", %{v: 1})
      {:ok, [persisted]} = Persistence.append(name, backend, "s1", event)
      assert persisted.event_number == 1

      {:ok, stream} = Persistence.read_stream(name, backend, "s1")
      assert length(stream) == 1

      {:ok, all} = Persistence.read_all(name, backend)
      assert length(all) == 1
    end

    test "forwards append preconditions and bounded head reads", %{name: name, backend: backend} do
      event = Event.new("s1", "started", %{})

      assert {:ok, [_]} =
               Persistence.append(name, backend, "s1", event, expected_version: 0)

      assert {:error, :version_conflict} =
               Persistence.append(
                 name,
                 backend,
                 "s1",
                 Event.new("s1", "duplicate", %{}),
                 expected_version: 0
               )

      assert {:ok, %Event{event_number: 1}} =
               Persistence.read_stream_head(name, backend, "s1")
    end

    test "facade rejects improper append input and forged reconciliation operations", %{
      name: name,
      backend: backend
    } do
      event = Event.new("facade-bounds", "created", %{value: 1})

      assert {:error, :invalid_events} =
               Persistence.append(name, backend, "facade-bounds", [event | :improper])

      assert {:error, :invalid_precondition} =
               Persistence.append(
                 name,
                 backend,
                 "facade-bounds",
                 event,
                 [{:expected_version, 0} | :improper]
               )

      assert {:ok, %AppendOperation{} = operation} =
               Arbor.Persistence.EventLog.build_operation("facade-bounds", [event])

      oversized_ids = Enum.map(1..1_001, &"evt_forged_#{&1}")

      for forged <- [
            %AppendOperation{operation | event_ids: [event.id | :improper]},
            %AppendOperation{operation | event_ids: oversized_ids, fingerprints: %{}}
          ] do
        assert {:error, :invalid_append_operation} =
                 Persistence.reconcile_append(name, backend, forged)
      end

      assert {:error, :invalid_precondition} =
               Persistence.reconcile_append(
                 name,
                 backend,
                 operation,
                 [{:append_timeout_ms, 10} | :improper]
               )
    end

    test "metadata-only nonempty heads are unavailable through the facade", %{
      name: name,
      backend: backend
    } do
      assert {:ok, {:identity_history_unavailable, _details}} =
               EventLog.ETS.rehydrate_metadata(
                 %{stream_versions: %{"durable-only" => 4}, global_position: 4},
                 name: name
               )

      assert {:error, :head_unavailable} =
               Persistence.read_stream_head(name, backend, "durable-only")
    end

    test "stream_exists?/stream_version", %{name: name, backend: backend} do
      refute Persistence.stream_exists?(name, backend, "s1")
      Persistence.append(name, backend, "s1", Event.new("s1", "t", %{}))
      assert Persistence.stream_exists?(name, backend, "s1")
      assert {:ok, 1} = Persistence.stream_version(name, backend, "s1")
    end

    test "list_streams/stream_count/event_count", %{name: name, backend: backend} do
      Persistence.append(name, backend, "s1", Event.new("s1", "t", %{}))
      Persistence.append(name, backend, "s2", Event.new("s2", "t", %{}))

      {:ok, streams} = Persistence.list_streams(name, backend)
      assert "s1" in streams
      assert "s2" in streams

      {:ok, count} = Persistence.stream_count(name, backend)
      assert count == 2

      {:ok, events} = Persistence.event_count(name, backend)
      assert events == 2
    end
  end

  describe "exists? fallback" do
    defmodule NoExistsBackend do
      @moduledoc false
      # Minimal backend that does NOT implement exists?/2
      def put(_key, _value, _opts), do: :ok
      def get("found", _opts), do: {:ok, "value"}
      def get(_key, _opts), do: {:error, :not_found}
      def delete(_key, _opts), do: :ok
      def list(_opts), do: {:ok, []}
    end

    test "falls back to get when backend doesn't export exists?/2" do
      assert Persistence.exists?(:x, NoExistsBackend, "found")
      refute Persistence.exists?(:x, NoExistsBackend, "missing")
    end

    test "compare-and-delete returns unsupported for a backend without the optional callback" do
      refute Persistence.supports_compare_and_delete?(NoExistsBackend)

      assert {:error, :unsupported} =
               Persistence.compare_and_delete(:x, NoExistsBackend, "found", "value")
    end
  end

  describe "facade contract callbacks" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      store_name = :"cb_store_#{:erlang.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      el_name = :"cb_el_#{:erlang.unique_integer([:positive])}"

      start_supervised!({Store.ETS, name: store_name})
      start_supervised!({EventLog.ETS, name: el_name})

      {:ok, store: store_name, el: el_name}
    end

    test "store callbacks", %{store: name} do
      backend = Store.ETS
      assert :ok = Persistence.store_value_by_key_using_backend(name, backend, "k", "v", [])
      assert {:ok, "v"} = Persistence.retrieve_value_by_key_using_backend(name, backend, "k", [])
      assert {:ok, ["k"]} = Persistence.list_all_keys_using_backend(name, backend, [])
      assert true == Persistence.check_key_exists_using_backend(name, backend, "k", [])
      assert :ok = Persistence.delete_value_by_key_using_backend(name, backend, "k", [])
      assert :ok = Persistence.put(name, backend, "conditional", "value")

      assert :ok =
               Persistence.compare_and_delete_value_using_backend(
                 name,
                 backend,
                 "conditional",
                 "value",
                 []
               )
    end

    test "event log callbacks", %{el: name} do
      backend = EventLog.ETS
      event = Event.new("s1", "t", %{})

      assert {:ok, [_]} =
               Persistence.append_events_to_stream_using_backend(name, backend, "s1", event, [])

      assert {:ok, [_]} =
               Persistence.read_events_from_stream_using_backend(name, backend, "s1", [])

      assert {:ok, %Event{event_number: 1}} =
               Persistence.read_current_stream_head_using_backend(name, backend, "s1", [])

      assert {:ok, [_]} = Persistence.read_all_events_using_backend(name, backend, [])

      assert Persistence.check_stream_exists_using_backend(name, backend, "s1", [])

      assert {:ok, 1} =
               Persistence.get_stream_version_using_backend(name, backend, "s1", [])

      assert {:ok, streams} = Persistence.list_all_streams_using_backend(name, backend, [])
      assert "s1" in streams

      assert {:ok, 1} = Persistence.get_stream_count_using_backend(name, backend, [])
      assert {:ok, 1} = Persistence.get_event_count_using_backend(name, backend, [])

      assert :ok =
               Persistence.purge_complete_event_stream_using_backend(
                 name,
                 backend,
                 "s1",
                 []
               )

      assert {:ok, []} =
               Persistence.read_events_from_stream_using_backend(name, backend, "s1", [])

      refute Persistence.check_stream_exists_using_backend(name, backend, "s1", [])
    end

    test "queryable store callbacks" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"cb_qs_#{:erlang.unique_integer([:positive])}"
      start_supervised!({QueryableStore.ETS, name: name})
      backend = QueryableStore.ETS

      r = Record.new("a", %{}) |> Map.put(:score, 10)
      Persistence.put(name, backend, "a", r)

      filter = Filter.new()

      assert {:ok, [_]} =
               Persistence.query_records_by_filter_using_backend(name, backend, filter, [])

      assert {:ok, 1} =
               Persistence.count_records_by_filter_using_backend(name, backend, filter, [])

      assert {:ok, 10} =
               Persistence.aggregate_field_by_filter_using_backend(
                 name,
                 backend,
                 filter,
                 :score,
                 :sum,
                 []
               )
    end
  end

  describe "error paths with failing backends" do
    alias Arbor.Persistence.TestBackends.FailingEventLog
    alias Arbor.Persistence.TestBackends.FailingStore

    test "failing store returns errors" do
      assert {:error, :write_failed} = Persistence.put(:x, FailingStore, "k", "v")
      assert {:error, :read_failed} = Persistence.get(:x, FailingStore, "k")
      assert {:error, :delete_failed} = Persistence.delete(:x, FailingStore, "k")
      assert {:error, :list_failed} = Persistence.list(:x, FailingStore)
    end

    test "failing event log returns errors" do
      event = Event.new("s1", "t", %{})
      assert {:error, :append_failed} = Persistence.append(:x, FailingEventLog, "s1", event)
      assert {:error, :read_failed} = Persistence.read_stream(:x, FailingEventLog, "s1")
      assert {:error, :read_failed} = Persistence.read_all(:x, FailingEventLog)
    end
  end
end
