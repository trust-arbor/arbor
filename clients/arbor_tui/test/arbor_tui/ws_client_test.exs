defmodule ArborTui.WSClientTest do
  use ExUnit.Case, async: true

  alias ArborTui.WSClient

  # The WSClient pushes lifecycle messages into its `:runtime` via
  # `TermUI.Runtime.send_message(runtime, :root, msg)`, which is a
  # `GenServer.cast(runtime, {:message, :root, msg})`. Pointing `:runtime` at the
  # test pid lets us observe those casts as plain messages:
  #     {:"$gen_cast", {:message, :root, {:ws_status, status, detail}}}
  defp await_status(timeout \\ 1_000) do
    receive do
      {:"$gen_cast", {:message, :root, {:ws_status, status, detail}}} -> {status, detail}
    after
      timeout -> flunk("no :ws_status message within #{timeout}ms")
    end
  end

  defp fake_identity do
    # Signer only needs these fields to build the upgrade header; we never reach
    # a real server in these tests.
    %{agent_id: "agent_test", private_key: :crypto.strong_rand_bytes(32)}
  end

  describe "backoff_window/1" do
    test "is base 500ms doubling per attempt, capped at 30_000ms" do
      # window (the high end of the jitter pair) follows 500 * 2^(n-1), capped.
      assert {_, 500} = WSClient.backoff_window(1)
      assert {_, 1_000} = WSClient.backoff_window(2)
      assert {_, 2_000} = WSClient.backoff_window(3)
      assert {_, 4_000} = WSClient.backoff_window(4)
      assert {_, 8_000} = WSClient.backoff_window(5)
      assert {_, 16_000} = WSClient.backoff_window(6)
      # attempt 7 would be 32_000 → capped at 30_000, and stays there forever.
      assert {_, 30_000} = WSClient.backoff_window(7)
      assert {_, 30_000} = WSClient.backoff_window(8)
      assert {_, 30_000} = WSClient.backoff_window(50)
    end

    test "the window is monotonic non-decreasing up to the cap" do
      windows = Enum.map(1..20, fn n -> elem(WSClient.backoff_window(n), 1) end)

      Enum.zip(windows, tl(windows))
      |> Enum.each(fn {a, b} -> assert b >= a end)

      assert List.last(windows) == 30_000
    end

    test "jitter low bound is ceil(window/2), so a delay picked in the window is bounded" do
      for n <- 1..10 do
        {lo, hi} = WSClient.backoff_window(n)
        assert lo == div(hi + 1, 2)
        assert lo >= 1
        assert lo <= hi
      end
    end
  end

  describe "reconnect behaviour" do
    # A closed port: connecting to it fails immediately, exercising the
    # initial-connect → schedule_reconnect funnel without a real server.
    defp closed_port do
      {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(lsock)
      :ok = :gen_tcp.close(lsock)
      port
    end

    test "initial attach to an unreachable gateway goes :detached (best-effort, no retry-spam)" do
      # NEW behaviour: the FIRST attach is best-effort. A never-established
      # connection that fails must NOT enter the indefinite backoff loop — it
      # lands in :detached so the UI can prompt for /agent <id> to retry. (The
      # backoff-reconnect loop only applies AFTER a successful attach.)
      port = closed_port()

      {:ok, _pid} =
        WSClient.start_link(
          runtime: self(),
          identity: fake_identity(),
          gateway_url: "ws://127.0.0.1:#{port}",
          target_agent_id: "agent_target"
        )

      assert {:connecting, _} = await_status()

      assert {:detached, detail} = await_status()
      assert detail =~ "Couldn't attach"

      # And it does NOT keep retrying: no further :connecting/:reconnecting.
      refute_receive {:"$gen_cast", {:message, :root, {:ws_status, _, _}}}, 1_500
    end
  end

  describe "idle start (no target)" do
    test "starting with target_agent_id: nil does not connect (no :connecting)" do
      {:ok, _pid} =
        WSClient.start_link(
          runtime: self(),
          identity: fake_identity(),
          gateway_url: "ws://127.0.0.1:1",
          target_agent_id: nil
        )

      # Idle: the client emits nothing until connect_to/2 is called.
      refute_receive {:"$gen_cast", {:message, :root, {:ws_status, _, _}}}, 500
    end

    test "connect_to/2 from idle initiates a connection (best-effort)" do
      port = closed_port()

      {:ok, pid} =
        WSClient.start_link(
          runtime: self(),
          identity: fake_identity(),
          gateway_url: "ws://127.0.0.1:#{port}",
          target_agent_id: nil
        )

      refute_receive {:"$gen_cast", {:message, :root, {:ws_status, _, _}}}, 200

      WSClient.connect_to(pid, "agent_picked")

      assert {:connecting, _} = await_status()
      # Unreachable → best-effort detach, not infinite retry.
      assert {:detached, _} = await_status()
    end
  end
end
