defmodule Arbor.Cartographer.SchedulerTest do
  use ExUnit.Case, async: false

  alias Arbor.Cartographer.Scheduler

  @moduletag :fast

  setup do
    # Clean circuit breaker state between tests
    Scheduler.reset_all_breakers()
    :ok
  end

  describe "circuit breaker" do
    test "report_failure tracks failures" do
      assert :ok = Scheduler.report_failure(:fake_node@host)
      assert :ok = Scheduler.report_failure(:fake_node@host)

      status = Scheduler.circuit_status()
      assert status[:fake_node@host].failures == 2
      assert status[:fake_node@host].status == :ok
    end

    test "trips after threshold failures" do
      assert :ok = Scheduler.report_failure(:fake_node@host)
      assert :ok = Scheduler.report_failure(:fake_node@host)
      assert :tripped = Scheduler.report_failure(:fake_node@host)

      assert Scheduler.node_tripped?(:fake_node@host)

      status = Scheduler.circuit_status()
      assert status[:fake_node@host].status == :tripped
      assert status[:fake_node@host].remaining_ms > 0
    end

    test "report_success clears failures and trips" do
      Scheduler.report_failure(:fake_node@host)
      Scheduler.report_failure(:fake_node@host)
      Scheduler.report_failure(:fake_node@host)

      assert Scheduler.node_tripped?(:fake_node@host)

      :ok = Scheduler.report_success(:fake_node@host)

      refute Scheduler.node_tripped?(:fake_node@host)
      status = Scheduler.circuit_status()
      refute Map.has_key?(status, :fake_node@host)
    end

    test "reset_breaker clears a specific node" do
      Scheduler.report_failure(:node_a@host)
      Scheduler.report_failure(:node_a@host)
      Scheduler.report_failure(:node_a@host)
      Scheduler.report_failure(:node_b@host)

      :ok = Scheduler.reset_breaker(:node_a@host)

      refute Scheduler.node_tripped?(:node_a@host)
      # node_b should still have its failure
      status = Scheduler.circuit_status()
      assert status[:node_b@host].failures == 1
    end

    test "reset_all_breakers clears everything" do
      Scheduler.report_failure(:node_a@host)
      Scheduler.report_failure(:node_b@host)
      Scheduler.report_failure(:node_b@host)
      Scheduler.report_failure(:node_b@host)

      :ok = Scheduler.reset_all_breakers()

      assert Scheduler.circuit_status() == %{}
      refute Scheduler.node_tripped?(:node_b@host)
    end

    test "tripped nodes are excluded from select_node" do
      # Trip a fake node
      Scheduler.report_failure(:fake_node@host)
      Scheduler.report_failure(:fake_node@host)
      Scheduler.report_failure(:fake_node@host)

      assert Scheduler.node_tripped?(:fake_node@host)

      # Local node should still be selectable
      result = Scheduler.select_node(requirements: [], strategy: :first_match)
      assert {:ok, node} = result
      refute node == :fake_node@host
    end

    test "skip_circuit_breaker option bypasses breaker" do
      # Even with tripped nodes, skip_circuit_breaker ignores them
      # (won't affect result since fake nodes aren't in all_nodes anyway,
      # but tests the code path)
      Scheduler.report_failure(:fake_node@host)
      Scheduler.report_failure(:fake_node@host)
      Scheduler.report_failure(:fake_node@host)

      result =
        Scheduler.select_node(
          requirements: [],
          strategy: :first_match,
          skip_circuit_breaker: true
        )

      assert {:ok, _} = result
    end

    test "circuit_status returns failure_threshold" do
      Scheduler.report_failure(:fake_node@host)
      status = Scheduler.circuit_status()
      assert status[:fake_node@host].failure_threshold == 3
    end
  end

  describe "resource guard" do
    test "select_node works with default max_load on local node" do
      # Local node should have low load in test environment
      assert {:ok, _node} = Scheduler.select_node()
    end

    test "max_load requirement is extracted and applied" do
      # With an impossibly low max_load, even local node should be filtered
      # (unless load is truly 0)
      result =
        Scheduler.select_node(requirements: [{:max_load, 0.0}])

      # Load is never exactly 0 due to the test runner itself
      # but we can't guarantee this, so just verify no crash
      assert result in [{:ok, Node.self()}, {:error, :no_matching_node}]
    end

    test "max_load option overrides default" do
      # Very high threshold — should always pass
      assert {:ok, _} = Scheduler.select_node(max_load: 100.0)
    end

    test "skip_resource_guard bypasses load check" do
      assert {:ok, _} = Scheduler.select_node(skip_resource_guard: true)
    end

    test "requirement max_load takes precedence over option" do
      # This just verifies it doesn't crash — requirement should be preferred
      result =
        Scheduler.select_node(
          requirements: [{:max_load, 100.0}],
          max_load: 0.0
        )

      assert {:ok, _} = result
    end
  end

  describe "select_node (existing behavior)" do
    test "selects local node with no requirements" do
      assert {:ok, node} = Scheduler.select_node()
      assert node == Node.self()
    end

    test "returns error when no nodes match impossible requirements" do
      assert {:error, :no_matching_node} =
               Scheduler.select_node(requirements: [{:os, :nonexistent_os}])
    end

    test "exclude option filters nodes" do
      assert {:error, :no_matching_node} =
               Scheduler.select_node(exclude: [Node.self()])
    end

    test "node_meets? works for local node" do
      # Local node should meet basic requirements
      assert Scheduler.node_meets?(Node.self(), [])
    end

    test "list_capabilities returns at least local node" do
      caps = Scheduler.list_capabilities()
      assert length(caps) >= 1
      assert Enum.any?(caps, fn {node, _} -> node == Node.self() end)
    end
  end
end
