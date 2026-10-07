defmodule Arbor.Common.ProcessPrivateStateSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "SSEC-002,SSEC-013"

  @moduletag :fast

  alias Arbor.Common.ProcessPrivateState

  defmodule Owner do
    use GenServer

    @anchor {__MODULE__, :credential}
    @schema :credential_v1

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)
    def read(pid), do: GenServer.call(pid, :read)
    def replace(pid, value), do: GenServer.call(pid, {:replace, value})
    def close(pid), do: GenServer.call(pid, :close)

    @impl true
    def init(:ok) do
      :ok = ProcessPrivateState.open(@anchor, @schema, %{secret: :legitimate}, &valid?/1)
      {:ok, %{replaceable_carrier: nil}}
    end

    @impl true
    def handle_call(:read, _from, state) do
      {:reply, ProcessPrivateState.fetch(@anchor, @schema, &valid?/1), state}
    end

    def handle_call({:replace, value}, _from, state) do
      {:reply, ProcessPrivateState.replace(@anchor, @schema, value, &valid?/1), state}
    end

    def handle_call(:close, _from, state) do
      :ok = ProcessPrivateState.close(@anchor)
      {:reply, :ok, state}
    end

    @impl true
    def handle_info({:"ETS-TRANSFER", _table, _former_owner, _gift}, state),
      do: {:noreply, state}

    defp valid?(%{secret: secret}), do: secret in [:legitimate, :rotated]
    defp valid?(_), do: false
  end

  @tag spec: "SSEC-002,SSEC-013"
  test "security regression: transferred state carrier cannot replace sealed private custody" do
    pid = start_supervised!(Owner)

    assert :sys.get_state(pid) == %{replaceable_carrier: nil}
    assert {:ok, %{secret: :legitimate}} = Owner.read(pid)

    forged = :ets.new(:forged_process_private_state, [:set, :private])
    true = :ets.insert(forged, {:credential_v1, %{secret: :forged}})
    true = :ets.give_away(forged, pid, :forged_private_state)
    assert eventually(fn -> :ets.info(forged, :owner) == pid end)

    :sys.replace_state(pid, &Map.put(&1, :replaceable_carrier, forged))

    assert {:ok, %{secret: :legitimate}} = Owner.read(pid)
    assert :ok = Owner.replace(pid, %{secret: :rotated})
    assert {:ok, %{secret: :rotated}} = Owner.read(pid)

    assert :ok = Owner.close(pid)
    assert {:error, :invalid_private_state} = Owner.read(pid)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end
end
