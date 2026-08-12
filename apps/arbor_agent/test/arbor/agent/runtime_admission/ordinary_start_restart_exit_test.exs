defmodule Arbor.Agent.RuntimeAdmission.OrdinaryStartRestartExitTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.RuntimeAdmission.OrdinaryStart

  @moduletag :fast

  test "classifies only GenServer.call exits targeting the stable store_ref" do
    store = :runtime_admission_test_store

    assert OrdinaryStart.store_restart_exit?(
             {:noproc, {GenServer, :call, [store, {:admit, :x}]}},
             store
           )

    assert OrdinaryStart.store_restart_exit?(
             {:killed, {GenServer, :call, [store, :msg]}},
             store
           )

    assert OrdinaryStart.store_restart_exit?(
             {{:shutdown, :brutal_kill}, {GenServer, :call, [store, :msg]}},
             store
           )
  end

  test "does not treat bare noproc or other-store exits as store restart" do
    store = :runtime_admission_test_store

    refute OrdinaryStart.store_restart_exit?({:noproc, :any}, store)
    refute OrdinaryStart.store_restart_exit?({:noproc, {:something, :else}}, store)

    refute OrdinaryStart.store_restart_exit?(
             {:noproc, {GenServer, :call, [:other_store, :msg]}},
             store
           )

    refute OrdinaryStart.store_restart_exit?(:timeout, store)
    refute OrdinaryStart.store_restart_exit?({:timeout, {GenServer, :call, [store, :msg]}}, store)
  end
end
