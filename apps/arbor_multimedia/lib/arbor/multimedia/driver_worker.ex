defmodule Arbor.Multimedia.DriverWorker do
  @moduledoc false
  use GenServer, restart: :temporary
  alias Arbor.Multimedia.{Driver, Fence, PcmCore, Redacted}

  def start_link({driver, owner, token, permit}),
    do: GenServer.start_link(__MODULE__, {driver, owner, token, permit})

  @impl true
  def init({driver, owner, token, permit}) do
    {:ok,
     %{
       driver: driver,
       permit: permit,
       owner: owner,
       monitor: Process.monitor(owner),
       token: token,
       handle: nil,
       opened: false,
       closing: false
     }}
  end

  @impl true
  def handle_info({:open, token, %Redacted{value: spec}}, %{token: token, opened: false} = state) do
    # Driver owns cleanup if it raises after touching native state; never infer
    # closure from a callback exception, an exit, or a pipeline DOWN message.
    case safe_open(state.driver, spec, state.permit) do
      {:ok, handle} ->
        {:noreply, %{state | handle: Redacted.new(handle), opened: true}}

      {:error, reason, :closed} ->
        notify(state, {:error, PcmCore.error(reason)})
        confirmed_close(state)

      _ ->
        notify(state, {:error, :driver_failed})
        {:noreply, %{state | opened: true}}
    end
  end

  def handle_info({:close, token}, %{token: token} = state), do: request_close(state)
  def handle_info(:retry_close, state), do: close(%{state | closing: false})

  def handle_info({:multimedia_driver, {:closed, _}}, state) do
    # Stream/pipeline notifications cannot attest cleanup. Only close/1's
    # checked return can issue a positive custody acknowledgement.
    notify(state, {:error, :invalid_media})
    {:noreply, state}
  end

  def handle_info({:multimedia_driver, event}, state) do
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
    :atomics.put(state.permit.active, 1, 0)
    Fence.release(state.token)
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
end
