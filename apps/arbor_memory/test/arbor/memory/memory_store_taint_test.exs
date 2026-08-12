defmodule Arbor.Memory.MemoryStoreTaintTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue}
  alias Arbor.Memory.MemoryStore
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore
  alias Arbor.Signals.Taint, as: TaintModule

  @moduletag :fast
  @store_name :arbor_memory_durable

  defmodule FailingNodeRestartBackend do
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

  defmodule CountingNodeRestartBackend do
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
        state = update_in(state, [:calls, :query], &(&1 + 1))
        {{:ok, Filter.apply(filter, Map.values(state.records))}, state}
      end)
    end

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule CleanupFailingNodeRestartBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: ETS.put(key, value, opts)

    @impl true
    def get(key, opts), do: ETS.get(key, opts)

    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)

    @impl true
    def list(opts), do: ETS.list(opts)

    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      Agent.update(
        Keyword.fetch!(opts, :counter),
        &Map.update!(&1, :cas, fn count -> count + 1 end)
      )

      ETS.compare_and_swap(key, expected, replacement, opts)
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      Agent.update(
        Keyword.fetch!(opts, :counter),
        &Map.update!(&1, :compare_delete, fn count -> count + 1 end)
      )

      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:legacy_cleanup_started, self()})

      receive do
        :release_legacy_cleanup -> ETS.compare_and_delete(key, expected, opts)
      end
    end

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule DelayedRawCasBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts) do
      maybe_block_raw_write(value, opts)
      result = ETS.put(key, value, opts)
      notify_raw_write_finished(value, result, opts)
      result
    end

    @impl true
    def get(key, opts), do: ETS.get(key, opts)

    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)

    @impl true
    def list(opts), do: ETS.list(opts)

    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      maybe_block_raw_write(replacement, opts)
      result = ETS.compare_and_swap(key, expected, replacement, opts)
      notify_raw_write_finished(replacement, result, opts)
      result
    end

    @impl true
    def compare_and_delete(key, expected, opts), do: ETS.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :node_restart

    defp maybe_block_raw_write(%{data: %{"source" => "raw-delayed"}}, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:raw_cas_blocked, self()})

      receive do
        :release_raw_cas -> :ok
      end
    end

    defp maybe_block_raw_write(_value, _opts), do: :ok

    defp notify_raw_write_finished(%{data: %{"source" => "raw-delayed"}}, result, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:raw_write_finished, self(), result})
    end

    defp notify_raw_write_finished(_value, _result, _opts), do: :ok
  end

  defmodule PostCommitRaisingNodeRestartBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: ETS.put(key, value, opts)

    @impl true
    def get(key, opts), do: ETS.get(key, opts)

    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)

    @impl true
    def list(opts), do: ETS.list(opts)

    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      result = ETS.compare_and_swap(key, expected, replacement, opts)
      Agent.update(Keyword.fetch!(opts, :counter), &(&1 + 1))
      if match?({:ok, _stored}, result), do: raise("post-commit CAS failure")
      result
    end

    @impl true
    def compare_and_delete(key, expected, opts), do: ETS.compare_and_delete(key, expected, opts)

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule LegacyDeleteRaceBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Persistence.QueryableStore.ETS

    @impl true
    def put(key, value, opts), do: ETS.put(key, value, opts)

    @impl true
    def get(key, opts), do: ETS.get(key, opts)

    @impl true
    def delete(key, opts), do: ETS.delete(key, opts)

    @impl true
    def list(opts), do: ETS.list(opts)

    @impl true
    def query(filter, opts), do: ETS.query(filter, opts)

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      ETS.compare_and_swap(key, expected, replacement, opts)
    end

    @impl true
    def compare_and_delete(key, expected, opts) do
      if key == Keyword.fetch!(opts, :race_key) do
        test_pid = Keyword.fetch!(opts, :test_pid)
        send(test_pid, {:legacy_delete_ready, self()})

        receive do
          :continue_legacy_delete -> ETS.compare_and_delete(key, expected, opts)
        after
          5_000 -> {:error, :test_timeout}
        end
      else
        ETS.compare_and_delete(key, expected, opts)
      end
    end

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  setup do
    start_supervised!({BufferedStore, name: @store_name, backend: nil, write_mode: :sync})
    :ok
  end

  describe "durable writes" do
    test "stores a JSON-safe payload-bound envelope from the actual data" do
      data = %{"secret" => "value"}
      taint = %Taint{level: :untrusted, sensitivity: :confidential, source: "test"}

      assert :ok =
               MemoryStore.persist("write", "valid", data,
                 taint: taint,
                 data: %{"caller_selected" => "not-bound"}
               )

      assert {:ok, %Record{data: ^data, metadata: %{"taint" => envelope}}} =
               BufferedStore.get("write:valid", name: @store_name)

      assert is_integer(envelope["version"])
      assert is_binary(envelope["payload_sha256"])
      assert is_map(envelope["taint"])
      assert {:ok, _json} = Jason.encode(envelope)

      assert {:ok, value, :verified} = MemoryStore.load_tainted_with_status("write", "valid")
      assert value.value == data
      assert value.taint.level == :untrusted
      assert value.taint.sensitivity == :confidential
    end

    test "writes empty metadata when no taint is supplied" do
      assert :ok = MemoryStore.persist("write", "plain", %{"value" => "plain"})

      assert {:ok, %Record{metadata: %{}}} =
               BufferedStore.get("write:plain", name: @store_name)
    end

    test "labeled compatibility writes remain updateable and deletable" do
      first = %{"version" => 1}
      second = %{"version" => 2}

      assert :ok =
               MemoryStore.persist("write", "labeled-compat", first,
                 taint: %Taint{level: :untrusted, source: "first"}
               )

      assert :ok =
               MemoryStore.persist("write", "labeled-compat", second,
                 taint: %Taint{level: :hostile, source: "second"}
               )

      assert {:ok, value, :verified, %Record{}, :namespaced} =
               MemoryStore.load_tainted_authoritative_with_status(
                 "write",
                 "labeled-compat"
               )

      assert value.value == second
      assert value.taint.level == :hostile

      assert :ok = MemoryStore.delete("write", "labeled-compat")

      assert {:error, :not_found} =
               Persistence.buffered_store_authoritative_get(
                 @store_name,
                 "write:labeled-compat"
               )
    end

    test "rejects malformed taint without inserting the record or leaking data" do
      data = %{"secret" => "do-not-leak"}
      malformed = %Taint{level: :not_a_level}

      error = MemoryStore.persist("write", "malformed", data, taint: malformed)

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} = error
      refute inspect(error) =~ "do-not-leak"
      assert {:error, :not_found} = BufferedStore.get("write:malformed", name: @store_name)
    end

    test "rejects an oversized payload before inserting the record" do
      data = %{"payload" => String.duplicate("x", 65_537)}
      taint = %Taint{level: :untrusted}

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} =
               MemoryStore.persist("write", "oversized", data, taint: taint)

      assert {:error, :not_found} = BufferedStore.get("write:oversized", name: @store_name)
    end

    test "validates supplied labels before honoring unavailable-store degradation" do
      stop_supervised!(BufferedStore)
      assert Process.whereis(@store_name) == nil
      malformed = %Taint{level: :not_a_level}

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} =
               MemoryStore.persist("write", "unavailable-invalid", %{"secret" => "value"},
                 taint: malformed
               )

      assert :ok = MemoryStore.persist("write", "unavailable-plain", %{"value" => "plain"})

      assert :ok =
               MemoryStore.persist_async("write", "unavailable-valid", %{"value" => "valid"},
                 taint: %Taint{level: :derived},
                 agent_id: "taint_unavailable_agent"
               )
    end

    test "rejects non-keyword options without raising" do
      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.persist("write", "bad-options", %{}, %{})

      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.persist_async("write", "bad-options", %{}, [:taint])

      improper = [{:taint, %Taint{level: :derived}} | :tail]

      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.persist("write", "improper-options", %{}, improper)
    end

    test "persist_async validates labeled input before spawning" do
      data = %{"secret" => "async-do-not-leak"}
      malformed = %Taint{level: :not_a_level}

      error =
        MemoryStore.persist_async("async", "malformed", data,
          taint: malformed,
          agent_id: "taint_malformed_agent"
        )

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} = error
      refute inspect(error) =~ "async-do-not-leak"
      assert {:error, :not_found} = BufferedStore.get("async:malformed", name: @store_name)
    end

    test "persist_async keeps valid writes fire-and-forget" do
      assert :ok =
               MemoryStore.persist_async("async", "valid", %{"value" => "written"},
                 taint: %Taint{level: :derived},
                 agent_id: "taint_async_valid_agent"
               )

      assert eventually(fn ->
               match?({:ok, %Record{}}, BufferedStore.get("async:valid", name: @store_name))
             end)
    end
  end

  describe "tainted reads" do
    test "missing metadata is untrusted, restricted, and unverified" do
      put_raw("read:missing", %{"value" => "legacy"}, %{})

      assert {:ok, value, :legacy_unlabeled} =
               MemoryStore.load_tainted_with_status("read", "missing")

      assert value.taint.level == :untrusted
      assert value.taint.sensitivity == :restricted
      assert value.taint.confidence == :unverified
      assert value.taint.source == "legacy_unlabeled"

      assert {:ok, compatibility_value} = MemoryStore.load_tainted("read", "missing")
      assert compatibility_value.taint.level == :untrusted
    end

    test "malformed, old, unknown-version, atom-key, and ambiguous metadata are invalid" do
      data = %{"value" => "tamper"}
      {:ok, envelope} = TaintModule.bind_durable_provenance(data, %Taint{level: :derived})

      cases = [
        {"malformed", %{"taint" => %{"version" => 1}}},
        {"old", %{"taint" => %{"taint_level" => "trusted"}}},
        {"atom_old", %{taint_level: "trusted"}},
        {"unknown", %{"taint" => Map.put(envelope, "version", 99)}},
        {"atom", %{taint: envelope}},
        {"ambiguous", Map.merge(%{taint: envelope}, %{"taint" => envelope})},
        {"valid_plus_legacy", %{"taint" => envelope, "taint_level" => "trusted"}},
        {"payload_mismatch", %{"taint" => envelope}}
      ]

      Enum.each(cases, fn {key, metadata} ->
        tampered_data =
          if key == "payload_mismatch", do: %{"value" => "changed"}, else: data

        put_raw("read:#{key}", tampered_data, metadata)

        assert {:ok, value, :invalid_durable_provenance} =
                 MemoryStore.load_tainted_with_status("read", key)

        assert value.taint.level == :hostile
        assert value.taint.sensitivity == :restricted
        assert value.taint.confidence == :unverified
        assert value.taint.source == "invalid_durable_provenance"
      end)
    end

    test "non-map metadata is invalid rather than missing" do
      put_raw("read:non_map", %{"value" => "legacy"}, :taint)

      assert {:ok, value, :invalid_durable_provenance} =
               MemoryStore.load_tainted_with_status("read", "non_map")

      assert value.taint.level == :hostile
    end

    test "security regression: missing metadata never emerges trusted or control-eligible" do
      put_raw("security:missing", %{"command" => "do-not-run"}, %{})

      assert {:ok, value} = MemoryStore.load_tainted("security", "missing")
      refute TaintedValue.level?(value, :trusted)
      assert value.taint.level == :untrusted
      assert value.taint.sensitivity == :restricted
      assert value.taint.confidence == :unverified
    end

    test "collections retain each item's taint and status" do
      verified_data = %{"value" => "verified"}

      {:ok, envelope} =
        TaintModule.bind_durable_provenance(verified_data, %Taint{level: :derived})

      put_raw("collection:verified", verified_data, %{"taint" => envelope})
      put_raw("collection:missing", %{"value" => "missing"}, %{})
      put_raw("collection:invalid", %{"value" => "invalid"}, %{taint: envelope})

      assert {:ok, entries} = MemoryStore.load_all_tainted("collection")
      assert Enum.map(entries, &elem(&1, 0)) == ["invalid", "missing", "verified"]

      statuses =
        Map.new(entries, fn {key, value, status} -> {key, {value.taint.level, status}} end)

      assert statuses["verified"] == {:derived, :verified}
      assert statuses["missing"] == {:untrusted, :legacy_unlabeled}
      assert statuses["invalid"] == {:hostile, :invalid_durable_provenance}

      assert {:ok, [{"verified", value, :verified}]} =
               MemoryStore.load_by_prefix_tainted("collection", "verified")

      assert value.taint.level == :derived
    end
  end

  describe "authoritative tainted inventory" do
    test "merges mixed namespaced and owned bare rows with namespaced precedence" do
      namespace = "inventory"
      duplicate_key = "duplicate"
      namespaced_taint = %Taint{level: :hostile, source: "namespaced"}
      legacy_taint = %Taint{level: :trusted, source: "legacy"}

      assert :ok =
               MemoryStore.persist(namespace, duplicate_key, %{"source" => "namespaced"},
                 taint: namespaced_taint
               )

      put_legacy_bare(
        namespace,
        duplicate_key,
        %{"source" => "legacy-duplicate"},
        legacy_taint
      )

      put_legacy_bare(namespace, "legacy-only", %{"source" => "legacy"}, legacy_taint)
      put_legacy_bare("foreign", "foreign-only", %{"source" => "foreign"}, legacy_taint)

      assert {:ok, entries} = MemoryStore.load_all_tainted_authoritative(namespace)
      assert Enum.map(entries, &elem(&1, 0)) == ["duplicate", "legacy-only"]

      assert {"duplicate", duplicate, :verified} = List.keyfind(entries, duplicate_key, 0)
      assert duplicate.value == %{"source" => "namespaced"}
      assert duplicate.taint.level == :hostile

      assert {"legacy-only", legacy, :verified} = List.keyfind(entries, "legacy-only", 0)
      assert legacy.value == %{"source" => "legacy"}

      assert {:ok, [{"legacy-only", _value, :verified}]} =
               MemoryStore.load_by_prefix_tainted_authoritative(namespace, "legacy")
    end

    test "fails closed on malformed structural rows" do
      malformed = Record.new("bad", %{"value" => "ambiguous"}, id: "not-an-owned-shape")
      assert :ok = BufferedStore.put("bad", malformed, name: @store_name)

      assert {:error, {:memory_store, :critical, :invalid_record}} =
               MemoryStore.load_all_tainted_authoritative("inventory")
    end

    test "security regression: oversized and malformed inventory keys fail closed" do
      invalid_physical_keys = [
        "inventory:" <> String.duplicate("k", 1_025),
        String.duplicate("p", 1_282),
        <<"inventory:", 255>>
      ]

      for physical_key <- invalid_physical_keys do
        record = Record.new(physical_key, %{}, id: "memory:" <> physical_key)
        assert :ok = BufferedStore.put(physical_key, record, name: @store_name)

        assert {:error, {:memory_store, :critical, :invalid_record}} =
                 MemoryStore.load_all_tainted_authoritative("inventory")

        assert :ok = BufferedStore.delete(physical_key, name: @store_name)
      end
    end

    test "rejects an over-cap authority write while inventory remains usable" do
      for index <- 1..10_000 do
        key = "other:#{index}"

        assert :ok =
                 BufferedStore.put(key, Record.new(key, %{}, id: "memory:#{key}"),
                   name: @store_name
                 )
      end

      overflow_key = "other:10001"

      assert {:error, :inventory_limit_exceeded} =
               BufferedStore.put(
                 overflow_key,
                 Record.new(overflow_key, %{}, id: "memory:#{overflow_key}"),
                 name: @store_name
               )

      assert {:ok, []} = MemoryStore.load_all_tainted_authoritative("inventory")
    end

    test "configured backend outage never falls back to caller-writable cache" do
      stop_supervised!(BufferedStore)

      start_supervised!(
        {BufferedStore,
         name: @store_name,
         backend: FailingNodeRestartBackend,
         write_mode: :async,
         ack_mode: :cache}
      )

      cached = Record.new("inventory:cached", %{"secret" => "cache-only"})
      true = :ets.insert(@store_name, {"inventory:cached", cached})

      assert {:error, {:memory_store, :critical, :durable_unavailable}} =
               MemoryStore.load_all_tainted_authoritative("inventory")
    end

    test "public inventory classifies one authoritative snapshot without N+1 calls" do
      stop_supervised!(BufferedStore)

      backend_name = unique_name(:memory_inventory_snapshot)
      data = %{"value" => "authoritative"}

      {:ok, envelope} =
        TaintModule.bind_durable_provenance(data, %Taint{level: :hostile, source: "backend"})

      record =
        Record.new("inventory:one", data,
          id: "memory:inventory:one",
          metadata: %{"taint" => envelope}
        )

      start_supervised!(%{
        id: backend_name,
        start:
          {Agent, :start_link,
           [
             fn ->
               %{
                 records: %{"inventory:one" => record},
                 calls: %{get: 0, list: 0, query: 0}
               }
             end,
             [name: backend_name]
           ]}
      })

      start_supervised!(
        {BufferedStore,
         name: @store_name, backend: CountingNodeRestartBackend, collection: backend_name}
      )

      Agent.update(backend_name, fn state ->
        %{state | calls: %{get: 0, list: 0, query: 0}}
      end)

      assert {:ok, [{"one", value, :verified}]} =
               MemoryStore.load_all_tainted_authoritative("inventory")

      assert value.value == data
      assert value.taint.level == :hostile
      assert %{calls: %{query: 1, list: 0, get: 0}} = Agent.get(backend_name, & &1)
    end
  end

  describe "authoritative ownership and migration" do
    test "security regression: compatibility mutation cannot overwrite marked critical authority" do
      critical_data = %{"value" => "critical"}
      label = %Taint{level: :hostile, sensitivity: :restricted, source: "critical-owner"}

      assert {:ok, %Record{data: ^critical_data, metadata: metadata} = stored} =
               MemoryStore.compare_and_swap_tainted(
                 "critical_marker",
                 "one",
                 :not_found,
                 critical_data,
                 taint: label
               )

      assert metadata["arbor_memory_authority"] == %{
               "mode" => "tainted_cas",
               "version" => 1
             }

      refute Map.has_key?(stored.data, "arbor_memory_authority")

      assert {:error, {:memory_store, :compatibility, :protected_authority}} =
               MemoryStore.persist(
                 "critical_marker",
                 "one",
                 %{"value" => "raw-overwrite"},
                 taint: %Taint{level: :trusted, source: "raw"}
               )

      assert :ok = MemoryStore.delete("critical_marker", "one")

      assert {:ok, value, :verified, ^stored, :namespaced} =
               MemoryStore.load_tainted_authoritative_with_status("critical_marker", "one")

      assert value.value == critical_data
      assert value.taint == label
    end

    test "security regression: delayed raw write cannot overwrite a completed authoritative CAS" do
      stop_supervised!(BufferedStore)
      backend_name = unique_name(:delayed_raw_backend)
      remote_store = unique_name(:delayed_raw_remote_store)
      physical_key = "raw_race:one"

      start_supervised!(%{
        id: backend_name,
        start: {Arbor.Persistence.QueryableStore.ETS, :start_link, [[name: backend_name]]}
      })

      start_supervised!(
        {BufferedStore,
         name: @store_name,
         backend: DelayedRawCasBackend,
         backend_opts: [test_pid: self()],
         collection: backend_name}
      )

      assert :ok = MemoryStore.persist("raw_race", "one", %{"source" => "baseline"})

      start_supervised!(%{
        id: remote_store,
        start:
          {BufferedStore, :start_link,
           [
             [
               name: remote_store,
               backend: DelayedRawCasBackend,
               backend_opts: [test_pid: self()],
               collection: backend_name
             ]
           ]}
      })

      raw_task =
        Task.async(fn ->
          MemoryStore.persist("raw_race", "one", %{"source" => "raw-delayed"})
        end)

      assert_receive {:raw_cas_blocked, raw_owner}, 1_000

      assert {:ok, %Record{} = baseline} =
               Persistence.buffered_store_authoritative_get(remote_store, physical_key)

      critical_data = %{"source" => "critical"}

      {:ok, envelope} =
        TaintModule.bind_durable_provenance(
          critical_data,
          %Taint{level: :hostile, source: "authoritative-winner"}
        )

      critical_metadata = %{
        "arbor_memory_authority" => %{"mode" => "tainted_cas", "version" => 1},
        "taint" => envelope
      }

      replacement = Record.update(baseline, critical_data, metadata: critical_metadata)

      assert {:ok, %Record{} = committed} =
               Persistence.buffered_store_acknowledged_compare_and_swap(
                 remote_store,
                 physical_key,
                 {:value, baseline},
                 replacement
               )

      send(raw_owner, :release_raw_cas)

      assert_receive {:raw_write_finished, ^raw_owner, _raw_result}, 1_000
      assert {:ok, _compatibility_result} = Task.yield(raw_task, 1_000)

      assert {:ok, ^committed} =
               Persistence.buffered_store_authoritative_get(remote_store, physical_key)

      assert {:error, :not_found} = BufferedStore.get(physical_key, name: @store_name)
    end

    test "security regression: critical logical keys are bounded before authority effects" do
      label = %Taint{level: :hostile, source: "bounded-key"}
      assert {:ok, []} = BufferedStore.authoritative_entries(name: @store_name)

      for invalid_key <- ["", "   ", <<255>>, String.duplicate("k", 1_025), :not_binary] do
        assert {:error, {:memory_store, :critical, :invalid_request}} =
                 MemoryStore.load_tainted_authoritative_with_status("bounded", invalid_key)

        assert {:error, {:memory_store, :critical, :invalid_request}} =
                 MemoryStore.compare_and_swap_tainted(
                   "bounded",
                   invalid_key,
                   :not_found,
                   %{"value" => "must-not-write"},
                   taint: label
                 )

        assert {:error, {:memory_store, :critical, :invalid_request}} =
                 MemoryStore.delete_tainted_authoritative("bounded", invalid_key)
      end

      assert {:ok, []} = BufferedStore.authoritative_entries(name: @store_name)

      maximum_key = String.duplicate("k", 1_024)

      assert {:ok, %Record{} = stored} =
               MemoryStore.compare_and_swap_tainted(
                 "bounded",
                 maximum_key,
                 :not_found,
                 %{"value" => "accepted"},
                 taint: label
               )

      assert {:ok, value, :verified, ^stored, :namespaced} =
               MemoryStore.load_tainted_authoritative_with_status("bounded", maximum_key)

      assert value.value == %{"value" => "accepted"}
      assert :ok = MemoryStore.delete_tainted_authoritative("bounded", maximum_key)
    end

    test "security regression: critical namespace grammar prevents composite-key aliases" do
      label = %Taint{level: :hostile, sensitivity: :restricted, source: "namespace-owner"}
      original = %{"owner" => "a", "logical_key" => "b:c"}

      assert {:ok, %Record{} = retained} =
               MemoryStore.compare_and_swap_tainted(
                 "a",
                 "b:c",
                 :not_found,
                 original,
                 taint: label
               )

      assert {:error, {:memory_store, :critical, :invalid_request}} =
               MemoryStore.compare_and_swap_tainted(
                 "a:b",
                 "c",
                 :not_found,
                 %{"owner" => "alias"},
                 taint: %Taint{level: :trusted, source: "alias"}
               )

      assert {:error, {:memory_store, :critical, :invalid_request}} =
               MemoryStore.load_tainted_authoritative_with_status("a:b", "c")

      assert {:error, {:memory_store, :critical, :invalid_request}} =
               MemoryStore.load_all_tainted_authoritative("a:b")

      assert {:error, {:memory_store, :critical, :invalid_request}} =
               MemoryStore.load_by_prefix_tainted_authoritative("a:b", "c")

      assert {:error, {:memory_store, :critical, :invalid_request}} =
               MemoryStore.delete_tainted_authoritative("a:b", "c")

      assert {:ok, ^retained} = BufferedStore.get("a:b:c", name: @store_name)

      assert {:ok, value, :verified, ^retained, :namespaced} =
               MemoryStore.load_tainted_authoritative_with_status("a", "b:c")

      assert value.value == original
      assert value.taint == label
    end

    test "malformed namespaced identity is rejected by load, CAS, and delete" do
      physical_key = "target:malformed-id"

      malformed =
        Record.new(physical_key, %{"value" => "foreign-id"}, id: "memory:foreign:malformed-id")

      assert :ok = BufferedStore.put(physical_key, malformed, name: @store_name)
      assert {:ok, retained} = BufferedStore.get(physical_key, name: @store_name)

      assert {:error, {:memory_store, :critical, :invalid_record}} =
               MemoryStore.load_tainted_authoritative_with_status("target", "malformed-id")

      assert {:error, {:memory_store, :critical, :invalid_record}} =
               MemoryStore.compare_and_swap_tainted(
                 "target",
                 "malformed-id",
                 malformed,
                 %{"value" => "replacement"},
                 taint: %Taint{level: :hostile}
               )

      assert {:error, {:memory_store, :critical, :invalid_record}} =
               MemoryStore.delete_tainted_authoritative("target", "malformed-id")

      assert {:ok, ^retained} = BufferedStore.get(physical_key, name: @store_name)
    end

    test "foreign bare row survives another namespace CAS, critical delete, and raw delete" do
      key = "shared-key"
      foreign = put_legacy_bare("foreign", key, %{"owner" => "foreign"}, %Taint{})
      label = %Taint{level: :untrusted, source: "target"}

      assert {:ok, %Record{}} =
               MemoryStore.compare_and_swap_tainted(
                 "target",
                 key,
                 :not_found,
                 %{"owner" => "target"},
                 taint: label
               )

      assert {:ok, ^foreign} = BufferedStore.get(key, name: @store_name)

      assert :ok = MemoryStore.delete_tainted_authoritative("target", key)
      assert {:ok, ^foreign} = BufferedStore.get(key, name: @store_name)

      assert :ok = MemoryStore.persist("target", key, %{"owner" => "raw-target"})
      assert :ok = MemoryStore.delete("target", key)
      assert {:ok, ^foreign} = BufferedStore.get(key, name: @store_name)
    end

    test "legacy bare baseline migrates with namespaced precedence and deferred cleanup" do
      namespace = "migration"
      key = "legacy"
      label = %Taint{level: :hostile, source: "legacy-hostile"}

      put_legacy_bare(namespace, key, %{"version" => 1}, label)

      assert {:ok, value, :verified, %Record{} = legacy_record, :legacy_bare} =
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)

      assert value.taint.level == :hostile

      assert {:ok, %Record{key: "migration:legacy"}} =
               MemoryStore.compare_and_swap_tainted(
                 namespace,
                 key,
                 legacy_record,
                 %{"version" => 2},
                 taint: label
               )

      assert {:ok, %Record{data: %{"version" => 1}}} =
               BufferedStore.get(key, name: @store_name)

      assert {:ok, %Record{data: %{"version" => 2}}} =
               BufferedStore.get("migration:legacy", name: @store_name)
    end

    test "security regression: legacy delete re-observes a concurrent namespaced migration" do
      stop_supervised!(BufferedStore)
      backend_name = unique_name(:legacy_delete_race_backend)
      namespace = "delete_race"
      key = "legacy"
      legacy_data = %{"version" => 1}
      migrated_data = %{"version" => 2}
      label = %Taint{level: :hostile, source: "concurrent-migration"}

      start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

      {:ok, legacy_envelope} = TaintModule.bind_durable_provenance(legacy_data, label)

      legacy =
        Record.new(key, legacy_data,
          id: "memory:#{namespace}:#{key}",
          metadata: %{"taint" => legacy_envelope}
        )

      assert :ok =
               Arbor.Persistence.QueryableStore.ETS.put(key, legacy, name: backend_name)

      start_supervised!(
        {BufferedStore,
         name: @store_name,
         backend: LegacyDeleteRaceBackend,
         backend_opts: [race_key: key, test_pid: self()],
         collection: backend_name}
      )

      delete_task = Task.async(fn -> MemoryStore.delete_tainted_authoritative(namespace, key) end)
      assert_receive {:legacy_delete_ready, backend_call}, 1_000

      namespaced_key = "#{namespace}:#{key}"
      {:ok, migrated_envelope} = TaintModule.bind_durable_provenance(migrated_data, label)

      migrated =
        Record.new(namespaced_key, migrated_data,
          id: "memory:#{namespaced_key}",
          metadata: %{"taint" => migrated_envelope}
        )

      assert {:ok, %Record{}} =
               Arbor.Persistence.QueryableStore.ETS.compare_and_swap(
                 namespaced_key,
                 :not_found,
                 migrated,
                 name: backend_name
               )

      send(backend_call, :continue_legacy_delete)
      assert :ok = Task.await(delete_task, 5_000)

      assert {:error, :not_found} =
               Arbor.Persistence.QueryableStore.ETS.get(key, name: backend_name)

      assert {:error, :not_found} =
               Arbor.Persistence.QueryableStore.ETS.get(namespaced_key, name: backend_name)
    end

    test "security regression: hanging legacy cleanup cannot delay a committed CAS receipt" do
      stop_supervised!(BufferedStore)
      backend_name = unique_name(:cleanup_failure_backend)
      counter = unique_name(:cleanup_failure_counter)
      namespace = "intent_retry"
      key = "intent:one"
      label = %Taint{level: :untrusted, source: "intent-transition"}
      legacy_data = %{"retry_count" => 0}
      replacement = %{"retry_count" => 1}

      start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

      start_supervised!(%{
        id: counter,
        start: {Agent, :start_link, [fn -> %{cas: 0, compare_delete: 0} end, [name: counter]]}
      })

      {:ok, legacy_envelope} = TaintModule.bind_durable_provenance(legacy_data, label)

      legacy =
        Record.new(key, legacy_data,
          id: "memory:#{namespace}:#{key}",
          metadata: %{"taint" => legacy_envelope}
        )

      assert :ok =
               Arbor.Persistence.QueryableStore.ETS.put(key, legacy, name: backend_name)

      start_supervised!(
        {BufferedStore,
         name: @store_name,
         backend: CleanupFailingNodeRestartBackend,
         backend_opts: [counter: counter, test_pid: self()],
         collection: backend_name}
      )

      assert {:ok, value, :verified, %Record{} = observed, :legacy_bare} =
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)

      assert value.value == legacy_data

      cas_task =
        Task.async(fn ->
          MemoryStore.compare_and_swap_tainted(
            namespace,
            key,
            observed,
            replacement,
            taint: label
          )
        end)

      assert {:ok, {:ok, %Record{generation: 1, revision: 1, data: ^replacement} = stored}} =
               Task.yield(cas_task, 2_000)

      refute_receive {:legacy_cleanup_started, _owner}
      assert %{cas: 1, compare_delete: 0} = Agent.get(counter, & &1)

      assert {:ok, authoritative, :verified, ^stored, :namespaced} =
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)

      assert authoritative.value == replacement

      assert {:ok, %Record{data: ^legacy_data}} =
               Arbor.Persistence.QueryableStore.ETS.get(key, name: backend_name)
    end

    test "security regression: MemoryStore preserves an ambiguous post-commit CAS outcome" do
      stop_supervised!(BufferedStore)
      backend_name = unique_name(:post_commit_failure_backend)
      counter = unique_name(:post_commit_failure_counter)

      start_supervised!({Arbor.Persistence.QueryableStore.ETS, name: backend_name})

      start_supervised!(%{
        id: counter,
        start: {Agent, :start_link, [fn -> 0 end, [name: counter]]}
      })

      start_supervised!(
        {BufferedStore,
         name: @store_name,
         backend: PostCommitRaisingNodeRestartBackend,
         backend_opts: [counter: counter],
         collection: backend_name}
      )

      assert {:error, {:memory_store, :critical, :outcome_unknown}} =
               MemoryStore.compare_and_swap_tainted(
                 "ambiguous",
                 "one",
                 :not_found,
                 %{"committed" => true},
                 taint: %Taint{level: :hostile, source: "ambiguous-backend"}
               )

      assert Agent.get(counter, & &1) == 1

      assert {:ok, %Record{data: %{"committed" => true}, revision: 1}} =
               Arbor.Persistence.QueryableStore.ETS.get("ambiguous:one", name: backend_name)
    end
  end

  describe "legacy taint compatibility helpers" do
    test "preserves all fields through the versionless compatibility format" do
      original = %Taint{
        level: :untrusted,
        sensitivity: :confidential,
        sanitizations: 0b00010011,
        confidence: :plausible,
        source: "external_api",
        chain: ["step1", "step2"]
      }

      persistable = TaintModule.to_persistable(original)
      restored = TaintModule.from_persistable(persistable)

      assert restored.level == original.level
      assert restored.sensitivity == original.sensitivity
      assert restored.sanitizations == original.sanitizations
      assert restored.confidence == original.confidence
      assert restored.source == original.source
      assert restored.chain == original.chain
    end

    test "persistable format uses string keys and survives JSON" do
      original = %Taint{level: :derived, sensitivity: :internal, confidence: :verified}
      persistable = TaintModule.to_persistable(original)

      assert is_binary(Map.keys(persistable) |> hd())
      assert persistable["taint_level"] == "derived"

      restored =
        persistable |> Jason.encode!() |> Jason.decode!() |> TaintModule.from_persistable()

      assert restored.level == original.level
      assert restored.sensitivity == original.sensitivity
      assert restored.confidence == original.confidence
    end
  end

  describe "embedding provenance" do
    test "invalid embedding taint returns a bounded error before spawning" do
      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} =
               MemoryStore.embed_async("embedding", "invalid", "sensitive-content",
                 agent_id: "agent_test",
                 taint: %Taint{level: :not_a_level}
               )
    end

    test "invalid embedding type returns a bounded error without raising" do
      assert {:error, {:memory_store, :invalid_request, :invalid_type}} =
               MemoryStore.embed_async("embedding", "invalid-type", "content",
                 agent_id: "agent_test",
                 type: %{}
               )

      assert {:error, {:memory_store, :invalid_request, :invalid_options}} =
               MemoryStore.embed_async("embedding", "bad-options", "content", %{type: :thought})
    end
  end

  defp put_raw(key, data, metadata) do
    record = Record.new(key, data, id: "memory:#{key}", metadata: metadata)
    assert :ok = BufferedStore.put(key, record, name: @store_name)
  end

  defp put_legacy_bare(namespace, key, data, taint) do
    {:ok, envelope} = TaintModule.bind_durable_provenance(data, taint)

    record =
      Record.new(key, data,
        id: "memory:#{namespace}:#{key}",
        metadata: %{"taint" => envelope}
      )

    assert :ok = BufferedStore.put(key, record, name: @store_name)
    assert {:ok, stored} = BufferedStore.get(key, name: @store_name)
    stored
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp unique_name(prefix) do
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end
end
