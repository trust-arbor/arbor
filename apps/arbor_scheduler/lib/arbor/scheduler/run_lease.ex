defmodule Arbor.Scheduler.RunLease do
  @moduledoc false

  use GenServer, restart: :temporary

  require Logger

  alias Arbor.Scheduler.RunLeaseSupervisor

  @call_timeout 30_000

  def start(owner, opts) when is_pid(owner) do
    DynamicSupervisor.start_child(RunLeaseSupervisor, {__MODULE__, {owner, opts}})
  end

  def start_link({owner, opts}) do
    GenServer.start_link(__MODULE__, {owner, opts})
  end

  def record_identity(lease, agent_id), do: call(lease, {:record_identity, agent_id})
  def record_capability(lease, cap_id), do: call(lease, {:record_capability, cap_id})
  def record_authority(lease, authority), do: call(lease, {:record_authority, authority})

  def revoke(nil), do: :ok
  def revoke(lease), do: call(lease, :revoke)

  @impl true
  def init({owner, opts}) do
    ttl_ms = Keyword.fetch!(opts, :ttl_ms)

    {:ok,
     %{
       owner_ref: Process.monitor(owner),
       expiry_ref: Process.send_after(self(), :expire, ttl_ms),
       security: Keyword.fetch!(opts, :security_facade),
       trust: Keyword.fetch!(opts, :trust_facade),
       agent_id: nil,
       cap_ids: [],
       authority: nil
     }}
  end

  @impl true
  def handle_call({:record_identity, agent_id}, _from, state) do
    {:reply, :ok, %{state | agent_id: agent_id}}
  end

  def handle_call({:record_capability, cap_id}, _from, state) do
    {:reply, :ok, %{state | cap_ids: [cap_id | state.cap_ids]}}
  end

  def handle_call({:record_authority, authority}, _from, state) do
    {:reply, :ok, %{state | authority: authority}}
  end

  def handle_call(:revoke, _from, state) do
    cleanup(state)
    {:stop, :normal, :ok, cleared(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    cleanup(state)
    {:stop, :normal, cleared(state)}
  end

  def handle_info(:expire, state) do
    Logger.warning("[RunLease] per-run identity lease expired; revoking run authority")
    cleanup(state)
    {:stop, :normal, cleared(state)}
  end

  defp cleanup(state) do
    safe_call(fn -> close_authority(state.security, state.authority) end, "close authority")

    Enum.each(state.cap_ids, fn cap_id ->
      safe_call(fn -> state.security.revoke(cap_id) end, "revoke capability #{cap_id}")
    end)

    if state.agent_id do
      safe_call(
        fn -> state.trust.delete_trust_profile(state.agent_id) end,
        "delete trust profile #{state.agent_id}"
      )

      safe_call(
        fn -> state.security.deregister_identity(state.agent_id) end,
        "deregister identity #{state.agent_id}"
      )
    end

    :ok
  end

  defp close_authority(_security, nil), do: :ok
  defp close_authority(security, authority), do: security.close_signing_authority(authority)

  defp safe_call(fun, operation) do
    case fun.() do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :authority_not_found} -> :ok
      {:error, reason} -> Logger.warning("[RunLease] failed to #{operation}: #{inspect(reason)}")
      _other -> :ok
    end
  rescue
    exception ->
      Logger.warning("[RunLease] exception during #{operation}: #{Exception.message(exception)}")
  catch
    :exit, reason -> Logger.warning("[RunLease] exit during #{operation}: #{inspect(reason)}")
  end

  defp call(lease, message) when is_pid(lease) do
    GenServer.call(lease, message, @call_timeout)
  catch
    :exit, {:noproc, _} -> :ok
    :exit, {:normal, _} -> :ok
    :exit, reason -> {:error, {:lease_unavailable, reason}}
  end

  defp cleared(state), do: %{state | agent_id: nil, cap_ids: [], authority: nil}
end
