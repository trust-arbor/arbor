defmodule Arbor.Signals.SubscriptionRegistry do
  @moduledoc false

  use GenServer

  alias Arbor.Common.AuthenticatedCall
  alias Arbor.Signals.Bus

  @test_env Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false)
  @supervisor_lookup_timeout_ms 25

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc false
  def put(subscription), do: call({:put, subscription})

  @doc false
  def delete(subscription_id), do: call({:delete, subscription_id})

  @doc false
  def delete_many(subscription_ids), do: call({:delete_many, subscription_ids})

  @doc false
  def snapshot, do: call(:snapshot)

  if @test_env do
    @doc false
    def clear, do: call(:clear)
  end

  @impl true
  def init(:ok) do
    Process.flag(:sensitive, true)

    {:ok,
     %{
       subscriptions: %{},
       owner_monitors: %{},
       authenticated_calls: AuthenticatedCall.new_custody()
     }}
  end

  @impl true
  # `GenServer.call/3` caller metadata is forgeable with a raw `$gen_call`.
  # Every registry request, including reads, travels over AuthenticatedCall so
  # only the live Bus process that received the challenge can reach this seam.
  def handle_call(_request, _from, state), do: {:reply, {:error, :unauthorized}, state}

  @impl true
  def handle_info({:DOWN, ref, :process, owner_pid, _reason}, state) do
    case Map.get(state.owner_monitors, owner_pid) do
      ^ref ->
        subscriptions =
          Map.reject(state.subscriptions, fn {_id, subscription} ->
            subscription.owner_pid == owner_pid
          end)

        {:noreply,
         %{
           state
           | subscriptions: subscriptions,
             owner_monitors: Map.delete(state.owner_monitors, owner_pid)
         }}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    case AuthenticatedCall.handle(message, state.authenticated_calls) do
      {:authenticated, caller_pid, request, reply_to} ->
        {reply, state} = dispatch_authenticated(request, caller_pid, state)
        :ok = AuthenticatedCall.reply(reply_to, reply)
        {:noreply, state}

      result when result in [:pending, :expired, :rejected] ->
        {:noreply, state}

      :unrecognized ->
        {:noreply, state}
    end
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    Map.put(status, :state, %{
      subscription_count: state |> Map.get(:subscriptions, %{}) |> map_size(),
      owner_count: state |> Map.get(:owner_monitors, %{}) |> map_size()
    })
  end

  defp handle_bus_call({:put, %{id: id, owner_pid: owner_pid} = subscription}, state)
       when is_binary(id) and is_pid(owner_pid) do
    cond do
      not Process.alive?(owner_pid) ->
        {:reply, {:error, :owner_not_alive}, state}

      Map.has_key?(state.subscriptions, id) ->
        {:reply, {:error, :already_exists}, state}

      true ->
        state =
          state
          |> put_in([:subscriptions, id], subscription)
          |> monitor_owner(owner_pid)

        {:reply, :ok, state}
    end
  end

  defp handle_bus_call({:put, _subscription}, state),
    do: {:reply, {:error, :invalid_subscription}, state}

  defp handle_bus_call({:delete, subscription_id}, state) when is_binary(subscription_id) do
    {:reply, :ok, remove_subscriptions(state, [subscription_id])}
  end

  defp handle_bus_call({:delete_many, subscription_ids}, state)
       when is_list(subscription_ids) do
    {:reply, :ok, remove_subscriptions(state, subscription_ids)}
  end

  defp handle_bus_call(:snapshot, state) do
    state = prune_dead_owners(state)
    {:reply, {:ok, state.subscriptions}, state}
  end

  if @test_env do
    defp handle_bus_call(:clear, state) do
      demonitor_all(state.owner_monitors)
      {:reply, :ok, %{state | subscriptions: %{}, owner_monitors: %{}}}
    end
  end

  defp handle_bus_call(_request, state), do: {:reply, {:error, :unsupported_request}, state}

  defp dispatch_authenticated(request, caller_pid, state) do
    if authorized_bus?(caller_pid) do
      case handle_bus_call(request, state) do
        {:reply, reply, state} -> {reply, state}
      end
    else
      {{:error, :unauthorized}, state}
    end
  end

  defp call(request) do
    case supervised_registry_pid() do
      registry_pid when is_pid(registry_pid) ->
        AuthenticatedCall.call(registry_pid, request)

      _missing ->
        {:error, :subscription_registry_unavailable}
    end
  catch
    :exit, _ -> {:error, :subscription_registry_unavailable}
  end

  defp authorized_bus?(caller) when is_pid(caller) do
    Process.whereis(Bus) == caller and supervised_bus_pid() == caller
  end

  defp authorized_bus?(_caller), do: false

  defp supervised_bus_pid do
    task = Task.async(&find_supervised_bus_pid/0)

    case Task.yield(task, @supervisor_lookup_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, bus_pid} -> bus_pid
      _timeout_or_exit -> nil
    end
  end

  defp supervised_registry_pid do
    case Process.whereis(Arbor.Signals.Supervisor) do
      supervisor when is_pid(supervisor) ->
        Enum.find_value(Supervisor.which_children(supervisor), fn
          {__MODULE__, pid, _type, _modules} when is_pid(pid) -> pid
          _other -> nil
        end)

      _missing ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp find_supervised_bus_pid do
    case Process.whereis(Arbor.Signals.Supervisor) do
      supervisor when is_pid(supervisor) ->
        Enum.find_value(Supervisor.which_children(supervisor), fn
          {Bus, pid, _type, _modules} when is_pid(pid) -> pid
          _other -> nil
        end)

      _missing ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp monitor_owner(state, owner_pid) do
    if Map.has_key?(state.owner_monitors, owner_pid) do
      state
    else
      put_in(state, [:owner_monitors, owner_pid], Process.monitor(owner_pid))
    end
  end

  defp remove_subscriptions(state, subscription_ids) do
    subscriptions = Map.drop(state.subscriptions, subscription_ids)
    reconcile_owner_monitors(%{state | subscriptions: subscriptions})
  end

  defp prune_dead_owners(state) do
    subscriptions =
      Map.reject(state.subscriptions, fn {_id, subscription} ->
        not Process.alive?(subscription.owner_pid)
      end)

    reconcile_owner_monitors(%{state | subscriptions: subscriptions})
  end

  defp reconcile_owner_monitors(state) do
    live_owners =
      state.subscriptions
      |> Map.values()
      |> Enum.map(& &1.owner_pid)
      |> MapSet.new()

    {kept, removed} =
      Map.split(state.owner_monitors, MapSet.to_list(live_owners))

    demonitor_all(removed)

    monitors =
      Enum.reduce(live_owners, kept, fn owner_pid, monitors ->
        Map.put_new_lazy(monitors, owner_pid, fn -> Process.monitor(owner_pid) end)
      end)

    %{state | owner_monitors: monitors}
  end

  defp demonitor_all(monitors) do
    Enum.each(monitors, fn {_owner_pid, ref} -> Process.demonitor(ref, [:flush]) end)
  end
end
