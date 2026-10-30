defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest.DeleteFailingJSONFile do
  @behaviour Arbor.Contracts.Persistence.Store
  @behaviour Arbor.Security.Store.BoundedInventory

  alias Arbor.Security.Store.JSONFile

  @delete_failures_key {__MODULE__, :delete_failures}
  @put_failures_key {__MODULE__, :put_failures}

  def fail_deletes(count) when is_integer(count) and count >= 0 do
    :persistent_term.put(@delete_failures_key, count)
  end

  def fail_puts(count) when is_integer(count) and count >= 0 do
    :persistent_term.put(@put_failures_key, count)
  end

  def clear do
    :persistent_term.erase(@delete_failures_key)
    :persistent_term.erase(@put_failures_key)
  end

  @impl true
  def put(key, record, opts \\ []) do
    case :persistent_term.get(@put_failures_key, 0) do
      count when count > 0 ->
        :persistent_term.put(@put_failures_key, count - 1)
        {:error, :injected_put_failure}

      _ ->
        JSONFile.put(key, record, opts)
    end
  end

  @impl true
  def get(key, opts \\ []), do: JSONFile.get(key, opts)

  @impl true
  def delete(key, opts \\ []) do
    case :persistent_term.get(@delete_failures_key, 0) do
      count when count > 0 ->
        :persistent_term.put(@delete_failures_key, count - 1)
        {:error, :injected_delete_failure}

      _ ->
        JSONFile.delete(key, opts)
    end
  end

  @impl true
  def list(opts \\ []), do: JSONFile.list(opts)

  @impl Arbor.Security.Store.BoundedInventory
  def bounded_list(limit, opts \\ []), do: JSONFile.bounded_list(limit, opts)

  @impl true
  def exists?(key, opts \\ []), do: JSONFile.exists?(key, opts)

  defdelegate authoritative_entry(key, opts), to: JSONFile

  @impl true
  defdelegate durability_class(opts), to: JSONFile

  def compare_and_create(key, expected, value, opts),
    do:
      with_failure(@put_failures_key, :injected_put_failure, fn ->
        JSONFile.compare_and_create(key, expected, value, opts)
      end)

  @impl true
  def compare_and_swap(key, expected, value, opts),
    do:
      with_failure(@put_failures_key, :injected_put_failure, fn ->
        JSONFile.compare_and_swap(key, expected, value, opts)
      end)

  @impl true
  def compare_and_delete(key, expected, opts),
    do:
      with_failure(@delete_failures_key, :injected_delete_failure, fn ->
        JSONFile.compare_and_delete(key, expected, opts)
      end)

  defp with_failure(key, reason, effect) do
    case :persistent_term.get(key, 0) do
      count when count > 0 ->
        :persistent_term.put(key, count - 1)
        {:error, reason}

      _ ->
        effect.()
    end
  end
end

defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest.CasUnsupportedJSONFile do
  @moduledoc false
  # CRUD-only double: deliberately does not export compare_and_swap/compare_and_delete
  # so acknowledged CAS admission remains fail-closed on unsupported backends.
  @behaviour Arbor.Contracts.Persistence.Store
  @behaviour Arbor.Security.Store.BoundedInventory

  alias Arbor.Security.Store.JSONFile

  @impl true
  def put(key, record, opts \\ []), do: JSONFile.put(key, record, opts)

  @impl true
  def get(key, opts \\ []), do: JSONFile.get(key, opts)

  @impl true
  def delete(key, opts \\ []), do: JSONFile.delete(key, opts)

  @impl true
  def list(opts \\ []), do: JSONFile.list(opts)

  @impl Arbor.Security.Store.BoundedInventory
  def bounded_list(limit, opts \\ []), do: JSONFile.bounded_list(limit, opts)

  @impl true
  def exists?(key, opts \\ []), do: JSONFile.exists?(key, opts)
end

defmodule Arbor.Security.CapabilityStorePersistenceRegressionTest.ReobserveStallingJSONFile do
  @moduledoc false
  # JSONFile double that stalls the first authoritative read of an armed key
  # after a successful compare-and-create: the grant's CAS lands, then the
  # audit boundary's re-read outlives the default GenServer.call timeout.
  @behaviour Arbor.Contracts.Persistence.Store
  @behaviour Arbor.Security.Store.BoundedInventory

  alias Arbor.Security.Store.JSONFile

  @armed_key {__MODULE__, :armed}
  @stall_key {__MODULE__, :stall}
  @stall_ms 5_500

  def arm(key) when is_binary(key), do: :persistent_term.put(@armed_key, key)

  def clear do
    :persistent_term.erase(@armed_key)
    :persistent_term.erase(@stall_key)
  end

  @impl true
  def put(key, record, opts \\ []), do: JSONFile.put(key, record, opts)

  @impl true
  def get(key, opts \\ []), do: JSONFile.get(key, opts)

  @impl true
  def delete(key, opts \\ []), do: JSONFile.delete(key, opts)

  @impl true
  def list(opts \\ []), do: JSONFile.list(opts)

  @impl Arbor.Security.Store.BoundedInventory
  def bounded_list(limit, opts \\ []), do: JSONFile.bounded_list(limit, opts)

  @impl true
  def exists?(key, opts \\ []), do: JSONFile.exists?(key, opts)

  def authoritative_entry(key, opts) do
    if :persistent_term.get(@stall_key, nil) == key do
      :persistent_term.erase(@stall_key)
      Process.sleep(@stall_ms)
    end

    JSONFile.authoritative_entry(key, opts)
  end

  @impl true
  defdelegate durability_class(opts), to: JSONFile

  def compare_and_create(key, expected, value, opts) do
    result = JSONFile.compare_and_create(key, expected, value, opts)

    if match?({:ok, _}, result) and :persistent_term.get(@armed_key, nil) == key do
      :persistent_term.erase(@armed_key)
      :persistent_term.put(@stall_key, key)
    end

    result
  end

  @impl true
  def compare_and_swap(key, expected, value, opts),
    do: JSONFile.compare_and_swap(key, expected, value, opts)

  @impl true
  def compare_and_delete(key, expected, opts),
    do: JSONFile.compare_and_delete(key, expected, opts)
end
