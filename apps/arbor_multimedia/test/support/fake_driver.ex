defmodule Arbor.Multimedia.FakeDriver do
  @behaviour Arbor.Multimedia.Driver
  @impl true
  def open(spec, permit) do
    test = Application.fetch_env!(:arbor_multimedia, :fake_test)
    send(test, {:opened, self(), spec})
    Process.put(:test, test)
    send(test, {:permit, permit})

    case Application.get_env(:arbor_multimedia, :fake_open, :ok) do
      :ok ->
        {:ok, self()}

      :wait ->
        receive do
          :continue_open -> {:ok, self()}
        end

      :raise ->
        raise "PRIVATE_PCM_SENTINEL"

      :unavailable ->
        {:error, :device_unavailable, :closed}
    end
  end

  @impl true
  def close(_handle) do
    send(Process.get(:test), {:close_attempt, self()})

    receive do
      {:close_result, result} -> result
    after
      1_000 -> {:error, :cleanup_pending}
    end
  end
end
