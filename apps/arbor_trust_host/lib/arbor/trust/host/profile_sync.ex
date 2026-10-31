defmodule Arbor.Trust.Host.ProfileSync do
  @moduledoc "Product trust invalidation with the original topics, origin and durable stream. Signals binds ordinary subscriptions to the calling Store PID and retires them on owner death."
  use Boundary, top_level?: true, deps: [Arbor.Trust, Arbor.Signals], exports: []
  @behaviour Arbor.Trust.Contracts.ProfileSync
  @types ~w(profile_updated profile_deleted profile_disabled)
  @impl true
  def subscribe(pid) when pid == self() do
    Enum.reduce_while(@types, {:ok, []}, fn type, {:ok, handles} ->
      result = subscribe_one(type, pid)

      case result do
        {:ok, handle} ->
          {:cont, {:ok, [handle | handles]}}

        {:error, reason} ->
          Enum.each(handles, &Arbor.Signals.unsubscribe/1)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _handles} -> :ok
      {:error, _} = error -> error
    end
  end

  def subscribe(_), do: {:error, :invalid_subscriber}
  @impl true
  def broadcast(type, data),
    do: Arbor.Signals.durable_emit(:trust, type, data, stream_id: "trust:events")

  defp subscribe_one(type, pid) do
    Arbor.Signals.subscribe("trust.#{type}", fn signal ->
      send(pid, {:signal_received, signal})
      :ok
    end)
  rescue
    _ -> {:error, :signals_unavailable}
  catch
    _, _ -> {:error, :signals_unavailable}
  end
end
