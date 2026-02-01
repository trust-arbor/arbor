defmodule Arbor.SDLC.ConfigTest do
  use ExUnit.Case, async: true

  alias Arbor.SDLC.Config

  @moduletag :fast

  describe "new/1" do
    test "creates config with defaults" do
      config = Config.new()

      assert config.roadmap_root == ".arbor/roadmap"
      assert config.poll_interval == 30_000
      assert config.debounce_ms == 1_000
      assert config.watcher_enabled == true
      assert config.max_deliberation_attempts == 3
      assert config.ai_timeout == 60_000
    end

    test "allows overriding defaults" do
      config =
        Config.new(
          roadmap_root: "/custom/roadmap",
          poll_interval: 60_000,
          watcher_enabled: false
        )

      assert config.roadmap_root == "/custom/roadmap"
      assert config.poll_interval == 60_000
      assert config.watcher_enabled == false
    end

    test "merges processor routing with defaults" do
      config = Config.new(processor_routing: %{expander: :complex})

      assert config.processor_routing[:expander] == :complex
      # Default for deliberator should still be present
      assert config.processor_routing[:deliberator] == :moderate
    end
  end

  describe "routing_for/3" do
    test "returns configured tier for processor" do
      config = Config.new(processor_routing: %{expander: :simple})

      assert Config.routing_for(config, :expander) == :simple
    end

    test "returns :moderate as default for unknown processor" do
      config = Config.new()

      assert Config.routing_for(config, :unknown_processor) == :moderate
    end

    test "overrides to :complex for critical features" do
      config = Config.new()
      item = %{priority: :critical, category: :feature}

      assert Config.routing_for(config, :expander, item) == :complex
    end

    test "overrides to :complex for critical infrastructure" do
      config = Config.new()
      item = %{priority: :critical, category: :infrastructure}

      assert Config.routing_for(config, :expander, item) == :complex
    end

    test "overrides to :simple for documentation" do
      config = Config.new()
      item = %{category: :documentation}

      assert Config.routing_for(config, :expander, item) == :simple
    end

    test "does not downgrade :complex to :simple for documentation" do
      config = Config.new(processor_routing: %{expander: :complex})
      item = %{category: :documentation}

      # Complex tier is preserved even for docs
      assert Config.routing_for(config, :expander, item) == :complex
    end

    test "returns base tier when no override applies" do
      config = Config.new()
      item = %{priority: :medium, category: :feature}

      assert Config.routing_for(config, :expander, item) == :moderate
    end
  end

  describe "application-level accessors" do
    # These test the default values when no app config is set

    test "roadmap_root/0 returns default" do
      assert Config.roadmap_root() == ".arbor/roadmap"
    end

    test "poll_interval/0 returns default" do
      assert Config.poll_interval() == 30_000
    end

    test "watcher_enabled?/0 returns default" do
      assert Config.watcher_enabled?() == true
    end

    test "ai_module/0 returns default" do
      assert Config.ai_module() == Arbor.AI
    end

    test "ai_timeout/0 returns default" do
      assert Config.ai_timeout() == 60_000
    end

    test "persistence_backend/0 returns default" do
      assert Config.persistence_backend() == Arbor.Persistence.Store.ETS
    end

    test "consensus_change_type/0 returns default" do
      assert Config.consensus_change_type() == :sdlc_decision
    end

    test "max_deliberation_attempts/0 returns default" do
      assert Config.max_deliberation_attempts() == 3
    end

    test "decisions_directory/0 returns default" do
      assert Config.decisions_directory() == ".arbor/decisions"
    end

    test "vision_docs/0 returns default list" do
      docs = Config.vision_docs()

      assert "VISION.md" in docs
      assert "CLAUDE.md" in docs
    end
  end

  describe "absolute_roadmap_root/0" do
    test "expands relative paths" do
      # This test assumes the default is relative
      path = Config.absolute_roadmap_root()

      assert Path.type(path) == :absolute
      assert String.ends_with?(path, ".arbor/roadmap")
    end
  end

  describe "absolute_decisions_directory/0" do
    test "expands relative paths" do
      path = Config.absolute_decisions_directory()

      assert Path.type(path) == :absolute
      assert String.ends_with?(path, ".arbor/decisions")
    end
  end
end
