defmodule Arbor.Trust.ProfileSync do
  @moduledoc "Closed authority-sensitive invalidation port; configured failure never falls back to single-node mode."
  @callbacks [subscribe: 1, broadcast: 2]
  def subscribe(pid), do: call(:subscribe, [pid])
  def broadcast(type, data), do: call(:broadcast, [type, data])

  defp call(callback, args) do
    case Application.get_env(:arbor_trust, :profile_sync_transport) do
      nil ->
        :ok

      provider when is_atom(provider) and provider not in [true, false] ->
        if Code.ensure_loaded?(provider) and
             Enum.all?(@callbacks, fn {name, arity} ->
               function_exported?(provider, name, arity)
             end) do
          case apply(provider, callback, args) do
            :ok -> :ok
            {:ok, _} when callback == :broadcast -> :ok
            {:error, reason} -> {:error, {:profile_sync_failed, reason}}
            _ -> {:error, :invalid_profile_sync_response}
          end
        else
          {:error, :profile_sync_unavailable}
        end

      _ ->
        {:error, :profile_sync_unavailable}
    end
  rescue
    _ -> {:error, :profile_sync_unavailable}
  catch
    _, _ -> {:error, :profile_sync_unavailable}
  end
end
