defmodule Arbor.Memory.Test.AsyncWriterHangBackend do
  @moduledoc false

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.Record

  defstruct records: %{}, hang: :off, waiting: [], cas_calls: 0

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :agent_name)
    Agent.start_link(fn -> %__MODULE__{} end, name: name)
  end

  def stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  @doc """
  Arm a hang on the CAS path (acknowledgement / caller-death / capacity).
  """
  def arm_hang(name, tester \\ self()) do
    arm_hang(name, :cas, tester)
  end

  @doc """
  Arm a hang on `:get` (authoritative read before CAS) or `:cas`.
  """
  def arm_hang(name, gate, tester) when gate in [:get, :cas] and is_pid(tester) do
    Agent.update(name, fn state ->
      %{state | hang: %{mode: :armed, gate: gate, tester: tester, waiting: []}}
    end)
  end

  @spec arm_get_hang(atom(), pid()) :: :ok
  def arm_get_hang(name, tester \\ self()) do
    arm_hang(name, :get, tester)
  end

  @spec cas_count(atom()) :: non_neg_integer()
  def cas_count(name) do
    Agent.get(name, & &1.cas_calls)
  end

  @doc """
  Wait until a backend operation parks.

  Returns `{:ok, ref, blocked_pid}` where `blocked_pid` is the process
  executing the hung store operation (never the Agent itself). For
  BufferedStore-backed tests this is the store process, not the worker.
  """
  def await_hang(timeout \\ 2_000) do
    receive do
      {:async_writer_hang, ref, blocked_pid} when is_reference(ref) and is_pid(blocked_pid) ->
        {:ok, ref, blocked_pid}
    after
      timeout -> {:error, :hang_timeout}
    end
  end

  def release(name) do
    waiters =
      Agent.get_and_update(name, fn state ->
        case state.hang do
          %{waiting: waiting} ->
            {waiting, %{state | hang: :off}}

          _ ->
            {[], %{state | hang: :off}}
        end
      end)

    Enum.each(waiters, fn {pid, ref} ->
      if is_pid(pid) and Process.alive?(pid) do
        send(pid, {:async_writer_go, ref})
      end
    end)

    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def durability_class(_opts), do: :node_restart

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :agent_name)
    maybe_hang(name, :get)

    case Agent.get(name, &Map.get(&1.records, key)) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @impl true
  def put(key, value, opts) do
    name = Keyword.fetch!(opts, :agent_name)
    Agent.update(name, fn state -> %{state | records: Map.put(state.records, key, value)} end)
    :ok
  end

  @impl true
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :agent_name)
    Agent.update(name, fn state -> %{state | records: Map.delete(state.records, key)} end)
    :ok
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :agent_name)
    {:ok, Agent.get(name, fn state -> Map.keys(state.records) end)}
  end

  @impl true
  def compare_and_swap(key, expected, %Record{} = replacement, opts) do
    name = Keyword.fetch!(opts, :agent_name)
    bump_cas(name)
    maybe_hang(name, :cas)

    Agent.get_and_update(name, fn state ->
      do_cas(state, key, expected, replacement)
    end)
  end

  def compare_and_swap(_key, _expected, _replacement, _opts), do: {:error, :conflict}

  defp bump_cas(name) do
    Agent.update(name, fn state -> %{state | cas_calls: state.cas_calls + 1} end)
  end

  # Capture the operation process BEFORE Agent.get_and_update — self() inside
  # the Agent callback is the Agent pid, not the blocked store caller.
  defp maybe_hang(name, gate) do
    blocked_pid = self()

    park =
      Agent.get_and_update(name, fn state ->
        case state.hang do
          %{mode: :armed, gate: ^gate, tester: tester, waiting: waiting} = hang ->
            ref = make_ref()
            send(tester, {:async_writer_hang, ref, blocked_pid})
            hang = %{hang | mode: :holding, waiting: [{blocked_pid, ref} | waiting]}
            {{:park, ref}, %{state | hang: hang}}

          _ ->
            {:cont, state}
        end
      end)

    case park do
      {:park, ref} ->
        receive do
          {:async_writer_go, ^ref} -> :ok
        after
          30_000 -> :ok
        end

      :cont ->
        :ok
    end
  end

  defp do_cas(state, key, :not_found, replacement) do
    case Map.get(state.records, key) do
      nil ->
        stored = %{replacement | generation: 1, revision: 1}
        {{:ok, stored}, %{state | records: Map.put(state.records, key, stored)}}

      _ ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, key, {:value, %Record{generation: gen, revision: rev}}, replacement) do
    case Map.get(state.records, key) do
      %Record{generation: ^gen, revision: ^rev} ->
        stored = %{replacement | generation: gen, revision: rev + 1}
        {{:ok, stored}, %{state | records: Map.put(state.records, key, stored)}}

      _ ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, _key, _expected, _replacement), do: {{:error, :conflict}, state}
end
