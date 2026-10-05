defmodule Arbor.Agent.ProfileAuthorityOwner do
  @moduledoc """
  Fixed synchronous owner of acknowledged Profile authority mutations and
  notice-only authoritative snapshots. Closed operations execute in this actor;
  no caller continuation, detached Task or delayed callback may write later.

  Lower notice-broker restart cannot expose a pre-write snapshot: new acquisition
  queues on this owner behind the acknowledged backend write. Owner restart also
  cannot resume a pre-enqueue write; enqueued operations remain serialized by the
  fixed BufferedStore backend owner. Ordinary Profile cache reads stay separate.
  """
  use GenServer
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def store(profile), do: call({:store, profile})
  def delete(principal), do: call({:delete, principal})
  def migrate(profile), do: call({:migrate, profile})
  def mutate(observed, governed), do: call({:mutate, {observed, governed}})
  def notice_snapshot(principal), do: call({:notice_snapshot, principal})

  defp call(message) do
    GenServer.call(__MODULE__, message, 30_000)
  rescue
    _ -> {:error, :authority_unavailable}
  catch
    :exit, _ -> {:error, :outcome_unknown}
  end

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    {:ok, nil}
  end

  @impl true
  def handle_call({operation, value}, _from, state)
      when operation in [:store, :delete, :migrate, :mutate, :notice_snapshot] do
    {:reply, Arbor.Agent.ProfileStore.apply_owned_profile_operation(operation, value), state}
  end

  @impl true
  def format_status(status) when is_map(status),
    do:
      status
      |> Map.put(:state, :redacted)
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, :redacted)
end
