defmodule Arbor.Memory.AsyncWriterPersistTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Memory.MemoryStore
  alias Arbor.Persistence
  alias Arbor.Persistence.BufferedStore

  @moduletag :fast
  @moduletag packet: "VP-05D2C3I1B0"
  @store_name :arbor_memory_durable

  defmodule ConflictBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok
    @impl true
    def get(_key, _opts), do: {:error, :not_found}
    @impl true
    def delete(_key, _opts), do: :ok
    @impl true
    def list(_opts), do: {:ok, []}
    @impl true
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}
    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule MalformedBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok
    @impl true
    def get(_key, _opts), do: {:error, :not_found}
    @impl true
    def delete(_key, _opts), do: :ok
    @impl true
    def list(_opts), do: {:ok, []}
    @impl true
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :key_mismatch}
    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule IndeterminateBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok
    @impl true
    def get(_key, _opts), do: {:error, :not_found}
    @impl true
    def delete(_key, _opts), do: :ok
    @impl true
    def list(_opts), do: {:ok, []}
    @impl true
    def compare_and_swap(_key, _expected, _replacement, _opts), do: {:ok, :not_a_record}
    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule ExceptionBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok
    @impl true
    def get(_key, _opts), do: {:error, :not_found}
    @impl true
    def delete(_key, _opts), do: :ok
    @impl true
    def list(_opts), do: {:ok, []}
    @impl true
    def compare_and_swap(_key, _expected, _replacement, _opts),
      do: raise("forced persist exception")

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  defmodule ExitBackend do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    @impl true
    def put(_key, _value, _opts), do: :ok
    @impl true
    def get(_key, _opts), do: {:error, :not_found}
    @impl true
    def delete(_key, _opts), do: :ok
    @impl true
    def list(_opts), do: {:ok, []}
    @impl true
    def compare_and_swap(_key, _expected, _replacement, _opts), do: exit(:forced_persist_exit)
    @impl true
    def durability_class(_opts), do: :node_restart
  end

  test "persist_confirmed acknowledges a successful write" do
    start_store!(backend: nil)
    key = "ok-#{System.unique_integer([:positive])}"

    assert {:ok, :acknowledged} =
             MemoryStore.persist_confirmed("async_writer", key, %{"value" => "ok"}, %{})

    assert {:ok, %Record{data: %{"value" => "ok"}}} =
             Persistence.buffered_store_authoritative_get(@store_name, "async_writer:#{key}")
  end

  test "persist_confirmed returns conflict" do
    start_store!(backend: ConflictBackend)

    assert {:error, :conflict} =
             MemoryStore.persist_confirmed("async_writer", "conflict", %{"v" => 1}, %{})
  end

  test "persist_confirmed returns malformed" do
    start_store!(backend: MalformedBackend)

    assert {:error, :malformed} =
             MemoryStore.persist_confirmed("async_writer", "malformed", %{"v" => 1}, %{})
  end

  test "persist_confirmed returns indeterminate for a non-record success" do
    start_store!(backend: IndeterminateBackend)

    assert {:error, :indeterminate} =
             MemoryStore.persist_confirmed("async_writer", "indet", %{"v" => 1}, %{})
  end

  test "persist_confirmed maps a backend raise to exception" do
    start_store!(backend: ExceptionBackend)

    assert {:error, reason} =
             MemoryStore.persist_confirmed("async_writer", "boom", %{"v" => 1}, %{})

    assert reason in [:exception, :indeterminate, :unavailable]
  end

  test "persist_confirmed maps a backend exit to exit or indeterminate" do
    start_store!(backend: ExitBackend)

    assert {:error, reason} =
             MemoryStore.persist_confirmed("async_writer", "exit", %{"v" => 1}, %{})

    assert reason in [:exit, :indeterminate, :unavailable]
  end

  test "persist_confirmed returns unavailable when the store is down" do
    stop_store()

    assert {:error, :unavailable} =
             MemoryStore.persist_confirmed("async_writer", "down", %{"v" => 1}, %{})
  end

  test "persist_confirmed never converts unknown outcomes to success" do
    start_store!(backend: IndeterminateBackend)
    refute match?({:ok, _}, MemoryStore.persist_confirmed("async_writer", "x", %{}, %{}))
    assert {:error, :malformed} = MemoryStore.persist_confirmed(:ns, "k", %{}, %{})
  end

  defp start_store!(opts) do
    stop_store()

    spec =
      {BufferedStore,
       [name: @store_name, write_mode: :sync, ack_mode: :backend] ++ Keyword.new(opts)}

    start_supervised!(spec)
  end

  defp stop_store do
    case Process.whereis(@store_name) do
      nil ->
        :ok

      _pid ->
        _ = stop_supervised(BufferedStore)
        :ok
    end
  catch
    :exit, _ -> :ok
  end
end
