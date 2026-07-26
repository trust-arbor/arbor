defmodule Arbor.Comms.InteractionRegistry.Dispatcher do
  @moduledoc false

  use GenServer

  require Logger

  alias Arbor.Comms.Config
  alias Arbor.Comms.InteractionDelivery
  alias Arbor.Comms.InteractionRegistry.Authority
  alias Arbor.Comms.InteractionRouter
  alias Arbor.Contracts.Comms.Interaction

  @delivery_supervisor Arbor.Comms.InteractionRegistry.DeliverySupervisor
  @call_timeout_ms 5_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec readiness() :: :ready | {:error, :unavailable}
  def readiness do
    GenServer.call(__MODULE__, :readiness, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc false
  @spec wake(String.t(), map()) :: :accepted | :queued | :settled
  def wake(request_id, adapter_map) when is_binary(request_id) and is_map(adapter_map) do
    GenServer.call(__MODULE__, {:wake, request_id, adapter_map}, @call_timeout_ms)
  catch
    :exit, _reason -> :queued
  end

  def wake(_request_id, _adapter_map), do: :queued

  @doc false
  @spec sweep_now() :: :ok | {:error, :unavailable}
  def sweep_now do
    GenServer.call(__MODULE__, :sweep_now, @call_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(_opts) do
    case Config.durable_interaction_dispatch_config() do
      {:ok, config} ->
        state = %{config: config, timer_ref: nil, inflight: %{}}
        {:ok, schedule_sweep(state, config.startup_delay_ms)}

      {:error, _reason} ->
        {:stop, :invalid_dispatch_config}
    end
  end

  @impl true
  def handle_call(:readiness, _from, state), do: {:reply, :ready, state}

  def handle_call({:wake, request_id, adapter_map}, _from, state) do
    {reply, next_state} = dispatch_request(state, request_id, adapter_map)
    {:reply, reply, next_state}
  end

  def handle_call(:sweep_now, _from, state) do
    {:reply, :ok, launch_sweep(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = %{state | timer_ref: nil}
    state = state |> launch_sweep() |> schedule_sweep(state.config.sweep_interval_ms)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.inflight, ref) do
      {nil, _inflight} ->
        {:noreply, state}

      {%{claim: claim, interaction: interaction}, inflight} ->
        Process.demonitor(ref, [:flush])
        maybe_dispatch_next(settle_delivery(claim, interaction, result))
        {:noreply, %{state | inflight: inflight}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) when is_reference(ref) do
    case Map.pop(state.inflight, ref) do
      {nil, _inflight} ->
        {:noreply, state}

      {%{claim: claim}, inflight} ->
        claim
        |> Authority.release_dispatch()
        |> release_outcome()
        |> maybe_dispatch_next()

        {:noreply, %{state | inflight: inflight}}
    end
  end

  def handle_info(:dispatch_next, state) do
    {:noreply, launch_sweep(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{timer_ref: timer_ref}) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp schedule_sweep(state, delay_ms) do
    timer_ref = Process.send_after(self(), :sweep, delay_ms)
    %{state | timer_ref: timer_ref}
  end

  defp launch_sweep(state) do
    available = max(state.config.max_concurrency - map_size(state.inflight), 0)
    limit = min(available, state.config.batch_size)
    adapters = InteractionDelivery.configured_adapters()
    do_launch_sweep(state, limit, adapters)
  end

  defp do_launch_sweep(state, 0, _adapters), do: state

  defp do_launch_sweep(state, remaining, adapters) do
    case Authority.claim_next_dispatch() do
      {:ok, claim, %Interaction{} = interaction} ->
        case launch_delivery(state, claim, interaction, adapters) do
          {:ok, next_state} -> do_launch_sweep(next_state, remaining - 1, adapters)
          {:error, next_state} -> next_state
        end

      :empty ->
        state

      {:error, reason} ->
        Logger.warning(
          "[InteractionRegistry.Dispatcher] durable sweep unavailable: #{inspect(reason)}"
        )

        state

      _unexpected ->
        state
    end
  end

  defp dispatch_request(state, request_id, adapter_map) do
    if map_size(state.inflight) >= state.config.max_concurrency do
      {:queued, state}
    else
      do_dispatch_request(state, request_id, adapter_map)
    end
  end

  defp do_dispatch_request(state, request_id, adapter_map) do
    case Authority.claim_dispatch(request_id) do
      {:ok, claim, %Interaction{} = interaction} ->
        case launch_delivery(state, claim, interaction, adapter_map) do
          {:ok, next_state} -> {:queued, next_state}
          {:error, next_state} -> {:queued, next_state}
        end

      status when status in [:already_claimed, :not_dispatchable] ->
        {dispatch_status(request_id, status), state}

      :not_found ->
        {:settled, state}

      {:error, _reason} ->
        {:queued, state}
    end
  end

  defp dispatch_status(request_id, :not_dispatchable) do
    case Authority.status(request_id) do
      {:ok, :pending} -> :queued
      _ -> :settled
    end
  end

  defp dispatch_status(_request_id, :already_claimed), do: :queued

  defp launch_delivery(state, claim, interaction, adapter_map) do
    task =
      Task.Supervisor.async_nolink(@delivery_supervisor, fn ->
        InteractionDelivery.deliver_bounded(
          interaction,
          adapter_map,
          state.config.send_timeout_ms
        )
      end)

    inflight =
      Map.put(state.inflight, task.ref, %{
        claim: claim,
        interaction: interaction,
        task_pid: task.pid
      })

    {:ok, %{state | inflight: inflight}}
  rescue
    _ ->
      _ = Authority.release_dispatch(claim)
      {:error, state}
  catch
    :exit, _reason ->
      _ = Authority.release_dispatch(claim)
      {:error, state}
  end

  defp settle_delivery(claim, interaction, result) do
    case result do
      :ok ->
        case Authority.accept_dispatch(claim) do
          :ok ->
            notify_accepted(interaction)
            :continue

          {:error, _reason} ->
            :defer
        end

      {:retry, _reason} ->
        claim
        |> Authority.release_dispatch()
        |> release_outcome()

      _invalid_result ->
        claim
        |> Authority.release_dispatch()
        |> release_outcome()
    end
  end

  defp release_outcome(:ok), do: :continue
  defp release_outcome({:error, _reason}), do: :defer

  defp maybe_dispatch_next(:continue), do: send(self(), :dispatch_next)
  defp maybe_dispatch_next(:defer), do: :ok

  defp notify_accepted(interaction) do
    InteractionRouter.durable_dispatch_accepted(interaction)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
