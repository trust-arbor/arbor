defmodule Arbor.Agent.SessionConfigTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.SessionConfig

  describe "build/2 — LLM config" do
    test "puts llm_provider when given a :provider atom" do
      opts = SessionConfig.build("agent_test", provider: :anthropic, recover_session: false)
      config = Keyword.fetch!(opts, :config)
      assert config["llm_provider"] == "anthropic"
    end

    test "puts llm_model when given a :model string" do
      opts =
        SessionConfig.build("agent_test", model: "claude-opus-4-6", recover_session: false)

      config = Keyword.fetch!(opts, :config)
      assert config["llm_model"] == "claude-opus-4-6"
    end
  end

  describe "build/2 — runtime axis (Phase 2d)" do
    test "defaults llm_runtime to :arbor when no :runtime option given" do
      opts = SessionConfig.build("agent_test", recover_session: false)
      config = Keyword.fetch!(opts, :config)
      assert config["llm_runtime"] == :arbor
    end

    test "puts llm_runtime when :runtime option given" do
      opts = SessionConfig.build("agent_test", runtime: :acp, recover_session: false)
      config = Keyword.fetch!(opts, :config)
      assert config["llm_runtime"] == :acp
    end

    test "explicit runtime: :arbor still ends up as :arbor in config" do
      opts = SessionConfig.build("agent_test", runtime: :arbor, recover_session: false)
      config = Keyword.fetch!(opts, :config)
      assert config["llm_runtime"] == :arbor
    end
  end

  describe "build/2 — fallback chain (Phase 4+ B3)" do
    test "defaults llm_fallback_chain to [] when no :fallback_chain option" do
      opts = SessionConfig.build("agent_test", recover_session: false)
      config = Keyword.fetch!(opts, :config)
      assert config["llm_fallback_chain"] == []
    end

    test "passes :fallback_chain through to config" do
      chain = [%{runtime: :acp}, %{model: "claude-sonnet-4-6"}]

      opts =
        SessionConfig.build("agent_test", fallback_chain: chain, recover_session: false)

      config = Keyword.fetch!(opts, :config)
      assert config["llm_fallback_chain"] == chain
    end

    test "fallback_chain and runtime can both flow through" do
      opts =
        SessionConfig.build("agent_test",
          runtime: :acp,
          fallback_chain: [%{runtime: :arbor}],
          recover_session: false
        )

      config = Keyword.fetch!(opts, :config)
      assert config["llm_runtime"] == :acp
      assert config["llm_fallback_chain"] == [%{runtime: :arbor}]
    end
  end
end
