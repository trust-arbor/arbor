defmodule Arbor.Memory.MemoryStoreTaintTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Contracts.Security.{Taint, TaintedValue}
  alias Arbor.Memory.MemoryStore
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
    def compare_and_delete(_key, _expected, opts) do
      call =
        Agent.get_and_update(
          Keyword.fetch!(opts, :counter),
          fn state ->
            next = state.compare_delete + 1
            {next, %{state | compare_delete: next}}
          end
        )

      if call == 1,
        do: raise("forced cleanup exception"),
        else: {:error, :forced_cleanup_failure}
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
                 taint: %Taint{level: :derived}
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

      error = MemoryStore.persist_async("async", "malformed", data, taint: malformed)

      assert {:error, {:memory_store, :invalid_durable_provenance, _reason}} = error
      refute inspect(error) =~ "async-do-not-leak"
      assert {:error, :not_found} = BufferedStore.get("async:malformed", name: @store_name)
    end

    test "persist_async keeps valid writes fire-and-forget" do
      assert :ok =
               MemoryStore.persist_async("async", "valid", %{"value" => "written"},
                 taint: %Taint{level: :derived}
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

    test "fails bounded when the authoritative inventory exceeds its cap" do
      for index <- 1..10_001 do
        key = "other:#{index}"

        assert :ok =
                 BufferedStore.put(key, Record.new(key, %{}, id: "memory:#{key}"),
                   name: @store_name
                 )
      end

      assert {:error, {:memory_store, :critical, :inventory_limit_exceeded}} =
               MemoryStore.load_all_tainted_authoritative("inventory")
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

    test "legacy bare baseline migrates through namespaced not-found CAS and owned cleanup" do
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

      assert {:error, :not_found} = BufferedStore.get(key, name: @store_name)

      assert {:ok, %Record{data: %{"version" => 2}}} =
               BufferedStore.get("migration:legacy", name: @store_name)
    end

    test "security regression: committed CAS succeeds once when legacy cleanup is deferred" do
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
         backend_opts: [counter: counter],
         collection: backend_name}
      )

      assert {:ok, value, :verified, %Record{} = observed, :legacy_bare} =
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)

      assert value.value == legacy_data

      assert {:ok, %Record{generation: 1, revision: 1, data: ^replacement} = stored} =
               MemoryStore.compare_and_swap_tainted(
                 namespace,
                 key,
                 observed,
                 replacement,
                 taint: label
               )

      assert %{cas: 1, compare_delete: 1} = Agent.get(counter, & &1)

      assert {:ok, authoritative, :verified, ^stored, :namespaced} =
               MemoryStore.load_tainted_authoritative_with_status(namespace, key)

      assert authoritative.value == replacement

      assert {:ok, %Record{data: ^legacy_data}} =
               Arbor.Persistence.QueryableStore.ETS.get(key, name: backend_name)
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
