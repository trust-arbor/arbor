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
      assert {:ok, ^record} = BufferedStore.get("key1", name: name)
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

      assert {:ok, ^r2} = BufferedStore.get("key1", name: name)
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
end
