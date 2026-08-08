defmodule Arbor.Memory.IndexProcessEvidence do
  @moduledoc false

  # Injectable process-evidence port for exact Index ownership cleanup.
  # Production adapter reads Arbor.Memory.Registry + IndexSupervisor.
  # Unit tests inject fakes so failure semantics need no global OTP state.

  alias Arbor.Contracts.Persistence.VectorRecord

  @type inventory_error ::
          :unavailable
          | :timeout
          | :malformed
          | :conflict
          | :dead
          | :duplicate_agent
          | :duplicate_pid

  @type supervisor_error :: :unavailable | :restarting_present | :timeout | :malformed

  @type terminate_error :: :timeout | :not_found | :failed | :exit

  @callback registry_inventory(timeout_ms :: non_neg_integer()) ::
              {:ok, %{optional(String.t()) => pid()}} | {:error, inventory_error()}

  @callback supervisor_live_pids(timeout_ms :: non_neg_integer()) ::
              {:ok, MapSet.t(pid())} | {:error, supervisor_error()}

  @callback terminate_child(pid(), timeout_ms :: non_neg_integer()) ::
              :ok | {:error, terminate_error()}

  @doc false
  @spec registry_inventory(non_neg_integer()) ::
          {:ok, %{optional(String.t()) => pid()}} | {:error, inventory_error()}
  def registry_inventory(timeout_ms) when is_integer(timeout_ms) and timeout_ms <= 0,
    do: {:error, :timeout}

  def registry_inventory(timeout_ms) when is_integer(timeout_ms) do
    case run_bounded(timeout_ms, fn ->
           Registry.select(Arbor.Memory.Registry, [
             {{{:index, :"$1"}, :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
           ])
         end) do
      {:ok, entries} when is_list(entries) ->
        build_inventory(entries, %{}, MapSet.new())

      {:ok, _malformed} ->
        {:error, :malformed}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :exit} ->
        {:error, :unavailable}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  def registry_inventory(_timeout_ms), do: {:error, :timeout}

  @doc false
  @spec supervisor_live_pids(non_neg_integer()) ::
          {:ok, MapSet.t(pid())} | {:error, supervisor_error()}
  def supervisor_live_pids(timeout_ms) when is_integer(timeout_ms) and timeout_ms <= 0,
    do: {:error, :timeout}

  def supervisor_live_pids(timeout_ms) when is_integer(timeout_ms) do
    case run_bounded(timeout_ms, fn ->
           DynamicSupervisor.which_children(Arbor.Memory.IndexSupervisor)
         end) do
      {:ok, children} when is_list(children) ->
        reduce_supervisor_children(children, MapSet.new())

      {:ok, _malformed} ->
        {:error, :malformed}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :exit} ->
        {:error, :unavailable}

      {:error, _} ->
        {:error, :unavailable}
    end
  end

  def supervisor_live_pids(_timeout_ms), do: {:error, :timeout}

  @doc false
  @spec terminate_child(pid(), non_neg_integer()) :: :ok | {:error, terminate_error()}
  def terminate_child(_pid, timeout_ms) when is_integer(timeout_ms) and timeout_ms <= 0,
    do: {:error, :timeout}

  def terminate_child(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    case run_bounded(timeout_ms, fn ->
           DynamicSupervisor.terminate_child(Arbor.Memory.IndexSupervisor, pid)
         end) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :not_found}} ->
        {:error, :not_found}

      {:ok, {:error, _reason}} ->
        {:error, :failed}

      {:ok, _other} ->
        {:error, :failed}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :exit} ->
        {:error, :exit}

      {:error, _} ->
        {:error, :failed}
    end
  end

  def terminate_child(_pid, _timeout_ms), do: {:error, :failed}

  # Unlinked timed helper: no link to caller, full reap on timeout, drain reply race.
  defp run_bounded(timeout_ms, fun)
       when is_integer(timeout_ms) and timeout_ms > 0 and is_function(fun, 0) do
    parent = self()
    ref = make_ref()

    {pid, mon} =
      spawn_monitor(fn ->
        reply =
          try do
            {:ok, fun.()}
          rescue
            _ -> {:raised, :failed_or_unavailable}
          catch
            :exit, _ -> {:exited, :exit}
            _, _ -> {:raised, :failed_or_unavailable}
          end

        send(parent, {ref, reply})
      end)

    receive do
      {^ref, {:ok, value}} ->
        Process.demonitor(mon, [:flush])
        {:ok, value}

      {^ref, {:raised, _}} ->
        Process.demonitor(mon, [:flush])
        {:error, :failed}

      {^ref, {:exited, _}} ->
        Process.demonitor(mon, [:flush])
        {:error, :exit}

      {:DOWN, ^mon, :process, ^pid, _reason} ->
        drain_tagged_reply(ref)
        {:error, :exit}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        # Local monitored process killed with :kill always emits DOWN. Wait with
        # no fallback so reap is proven and the evidence budget is not extended.
        receive do
          {:DOWN, ^mon, :process, ^pid, _} -> :ok
        end

        drain_tagged_reply(ref)
        {:error, :timeout}
    end
  end

  defp drain_tagged_reply(ref) do
    receive do
      {^ref, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp build_inventory([], inventory, _seen_pids), do: {:ok, inventory}

  defp build_inventory([{agent_id, pid} | rest], inventory, seen_pids) do
    with :ok <- validate_inventory_agent(agent_id),
         :ok <- validate_inventory_pid(pid),
         :ok <- reject_duplicate_agent(inventory, agent_id),
         :ok <- reject_duplicate_pid(seen_pids, pid),
         true <- Process.alive?(pid) do
      build_inventory(
        rest,
        Map.put(inventory, agent_id, pid),
        MapSet.put(seen_pids, pid)
      )
    else
      false ->
        {:error, :dead}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_inventory([_malformed | _rest], _inventory, _seen_pids), do: {:error, :malformed}

  defp validate_inventory_agent(agent_id) do
    case VectorRecord.validate_identity(agent_id, "legacy", "legacy") do
      {:ok, _identity} -> :ok
      {:error, :invalid_vector_identity} -> {:error, :malformed}
    end
  end

  defp validate_inventory_pid(pid) when is_pid(pid), do: :ok
  defp validate_inventory_pid(_), do: {:error, :malformed}

  defp reject_duplicate_agent(inventory, agent_id) do
    if Map.has_key?(inventory, agent_id), do: {:error, :duplicate_agent}, else: :ok
  end

  defp reject_duplicate_pid(seen_pids, pid) do
    if MapSet.member?(seen_pids, pid), do: {:error, :duplicate_pid}, else: :ok
  end

  defp reduce_supervisor_children([], set), do: {:ok, set}

  defp reduce_supervisor_children([{_id, :restarting, _type, _mods} | _rest], _set),
    do: {:error, :restarting_present}

  defp reduce_supervisor_children([{_id, pid, _type, _mods} | rest], set) when is_pid(pid) do
    if Process.alive?(pid) do
      reduce_supervisor_children(rest, MapSet.put(set, pid))
    else
      # Dead child still listed — treat as uncertain ownership evidence.
      {:error, :malformed}
    end
  end

  defp reduce_supervisor_children([{_id, :undefined, _type, _mods} | rest], set) do
    # Already gone child slot is not a live Index ownership claim.
    reduce_supervisor_children(rest, set)
  end

  defp reduce_supervisor_children([_malformed | _rest], _set), do: {:error, :malformed}
end
