defmodule Arbor.Security.AuthorityStoreTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.{Record, Revision}
  alias Arbor.Security.AuthorityStore
  alias Arbor.Security.Store.JSONFile

  @json_fixture_prefix "authority_store_"
  @json_fixture_name ~r/^authority_store_[1-9][0-9]*$/

  defmodule OverflowBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: :ok
    def get(_key, opts), do: send(opts[:test_pid], :overflow_get) && {:error, :not_found}
    def delete(_key, _opts), do: :ok
    def list(_opts), do: {:ok, ["a", "b", "c"]}
    def durability_class(_opts), do: :process_lifetime
  end

  defmodule MalformedBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: :not_ok
    def get(_key, _opts), do: {:ok, :not_a_record}
    def delete(_key, _opts), do: {:ok, :not_deleted}
    def list(_opts), do: {:ok, ["valid", 42]}
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:ok, :not_a_record}
    def compare_and_delete(_key, _expected, _opts), do: {:ok, :not_deleted}
    def durability_class(_opts), do: :process_lifetime
  end

  defmodule RaisingBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: raise("secret put path /tmp/private")
    def get(_key, _opts), do: exit({:secret_path, "/tmp/private"})
    def delete(_key, _opts), do: throw({:secret_value, "value"})
    def list(_opts), do: raise("secret list path /tmp/private")
    def compare_and_swap(_key, _expected, _replacement, _opts), do: exit(:secret)
    def compare_and_delete(_key, _expected, _opts), do: throw(:secret)
    def durability_class(_opts), do: :process_lifetime
  end

  defmodule MissingCasBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: :ok
    def get(_key, _opts), do: {:error, :not_found}
    def delete(_key, _opts), do: :ok
    def list(_opts), do: {:ok, []}
    def durability_class(_opts), do: :process_lifetime
  end

  defmodule HydratedMalformedBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    def put(_key, _value, _opts), do: :not_ok
    def get(_key, _opts), do: {:ok, :not_a_record}
    def delete(_key, _opts), do: {:ok, :not_deleted}
    def list(_opts), do: {:ok, []}
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:ok, :not_a_record}
    def compare_and_delete(_key, _expected, _opts), do: {:ok, :not_deleted}
    def durability_class(_opts), do: :process_lifetime
  end

  defmodule MissingDeleteBackend do
    def put(_key, _value, _opts), do: :ok
    def get(_key, _opts), do: {:error, :not_found}
    def list(_opts), do: {:ok, []}
  end

  defmodule ObservedBackend do
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Contracts.Persistence.{Record, Revision}

    def put(key, %Record{} = replacement, opts) do
      send(opts[:test_pid], {:backend_put, key})

      Agent.get_and_update(opts[:backend_agent], fn entries ->
        current = Map.get(entries, key, :absent)

        case Revision.apply_put(current, replacement) do
          {:ok, stored} -> {:ok, Map.put(entries, key, stored)}
          {:error, reason} -> {{:error, reason}, entries}
        end
      end)
    end

    def get(key, opts) do
      send(opts[:test_pid], {:backend_get, key})

      Agent.get(opts[:backend_agent], fn entries ->
        entries
        |> Map.get(key, :absent)
        |> Revision.live_value()
        |> case do
          {:ok, record} -> {:ok, record}
          :not_found -> {:error, :not_found}
        end
      end)
    end

    def delete(key, opts) do
      send(opts[:test_pid], {:backend_delete, key})
      Agent.update(opts[:backend_agent], &Map.delete(&1, key))
    end

    def list(opts) do
      keys = Agent.get(opts[:backend_agent], &Map.keys/1)
      send(opts[:test_pid], {:backend_list, Enum.sort(keys)})
      {:ok, keys}
    end

    def durability_class(_opts), do: :process_lifetime
  end

  defmodule LargeBoundBackend do
    @behaviour Arbor.Contracts.Persistence.Store
    @behaviour Arbor.Security.Store.BoundedInventory

    @impl true
    def put(_key, _value, _opts), do: :ok

    @impl true
    def get(_key, _opts), do: {:error, :not_found}

    @impl true
    def delete(_key, _opts), do: :ok

    @impl true
    def list(opts), do: send(opts[:test_pid], :unbounded_list) && {:ok, []}

    @impl Arbor.Security.Store.BoundedInventory
    def bounded_list(limit, opts) do
      send(opts[:test_pid], {:bounded_list, limit})
      {:ok, []}
    end

    @impl true
    def durability_class(_opts), do: :process_lifetime
  end

  describe "default JSONFile backend" do
    setup do
      fixture_name = @json_fixture_prefix <> Integer.to_string(System.unique_integer([:positive]))
      base_dir = Path.join(System.tmp_dir!(), fixture_name)

      name = unique_name(:authority_json)

      start_supervised!(
        {AuthorityStore,
         name: name,
         namespace: "authority-json",
         backend_opts: [base_dir: base_dir],
         hydration_limit: 20}
      )

      on_exit(fn -> remove_json_fixture!(base_dir) end)
      %{base_dir: base_dir, name: name}
    end

    test "durable CRUD, bounded inventory, CAS, and compare-delete use Store shapes", %{
      base_dir: base_dir,
      name: name
    } do
      assert AuthorityStore.durability_class(name: name) == :node_restart

      assert AuthorityStore.hydration_status(name: name) ==
               {:ok,
                %{
                  status: :ready,
                  loaded_count: 0,
                  configured_limit: 20,
                  reason: :ok
                }}

      assert :ok = AuthorityStore.put("plain", Record.new("plain", %{"v" => 1}), name: name)

      assert {:ok, %Record{generation: 1, revision: 1}} =
               AuthorityStore.authoritative_get("plain", name: name)

      assert {:ok, inserted} =
               AuthorityStore.acknowledged_compare_and_swap(
                 "cas",
                 :not_found,
                 Record.new("cas", %{"v" => 1}),
                 name: name
               )

      assert {:ok, updated} =
               AuthorityStore.acknowledged_compare_and_swap(
                 "cas",
                 {:value, inserted},
                 Record.update(inserted, %{"v" => 2}),
                 name: name
               )

      assert updated.generation == inserted.generation
      assert updated.revision == inserted.revision + 1

      assert {:error, :conflict} =
               AuthorityStore.acknowledged_compare_and_swap(
                 "cas",
                 {:value, inserted},
                 Record.update(inserted, %{"v" => 3}),
                 name: name
               )

      assert {:ok, keys} = AuthorityStore.authoritative_list(name: name)
      assert Enum.sort(keys) == ["cas", "plain"]
      assert {:ok, entries} = AuthorityStore.authoritative_entries(name: name)
      assert Enum.sort(Enum.map(entries, &elem(&1, 0))) == ["cas", "plain"]

      assert :ok = AuthorityStore.acknowledged_compare_and_delete("cas", updated, name: name)
      assert {:error, :not_found} = AuthorityStore.authoritative_get("cas", name: name)

      assert {:error, :conflict} =
               AuthorityStore.acknowledged_compare_and_delete("cas", updated, name: name)

      assert {:ok, reinserted} =
               AuthorityStore.acknowledged_compare_and_swap(
                 "cas",
                 :not_found,
                 Record.new("cas", %{"v" => 4}),
                 name: name
               )

      assert reinserted.generation == updated.generation + 1
      assert reinserted.revision == 1

      assert {:error, :conflict} =
               AuthorityStore.acknowledged_compare_and_swap(
                 "cas",
                 {:value, updated},
                 Record.update(updated, %{"v" => 5}),
                 name: name
               )

      assert :ok = AuthorityStore.acknowledged_delete("plain", name: name)
      assert :ok = AuthorityStore.acknowledged_delete("cas", name: name)
      assert {:ok, []} = AuthorityStore.authoritative_list(name: name)

      assert {:error, :inventory_limit_exceeded} =
               JSONFile.bounded_list(1, name: "authority-json", base_dir: base_dir)

      assert {:ok, []} =
               JSONFile.bounded_list(2, name: "authority-json", base_dir: base_dir)
    end
  end

  test "explicit nil backend is owner-private and process-lifetime durable" do
    name = unique_name(:authority_ephemeral)
    pid = start_supervised!({AuthorityStore, name: name, backend: nil, namespace: "ephemeral"})

    assert AuthorityStore.durability_class(name: name) == :process_lifetime

    assert AuthorityStore.hydration_status(name: name) ==
             {:ok, %{status: :ready, loaded_count: 0, configured_limit: 10_000, reason: :ok}}

    assert {:ok, stored} =
             AuthorityStore.acknowledged_put("k", Record.new("k", %{"v" => 1}), name: name)

    assert stored.generation > 0
    assert stored.revision == 1
    assert {:ok, [{"k", ^stored}]} = AuthorityStore.authoritative_entries(name: name)

    assert :ok = AuthorityStore.acknowledged_delete("k", name: name)
    assert :sys.get_state(pid).entries == %{}

    assert {:ok, reinserted} =
             AuthorityStore.acknowledged_compare_and_swap(
               "k",
               :not_found,
               Record.new("k", %{"v" => 2}),
               name: name
             )

    assert reinserted.generation > stored.generation
    assert reinserted.revision == 1

    assert {:error, :conflict} =
             AuthorityStore.acknowledged_compare_and_swap(
               "k",
               {:value, stored},
               Record.update(stored, %{"v" => 3}),
               name: name
             )

    state = :sys.get_state(pid)
    assert state.entries == %{"k" => reinserted}
    refute Map.has_key?(state, :table)
  end

  test "ephemeral inventory limit rejects new put and CAS without partial mutation" do
    name = unique_name(:authority_ephemeral_limit)
    pid = start_supervised!({AuthorityStore, name: name, backend: nil, hydration_limit: 1})

    assert {:ok, stored} =
             AuthorityStore.acknowledged_put("existing", Record.new("existing"), name: name)

    assert {:error, :inventory_limit_exceeded} =
             AuthorityStore.put("put-overflow", Record.new("put-overflow"), name: name)

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get("put-overflow", name: name)

    assert :sys.get_state(pid).entries == %{"existing" => stored}

    assert {:error, :inventory_limit_exceeded} =
             AuthorityStore.acknowledged_compare_and_swap(
               "cas-overflow",
               :not_found,
               Record.new("cas-overflow"),
               name: name
             )

    assert {:error, :not_found} =
             AuthorityStore.authoritative_get("cas-overflow", name: name)

    assert :sys.get_state(pid).entries == %{"existing" => stored}

    assert {:ok, updated} =
             AuthorityStore.acknowledged_put(
               "existing",
               Record.update(stored, %{"updated" => true}),
               name: name
             )

    assert updated.generation == stored.generation
    assert updated.revision == stored.revision + 1
    assert :sys.get_state(pid).entries == %{"existing" => updated}
  end

  test "explicit hydration limit above the default is accepted without preallocation" do
    name = unique_name(:authority_large_limit)
    pid = start_supervised!({AuthorityStore, name: name, backend: nil, hydration_limit: 100_000})

    assert AuthorityStore.hydration_status(name: name) ==
             {:ok, %{status: :ready, loaded_count: 0, configured_limit: 100_000, reason: :ok}}

    assert :sys.get_state(pid).entries == %{}
  end

  test "large durable hydration uses the explicit backend bound without preallocation" do
    name = unique_name(:authority_large_bounded)

    start_supervised!(
      {AuthorityStore,
       name: name,
       backend: LargeBoundBackend,
       backend_opts: [test_pid: self()],
       hydration_limit: 100_000}
    )

    assert_received {:bounded_list, 100_000}
    refute_received :unbounded_list

    assert {:ok, %{status: :ready, loaded_count: 0, configured_limit: 100_000}} =
             AuthorityStore.hydration_status(name: name)
  end

  test "large durable hydration fails closed without bounded inventory support" do
    name = unique_name(:authority_large_unsupported)

    start_supervised!(
      {AuthorityStore, name: name, backend: MissingCasBackend, hydration_limit: 10_001}
    )

    assert {:ok,
            %{
              status: :failed,
              loaded_count: 0,
              configured_limit: 10_001,
              reason: :bounded_inventory_unsupported
            }} = AuthorityStore.hydration_status(name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.take_hydrated_entries(name: name)
  end

  test "first handoff returns the validated startup entries without another backend scan" do
    name = unique_name(:authority_handoff)
    record = Record.new("existing", %{"v" => 1})
    {:ok, backend_agent} = start_supervised({Agent, fn -> %{"existing" => record} end})

    start_supervised!(
      {AuthorityStore,
       name: name,
       backend: ObservedBackend,
       backend_opts: [backend_agent: backend_agent, test_pid: self()],
       hydration_limit: 10}
    )

    assert_received {:backend_list, ["existing"]}
    assert_received {:backend_get, "existing"}
    assert {:ok, [{"existing", ^record}]} = AuthorityStore.take_hydrated_entries(name: name)
    refute_received {:backend_list, _}
    refute_received {:backend_get, _}
  end

  test "mutation before first handoff invalidates the cached startup entries" do
    name = unique_name(:authority_handoff_mutation)
    old = Record.new("old", %{"v" => 1})
    {:ok, backend_agent} = start_supervised({Agent, fn -> %{"old" => old} end})

    start_supervised!(
      {AuthorityStore,
       name: name,
       backend: ObservedBackend,
       backend_opts: [backend_agent: backend_agent, test_pid: self()],
       hydration_limit: 10}
    )

    assert_received {:backend_list, ["old"]}
    assert_received {:backend_get, "old"}

    assert :ok = AuthorityStore.put("new", Record.new("new", %{"v" => 2}), name: name)
    assert_received {:backend_put, "new"}

    assert {:ok, entries} = AuthorityStore.take_hydrated_entries(name: name)
    assert Enum.map(entries, &elem(&1, 0)) == ["new", "old"]
    assert_received {:backend_list, ["new", "old"]}
    assert_received {:backend_get, "new"}
    assert_received {:backend_get, "old"}
  end

  test "attempted mutation before first handoff also forces a fresh complete read" do
    name = unique_name(:authority_handoff_attempt)
    record = Record.new("existing")
    {:ok, backend_agent} = start_supervised({Agent, fn -> %{"existing" => record} end})

    start_supervised!(
      {AuthorityStore,
       name: name,
       backend: ObservedBackend,
       backend_opts: [backend_agent: backend_agent, test_pid: self()],
       hydration_limit: 10}
    )

    assert_received {:backend_list, ["existing"]}
    assert_received {:backend_get, "existing"}
    assert {:error, :invalid_key} = AuthorityStore.put(:invalid, record, name: name)
    assert {:ok, [{"existing", ^record}]} = AuthorityStore.take_hydrated_entries(name: name)
    assert_received {:backend_list, ["existing"]}
    assert_received {:backend_get, "existing"}
  end

  test "bounded hydration rejects overflow before fetching any prefix" do
    name = unique_name(:authority_overflow)

    start_supervised!(
      {AuthorityStore,
       name: name, backend: OverflowBackend, backend_opts: [test_pid: self()], hydration_limit: 2}
    )

    assert {:ok,
            %{
              status: :failed,
              loaded_count: 0,
              configured_limit: 2,
              reason: :hydration_limit_exceeded
            }} = AuthorityStore.hydration_status(name: name)

    assert {:error, :hydration_unavailable} = AuthorityStore.authoritative_list(name: name)
    assert {:error, :hydration_unavailable} = AuthorityStore.authoritative_entries(name: name)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.put("k", Record.new("k"), name: name)

    refute_received :overflow_get
  end

  test "malformed, raising, and missing-CAS backends fail closed without crashing callers" do
    malformed = unique_name(:authority_malformed)
    raising = unique_name(:authority_raising)
    missing_cas = unique_name(:authority_missing_cas)
    hydrated_malformed = unique_name(:authority_hydrated_malformed)

    start_supervised!({AuthorityStore, name: malformed, backend: MalformedBackend})
    start_supervised!({AuthorityStore, name: raising, backend: RaisingBackend})
    start_supervised!({AuthorityStore, name: missing_cas, backend: MissingCasBackend})

    start_supervised!(
      {AuthorityStore, name: hydrated_malformed, backend: HydratedMalformedBackend}
    )

    assert {:ok, %{status: :failed, reason: :invalid_backend_response}} =
             AuthorityStore.hydration_status(name: malformed)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.authoritative_get("k", name: malformed)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.put("k", Record.new("k"), name: malformed)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_put("k", Record.new("k"), name: malformed)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_delete("k", name: malformed)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_compare_and_swap(
               "k",
               :not_found,
               Record.new("k"),
               name: malformed
             )

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_compare_and_delete(
               "k",
               Record.new("k"),
               name: malformed
             )

    assert {:ok, %{status: :failed, reason: :backend_unavailable}} =
             AuthorityStore.hydration_status(name: raising)

    assert {:error, :hydration_unavailable} = AuthorityStore.authoritative_get("k", name: raising)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.put("k", Record.new("k"), name: raising)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_delete("k", name: raising)

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_compare_and_swap(
               "k",
               :not_found,
               Record.new("k"),
               name: raising
             )

    assert {:error, :hydration_unavailable} =
             AuthorityStore.acknowledged_compare_and_delete("k", Record.new("k"), name: raising)

    assert Process.alive?(Process.whereis(raising))

    assert {:ok, %{status: :ready}} = AuthorityStore.hydration_status(name: missing_cas)

    assert {:error, :unsupported} =
             AuthorityStore.acknowledged_compare_and_swap(
               "k",
               :not_found,
               Record.new("k"),
               name: missing_cas
             )

    assert {:error, :unsupported} =
             AuthorityStore.acknowledged_compare_and_delete(
               "k",
               Record.new("k"),
               name: missing_cas
             )

    assert {:ok, %{status: :ready}} = AuthorityStore.hydration_status(name: hydrated_malformed)

    assert {:error, :invalid_backend_response} =
             AuthorityStore.authoritative_get("k", name: hydrated_malformed)

    assert {:error, :invalid_backend_response} =
             AuthorityStore.put("k", Record.new("k"), name: hydrated_malformed)

    assert {:error, :outcome_unknown} =
             AuthorityStore.acknowledged_put("k", Record.new("k"), name: hydrated_malformed)

    assert {:error, :outcome_unknown} =
             AuthorityStore.acknowledged_delete("k", name: hydrated_malformed)

    assert {:error, :outcome_unknown} =
             AuthorityStore.acknowledged_compare_and_swap(
               "k",
               :not_found,
               Record.new("k"),
               name: hydrated_malformed
             )

    assert {:error, :outcome_unknown} =
             AuthorityStore.acknowledged_compare_and_delete(
               "k",
               Record.new("k"),
               name: hydrated_malformed
             )
  end

  test "required CRUD callbacks are validated at init" do
    name = unique_name(:authority_invalid_backend)
    previous = Process.flag(:trap_exit, true)

    assert {:error, {:missing_backend_callback, :delete, 2}} =
             AuthorityStore.start_link(name: name, backend: MissingDeleteBackend)

    Process.flag(:trap_exit, previous)
  end

  test "backend, namespace, options, limit, and mode are frozen after init" do
    name = unique_name(:authority_frozen)
    original = Application.fetch_env(:arbor_security, :storage_backend)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:arbor_security, :storage_backend, value)
        :error -> Application.delete_env(:arbor_security, :storage_backend)
      end
    end)

    start_supervised!(
      {AuthorityStore,
       name: name,
       backend: nil,
       namespace: "frozen-namespace",
       backend_opts: [marker: :original],
       hydration_limit: 3}
    )

    Application.put_env(:arbor_security, :storage_backend, JSONFile)

    assert AuthorityStore.durability_class(name: name) == :process_lifetime
    assert {:ok, %{configured_limit: 3}} = AuthorityStore.hydration_status(name: name)
    assert {:ok, _stored} = AuthorityStore.acknowledged_put("k", Record.new("k"), name: name)

    state = :sys.get_state(name)
    assert state.name == name
    assert state.namespace == "frozen-namespace"
    assert state.backend == nil
    assert state.backend_opts == [name: "frozen-namespace", marker: :original]
    assert state.hydration_limit == 3
    assert state.persistence_mode == :ephemeral
  end

  test "concurrent exact Record CAS has one winner" do
    name = unique_name(:authority_cas)
    start_supervised!({AuthorityStore, name: name, backend: nil})

    results =
      1..24
      |> Task.async_stream(
        fn i ->
          AuthorityStore.acknowledged_compare_and_swap(
            "winner",
            :not_found,
            Record.new("winner", %{"claimant" => i}),
            name: name
          )
        end,
        max_concurrency: 24,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, %Record{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :conflict})) == 23

    assert {:ok, %Record{generation: generation, revision: 1}} =
             AuthorityStore.authoritative_get("winner", name: name)

    assert generation > 0
  end

  defp remove_json_fixture!(base_dir) do
    tmp_dir = Path.expand(System.tmp_dir!())
    fixture_root = Path.expand(base_dir)

    unless Path.dirname(fixture_root) == tmp_dir and
             Regex.match?(@json_fixture_name, Path.basename(fixture_root)) do
      raise "refusing to remove invalid AuthorityStore fixture root"
    end

    case File.rm_rf(fixture_root) do
      {:ok, _removed} ->
        :ok

      {:error, reason, _path} ->
        raise "failed to remove AuthorityStore fixture: #{inspect(reason)}"
    end
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
  end
end
