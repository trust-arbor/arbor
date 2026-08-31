defmodule Arbor.Consensus.ConsultSeatOwner do
  @moduledoc false

  use GenServer

  @spec start(pid(), timeout()) :: {:ok, pid()} | {:error, term()}
  def start(caller, timeout \\ 5_000) when is_pid(caller) do
    # Unlinked from the consult caller so a caller crash does not EXIT
    # this owner. The owner monitors the caller and then shuts seats down.
    # Seat tasks stay unlinked from the caller via Task.Supervisor.async_nolink.
    # The init timeout bounds startup: GenServer.start kills a hung init
    # and returns {:error, :timeout}.
    GenServer.start(__MODULE__, caller, timeout: timeout)
  end

  @spec supervisor(pid(), timeout()) :: pid()
  def supervisor(owner, timeout \\ 5_000) when is_pid(owner) do
    GenServer.call(owner, :supervisor, timeout)
  end

  @spec stop(pid()) :: :ok
  def stop(owner) when is_pid(owner) do
    if Process.alive?(owner), do: GenServer.stop(owner, :shutdown, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(caller) do
    ref = Process.monitor(caller)
    {:ok, supervisor} = Task.Supervisor.start_link()
    {:ok, %{caller: caller, caller_ref: ref, supervisor: supervisor}}
  end

  @impl true
  def handle_call(:supervisor, _from, state), do: {:reply, state.supervisor, state}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{caller_ref: ref} = state) do
    {:stop, :shutdown, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_pid(state.supervisor) and Process.alive?(state.supervisor) do
      Supervisor.stop(state.supervisor, :shutdown, 1_000)
    end

    :ok
  end
end
