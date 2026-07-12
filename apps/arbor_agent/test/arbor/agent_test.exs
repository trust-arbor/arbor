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

  describe "run_legacy_coding_task/3" do
    test "routes through the public facade and preserves executor validation" do
      assert {:error, :invalid_agent_id} =
               Arbor.Agent.run_legacy_coding_task("", %{}, %{})
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

  describe "model_id_from_metadata/1" do
    test "reads the live-registry shape (:model_config, atom keys)" do
      assert Arbor.Agent.model_id_from_metadata(%{model_config: %{id: "gpt-oss", provider: :x}}) ==
               "gpt-oss"
    end

    test "reads the persisted-profile shape (:last_model_config, atom keys)" do
      assert Arbor.Agent.model_id_from_metadata(%{last_model_config: %{id: "claude"}}) == "claude"
    end

    test "reads the JSON-reloaded shape (string keys, outer AND inner)" do
      # normalize_metadata only atomizes known keys, so last_model_config + its
      # inner id come back string-keyed after a profile round-trips through JSON.
      assert Arbor.Agent.model_id_from_metadata(%{"last_model_config" => %{"id" => "haiku"}}) ==
               "haiku"
    end

    test "returns nil when no model is recorded (the old (unknown) case)" do
      assert Arbor.Agent.model_id_from_metadata(%{"template_source" => %{}}) == nil
      assert Arbor.Agent.model_id_from_metadata(%{}) == nil
      assert Arbor.Agent.model_id_from_metadata(nil) == nil
    end
  end
end
