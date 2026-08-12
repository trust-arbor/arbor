defmodule Arbor.Memory.TestBootstrap.AdmissionBackend do
  @moduledoc """
  Test-bootstrap-only single-BEAM simulation of a `:node_restart`
  mutation-admission store.

  In-process Agent table used solely when `Arbor.Memory.TestBootstrap` starts
  admission under the empty-app topology (`start_children: false`). Not
  crash-durable and never a production or global Application-config backend.
  """

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record

  @name :arbor_memory_test_bootstrap_admission

  @doc false
  def child_spec(opts) do
    name = Keyword.get(opts, :agent_name, @name)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec start_link(keyword()) :: Agent.on_start() | {:error, :disabled}
  def start_link(opts \\ []) do
    if bootstrap_topology_allowed?(opts) do
      name = Keyword.get(opts, :agent_name, @name)
      Agent.start_link(fn -> %{records: %{}} end, name: name)
    else
      {:error, :disabled}
    end
  end

  @spec name() :: atom()
  def name, do: @name

  @impl true
  def durability_class(_opts), do: :node_restart

  @impl true
  def get(key, opts) do
    name = store_name(opts)

    case Agent.get(name, &Map.get(&1.records, key)) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl true
  def put(key, value, opts) do
    name = store_name(opts)
    Agent.update(name, fn state -> %{state | records: Map.put(state.records, key, value)} end)
    :ok
  end

  @impl true
  def delete(key, opts) do
    name = store_name(opts)
    Agent.update(name, fn state -> %{state | records: Map.delete(state.records, key)} end)
    :ok
  end

  @impl true
  def list(opts) do
    name = store_name(opts)
    {:ok, Agent.get(name, fn state -> Map.keys(state.records) end)}
  end

  @impl true
  def compare_and_swap(key, expected, %Record{} = replacement, opts) do
    name = store_name(opts)

    Agent.get_and_update(name, fn state ->
      do_cas(state, key, expected, replacement)
    end)
  end

  def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}

  # Explicit TestBootstrap opt + empty-app topology. Mix.env is not sufficient.
  defp bootstrap_topology_allowed?(opts) do
    Keyword.get(opts, :allow_test_bootstrap, false) == true and
      Application.get_env(:arbor_memory, :start_children, true) == false and
      is_pid(Process.whereis(Arbor.Memory.Supervisor))
  end

  defp do_cas(state, key, :not_found, replacement) do
    case Map.get(state.records, key) do
      nil ->
        stored = %{replacement | generation: 1, revision: 1, metadata: %{}}
        {{:ok, stored}, %{state | records: Map.put(state.records, key, stored)}}

      _ ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, key, {:value, %Record{generation: gen, revision: rev}}, replacement) do
    case Map.get(state.records, key) do
      %Record{generation: ^gen, revision: ^rev} ->
        stored = %{replacement | generation: gen, revision: rev + 1, metadata: %{}}
        {{:ok, stored}, %{state | records: Map.put(state.records, key, stored)}}

      _ ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, _key, _expected, _replacement), do: {{:error, :conflict}, state}

  defp store_name(opts), do: Keyword.get(opts, :agent_name, @name)
end
