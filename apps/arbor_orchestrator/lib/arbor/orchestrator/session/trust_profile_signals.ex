defmodule Arbor.Orchestrator.Session.TrustProfileSignals do
  @moduledoc """
  Subscribes a session process to trust profile changes.

  When an agent's trust profile changes, its running session must revoke the
  session-scoped capabilities it was granted under the old profile. The Trust
  host broadcasts those changes on `trust.profile_updated`; this module
  delivers them to the session as `{:signal_received, signal}`, the message
  `Arbor.Orchestrator.Session.handle_info/2` matches.

  Signals binds the subscription to the calling process and retires it when
  that process dies, so a session subscribes once in `init/1` and never
  unsubscribes.
  """

  @topic "trust.profile_updated"

  @doc """
  Subscribe the calling process. Returns `{:error, reason}` when the signal bus
  is unavailable or refuses the subscription; it never raises.
  """
  @spec subscribe() :: {:ok, String.t()} | {:error, term()}
  def subscribe do
    subscriber = self()

    case Arbor.Signals.subscribe(@topic, fn signal ->
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
end
