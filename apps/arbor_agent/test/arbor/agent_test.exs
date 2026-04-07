defmodule Arbor.AgentTest do
  @moduledoc """
  Tests for the Arbor.Agent facade.

  Note: Agent.Server was removed. Agent lifecycle now goes through
  Lifecycle.create + Lifecycle.start. The deprecated start/4 returns
  {:error, :deprecated_use_lifecycle}.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  describe "start/4 (deprecated)" do
    test "returns deprecation error" do
      assert {:error, :deprecated_use_lifecycle} =
               Arbor.Agent.start("facade-1", SomeModule, %{value: 0})
    end
  end

  describe "stop/1" do
    test "returns error when stopping nonexistent agent" do
      assert {:error, :not_found} = Arbor.Agent.stop("nonexistent")
    end
  end

  describe "run_action/3" do
    test "returns error for non-running agent" do
      assert {:error, :not_found} = Arbor.Agent.run_action("nonexistent", SomeAction)
    end
  end

  describe "get_state/1" do
    test "returns error for non-running agent" do
      assert {:error, :not_found} = Arbor.Agent.get_state("nonexistent")
    end
  end

  describe "lookup/1 and whereis/1" do
    test "returns not_found for non-running agent" do
      assert {:error, :not_found} = Arbor.Agent.lookup("nonexistent")
      assert {:error, :not_found} = Arbor.Agent.whereis("nonexistent")
    end
  end

  describe "running?/1" do
    test "returns false for non-running agent" do
      refute Arbor.Agent.running?("nonexistent")
    end
  end

  describe "checkpoint/1" do
    test "returns :ok (delegated to session persistence)" do
      assert :ok = Arbor.Agent.checkpoint("nonexistent")
    end
  end

  describe "count/0" do
    test "returns non-negative count" do
      assert Arbor.Agent.count() >= 0
    end
  end

  describe "summary/1 (the 2am rule)" do
    test "returns not_found for nonexistent agent" do
      assert {:error, :not_found} =
               Arbor.Agent.summary("does-not-exist-#{System.unique_integer()}")
    end

    test "function is defined and returns the documented error shape" do
      # Positive cases require ProfileStore + Trust + Telemetry running
      # (covered by integration tests). Here we just verify the function
      # exists, takes a binary, and returns the documented error shape.
      assert function_exported?(Arbor.Agent, :summary, 1)
      assert {:error, :not_found} = Arbor.Agent.summary("nonexistent")
    end
  end
end
