defmodule Arbor.Security.DeliveryReceiptBrokerTest do
  use ExUnit.Case, async: false
  @moduletag :fast
  @moduletag voice_id: "VOICE-17"

  alias Arbor.Contracts.Security.DeliveryReceipt
  alias Arbor.Security.DeliveryReceiptBroker

  defmodule Clock do
    @moduledoc false
    def start_link(initial), do: Agent.start_link(fn -> initial end)
    def now(agent), do: Agent.get(agent, & &1)
    def set(agent, t), do: Agent.update(agent, fn _ -> t end)
    def advance(agent, ms), do: Agent.update(agent, &(&1 + ms))
  end

  setup do
    {:ok, clock} = Clock.start_link(1_000_000)
    name = :"delivery_receipt_broker_test_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      DeliveryReceiptBroker.start_link(
        name: name,
        ttl_ms: 1_000,
        max_entries: 2,
        cleanup_interval_ms: 50,
        clock: fn -> Clock.now(clock) end
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    end)

    {:ok, broker: name, pid: pid, clock: clock}
  end

  test "issues exact 32-byte random tokens and returns closed receipt", %{broker: broker} do
    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(broker, "human_a", "arbor://r/1", :chat)

    token = Map.get(receipt, :token)
    assert is_binary(token)
    assert byte_size(token) == 32
    assert inspect(receipt) =~ "[REDACTED]"
    refute inspect(receipt) =~ Base.encode16(token, case: :lower)
  end

  test "consume is one-use and mismatch spends the token", %{broker: broker} do
    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(broker, "human_a", "arbor://r/1", :chat)

    token = Map.get(receipt, :token)

    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(broker, token, "arbor://r/other", :chat)

    # Already spent — cannot retry against correct target
    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(broker, token, "arbor://r/1", :chat)
  end

  test "successful consume returns principal; replay invalid", %{broker: broker} do
    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(broker, "human_bound", "arbor://r/1", :chat)

    token = Map.get(receipt, :token)

    assert {:ok, "human_bound"} =
             DeliveryReceiptBroker.consume(broker, token, "arbor://r/1", :chat)

    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(broker, token, "arbor://r/1", :chat)
  end

  test "expiry after mono clock advance invalidates", %{broker: broker, clock: clock} do
    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(broker, "human_a", "arbor://r/1", :chat)

    token = Map.get(receipt, :token)
    Clock.advance(clock, 1_001)

    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(broker, token, "arbor://r/1", :chat)
  end

  test "capacity enforced after pruning expired entries", %{broker: broker, clock: clock} do
    assert {:ok, r1} = DeliveryReceiptBroker.issue(broker, "human_a", "arbor://r/1", :chat)
    assert {:ok, r2} = DeliveryReceiptBroker.issue(broker, "human_b", "arbor://r/2", :chat)

    assert {:error, :broker_full} =
             DeliveryReceiptBroker.issue(broker, "human_c", "arbor://r/3", :chat)

    Clock.advance(clock, 1_001)

    # Prune happens on issue — capacity frees after expiry
    assert {:ok, _r3} = DeliveryReceiptBroker.issue(broker, "human_c", "arbor://r/3", :chat)

    # Prior receipts expired
    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(
               broker,
               Map.get(r1, :token),
               "arbor://r/1",
               :chat
             )

    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(
               broker,
               Map.get(r2, :token),
               "arbor://r/2",
               :chat
             )
  end

  test "concurrent single-winner consume", %{broker: broker} do
    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(broker, "human_race", "arbor://r/race", :chat)

    token = Map.get(receipt, :token)

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          DeliveryReceiptBroker.consume(broker, token, "arbor://r/race", :chat)
        end)
      end

    results = Enum.map(tasks, &Task.await/1)
    wins = Enum.filter(results, &match?({:ok, "human_race"}, &1))
    losses = Enum.filter(results, &match?({:error, :invalid_receipt}, &1))

    assert length(wins) == 1
    assert length(losses) == 7
  end

  test "discard is idempotent for well-shaped tokens", %{broker: broker} do
    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(broker, "human_a", "arbor://r/1", :chat)

    token = Map.get(receipt, :token)
    assert :ok = DeliveryReceiptBroker.discard(broker, token)
    assert :ok = DeliveryReceiptBroker.discard(broker, token)

    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(broker, token, "arbor://r/1", :chat)
  end

  test "periodic cleanup removes expired entries", %{broker: broker, clock: clock} do
    assert {:ok, _r} = DeliveryReceiptBroker.issue(broker, "human_a", "arbor://r/1", :chat)
    assert %{active: 1} = DeliveryReceiptBroker.stats(broker)

    Clock.advance(clock, 1_001)
    # Wait for cleanup tick (50ms interval)
    Process.sleep(120)

    assert %{active: 0} = DeliveryReceiptBroker.stats(broker)
  end

  test "crash/restart invalidates outstanding receipts" do
    name = :"delivery_receipt_broker_restart_#{System.unique_integer([:positive])}"
    {:ok, pid} = DeliveryReceiptBroker.start_link(name: name, ttl_ms: 30_000, max_entries: 16)

    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(name, "human_a", "arbor://r/1", :chat)

    token = Map.get(receipt, :token)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

    # Fresh process, empty map
    {:ok, _pid2} = DeliveryReceiptBroker.start_link(name: name, ttl_ms: 30_000, max_entries: 16)

    on_exit(fn ->
      case Process.whereis(name) do
        pid when is_pid(pid) -> GenServer.stop(pid, :normal, 1_000)
        _ -> :ok
      end
    end)

    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(name, token, "arbor://r/1", :chat)
  end

  test "stats are counts only without token material", %{broker: broker} do
    assert {:ok, receipt} =
             DeliveryReceiptBroker.issue(broker, "human_a", "arbor://r/1", :chat)

    token = Map.get(receipt, :token)
    stats = DeliveryReceiptBroker.stats(broker)
    assert is_integer(stats.active)
    assert is_integer(stats.issued)
    refute inspect(stats) =~ Base.encode16(token, case: :lower)
  end

  test "forged DeliveryReceipt shape never confers authority", %{broker: broker} do
    assert {:ok, local} = DeliveryReceipt.new(token: :crypto.strong_rand_bytes(32))

    assert {:error, :invalid_receipt} =
             DeliveryReceiptBroker.consume(
               broker,
               Map.get(local, :token),
               "arbor://r/1",
               :chat
             )
  end
end
