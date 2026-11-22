defmodule Arbor.Orchestrator.Session.TrustProfileSignals do
  @moduledoc """
  Subscribes a session process to trust profile changes.

  The Trust host broadcasts three profile events, each on its own topic:
  `trust.profile_updated`, `trust.profile_deleted` and `trust.profile_disabled`
  (a failed durable delete, which installs a fail-closed tombstone). This
  module delivers all three to the session as `{:signal_received, signal}`,
  the message `Arbor.Orchestrator.Session.handle_info/2` matches.

  These signals are a hint to the session, not the enforcement point. Calls
  made through `Arbor.Trust.authorize/4` apply the current profile on every
  call. See `Session.handle_info/2` for what the session does on a change.

  Signals binds each subscription to the calling process and retires it when
  that process dies, so a session subscribes once in `init/1` and never
  unsubscribes.
  """

  @types [:profile_updated, :profile_deleted, :profile_disabled]

  @doc "The trust signal types a session reacts to."
  @spec types() :: [atom()]
  def types, do: @types

  @doc """
  Subscribe the calling process to every profile change topic. Returns
  `{:error, reason}` when the signal bus is unavailable or refuses any one
  subscription, after retiring the ones already made; it never raises.
  """
  @spec subscribe() :: {:ok, [String.t()]} | {:error, term()}
  def subscribe do
    subscriber = self()

    Enum.reduce_while(@types, {:ok, []}, fn type, {:ok, ids} ->
      case subscribe_one(type, subscriber) do
        {:ok, id} ->
          {:cont, {:ok, [id | ids]}}

        {:error, reason} ->
          Enum.each(ids, &safe_unsubscribe/1)
          {:halt, {:error, {type, reason}}}
      end
    end)
  end

  defp subscribe_one(type, subscriber) do
    case Arbor.Signals.subscribe("trust.#{type}", fn signal ->
           send(subscriber, {:signal_received, signal})
           :ok
         end) do
      {:ok, subscription_id} -> {:ok, subscription_id}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_subscribe_result, other}}
    end
  rescue
    error -> {:error, {:signals_unavailable, error.__struct__}}
  catch
    :exit, reason -> {:error, {:signals_unavailable, reason}}
  end

  defp safe_unsubscribe(id) do
    Arbor.Signals.unsubscribe(id)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
