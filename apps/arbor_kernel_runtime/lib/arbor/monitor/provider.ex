defmodule Arbor.Monitor.Provider do
  @moduledoc false

  alias Arbor.Monitor.Config

  @admitted_deliver_errors [:not_found, :not_member, :rate_limited, :delivery_failed]
  @admitted_create_errors [:invalid_participants, :create_failed]
  @admitted_list_errors [:directory_unavailable]

  @spec deliver(String.t(), String.t(), String.t(), atom(), String.t()) ::
          :ok | {:error, atom()} | {:skip, atom()} | {:skip, :provider_raised, module()}
  def deliver(channel_id, sender_id, sender_name, sender_type, content) do
    with {:ok, provider} <-
           resolve(Config.channel_bridge_module(), :deliver_channel_message, 5) do
      provider
      |> invoke(fn mod ->
        mod.deliver_channel_message(channel_id, sender_id, sender_name, sender_type, content)
      end)
      |> normalize_deliver()
    end
  end

  @spec create_ops_room(String.t(), [map()]) ::
          {:ok, String.t()}
          | {:error, atom()}
          | {:skip, atom()}
          | {:skip, :provider_raised, module()}
  def create_ops_room(name, participants) do
    with {:ok, provider} <- resolve(Config.channel_bridge_module(), :create_ops_room, 2) do
      provider
      |> invoke(fn mod -> mod.create_ops_room(name, participants) end)
      |> normalize_create()
    end
  end

  @spec list_agents() ::
          {:ok, [map()]}
          | {:error, atom()}
          | {:skip, atom()}
          | {:skip, :provider_raised, module()}
  def list_agents do
    with {:ok, provider} <- resolve(Config.agent_directory_module(), :list_monitor_agents, 0) do
      provider
      |> invoke(fn mod -> mod.list_monitor_agents() end)
      |> normalize_list()
    end
  end

  defp resolve(nil, _function, _arity), do: {:skip, :absent}
  defp resolve(true, _function, _arity), do: {:skip, :invalid_provider}
  defp resolve(false, _function, _arity), do: {:skip, :invalid_provider}

  defp resolve(provider, _function, _arity) when not is_atom(provider),
    do: {:skip, :invalid_provider}

  defp resolve(provider, function, arity) do
    if function_exported?(provider, function, arity) do
      {:ok, provider}
    else
      {:skip, :missing_callback}
    end
  end

  defp invoke(provider, fun) do
    fun.(provider)
  rescue
    exception -> {:raised, exception.__struct__}
  catch
    :throw, _ -> :threw
    :exit, _ -> :exited
  end

  defp normalize_deliver(:ok), do: :ok
  defp normalize_deliver({:ok, :delivered}), do: :ok

  defp normalize_deliver({:error, reason}) when reason in @admitted_deliver_errors,
    do: {:error, reason}

  defp normalize_deliver({:error, _reason}), do: {:skip, :malformed_result}

  defp normalize_deliver({:raised, exception_struct}),
    do: {:skip, :provider_raised, exception_struct}

  defp normalize_deliver(:threw), do: {:skip, :provider_threw}
  defp normalize_deliver(:exited), do: {:skip, :provider_exited}
  defp normalize_deliver(_other), do: {:skip, :malformed_result}

  defp normalize_create({:ok, id}) when is_binary(id) and id != "", do: {:ok, id}

  defp normalize_create({:error, reason}) when reason in @admitted_create_errors,
    do: {:error, reason}

  defp normalize_create({:error, _reason}), do: {:skip, :malformed_result}

  defp normalize_create({:raised, exception_struct}),
    do: {:skip, :provider_raised, exception_struct}

  defp normalize_create(:threw), do: {:skip, :provider_threw}
  defp normalize_create(:exited), do: {:skip, :provider_exited}
  defp normalize_create(_other), do: {:skip, :malformed_result}

  defp normalize_list({:ok, list}) when is_list(list) do
    case project_agents(list) do
      {:ok, agents} -> {:ok, agents}
      :malformed -> {:skip, :malformed_result}
    end
  end

  defp normalize_list({:error, reason}) when reason in @admitted_list_errors,
    do: {:error, reason}

  defp normalize_list({:error, _reason}), do: {:skip, :malformed_result}

  defp normalize_list({:raised, exception_struct}),
    do: {:skip, :provider_raised, exception_struct}

  defp normalize_list(:threw), do: {:skip, :provider_threw}
  defp normalize_list(:exited), do: {:skip, :provider_exited}
  defp normalize_list(_other), do: {:skip, :malformed_result}

  defp project_agents(list) do
    Enum.reduce_while(list, [], fn
      row, acc when is_map(row) and not is_struct(row) ->
        id = Map.get(row, :agent_id)
        name = Map.get(row, :display_name)

        if is_binary(id) and (is_binary(name) or is_nil(name)) do
          {:cont, [%{agent_id: id, display_name: name} | acc]}
        else
          {:halt, :malformed}
        end

      _row, _acc ->
        {:halt, :malformed}
    end)
    |> case do
      :malformed -> :malformed
      acc -> {:ok, Enum.reverse(acc)}
    end
  end
end
