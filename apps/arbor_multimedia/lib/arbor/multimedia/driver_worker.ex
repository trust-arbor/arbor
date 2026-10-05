defmodule Arbor.Multimedia.DriverWorker do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Arbor.Multimedia.{Driver, Fence, PcmCore, Redacted}

  def start_link(%Redacted{} = bootstrap),
    do: GenServer.start_link(__MODULE__, bootstrap)

  @impl true
  def init(%Redacted{value: {driver, owner, token, fence_id, permit}}) do
    permit =
      Map.merge(permit, %{
        receiver: self(),
        notification: :crypto.strong_rand_bytes(32),
        custody: {owner, token, fence_id, self()}
      })

    {:ok,
     %{
       driver: driver,
       permit: permit,
       owner: owner,
       monitor: Process.monitor(owner),
       token: token,
       fence_id: fence_id,
       handle: nil,
       activation: :crypto.strong_rand_bytes(32),
       opened: false,
       activated: false,
       finish_requested: false,
       finish_sent: false,
       closing: false
     }}
  end

  @impl true
  def handle_info({:open, token, %Redacted{value: spec}}, %{token: token, opened: false} = state) do
    # Driver owns cleanup if it raises after touching native state; never infer
    # closure from a callback exception, an exit, or a pipeline DOWN message.
    case safe_open(state.driver, spec, state.permit) do
      {:ok, handle} ->
        send(self(), {:activate, state.activation, Redacted.new(spec)})
        {:noreply, %{state | handle: Redacted.new(handle), opened: true}}

      {:error, reason, :closed} ->
        notify(state, {:error, PcmCore.error(reason)})
        confirmed_close(state)

      _ ->
        notify(state, {:error, :driver_failed})
        {:noreply, %{state | opened: true}}
    end
  end

  def handle_info(
        {:activate, activation, %Redacted{value: spec}},
        %{activation: activation, handle: %Redacted{value: handle}, closing: false} = state
      )
      when is_binary(activation) do
    state = %{state | activation: nil}

    if Driver.admitted?(state.permit) do
      case safe_activate(state.driver, handle, spec, state.permit) do
        :ok ->
          maybe_finish(%{state | activated: true})

        _ ->
          notify(state, {:error, :driver_failed})
          request_close(state)
      end
    else
      notify(state, {:error, :timeout})
      request_close(state)
    end
  end

  def handle_info({:finish, token}, %{token: token, closing: false} = state),
    do: maybe_finish(%{state | finish_requested: true})

  def handle_info({:close, token}, %{token: token} = state), do: request_close(state)
  def handle_info(:retry_close, state), do: close(%{state | closing: false})

  def handle_info(
        {:multimedia_driver, notification, %Redacted{value: {:closed, _}}},
        %{permit: %{notification: notification}} = state
      ) do
    # Stream/pipeline notifications cannot attest cleanup. Only close/1's
    # checked return can issue a positive custody acknowledgement.
    notify(state, {:error, :invalid_media})
    {:noreply, state}
  end

  def handle_info(
        {:multimedia_driver, notification, %Redacted{value: event}},
        %{permit: %{notification: notification}} = state
      ) do
    notify(state, event)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, owner, _},
        %{monitor: monitor, owner: owner} = state
      ),
      do: request_close(state)

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  # init has no effects, and a still-unprocessed open message cannot execute
  # after this normal stop. Unknown/blocked open never reaches this clause.
  defp close(%{handle: nil, opened: false} = state), do: confirmed_close(state)

  defp close(%{handle: %Redacted{value: handle}} = state) do
    case safe_close(state.driver, handle) do
      :ok ->
        confirmed_close(state)

      {:error, reason, :closed} ->
        notify(state, {:error, PcmCore.error(reason)})
        confirmed_close(state)

      _ ->
        notify(state, {:closed, {:error, :cleanup_pending}})
        Process.send_after(self(), :retry_close, 100)
        {:noreply, %{state | closing: true}}
    end
  end

  defp close(state) do
    notify(state, {:closed, {:error, :cleanup_pending}})
    {:noreply, %{state | closing: true}}
  end

  defp request_close(%{closing: true} = state), do: {:noreply, state}
  defp request_close(state), do: close(state)

  defp confirmed_close(state) do
    # Close is already proven. Release the exact fence here even when the
    # coordinating owner dies before receiving its acknowledgement.
    :atomics.put(state.permit.revoked, 1, 1)
    Fence.release(state.fence_id)
    notify(state, {:closed, :ok})
    {:stop, :normal, %{state | handle: nil}}
  end

  defp notify(state, event), do: send(state.owner, {:driver, state.token, Redacted.new(event)})

  defp safe_open(driver, spec, permit) do
    if Driver.admitted?(permit),
      do: driver.open(spec, permit),
      else: {:error, :timeout, :closed}
  rescue
    _ -> :uncertain
  catch
    _, _ -> :uncertain
  end

  defp safe_close(driver, handle) do
    driver.close(handle)
  rescue
    _ -> {:error, :cleanup_pending}
  catch
    _, _ -> {:error, :cleanup_pending}
  end

  defp maybe_finish(
         %{
           activated: true,
           finish_requested: true,
           finish_sent: false,
           handle: %Redacted{value: handle}
         } = state
       ) do
    state = %{state | finish_sent: true}

    if Driver.admitted?(state.permit) and safe_finish(state.driver, handle) == :ok do
      {:noreply, state}
    else
      notify(state, {:error, :finish_unavailable})
      request_close(state)
    end
  end

  defp maybe_finish(state), do: {:noreply, state}

  defp safe_finish(driver, handle) do
    if Driver.manual_finish_supported?(driver),
      do: driver.finish(handle),
      else: {:error, :finish_unavailable}
  rescue
    _ -> {:error, :finish_unavailable}
  catch
    _, _ -> {:error, :finish_unavailable}
  end

  defp safe_activate(driver, handle, spec, permit) do
    driver.activate(handle, spec, permit)
  rescue
    _ -> {:error, :driver_failed}
  catch
    _, _ -> {:error, :driver_failed}
  end
end
