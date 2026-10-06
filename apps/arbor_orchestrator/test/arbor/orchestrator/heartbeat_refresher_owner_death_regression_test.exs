defmodule Arbor.Orchestrator.HeartbeatRefresherOwnerDeathRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  test "ownership regression: killing the public wrapper owner terminates its heartbeat ticker" do
    observer = self()

    owner =
      spawn(fn ->
        receive do
          :run ->
            Arbor.Orchestrator.HeartbeatRefresher.with_heartbeat_refresh(
              "owner_death_probe",
              fn ->
                send(observer, {:entered, self()})
                receive do: (:finish -> :ok)
              end,
              interval_ms: 60_000
            )
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    :erlang.trace(owner, true, [:procs])
    send(owner, :run)
    assert_receive {:trace, ^owner, :spawn, ticker, _}, 1_000
    on_exit(fn -> if Process.alive?(ticker), do: Process.exit(ticker, :kill) end)
    ticker_ref = Process.monitor(ticker)
    assert_receive {:entered, ^owner}, 1_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ticker_ref, :process, ^ticker, _}, 1_000
  end
end
