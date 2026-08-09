defmodule Arbor.Persistence.BufferedStoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Persistence.{Filter, Record}
  alias Arbor.Persistence.BufferedStore

  # In-memory Store backend for testing
  defmodule MemoryBackend do
    @moduledoc false
    use Agent

    @behaviour Arbor.Contracts.Persistence.Store

    def start_link(name) do
      Agent.start_link(fn -> %{} end, name: name)
    end

    @impl true
    def put(key, value, opts) do
      agent = agent_name(opts)
      Agent.update(agent, &Map.put(&1, key, value))
      :ok
    end

    @impl true
    def get(key, opts) do
      agent = agent_name(opts)

      case Agent.get(agent, &Map.get(&1, key)) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end

    @impl true
    def delete(key, opts) do
      agent = agent_name(opts)
      Agent.update(agent, &Map.delete(&1, key))
      :ok
    end

    @impl true
    def list(opts) do
      agent = agent_name(opts)
      keys = Agent.get(agent, &Map.keys/1)
      {:ok, keys}
    end

    @impl true
    def exists?(key, opts) do
      agent = agent_name(opts)
      Agent.get(agent, &Map.has_key?(&1, key))
    end

    defp agent_name(opts) do
      # Use the collection name as agent process name
      name = Keyword.get(opts, :name, "default")
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      String.to_atom("memory_backend_#{name}")
    end
  end

  defmodule DeleteFailingBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok

    @impl true
    def get(_key, _opts), do: {:error, :not_found}

    @impl true
    def delete(_key, _opts), do: {:error, :delete_failed}

    @impl true
    def list(_opts), do: {:ok, []}
  end

  describe "ETS-only mode (nil backend)" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_test_#{System.unique_integer([:positive])}"

      start_supervised!({BufferedStore, name: name, backend: nil})

      %{name: name}
    end

    test "put and get", %{name: name} do
      record = Record.new("key1", %{"value" => "hello"})

      assert :ok = BufferedStore.put("key1", record, name: name)

      assert {:ok, %Record{revision: 1, data: %{"value" => "hello"}} = stored} =
               BufferedStore.get("key1", name: name)

      assert stored.generation > 0
    end

    test "get returns not_found for missing key", %{name: name} do
      assert {:error, :not_found} = BufferedStore.get("missing", name: name)
    end

    test "delete removes key", %{name: name} do
      record = Record.new("key1", %{"value" => "hello"})

      :ok = BufferedStore.put("key1", record, name: name)
      assert :ok = BufferedStore.delete("key1", name: name)
      assert {:error, :not_found} = BufferedStore.get("key1", name: name)
    end

    test "list returns sorted keys", %{name: name} do
      :ok = BufferedStore.put("c", Record.new("c", %{}), name: name)
      :ok = BufferedStore.put("a", Record.new("a", %{}), name: name)
      :ok = BufferedStore.put("b", Record.new("b", %{}), name: name)

      assert {:ok, ["a", "b", "c"]} = BufferedStore.list(name: name)
    end

    test "list returns empty for fresh store", %{name: name} do
      assert {:ok, []} = BufferedStore.list(name: name)
    end

    test "exists? returns true for present key", %{name: name} do
      :ok = BufferedStore.put("key1", Record.new("key1", %{}), name: name)
      assert BufferedStore.exists?("key1", name: name)
    end

    test "exists? returns false for missing key", %{name: name} do
      refute BufferedStore.exists?("nope", name: name)
    end

    test "put overwrites existing key", %{name: name} do
      r1 = Record.new("key1", %{"v" => 1})
      r2 = Record.new("key1", %{"v" => 2})

      :ok = BufferedStore.put("key1", r1, name: name)
      :ok = BufferedStore.put("key1", r2, name: name)

      assert {:ok, %Record{revision: 2, data: %{"v" => 2}} = stored} =
               BufferedStore.get("key1", name: name)

      assert stored.generation > 0
    end

    test "security regression: put rejects Record physical-key mismatch and does not mutate",
         %{name: name} do
      # Physical store key must equal Record.key. A mismatched Record must not
      # land in owner authority, the public ETS projection, or any backend.
      mismatched = Record.new("other-key", %{"secret" => true})

      assert {:error, :key_mismatch} =
               BufferedStore.put("k", mismatched, name: name)

      assert {:error, :not_found} = BufferedStore.get("k", name: name)
      assert {:ok, []} = BufferedStore.list(name: name)

      # A valid owner put advances the private authoritative fence and projection.
      valid = Record.new("k", %{"ok" => true})
      assert :ok = BufferedStore.put("k", valid, name: name)

      assert {:ok, %Record{revision: 1, data: %{"ok" => true}} = stored} =
               BufferedStore.get("k", name: name)

      assert stored.generation > 0

      # A later mismatch still must not overwrite the valid entry.
      assert {:error, :key_mismatch} =
               BufferedStore.put("k", mismatched, name: name)

      assert {:ok, ^stored} = BufferedStore.get("k", name: name)
    end
  end

  describe "query operations" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_query_#{System.unique_integer([:positive])}"
      start_supervised!({BufferedStore, name: name, backend: nil})

      # Insert test records
      now = DateTime.utc_now()

      for i <- 1..5 do
        record =
          Record.new("item_#{i}", %{"type" => "test", "score" => i * 10},
            inserted_at: DateTime.add(now, i, :second)
          )

        :ok = BufferedStore.put("item_#{i}", record, name: name)
      end

      %{name: name}
    end

    test "query with filter", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "test")
      assert {:ok, results} = BufferedStore.query(filter, name: name)
      assert length(results) == 5
    end

    test "query with limit", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "test") |> Filter.limit(2)
      assert {:ok, results} = BufferedStore.query(filter, name: name)
      assert length(results) == 2
    end

    test "count", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "test")
      assert {:ok, 5} = BufferedStore.count(filter, name: name)
    end

    test "aggregate sum", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "test")
      assert {:ok, 150} = BufferedStore.aggregate(filter, :score, :sum, name: name)
    end

    test "aggregate avg", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "test")
      assert {:ok, 30.0} = BufferedStore.aggregate(filter, :score, :avg, name: name)
    end

    test "aggregate min", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "test")
      assert {:ok, 10} = BufferedStore.aggregate(filter, :score, :min, name: name)
    end

    test "aggregate max", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "test")
      assert {:ok, 50} = BufferedStore.aggregate(filter, :score, :max, name: name)
    end

    test "aggregate on empty results", %{name: name} do
      filter = Filter.new() |> Filter.where(:type, :eq, "nonexistent")
      assert {:ok, nil} = BufferedStore.aggregate(filter, :score, :sum, name: name)
    end
  end

  describe "with backend" do
    setup do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_backend_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})

      start_supervised!(
        {BufferedStore,
         name: name,
         backend: MemoryBackend,
         backend_opts: [],
         write_mode: :sync,
         collection: to_string(name)}
      )

      %{name: name, backend_agent: backend_agent}
    end

    test "put writes to both ETS and backend", %{name: name, backend_agent: agent} do
      record = Record.new("key1", %{"v" => 1})
      :ok = BufferedStore.put("key1", record, name: name)

      # ETS has it
      assert {:ok, ^record} = BufferedStore.get("key1", name: name)

      # Backend has it
      backend_data = Agent.get(agent, & &1)
      assert Map.has_key?(backend_data, "key1")
    end

    test "security regression: key_mismatch does not mutate ETS or backend",
         %{name: name, backend_agent: agent} do
      mismatched = Record.new("other", %{"v" => 1})

      assert {:error, :key_mismatch} =
               BufferedStore.put("key1", mismatched, name: name)

      assert {:error, :not_found} = BufferedStore.get("key1", name: name)
      assert Agent.get(agent, & &1) == %{}
    end

    test "delete removes from both ETS and backend", %{name: name, backend_agent: agent} do
      record = Record.new("key1", %{"v" => 1})
      :ok = BufferedStore.put("key1", record, name: name)
      :ok = BufferedStore.delete("key1", name: name)

      assert {:error, :not_found} = BufferedStore.get("key1", name: name)

      backend_data = Agent.get(agent, & &1)
      refute Map.has_key?(backend_data, "key1")
    end
  end

  describe "backend load on init" do
    test "loads existing data from backend into ETS" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_preload_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})

      # Pre-populate backend
      record = Record.new("preloaded", %{"hello" => "world"})
      opts = [name: to_string(name)]
      MemoryBackend.put("preloaded", record, opts)

      # Start BufferedStore — should load from backend
      start_supervised!(
        {BufferedStore,
         name: name, backend: MemoryBackend, write_mode: :sync, collection: to_string(name)}
      )

      # Should be available via ETS immediately
      assert {:ok, ^record} = BufferedStore.get("preloaded", name: name)
    end
  end

  describe "graceful degradation" do
    test "starts successfully even when backend fails to list" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_fail_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore,
         name: name, backend: Arbor.Persistence.TestBackends.FailingStore, write_mode: :sync}
      )

      # Store works in ETS-only mode
      record = Record.new("key1", %{"v" => 1})
      assert :ok = BufferedStore.put("key1", record, name: name)
      assert {:ok, ^record} = BufferedStore.get("key1", name: name)
    end

    test "put succeeds even when backend write fails" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_fail_put_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore,
         name: name, backend: Arbor.Persistence.TestBackends.FailingStore, write_mode: :sync}
      )

      record = Record.new("key1", %{"v" => 1})
      # Should succeed — backend failure is logged but doesn't fail the call
      assert :ok = BufferedStore.put("key1", record, name: name)
      assert {:ok, ^record} = BufferedStore.get("key1", name: name)
    end
  end

  describe "backend acknowledgement" do
    test "durability regression: failed put is returned without mutating the cache" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_backend_ack_put_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore,
         name: name,
         backend: Arbor.Persistence.TestBackends.FailingStore,
         write_mode: :sync,
         ack_mode: :backend}
      )

      record = Record.new("key1", %{"v" => 1})

      assert {:error, :write_failed} = BufferedStore.put("key1", record, name: name)
      assert {:error, :not_found} = BufferedStore.get("key1", name: name)
      assert Process.alive?(Process.whereis(name))
    end

    test "durability regression: failed delete preserves the acknowledged cache entry" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_backend_ack_delete_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore,
         name: name, backend: DeleteFailingBackend, write_mode: :sync, ack_mode: :backend}
      )

      record = Record.new("key1", %{"v" => 1})
      assert :ok = BufferedStore.put("key1", record, name: name)

      assert {:error, :delete_failed} = BufferedStore.delete("key1", name: name)
      assert {:ok, ^record} = BufferedStore.get("key1", name: name)
    end

    test "backend acknowledgement rejects writes when no backend is configured" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_backend_ack_nil_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore, name: name, backend: nil, write_mode: :sync, ack_mode: :backend}
      )

      record = Record.new("key1", %{"v" => 1})

      assert {:error, :backend_not_configured} =
               BufferedStore.put("key1", record, name: name)

      assert {:error, :not_found} = BufferedStore.get("key1", name: name)
    end
  end

  describe "async write mode" do
    test "put returns immediately in async mode" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_async_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})

      start_supervised!(
        {BufferedStore,
         name: name, backend: MemoryBackend, write_mode: :async, collection: to_string(name)}
      )

      record = Record.new("key1", %{"v" => 1})
      assert :ok = BufferedStore.put("key1", record, name: name)

      # ETS is immediate
      assert {:ok, ^record} = BufferedStore.get("key1", name: name)

      # Backend write happens async — give it a moment
      Process.sleep(50)
      backend_data = Agent.get(backend_agent, & &1)
      assert Map.has_key?(backend_data, "key1")
    end
  end

  # ────────────────────────────────────────────────────────────────────────
  # Phase 1 resilience regression: BufferedStore must not crash when the
  # backend exits, throws, or raises during init / read / write.
  #
  # Before this fix, the `rescue` blocks caught Elixir exceptions but not
  # :exit signals — so when the Ecto Repo wasn't started or the Sandbox
  # wasn't checked out, BufferedStore init crashed (and any non-database
  # test using a BufferedStore that happened to be configured for Postgres
  # would fail with a cascading error). The fix adds matching `catch :exit`
  # and `catch :throw` clauses so the documented contract
  # ("backend failure → start empty") actually holds for the failure mode
  # that bites in practice.
  #
  # See: .arbor/roadmap/2-planned/buffered-store-test-infrastructure.md
  # ────────────────────────────────────────────────────────────────────────

  defmodule CrashingBackend do
    @moduledoc false
    # A Store backend that exits on every call. Simulates the Repo-not-started
    # / Sandbox-not-checked-out failure mode that crashes through `rescue`.

    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: exit(:simulated_backend_unavailable)

    @impl true
    def get(_key, _opts), do: exit(:simulated_backend_unavailable)

    @impl true
    def delete(_key, _opts), do: exit(:simulated_backend_unavailable)

    @impl true
    def list(_opts), do: exit(:simulated_backend_unavailable)

    @impl true
    def exists?(_key, _opts), do: exit(:simulated_backend_unavailable)

    @impl true
    def query(_filter, _opts), do: exit(:simulated_backend_unavailable)

    @impl true
    def count(_filter, _opts), do: exit(:simulated_backend_unavailable)

    @impl true
    def aggregate(_filter, _field, _op, _opts), do: exit(:simulated_backend_unavailable)
  end

  describe "resilience regression: backend exits/throws don't crash the store" do
    test "init survives a backend whose list/1 exits" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_crash_init_#{System.unique_integer([:positive])}"

      # Without the fix this start_supervised! call returns {:error, ...}
      # because BufferedStore init/1 crashes when load_from_backend's
      # unrescued :exit propagates. With the fix it starts cleanly.
      assert {:ok, pid} =
               start_supervised(
                 {BufferedStore,
                  name: name, backend: CrashingBackend, collection: to_string(name)},
                 id: name
               )

      assert is_pid(pid) and Process.alive?(pid),
             """
             RESILIENCE REGRESSION: BufferedStore did not start with a
             backend whose list/1 exits during init. This is the exact
             failure mode the planned doc identified — an Ecto Repo
             that's not started, or a Sandbox not checked out, signals
             via :exit (not via a raised exception), and without a
             matching catch clause it crashes init/1.

             See: .arbor/roadmap/2-planned/buffered-store-test-infrastructure.md
             """

      # ETS is reachable (the moduledoc contract: "start empty").
      assert {:ok, []} = BufferedStore.list(name: name)
    end

    test "sync put survives a backend whose put/3 exits" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_crash_put_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        start_supervised(
          {BufferedStore,
           name: name, backend: CrashingBackend, write_mode: :sync, collection: to_string(name)},
          id: name
        )

      record = Record.new("key1", %{"v" => 1})

      # Without the fix, the backend's :exit propagates through the
      # sync put path and crashes the BufferedStore GenServer (so this
      # call would either crash the calling test process or never return).
      assert :ok = BufferedStore.put("key1", record, name: name)

      # ETS got the write even though the backend didn't.
      assert {:ok, ^record} = BufferedStore.get("key1", name: name)
    end

    test "sync delete survives a backend whose delete/2 exits" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_crash_delete_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        start_supervised(
          {BufferedStore,
           name: name, backend: CrashingBackend, write_mode: :sync, collection: to_string(name)},
          id: name
        )

      # Pre-seed ETS via the public API — the previous test proves sync
      # put doesn't crash.
      :ok = BufferedStore.put("key1", Record.new("key1", %{}), name: name)
      assert :ok = BufferedStore.delete("key1", name: name)
      assert {:error, :not_found} = BufferedStore.get("key1", name: name)
    end
  end

  describe "backend_healthy?/1" do
    test "returns true with no backend (ETS-only)" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_health_nil_#{System.unique_integer([:positive])}"

      start_supervised!({BufferedStore, name: name}, id: name)

      assert BufferedStore.backend_healthy?(name: name) == true
    end

    test "returns true with a reachable backend" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_health_ok_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})

      start_supervised!(
        {BufferedStore, name: name, backend: MemoryBackend, collection: to_string(name)},
        id: name
      )

      assert BufferedStore.backend_healthy?(name: name) == true
    end

    test "returns false with a backend whose list/1 exits" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_health_crash_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore, name: name, backend: CrashingBackend, collection: to_string(name)},
        id: name
      )

      assert BufferedStore.backend_healthy?(name: name) == false
    end
  end

  defmodule QueryMemoryBackend do
    @moduledoc false
    use Agent
    @behaviour Arbor.Contracts.Persistence.Store

    def start_link(name), do: Agent.start_link(fn -> %{} end, name: name)

    def seed(agent, entries) when is_map(entries) do
      Agent.update(agent, fn _ -> entries end)
    end

    @impl true
    def put(key, value, opts) do
      Agent.update(agent_name(opts), &Map.put(&1, key, value))
      :ok
    end

    @impl true
    def get(key, opts) do
      case Agent.get(agent_name(opts), &Map.get(&1, key)) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end

    @impl true
    def delete(key, opts) do
      Agent.update(agent_name(opts), &Map.delete(&1, key))
      :ok
    end

    @impl true
    def list(opts) do
      keys = Agent.get(agent_name(opts), &Map.keys/1)
      {:ok, keys}
    end

    @impl true
    def exists?(key, opts), do: Agent.get(agent_name(opts), &Map.has_key?(&1, key))

    @impl true
    def query(%Filter{} = filter, opts) do
      records =
        agent_name(opts)
        |> Agent.get(&Map.values/1)
        |> Enum.filter(&match?(%Record{}, &1))

      {:ok, Filter.apply(filter, records)}
    end

    defp agent_name(opts) do
      name = Keyword.get(opts, :name, "default")
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      String.to_atom("query_memory_backend_#{name}")
    end
  end

  defmodule InjectedFailureBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @table :buffered_store_hydration_failure_inject

    def install do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ets.insert(@table, {:mode, :ok})
      :ok
    end

    def fail_list, do: :ets.insert(@table, {:mode, :fail_list})
    def fail_get, do: :ets.insert(@table, {:mode, :fail_get})
    def fail_query, do: :ets.insert(@table, {:mode, :fail_query})
    def seed(entries), do: :ets.insert(@table, {:entries, entries})

    defp mode do
      case :ets.lookup(@table, :mode) do
        [{:mode, mode}] -> mode
        _ -> :ok
      end
    end

    defp entries do
      case :ets.lookup(@table, :entries) do
        [{:entries, entries}] -> entries
        _ -> %{}
      end
    end

    @impl true
    def put(key, value, _opts) do
      :ets.insert(@table, {:entries, Map.put(entries(), key, value)})
      :ok
    end

    @impl true
    def get(key, _opts) do
      case mode() do
        :fail_get ->
          {:error, :injected_get_failure}

        _ ->
          case Map.fetch(entries(), key) do
            {:ok, value} -> {:ok, value}
            :error -> {:error, :not_found}
          end
      end
    end

    @impl true
    def delete(key, _opts) do
      :ets.insert(@table, {:entries, Map.delete(entries(), key)})
      :ok
    end

    @impl true
    def list(_opts) do
      case mode() do
        :fail_list -> {:error, :injected_list_failure}
        _ -> {:ok, Map.keys(entries())}
      end
    end

    @impl true
    def exists?(key, _opts), do: Map.has_key?(entries(), key)
  end

  defmodule InjectedQueryFailureBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @table :buffered_store_query_hydration_failure_inject

    def install do
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:named_table, :public, :set])
        _ -> :ok
      end

      :ets.insert(@table, {:mode, :ok})
      :ok
    end

    def fail_query, do: :ets.insert(@table, {:mode, :fail_query})
    def seed(entries), do: :ets.insert(@table, {:entries, entries})

    defp mode do
      case :ets.lookup(@table, :mode) do
        [{:mode, mode}] -> mode
        _ -> :ok
      end
    end

    defp entries do
      case :ets.lookup(@table, :entries) do
        [{:entries, entries}] -> entries
        _ -> %{}
      end
    end

    @impl true
    def put(key, value, _opts) do
      :ets.insert(@table, {:entries, Map.put(entries(), key, value)})
      :ok
    end

    @impl true
    def get(key, _opts) do
      case Map.fetch(entries(), key) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :not_found}
      end
    end

    @impl true
    def delete(key, _opts) do
      :ets.insert(@table, {:entries, Map.delete(entries(), key)})
      :ok
    end

    @impl true
    def list(_opts), do: {:ok, Map.keys(entries())}

    @impl true
    def exists?(key, _opts), do: Map.has_key?(entries(), key)

    @impl true
    def query(_filter, _opts) do
      case mode() do
        :fail_query -> {:error, :injected_query_failure}
        _ -> {:ok, Map.values(entries())}
      end
    end
  end

  describe "startup hydration limit and status" do
    test "custom hydration_limit above 10_000 succeeds while public authoritative stays capped" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_hydrate_high_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})

      total = 10_001

      for i <- 1..total do
        key = "k-#{i}"
        :ok = MemoryBackend.put(key, Record.new(key, %{"i" => i}), name: to_string(name))
      end

      start_supervised!(
        {BufferedStore,
         name: name, backend: MemoryBackend, collection: to_string(name), hydration_limit: 20_000},
        id: name
      )

      assert {:ok,
              %{
                status: :ready,
                loaded_count: ^total,
                configured_limit: 20_000,
                reason: :ok
              }} = BufferedStore.hydration_status(name: name)

      assert {:ok,
              %{
                status: :ready,
                loaded_count: ^total,
                configured_limit: 20_000,
                reason: :ok
              }} = Arbor.Persistence.buffered_store_hydration_status(name)

      assert {:ok, keys} = BufferedStore.list(name: name)
      assert length(keys) == total

      assert {:error, :inventory_limit_exceeded} = BufferedStore.authoritative_list(name: name)
      assert {:error, :unsupported} = BufferedStore.authoritative_entries(name: name)
    end

    test "default hydration_limit leaves empty ETS and failed status above 10_000" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_hydrate_default_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})

      for i <- 1..10_001 do
        key = "k-#{i}"
        :ok = MemoryBackend.put(key, Record.new(key, %{"i" => i}), name: to_string(name))
      end

      start_supervised!(
        {BufferedStore, name: name, backend: MemoryBackend, collection: to_string(name)},
        id: name
      )

      assert {:ok,
              %{
                status: :failed,
                loaded_count: 0,
                configured_limit: 10_000,
                reason: :inventory_limit_exceeded
              }} = BufferedStore.hydration_status(name: name)

      assert {:ok, []} = BufferedStore.list(name: name)
    end

    test "CRUD backend get failure leaves empty ETS and failed status" do
      InjectedFailureBackend.install()

      entries =
        for i <- 1..3, into: %{} do
          key = "k-#{i}"
          {key, Record.new(key, %{"i" => i})}
        end

      InjectedFailureBackend.seed(entries)
      InjectedFailureBackend.fail_get()

      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_hydrate_get_fail_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore, name: name, backend: InjectedFailureBackend, collection: to_string(name)},
        id: name
      )

      assert {:ok,
              %{
                status: :failed,
                loaded_count: 0,
                reason: :incomplete_inventory
              }} = BufferedStore.hydration_status(name: name)

      assert {:ok, []} = BufferedStore.list(name: name)
    end

    test "query backend failure leaves empty ETS and failed status" do
      InjectedQueryFailureBackend.install()

      entries =
        for i <- 1..2, into: %{} do
          key = "k-#{i}"
          {key, Record.new(key, %{"i" => i})}
        end

      InjectedQueryFailureBackend.seed(entries)
      InjectedQueryFailureBackend.fail_query()

      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_hydrate_query_fail_#{System.unique_integer([:positive])}"

      start_supervised!(
        {BufferedStore,
         name: name, backend: InjectedQueryFailureBackend, collection: to_string(name)},
        id: name
      )

      assert {:ok,
              %{
                status: :failed,
                loaded_count: 0,
                reason: :backend_unavailable
              }} = BufferedStore.hydration_status(name: name)

      assert {:ok, []} = BufferedStore.list(name: name)
    end

    test "query backend hydrates above 10_000 while authoritative entries stay capped" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_hydrate_query_ok_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("query_memory_backend_#{name}")

      start_supervised!({QueryMemoryBackend, backend_agent})

      total = 10_001

      entries =
        for i <- 1..total, into: %{} do
          key = "k-#{i}"
          {key, Record.new(key, %{"i" => i})}
        end

      QueryMemoryBackend.seed(backend_agent, entries)

      start_supervised!(
        {BufferedStore,
         name: name,
         backend: QueryMemoryBackend,
         collection: to_string(name),
         hydration_limit: 20_000},
        id: name
      )

      assert {:ok,
              %{
                status: :ready,
                loaded_count: ^total,
                configured_limit: 20_000,
                reason: :ok
              }} =
               BufferedStore.hydration_status(name: name)

      assert {:ok, keys} = BufferedStore.list(name: name)
      assert length(keys) == total
      assert {:error, :inventory_limit_exceeded} = BufferedStore.authoritative_entries(name: name)
    end

    test "non-Record values hydrate when key_mismatch? is false" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_hydrate_plain_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})
      :ok = MemoryBackend.put("plain", %{"v" => 1}, name: to_string(name))

      start_supervised!(
        {BufferedStore, name: name, backend: MemoryBackend, collection: to_string(name)},
        id: name
      )

      assert {:ok, %{status: :ready, loaded_count: 1}} =
               BufferedStore.hydration_status(name: name)

      assert {:ok, %{"v" => 1}} = BufferedStore.get("plain", name: name)
    end

    test "mismatched Record fails hydration closed with empty ETS" do
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      name = :"buffered_hydrate_mismatch_#{System.unique_integer([:positive])}"
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      backend_agent = String.to_atom("memory_backend_#{name}")

      start_supervised!({MemoryBackend, backend_agent})

      bad = %Record{Record.new("other", %{"v" => 1}) | key: "other"}
      :ok = MemoryBackend.put("stored-key", bad, name: to_string(name))

      start_supervised!(
        {BufferedStore, name: name, backend: MemoryBackend, collection: to_string(name)},
        id: name
      )

      assert {:ok,
              %{
                status: :failed,
                loaded_count: 0,
                reason: :invalid_backend_record
              }} = BufferedStore.hydration_status(name: name)

      assert {:ok, []} = BufferedStore.list(name: name)
    end
  end
end
