defmodule Arbor.Memory.Test.SignalsCheckpointFake do
  @moduledoc false

  # Memory-owned injectable checkpoint backend for C4D Signals integration.
  # Implements save/3 and load/2 expected by Arbor.Signals.Store.

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        %{
          snapshot: Keyword.get(opts, :snapshot, nil),
          mode: Keyword.get(opts, :mode, :ok),
          calls: []
        }
      end,
      name: name
    )
  end

  def stop(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        try do
          Agent.stop(pid)
        catch
          :exit, {:noproc, _} -> :ok
          :exit, {:normal, _} -> :ok
          :exit, :noproc -> :ok
          :exit, :normal -> :ok
        end
    end
  end

  def reset(name \\ __MODULE__, opts \\ []) do
    Agent.update(name, fn state ->
      %{
        state
        | snapshot: Keyword.get(opts, :snapshot, nil),
          mode: Keyword.get(opts, :mode, :ok),
          calls: []
      }
    end)
  end

  def set_mode(name \\ __MODULE__, mode) do
    Agent.update(name, &%{&1 | mode: mode})
  end

  def set_snapshot(name \\ __MODULE__, snapshot) do
    Agent.update(name, &%{&1 | snapshot: snapshot})
  end

  def get_snapshot(name \\ __MODULE__) do
    Agent.get(name, & &1.snapshot)
  end

  def calls(name \\ __MODULE__) do
    Agent.get(name, & &1.calls)
  end

  def save(id, snapshot, store) do
    name = store_name(store)
    record(name, {:save, id, self()})

    case Agent.get(name, & &1.mode) do
      :fail_save ->
        {:error, :injected_save_failure}

      _other ->
        Agent.update(name, &%{&1 | snapshot: snapshot})
        :ok
    end
  end

  def load(id, store) do
    name = store_name(store)
    record(name, {:load, id, self()})

    case Agent.get(name, & &1.mode) do
      :fail_load ->
        {:error, :injected_load_failure}

      _other ->
        case Agent.get(name, & &1.snapshot) do
          nil -> {:error, :not_found}
          snapshot -> {:ok, snapshot}
        end
    end
  end

  defp store_name(store) when is_atom(store), do: store
  defp store_name(store) when is_pid(store), do: store
  defp store_name(_), do: __MODULE__

  defp record(name, call) do
    Agent.update(name, fn state ->
      %{state | calls: [call | state.calls]}
    end)
  end
end
