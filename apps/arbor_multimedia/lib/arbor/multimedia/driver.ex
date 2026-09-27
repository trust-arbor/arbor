defmodule Arbor.Multimedia.Driver do
  @moduledoc false
  # Internal, trusted application configuration only. No caller-selectable implementation.
  # Runs inside a retained supervised DriverWorker. open/2 may block without blocking
  # the caller deadline. Emit events through notify/2 using the private permit. Its mailbox
  # serializes close with open; returning closed must prove no native resource remains.
  # Recheck the permit before every native create/start effect, including after
  # asynchronous permission or setup waits. A deadline cannot interrupt a NIF
  # already in progress; such work retains custody until checked close.
  @callback open(map(), map()) :: {:ok, term()} | {:error, atom(), :closed}
  @callback close(term()) :: :ok | {:error, atom(), :closed} | {:error, :cleanup_pending}

  def admitted?(permit) do
    :atomics.get(permit.active, 1) == 1 and
      System.monotonic_time(:millisecond) < permit.deadline and
      Process.alive?(permit.owner) and Process.alive?(permit.caller)
  end

  def notify(permit, event) do
    send(
      permit.receiver,
      {:multimedia_driver, permit.notification, Arbor.Multimedia.Redacted.new(event)}
    )

    :ok
  end
end

defmodule Arbor.Multimedia.Driver.Unavailable do
  @moduledoc false
  @behaviour Arbor.Multimedia.Driver
  @impl true
  def open(_, _), do: {:error, :device_unavailable, :closed}
  @impl true
  def close(_), do: :ok
end
