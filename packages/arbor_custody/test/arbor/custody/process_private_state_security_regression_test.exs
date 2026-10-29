defmodule Arbor.Custody.ProcessPrivateStateSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag spec: "SSEC-002,SSEC-013"

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Custody

  @legacy_seal_prefix {Arbor.Common.ProcessPrivateState, :sealed}

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
      :ok =
        Custody.open_process_private_state(@anchor, @schema, %{secret: :legitimate}, &valid?/1)

      {:ok, %{replaceable_carrier: nil}}
    end

    @impl true
    def handle_call(:read, _from, state) do
      {:reply, Custody.fetch_process_private_state(@anchor, @schema, &valid?/1), state}
    end

    def handle_call({:replace, value}, _from, state) do
      {:reply, Custody.replace_process_private_state(@anchor, @schema, value, &valid?/1), state}
    end

    def handle_call(:close, _from, state) do
      :ok = Custody.close_process_private_state(@anchor)
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

  test "security regression: anchors and schemas cannot substitute another credential" do
    anchor = {__MODULE__, make_ref()}
    other_anchor = {__MODULE__, make_ref()}
    valid? = fn value -> value in [:original, :rotated] end

    try do
      assert :ok = Custody.open_process_private_state(anchor, :credential_v1, :original, valid?)

      assert {:error, :invalid_private_state} =
               Custody.open_process_private_state(anchor, :credential_v1, :rotated, valid?)

      assert {:error, :invalid_private_state} =
               Custody.fetch_process_private_state(other_anchor, :credential_v1, valid?)

      assert {:error, :invalid_private_state} =
               Custody.fetch_process_private_state(anchor, :other_schema, valid?)

      assert {:error, :invalid_private_state} =
               Custody.replace_process_private_state(anchor, :credential_v1, :forged, valid?)

      assert {:ok, :original} =
               Custody.fetch_process_private_state(anchor, :credential_v1, valid?)

      assert :ok =
               Custody.update_process_private_state(
                 anchor,
                 :credential_v1,
                 fn :original -> :rotated end,
                 valid?
               )

      assert {:ok, :rotated} =
               Custody.fetch_process_private_state(anchor, :credential_v1, valid?)
    after
      Custody.close_process_private_state(anchor)
      Custody.close_process_private_state(other_anchor)
    end
  end

  test "security regression: a legacy sealed credential survives facade access and update" do
    anchor = {__MODULE__, make_ref()}
    seal_key = {@legacy_seal_prefix, anchor}
    table = :ets.new(Arbor.Common.ProcessPrivateState, [:set, :private])
    valid? = fn value -> value in [:original, :rotated] end
    true = :ets.insert(table, {:credential_v1, :original})
    Process.put(seal_key, table)

    try do
      assert {:ok, :original} =
               Custody.fetch_process_private_state(anchor, :credential_v1, valid?)

      assert :ok =
               Custody.replace_process_private_state(anchor, :credential_v1, :rotated, valid?)

      assert Process.get(seal_key) == table
      assert [{:credential_v1, :rotated}] = :ets.lookup(table, :credential_v1)
      assert :ok = Custody.close_process_private_state(anchor)
      assert Process.get(seal_key) == nil
      assert :ets.info(table) == :undefined
    after
      Custody.close_process_private_state(anchor)
    end
  end

  test "security regression: possessing another owner's locator cannot read or delete its custody" do
    owner = start_supervised!(Owner)
    anchor = {Owner, :credential}
    seal_key = {@legacy_seal_prefix, anchor}
    {:dictionary, dictionary} = Process.info(owner, :dictionary)
    {^seal_key, table} = List.keyfind(dictionary, seal_key, 0)
    Process.put(seal_key, table)

    try do
      assert_raise ArgumentError, fn -> :ets.tab2list(table) end

      assert {:error, :invalid_private_state} =
               Custody.fetch_process_private_state(anchor, :credential_v1, fn _ -> true end)

      assert :ok = Custody.close_process_private_state(anchor)
      assert :ets.info(table, :owner) == owner
      assert {:ok, %{secret: :legitimate}} = Owner.read(owner)
    after
      Custody.close_process_private_state(anchor)
    end
  end

  test "security regression: validator failures cannot install or replace private state" do
    anchor = {__MODULE__, make_ref()}
    valid? = fn value -> value == :original end

    faults = [
      fn _ -> raise "validator unavailable" end,
      fn _ -> throw(:validator_unavailable) end,
      fn _ -> exit(:validator_unavailable) end,
      fn _ -> false end
    ]

    try do
      for validator <- faults do
        assert {:error, :invalid_private_state} =
                 Custody.open_process_private_state(anchor, :credential_v1, :forged, validator)
      end

      assert :ok = Custody.open_process_private_state(anchor, :credential_v1, :original, valid?)

      for validator <- faults do
        assert {:error, :invalid_private_state} =
                 Custody.replace_process_private_state(
                   anchor,
                   :credential_v1,
                   :forged,
                   validator
                 )
      end

      assert {:ok, :original} =
               Custody.fetch_process_private_state(anchor, :credential_v1, valid?)
    after
      Custody.close_process_private_state(anchor)
    end
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
