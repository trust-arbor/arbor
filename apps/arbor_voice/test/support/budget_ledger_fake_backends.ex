defmodule Arbor.Voice.Test.BudgetLedgerFakeBackend do
  @moduledoc """
  Deterministic, network-free `Arbor.Contracts.Persistence.Store` fake for
  `Arbor.Voice.BudgetLedger` tests. Implements CAS fenced on Record
  generation+revision directly (mirroring `QueryableStore.Postgres`'s
  insert-vs-update semantics) so ledger tests exercise real fencing without
  touching Postgres. `durability_class/1` reports `:node_restart`.

  Each test starts its own named instance via `start_link/1` — no shared
  state across tests. Optional file persistence (`opts[:path]` at
  `start_link/1` time) lets a fresh instance started against the same path
  observe prior state, simulating a node restart.
  """

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record

  defstruct records: %{}, force_conflicts: %{}, fail_next: %{}, history: [], path: nil

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    name = Keyword.fetch!(opts, :agent_name)
    path = Keyword.get(opts, :path)
    Agent.start_link(fn -> %__MODULE__{records: load(path), path: path} end, name: name)
  end

  @spec stop(atom()) :: :ok
  def stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  # ---------------------------------------------------------------------------
  # Test control
  # ---------------------------------------------------------------------------

  @doc "Force the next `count` compare_and_swap calls for `key` to return {:error, :conflict}."
  @spec force_conflicts(atom(), String.t(), non_neg_integer()) :: :ok
  def force_conflicts(name, key, count) do
    Agent.update(name, fn state ->
      %{state | force_conflicts: Map.put(state.force_conflicts, key, count)}
    end)
  end

  @doc "Convenience: force the next `count` CAS calls on every key."
  @spec set_conflict_count(atom(), non_neg_integer()) :: :ok
  def set_conflict_count(name, count) do
    Agent.update(name, fn state ->
      %{state | force_conflicts: %{"__all__" => count}}
    end)
  end

  @doc "Force the next call of `kind` (:get | :compare_and_swap) to return {:error, reason}."
  @spec fail_next(atom(), :get | :compare_and_swap, term()) :: :ok
  def fail_next(name, kind, reason) do
    Agent.update(name, fn state ->
      %{state | fail_next: Map.put(state.fail_next, kind, reason)}
    end)
  end

  @doc "Convenience: make the next :get call fail with `reason`."
  @spec set_get_error(atom(), term()) :: :ok
  def set_get_error(name, reason), do: fail_next(name, :get, reason)

  @doc "Convenience: make the next :compare_and_swap call fail with `reason`."
  @spec set_cas_error(atom(), term()) :: :ok
  def set_cas_error(name, reason), do: fail_next(name, :compare_and_swap, reason)

  @doc "Clear recorded history so a test can assert that no backend call happened."
  @spec clear_history(atom()) :: :ok
  def clear_history(name) do
    Agent.update(name, fn state -> %{state | history: []} end)
  end

  @doc "Raw stored Record (or nil) under `key`, for asserting no-overwrite-on-malformed-decision."
  @spec peek(atom(), String.t()) :: Record.t() | nil
  def peek(name, key) do
    Agent.get(name, fn state -> Map.get(state.records, key) end)
  end

  @doc "Recorded CAS operations in order: %{key:, cas_expected:, record: | nil}."
  @spec history(atom()) :: [map()]
  def history(name) do
    Agent.get(name, fn state ->
      Enum.reverse(state |> Map.get(:history, []))
    end)
  end

  # ---------------------------------------------------------------------------
  # Store behaviour
  # ---------------------------------------------------------------------------

  @impl true
  def durability_class(_opts), do: :node_restart

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :agent_name)

    Agent.get_and_update(name, fn state ->
      case pop_fail(state, :get) do
        {nil, state} -> {lookup(state, key), append_history(state, :get, key, nil, nil)}
        {reason, state} -> {{:error, reason}, state}
      end
    end)
  end

  @impl true
  def compare_and_swap(key, expected, %Record{} = replacement, opts) do
    name = Keyword.fetch!(opts, :agent_name)

    Agent.get_and_update(name, fn state ->
      case pop_fail(state, :compare_and_swap) do
        {nil, state} -> do_cas(state, key, expected, replacement)
        {reason, state} -> {{:error, reason}, state}
      end
    end)
  end

  @impl true
  def put(key, value, opts) do
    name = Keyword.fetch!(opts, :agent_name)

    Agent.update(name, fn state ->
      persist(%{state | records: Map.put(state.records, key, value)})
    end)

    :ok
  end

  @impl true
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :agent_name)

    Agent.update(name, fn state -> persist(%{state | records: Map.delete(state.records, key)}) end)

    :ok
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :agent_name)
    {:ok, Agent.get(name, fn state -> Map.keys(state.records) end)}
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp lookup(state, key) do
    case Map.get(state.records, key) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  defp pop_fail(state, kind) do
    case Map.pop(state.fail_next, kind) do
      {nil, _rest} -> {nil, state}
      {reason, rest} -> {reason, %{state | fail_next: rest}}
    end
  end

  defp do_cas(state, key, :not_found, replacement) do
    case Map.get(state.records, key) do
      nil -> admit_or_conflict(state, key, :not_found, replacement, 1, 1)
      _existing -> {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, key, {:value, %Record{generation: exp_gen, revision: exp_rev}}, replacement) do
    case Map.get(state.records, key) do
      %Record{generation: ^exp_gen, revision: ^exp_rev} = current ->
        admit_or_conflict(
          state,
          key,
          {:value, current},
          replacement,
          current.generation,
          current.revision + 1
        )

      _other ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, _key, _expected, _replacement), do: {{:error, :conflict}, state}

  defp append_history(state, kind, key, expected, record) do
    entry = %{kind: kind, key: key, cas_expected: expected, record: record}
    %{state | history: [entry | state |> Map.get(:history, [])]}
  end

  defp admit_or_conflict(state, key, expected, replacement, generation, revision) do
    cond do
      Map.get(state.force_conflicts, key, 0) > 0 ->
        {{:error, :conflict},
         %{state | force_conflicts: Map.update!(state.force_conflicts, key, &max(&1 - 1, 0))}}

      Map.get(state.force_conflicts, "__all__", 0) > 0 ->
        {{:error, :conflict},
         %{
           state
           | force_conflicts: Map.update!(state.force_conflicts, "__all__", &max(&1 - 1, 0))
         }}

      true ->
        stored = %{replacement | generation: generation, revision: revision}
        new_state = persist(%{state | records: Map.put(state.records, key, stored)})
        {{:ok, stored}, append_history(new_state, :compare_and_swap, key, expected, stored)}
    end
  end

  defp persist(%{path: nil} = state), do: state

  defp persist(%{path: path} = state) do
    File.write!(path, :erlang.term_to_binary(state.records))
    state
  end

  defp load(nil), do: %{}

  defp load(path) do
    case File.read(path) do
      {:ok, binary} -> :erlang.binary_to_term(binary)
      {:error, _reason} -> %{}
    end
  end
end

defmodule Arbor.Voice.Test.BudgetLedgerNoCasBackend do
  @moduledoc "Fake lacking compare_and_swap/4, for readiness/attestation-rejection tests."

  @behaviour Arbor.Contracts.Persistence.Store

  def get(_key, _opts), do: {:error, :not_found}
  def put(_key, _value, _opts), do: :ok
  def delete(_key, _opts), do: :ok
  def list(_opts), do: {:ok, []}
  def durability_class(_opts), do: :node_restart
end

defmodule Arbor.Voice.Test.BudgetLedgerNoDurabilityBackend do
  @moduledoc "Fake with CAS but no durability_class/1, for readiness/attestation-rejection tests."

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record

  def get(_key, _opts), do: {:error, :not_found}
  def put(_key, _value, _opts), do: :ok
  def delete(_key, _opts), do: :ok
  def list(_opts), do: {:ok, []}
  def compare_and_swap(_key, _expected, %Record{} = replacement, _opts), do: {:ok, replacement}
end

defmodule Arbor.Voice.Test.BudgetLedgerWeakDurabilityBackend do
  @moduledoc "Fake with CAS but process_lifetime durability, for readiness/attestation-rejection tests."

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record

  def get(_key, _opts), do: {:error, :not_found}
  def put(_key, _value, _opts), do: :ok
  def delete(_key, _opts), do: :ok
  def list(_opts), do: {:ok, []}
  def compare_and_swap(_key, _expected, %Record{} = replacement, _opts), do: {:ok, replacement}
  def durability_class(_opts), do: :process_lifetime
end
