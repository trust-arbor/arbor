defmodule Arbor.Orchestrator.Eval.PersistenceBridgeTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.PersistenceBridge

  describe "available?/0" do
    test "returns boolean" do
      result = PersistenceBridge.available?()
      assert is_boolean(result)
    end
  end

  describe "generate_run_id/2" do
    test "creates slug from model and domain" do
      id = PersistenceBridge.generate_run_id("kimi-k2.5:cloud", "coding")
      assert String.contains?(id, "kimi-k2-5-cloud")
      assert String.contains?(id, "coding")
    end

    test "includes date" do
      id = PersistenceBridge.generate_run_id("model", "domain")
      date = Date.utc_today() |> Date.to_iso8601()
      assert String.contains?(id, date)
    end

    test "includes random suffix" do
      id1 = PersistenceBridge.generate_run_id("model", "domain")
      id2 = PersistenceBridge.generate_run_id("model", "domain")
      assert id1 != id2
    end

    test "lowercases the slug" do
      id = PersistenceBridge.generate_run_id("Claude-Sonnet-4.5", "chat")
      assert id == String.downcase(id)
    end

    test "replaces special chars in model name" do
      id = PersistenceBridge.generate_run_id("openai/gpt-4o:latest", "coding")
      refute String.contains?(id, "/")
      refute String.contains?(id, ":")
    end
  end

  describe "create_run/1" do
    test "returns {:ok, _} even when persistence unavailable" do
      attrs = %{
        id: "test-#{System.os_time(:millisecond)}",
        model: "test-model",
        domain: "coding",
        provider: "test",
        dataset: "test.jsonl",
        graders: [],
        status: "running",
        config: %{}
      }

      assert {:ok, _} = PersistenceBridge.create_run(attrs)
    end
  end

  describe "complete_run/4" do
    test "delegates to update_run with completed status" do
      # Should not crash even without persistence
      result = PersistenceBridge.complete_run("nonexistent", %{}, 0, 0)
      assert result == :ok
    end
  end

  describe "fail_run/2" do
    test "delegates to update_run with failed status" do
      result = PersistenceBridge.fail_run("nonexistent", "test error")
      assert result == :ok
    end
  end

  describe "save_result/1" do
    test "does not crash when persistence unavailable" do
      result =
        PersistenceBridge.save_result(%{
          id: "result-test",
          run_id: "run-test",
          sample_id: "sample-1",
          passed: true,
          scores: %{}
        })

      assert result == :ok
    end
  end

  describe "list_runs/1" do
    test "returns list (possibly empty)" do
      # Falls back to RunStore which returns a list
      case PersistenceBridge.list_runs([]) do
        {:ok, runs} -> assert is_list(runs)
        runs when is_list(runs) -> assert is_list(runs)
      end
    end
  end
end
