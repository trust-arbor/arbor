defmodule Arbor.Agent.ContextManagerTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ContextManager
  alias Arbor.Memory

  # Use a temp directory for test persistence
  @test_dir System.tmp_dir!() |> Path.join("arbor_context_manager_test_#{:rand.uniform(10_000)}")

  setup do
    # Configure test directory
    Application.put_env(:arbor_agent, :context_window_dir, @test_dir)
    Application.put_env(:arbor_agent, :context_persistence_enabled, true)

    on_exit(fn ->
      File.rm_rf(@test_dir)
      Application.delete_env(:arbor_agent, :context_window_dir)
    end)

    :ok
  end

  describe "init_context/2" do
    test "creates new context when none exists" do
      {:ok, window} = ContextManager.init_context("new-agent-#{:rand.uniform(10_000)}")
      assert window != nil
    end

    test "creates context with preset" do
      {:ok, window} =
        ContextManager.init_context("preset-test-#{:rand.uniform(10_000)}", preset: :conservative)

      if is_struct(window, Arbor.Memory.ContextWindow) do
        assert window.max_tokens == 5_000
      end
    end

    test "restores saved context" do
      agent_id = "restore-test-#{:rand.uniform(10_000)}"

      # Create and save a context window
      {:ok, window} = ContextManager.init_context(agent_id)

      if Code.ensure_loaded?(Arbor.Memory.ContextWindow) do
        window = Memory.add_context_entry(window, :message, "Hello")
        :ok = ContextManager.save_context(agent_id, window)

        # Restore it
        {:ok, restored} = ContextManager.init_context(agent_id)
        assert restored != nil

        if is_struct(restored, Arbor.Memory.ContextWindow) do
          assert Memory.context_entry_count(restored) == 1
        end
      end
    end
  end

  describe "create_context/3" do
    test "creates balanced context by default" do
      window = ContextManager.create_context("test-agent", :balanced)
      assert window != nil

      if is_struct(window, Arbor.Memory.ContextWindow) do
        assert window.max_tokens == 10_000
        assert window.summary_threshold == 0.7
      end
    end

    test "creates conservative context" do
      window = ContextManager.create_context("test-agent", :conservative)

      if is_struct(window, Arbor.Memory.ContextWindow) do
        assert window.max_tokens == 5_000
        assert window.summary_threshold == 0.6
      end
    end

    test "creates expansive context" do
      window = ContextManager.create_context("test-agent", :expansive)

      if is_struct(window, Arbor.Memory.ContextWindow) do
        assert window.max_tokens == 50_000
        assert window.summary_threshold == 0.8
      end
    end

    test "opts override preset values" do
      window = ContextManager.create_context("test-agent", :balanced, max_tokens: 99_999)

      if is_struct(window, Arbor.Memory.ContextWindow) do
        assert window.max_tokens == 99_999
      end
    end
  end

  describe "save_context/2 and restore_context/1" do
    test "round-trips context through JSON" do
      agent_id = "roundtrip-#{:rand.uniform(10_000)}"

      if Code.ensure_loaded?(Arbor.Memory.ContextWindow) do
        window = Memory.new_context_window(agent_id, max_tokens: 5_000)
        window = Memory.add_context_entry(window, :message, "Test entry 1")
        window = Memory.add_context_entry(window, :message, "Test entry 2")

        assert :ok = ContextManager.save_context(agent_id, window)
        assert {:ok, restored} = ContextManager.restore_context(agent_id)

        assert is_struct(restored, Arbor.Memory.ContextWindow)
        assert Memory.context_entry_count(restored) == 2
        assert restored.max_tokens == 5_000
      end
    end

    test "returns :not_found when no persisted context" do
      assert {:error, :not_found} =
               ContextManager.restore_context("nonexistent-#{:rand.uniform(10_000)}")
    end

    test "returns :persistence_disabled when disabled" do
      Application.put_env(:arbor_agent, :context_persistence_enabled, false)

      result = ContextManager.restore_context("test-agent")
      assert {:error, :persistence_disabled} = result

      Application.put_env(:arbor_agent, :context_persistence_enabled, true)
    end

    test "save returns :ok when persistence disabled" do
      Application.put_env(:arbor_agent, :context_persistence_enabled, false)
      assert :ok = ContextManager.save_context("test", %{})
      Application.put_env(:arbor_agent, :context_persistence_enabled, true)
    end
  end

  describe "should_compress?/1" do
    test "returns false when compression disabled" do
      Application.put_env(:arbor_agent, :context_compression_enabled, false)

      refute ContextManager.should_compress?(%{})

      Application.put_env(:arbor_agent, :context_compression_enabled, true)
    end

    test "delegates to ContextWindow.should_summarize?" do
      if Code.ensure_loaded?(Arbor.Memory.ContextWindow) do
        # A fresh window with no entries should not need compression
        window = Memory.new_context_window("test")
        refute ContextManager.should_compress?(window)
      end
    end
  end
end
