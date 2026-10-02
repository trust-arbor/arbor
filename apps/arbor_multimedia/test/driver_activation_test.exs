defmodule Arbor.Multimedia.DriverActivationTest do
  use ExUnit.Case, async: false
  alias Arbor.Multimedia.{DriverWorker, Fence, Redacted}
  @moduletag :fast

  defmodule DormantDriver do
    def open(%{test: test}, permit) do
      handle = make_ref()
      send(test, {:dormant, self(), handle, permit})
      receive do: (:return_dormant -> {:ok, handle})
    end

    def activate(handle, %{test: test}, permit) do
      send(test, {:activated, self(), handle, permit})
      :ok
    end

    def close(_handle), do: :ok
  end

  setup do
    Fence.init()
    Fence.release(Fence.current())
    on_exit(fn -> Fence.release(Fence.current()) end)
    :ok
  end

  test "security regression: activation follows committed dormant-handle custody" do
    {worker, token} = worker(System.monotonic_time(:millisecond) + 5_000)
    send(worker, {:open, token, Redacted.new(%{test: self()})})
    assert_receive {:dormant, ^worker, handle, _}
    snapshot = Task.async(fn -> :sys.get_state(worker) end)
    wait_system_message(worker)
    send(worker, :return_dormant)
    assert %{handle: %Redacted{value: ^handle}, opened: true} = Task.await(snapshot)
    assert_receive {:activated, ^worker, ^handle, _}, 500
    send(worker, {:close, token})
  end

  test "security regression: revoked dormant handoff never activates and positively closes" do
    {worker, token} = worker(System.monotonic_time(:millisecond) + 5_000)
    send(worker, {:open, token, Redacted.new(%{test: self()})})
    assert_receive {:dormant, ^worker, _handle, permit}
    :atomics.put(permit.revoked, 1, 1)
    :atomics.put(permit.active, 1, 0)
    send(worker, :return_dormant)
    assert_receive {:driver, ^token, %Redacted{value: {:closed, :ok}}}, 500
    refute_received {:activated, _, _, _}
    assert Fence.current() == nil
  end

  defp worker(deadline) do
    fence = System.unique_integer([:positive, :monotonic])
    :ok = Fence.acquire(fence)
    active = :atomics.new(1, [])
    :atomics.put(active, 1, 1)

    permit = %{
      active: active,
      revoked: :atomics.new(1, []),
      deadline: deadline,
      owner: self(),
      caller: self()
    }

    token = make_ref()

    worker =
      start_supervised!(
        {DriverWorker, Redacted.new({DormantDriver, self(), token, fence, permit})}
      )

    {worker, token}
  end

  defp wait_system_message(worker, attempts \\ 100)
  defp wait_system_message(_, 0), do: flunk("system-state observation was not queued")

  defp wait_system_message(worker, attempts) do
    {:messages, messages} = Process.info(worker, :messages)

    if Enum.any?(messages, &match?({:system, _, _}, &1)),
      do: :ok,
      else:
        (
          Process.sleep(2)
          wait_system_message(worker, attempts - 1)
        )
  end
end
