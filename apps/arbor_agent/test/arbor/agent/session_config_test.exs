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

  describe "build/2 — compactor window (regression: per-model, not flat 75k)" do
    # Regression for the 2026-07-04 context-compaction audit: session_config used to pass
    # effective_window: 75_000, which shadowed ContextCompactor's per-model derivation
    # (it only calls ModelProfile.effective_window(model) when NO explicit window is passed).
    # Result: every session compacted at a flat 75k regardless of model — blowing small-window
    # models (e.g. a 32k model: 75k > 32k → provider errors). Fix passes nil through so the
    # compactor derives per-model. This test fails on the pre-fix code (75_000) and passes now.
    test "compactor derives effective_window from the model, not a hardcoded 75_000" do
      opts =
        SessionConfig.build("agent_test",
          model: "claude-opus-4-6",
          context_management: :full,
          recover_session: false
        )

      {Arbor.Agent.ContextCompactor, compactor_opts} = Keyword.fetch!(opts, :compactor)

      # session_config must NOT inject a flat 75_000 default (that was the shadowing bug)
      refute Keyword.get(compactor_opts, :effective_window) == 75_000

      # the compactor derives the window from the model (opus-4-6 = 200k * 0.75 = 150k)
      compactor = Arbor.Agent.ContextCompactor.new(compactor_opts)
      assert compactor.effective_window == Arbor.Common.ModelProfile.effective_window("claude-opus-4-6")
      refute compactor.effective_window == 75_000
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
