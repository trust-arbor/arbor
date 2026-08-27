defmodule Arbor.Orchestrator.CrossAppContinuation.FakeStore do
  @moduledoc false

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Contracts.Persistence.{Record, Revision}

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.start_link(
      fn ->
        %{
          records: %{},
          fail_next: %{},
          mismatch_next: %{},
          list_delay_ms: 0,
          list_call_count: 0,
          durability_class: :node_restart
        }
      end,
      name: name
    )
  end

  def stop(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  catch
    :exit, _ -> :ok
  end

  def fail_next(name, kind, reason) do
    Agent.update(name, fn state ->
      %{state | fail_next: Map.put(state.fail_next, kind, reason)}
    end)
  end

  def mismatch_next_key(name, kind, key) when kind in [:get, :compare_and_swap] do
    Agent.update(name, fn state ->
      %{state | mismatch_next: Map.put(state.mismatch_next, kind, key)}
    end)
  end

  def set_durability_class(name, class) do
    Agent.update(name, fn state -> %{state | durability_class: class} end)
  end

  def peek(name, key) do
    Agent.get(name, fn state -> Map.get(state.records, key) end)
  end

  def record_count(name), do: Agent.get(name, &map_size(&1.records))
  def list_call_count(name), do: Agent.get(name, & &1.list_call_count)

  def set_list_delay(name, ms) when is_integer(ms) and ms >= 0 do
    Agent.update(name, fn state -> %{state | list_delay_ms: ms} end)
  end

  def put_record(name, %Record{} = record) do
    Agent.update(name, fn state ->
      stored = %{
        record
        | generation: max(record.generation, 1),
          revision: max(record.revision, 1)
      }

      %{state | records: Map.put(state.records, record.key, stored)}
    end)
  end

  @impl true
  def durability_class(opts) do
    opts |> Keyword.fetch!(:name) |> Agent.get(& &1.durability_class)
  end

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.get_and_update(name, fn state ->
      case pop_fail(state, :get) do
        {nil, state} ->
          {mismatch_result(state, :get, lookup(state, key)), clear_mismatch(state, :get)}

        {reason, state} ->
          {{:error, reason}, state}
      end
    end)
  end

  @impl true
  def put(key, %Record{} = record, opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.update(name, fn state ->
      %{state | records: Map.put(state.records, key, record)}
    end)

    :ok
  end

  def put(_key, _value, _opts), do: {:error, :malformed_record}

  @impl true
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)
    Agent.update(name, fn state -> %{state | records: Map.delete(state.records, key)} end)
    :ok
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :name)

    with {:ok, limit} <- Revision.authoritative_list_limit(opts) do
      delay =
        Agent.get_and_update(name, fn state ->
          {
            state.list_delay_ms,
            %{state | list_call_count: state.list_call_count + 1}
          }
        end)

      if delay > 0, do: Process.sleep(delay)
      keys = Agent.get(name, &Map.keys(&1.records))

      cond do
        is_nil(limit) -> {:ok, keys}
        length(keys) > limit -> {:ok, Enum.take(keys, limit)}
        true -> {:ok, keys}
      end
    end
  end

  @impl true
  def compare_and_swap(key, expected, %Record{} = replacement, opts) do
    name = Keyword.fetch!(opts, :name)

    Agent.get_and_update(name, fn state ->
      case pop_fail(state, :compare_and_swap) do
        {nil, state} ->
          {result, state} = do_cas(state, key, expected, replacement)

          {
            mismatch_result(state, :compare_and_swap, result),
            clear_mismatch(state, :compare_and_swap)
          }

        {reason, state} ->
          {{:error, reason}, state}
      end
    end)
  end

  defp lookup(state, key) do
    case Map.fetch(state.records, key) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp pop_fail(state, kind) do
    case Map.pop(state.fail_next, kind) do
      {nil, _rest} -> {nil, state}
      {reason, rest} -> {reason, %{state | fail_next: rest}}
    end
  end

  defp mismatch_result(state, kind, {:ok, %Record{} = record}) do
    case Map.fetch(state.mismatch_next, kind) do
      {:ok, key} -> {:ok, %{record | key: key}}
      :error -> {:ok, record}
    end
  end

  defp mismatch_result(_state, _kind, result), do: result

  defp clear_mismatch(state, kind),
    do: %{state | mismatch_next: Map.delete(state.mismatch_next, kind)}

  defp do_cas(state, key, :not_found, replacement) do
    if Map.has_key?(state.records, key) do
      {{:error, :conflict}, state}
    else
      stored = Revision.advance_cas_insert(replacement)
      {{:ok, stored}, %{state | records: Map.put(state.records, key, stored)}}
    end
  end

  defp do_cas(state, key, {:value, %Record{} = expected}, replacement) do
    case Map.get(state.records, key) do
      %Record{} = current ->
        if Revision.cas_matches?(current, expected) do
          case Revision.advance_cas_update(current, replacement) do
            {:ok, stored} ->
              {{:ok, stored}, %{state | records: Map.put(state.records, key, stored)}}

            {:error, reason} ->
              {{:error, reason}, state}
          end
        else
          {{:error, :conflict}, state}
        end

      _other ->
        {{:error, :conflict}, state}
    end
  end

  defp do_cas(state, _key, _expected, _replacement), do: {{:error, :conflict}, state}
end
