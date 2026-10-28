defmodule Arbor.Persistence.OwnerContextRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Persistence.{BufferedStore, ContractProviders, Store}
  alias Arbor.Persistence.Contracts.Filter

  defmodule ContextOwner do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    def init(opts) do
      table = Keyword.get_lazy(opts, :table, fn -> :ets.new(__MODULE__, [:set, :protected]) end)
      {:ok, %{table: table, contracts: ContractProviders.capture!(), opts: opts}}
    end

    def handle_call(:contract_context, _from, %{opts: opts} = state) do
      if Keyword.get(opts, :stop_on_context, false) do
        {:stop, :normal, state}
      else
        Process.sleep(Keyword.get(opts, :metadata_delay, 0))

        if replacement = Keyword.get(opts, :rebind_to) do
          true = Process.unregister(Keyword.fetch!(opts, :name))
          true = Process.register(replacement, Keyword.fetch!(opts, :name))
        end

        next_state = %{state | opts: Keyword.delete(opts, :rebind_to)}
        {:reply, Map.take(state, [:contracts, :table]), next_state}
      end
    end

    def handle_call(message, _from, %{opts: opts} = state) do
      Process.sleep(Keyword.get(opts, :write_delay, 0))
      observer = Keyword.fetch!(opts, :observer)
      send(observer, {:unexpected_dispatch, message})
      send(observer, {:owner_dispatch, self(), message})
      {:reply, :ok, state}
    end
  end

  test "missing authoritative owner keeps typed read and mutation failures" do
    name = unique_name(:missing_authoritative_owner)
    assert {:error, :store_unavailable} = BufferedStore.authoritative_get("key", name: name)

    assert {:error, :store_unavailable} =
             BufferedStore.acknowledged_put("key", "value", name: name)
  end

  test "metadata owner loss stays within the original typed authority boundary" do
    read = context_owner(stop_on_context: true)
    assert {:error, :store_unavailable} = BufferedStore.authoritative_get("key", name: read)
    mutation = context_owner(stop_on_context: true)

    assert {:error, :outcome_unknown} =
             BufferedStore.acknowledged_put("key", "value", name: mutation)

    refute_receive {:unexpected_dispatch, _}
  end

  test "a named owner cannot substitute another process's ETS table" do
    foreign_table = :ets.new(__MODULE__, [:set, :public])
    name = context_owner(table: foreign_table)
    assert {:error, :store_unavailable} = BufferedStore.authoritative_get("key", name: name)
    assert {:error, :outcome_unknown} = BufferedStore.acknowledged_put("key", "value", name: name)
    assert :ets.tab2list(foreign_table) == []
    refute_receive {:unexpected_dispatch, _}
  end

  test "ordinary BufferedStore calls keep the selected PID when its name is rebound" do
    for {function, arguments, message} <- [
          {:put, ["key", "value"], {:put, "key", "value"}},
          {:delete, ["key"], {:delete, "key"}},
          {:backend_healthy?, [], :backend_healthy?}
        ] do
      replacement_name = context_owner([])
      replacement = Process.whereis(replacement_name)
      true = Process.unregister(replacement_name)
      name = context_owner(rebind_to: replacement)
      selected = Process.whereis(name)

      assert :ok = apply(BufferedStore, function, arguments ++ [[name: name]])
      assert Process.whereis(name) == replacement
      assert_receive {:owner_dispatch, ^selected, ^message}
      refute_receive {:owner_dispatch, ^replacement, ^message}
    end
  end

  test "nested store contexts retain the original owner after name rebinding" do
    replacement_name = context_owner([])
    replacement = Process.whereis(replacement_name)
    true = Process.unregister(replacement_name)
    name = context_owner(rebind_to: replacement)
    selected = Process.whereis(name)

    assert :ok =
             ContractProviders.with_store([name: name], fn ->
               ContractProviders.with_store([name: name], fn ->
                 ContractProviders.server_call(ContractProviders.owner_ref(name), :nested_probe)
               end)
             end)

    assert_receive {:owner_dispatch, ^selected, :nested_probe}
    refute_receive {:owner_dispatch, ^replacement, :nested_probe}
  end

  test "nested Agent contexts retain the original owner after name rebinding" do
    name = unique_name(:nested_agent_owner)
    replacement_name = unique_name(:nested_agent_replacement)
    start_supervised!({Store.Agent, name: name}, id: name)
    start_supervised!({Store.Agent, name: replacement_name}, id: replacement_name)
    selected = Process.whereis(name)
    replacement = Process.whereis(replacement_name)
    true = Process.unregister(replacement_name)

    assert ^selected =
             ContractProviders.with_agent([name: name], fn ->
               true = Process.unregister(name)
               true = Process.register(replacement, name)

               ContractProviders.with_agent([name: name], fn ->
                 ContractProviders.owner_ref(name)
               end)
             end)
  end

  test "owner-local projection queries do not issue a metadata RPC to self" do
    name = unique_name(:owner_local_query)
    start_supervised!({BufferedStore, name: name})
    assert :ok = BufferedStore.put("key", %{value: 1}, name: name)
    observer = self()

    :sys.replace_state(name, fn state ->
      send(observer, {:owner_local_query, BufferedStore.query(Filter.new(), name: name)})
      state
    end)

    assert_receive {:owner_local_query, {:ok, [%{value: 1}]}}
  end

  @tag timeout: 15_000
  test "metadata and ordinary dispatch share the original single five-second budget" do
    name = context_owner(metadata_delay: 4_000, write_delay: 4_000)
    started = System.monotonic_time(:millisecond)
    assert catch_exit(Store.ETS.put("key", "value", name: name))
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 7_000
  end

  defp context_owner(opts) do
    name = unique_name(:context_owner)

    child = %{
      id: name,
      start: {ContextOwner, :start_link, [Keyword.merge(opts, name: name, observer: self())]},
      restart: :temporary
    }

    start_supervised!(child)
    name
  end

  defp unique_name(prefix) do
    # A bounded number of test-owned names, never an external identifier.
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
