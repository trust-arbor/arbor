defmodule Arbor.Signals.Test.MemoryCheckpointFake do
  @moduledoc false

  # Injectable checkpoint backend for privacy cleanup tests.
  # Implements save/3 and load/2 expected by Arbor.Signals.Store.

  use Agent

  @type mode ::
          :ok
          | :fail_save
          | :malformed_save
          | :fail_load
          | :malformed_load
          | :block_save
          | :block_load
          | :mutate_loaded

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        %{
          snapshot: nil,
          mode: Keyword.get(opts, :mode, :ok),
          calls: [],
          block_ms: Keyword.get(opts, :block_ms, 60_000),
          notify: Keyword.get(opts, :notify),
          late_effects: [],
          allow_after_block: false
        }
      end,
      name: name
    )
  end

  def stop(name \\ __MODULE__) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  def reset(name \\ __MODULE__, opts \\ []) do
    Agent.update(name, fn state ->
      %{
        state
        | snapshot: Keyword.get(opts, :snapshot, nil),
          mode: Keyword.get(opts, :mode, :ok),
          calls: [],
          block_ms: Keyword.get(opts, :block_ms, state.block_ms),
          notify: Keyword.get(opts, :notify, state.notify),
          late_effects: [],
          allow_after_block: false
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

  def late_effects(name \\ __MODULE__) do
    Agent.get(name, & &1.late_effects)
  end

  def save(id, snapshot, store) do
    name = store_name(store)
    record(name, {:save, id, self()})
    maybe_notify_blocked(name, :save, self())

    case Agent.get(name, & &1.mode) do
      :block_save ->
        block(name, :save)
        # If we resume after kill attempt, record late effect.
        record_late(name, {:save, id, self()})
        do_save(name, id, snapshot)

      :fail_save ->
        {:error, :injected_save_failure}

      :malformed_save ->
        :not_ok

      :mutate_loaded ->
        do_save(name, id, snapshot)

      _other ->
        do_save(name, id, snapshot)
    end
  end

  def load(id, store) do
    name = store_name(store)
    record(name, {:load, id, self()})
    maybe_notify_blocked(name, :load, self())

    case Agent.get(name, & &1.mode) do
      :block_load ->
        block(name, :load)
        record_late(name, {:load, id, self()})
        do_load(name, id)

      :fail_load ->
        {:error, :injected_load_failure}

      :malformed_load ->
        {:ok, :not_a_map}

      :mutate_loaded ->
        case do_load(name, id) do
          {:ok, snapshot} when is_map(snapshot) ->
            # Return a different survivor set so equality fails.
            {:ok, Map.put(snapshot, :stats, %{total_stored: -1, total_expired: 0, total_evicted: 0})}

          other ->
            other
        end

      _other ->
        do_load(name, id)
    end
  end

  defp do_save(name, _id, snapshot) do
    Agent.update(name, &%{&1 | snapshot: snapshot})
    :ok
  end

  defp do_load(name, _id) do
    case Agent.get(name, & &1.snapshot) do
      nil -> {:error, :not_found}
      snapshot -> {:ok, snapshot}
    end
  end

  defp block(name, op) do
    ms = Agent.get(name, & &1.block_ms)
    # Sleep in chunks so kill is responsive.
    deadline = System.monotonic_time(:millisecond) + ms
    spin_block(name, op, deadline)
  end

  defp spin_block(name, op, deadline) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      :ok
    else
      maybe_notify_blocked(name, op, self())
      Process.sleep(20)
      spin_block(name, op, deadline)
    end
  end

  defp maybe_notify_blocked(name, op, worker) do
    case Agent.get(name, & &1.notify) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        parent =
          case Process.info(worker, :parent) do
            {:parent, p} -> p
            _ -> nil
          end

        links =
          case Process.info(worker, :links) do
            {:links, ls} -> ls
            _ -> []
          end

        send(pid, {:checkpoint_blocked, op, worker, parent, links})
    end
  end

  defp record(name, call) do
    Agent.update(name, fn state ->
      %{state | calls: state.calls ++ [call]}
    end)
  end

  defp record_late(name, call) do
    Agent.update(name, fn state ->
      %{state | late_effects: state.late_effects ++ [call]}
    end)
  end

  defp store_name(name) when is_atom(name), do: name
  defp store_name(pid) when is_pid(pid), do: pid
end
