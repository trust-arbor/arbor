defmodule Arbor.Memory.Test.NodeRestartBackend do
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
  def compare_and_swap(key, expected, replacement, opts),
    do: ETS.compare_and_swap(key, expected, replacement, opts)

  @impl true
  def compare_and_delete(key, expected, opts),
    do: ETS.compare_and_delete(key, expected, opts)

  @impl true
  def durability_class(_opts), do: :node_restart
end

defmodule Arbor.Memory.Test.DurableGraphAuthority do
  @moduledoc false

  alias Arbor.Memory.Test.NodeRestartBackend
  alias Arbor.Persistence.{BufferedStore, QueryableStore}

  @store_name :arbor_memory_durable

  @spec start!() :: %{backend_name: atom(), store_name: atom()}
  def start! do
    assert_unowned!()

    backend_name = unique_name(:arbor_memory_graph_authority_backend)

    ExUnit.Callbacks.start_supervised!(%{
      id: backend_name,
      start: {QueryableStore.ETS, :start_link, [[name: backend_name]]}
    })

    ExUnit.Callbacks.start_supervised!({
      BufferedStore,
      name: @store_name,
      backend: NodeRestartBackend,
      collection: backend_name,
      write_mode: :sync,
      ack_mode: :backend
    })

    %{backend_name: backend_name, store_name: @store_name}
  end

  defp assert_unowned! do
    case Process.whereis(@store_name) do
      nil ->
        :ok

      pid ->
        raise "durable graph authority already owned by #{inspect(pid)}; graph tests must be async: false and own the fixture explicitly"
    end
  end

  defp unique_name(prefix),
    do: String.to_atom("#{prefix}_#{System.unique_integer([:positive])}")
end
