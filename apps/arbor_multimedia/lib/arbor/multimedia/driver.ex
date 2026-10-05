defmodule Arbor.Multimedia.Driver do
  @moduledoc false
  alias Arbor.Multimedia.{Fence, Redacted}
  # Internal, trusted application configuration only. No caller-selectable implementation.
  # Runs inside a retained supervised DriverWorker. open/2 may block without blocking
  # the caller deadline. Emit events through notify/2 using the private permit. Its mailbox
  # serializes close with open; returning closed must prove no native resource remains.
  # Recheck the permit before every native create/start effect, including after
  # asynchronous permission or setup waits. A deadline cannot interrupt a NIF
  # already in progress; such work retains custody until checked close.
  @callback open(map(), map()) :: {:ok, term()} | {:error, atom(), :closed}
  @callback activate(term(), map(), map()) :: :ok | {:error, atom()}
  @callback close(term()) :: :ok | {:error, atom(), :closed} | {:error, :cleanup_pending}

  # Optional, additive capability. finish acknowledges the request only; a
  # correlated {:partial, frames} plus checked close settles actual media.
  @callback manual_capture_finish_supported?() :: boolean()
  @callback finish(term()) :: :ok | {:error, :finish_unavailable}
  @optional_callbacks manual_capture_finish_supported?: 0, finish: 1

  def manual_finish_supported?(driver) do
    Code.ensure_loaded?(driver) and
      function_exported?(driver, :manual_capture_finish_supported?, 0) and
      function_exported?(driver, :finish, 1) and
      driver.manual_capture_finish_supported?() == true
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def admitted?(permit) do
    :atomics.get(permit.revoked, 1) == 0 and
      System.monotonic_time(:millisecond) < permit.deadline and
      Process.alive?(permit.owner) and Process.alive?(permit.caller)
  end

  def notify(permit, event) do
    send(
      permit.receiver,
      {:multimedia_driver, permit.notification, Redacted.new(event)}
    )

    :ok
  end

  # Source-owned positive cleanup recovery, never a stream notification. Native
  # custody invokes this only after the pinned barriers and process tree settle.
  def confirm_custody_closed(%{
        custody: {owner, token, fence_id, worker},
        native_custodian: {session, secret}
      }) do
    Fence.release(fence_id)
    send(owner, {:driver_custody_closed, token, worker, fence_id, session, secret})
    :ok
  end
end

defmodule Arbor.Multimedia.Driver.Unavailable do
  @moduledoc false
  @behaviour Arbor.Multimedia.Driver
  @impl true
  def open(_, _), do: {:error, :device_unavailable, :closed}
  @impl true
  def activate(_, _, _), do: {:error, :device_unavailable}
  @impl true
  def close(_), do: :ok
end
