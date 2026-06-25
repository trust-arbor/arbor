defmodule Arbor.Orchestrator.PreprocessorTest do
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.{Config, Preprocessor}

  @app :arbor_orchestrator

  setup do
    # Preserve and restore the flag + per-stage config so tests don't leak.
    original = Application.get_env(@app, :preprocessor_enabled, false)
    original_pp = Application.get_env(@app, :preprocessor)

    on_exit(fn ->
      Application.put_env(@app, :preprocessor_enabled, original)

      if original_pp,
        do: Application.put_env(@app, :preprocessor, original_pp),
        else: Application.delete_env(@app, :preprocessor)
    end)

    :ok
  end

  describe "disabled by default (the fail-safe invariant)" do
    test "preprocessor is off by default" do
      Application.delete_env(@app, :preprocessor_enabled)
      refute Config.preprocessor_enabled?()
    end

    test "run/2 is a true no-op when disabled — returns empty map, no provider calls" do
      Application.put_env(@app, :preprocessor_enabled, false)
      # No Ollama/LM Studio needed; must not raise or call out.
      assert {:ok, %{}} = Preprocessor.run("delete the old logs and commit")
    end
  end

  describe "tier derivation (pure, no I/O)" do
    test "needs_tools=false → DIRECT regardless of complexity" do
      assert Preprocessor.derive_tier(false, "SIMPLE") == "DIRECT"
      assert Preprocessor.derive_tier(false, "MULTI_STEP") == "DIRECT"
    end

    test "needs_tools=true splits by complexity" do
      assert Preprocessor.derive_tier(true, "SIMPLE") == "STANDARD"
      assert Preprocessor.derive_tier(true, "MULTI_STEP") == "DEEP"
      assert Preprocessor.derive_tier(true, "NON_ACTIONABLE") == "DEEP"
    end
  end

  describe "tool_override (engine consumption decision)" do
    test "DIRECT empties the tool list by default (no-tools fast lane)" do
      assert Preprocessor.tool_override(%{"tier" => "DIRECT"}) == {:override, []}
    end

    test "DIRECT is advisory-only when direct_skips_tools? is false (insurance)" do
      assert Preprocessor.tool_override(%{"tier" => "DIRECT"}, direct_skips_tools?: false) ==
               :no_override
    end

    test "STANDARD / DEEP do not override (normal tool resolution)" do
      assert Preprocessor.tool_override(%{"tier" => "STANDARD"}) == :no_override
      assert Preprocessor.tool_override(%{"tier" => "DEEP"}) == :no_override
    end

    test "an explicit retrieved_tools list always wins (JIT injection hook)" do
      tools = ["file_read", "git_commit"]
      # even on DIRECT, an explicit retrieval list takes precedence
      assert Preprocessor.tool_override(%{"tier" => "DIRECT", "retrieved_tools" => tools}) ==
               {:override, tools}

      assert Preprocessor.tool_override(%{"tier" => "STANDARD", "retrieved_tools" => tools}) ==
               {:override, tools}
    end

    test "empty preproc map → no override" do
      assert Preprocessor.tool_override(%{}) == :no_override
    end
  end

  describe "expand_modules (retrieval module → action-name mapping)" do
    test "a retrieved index module fans out to all its action names (dot-form)" do
      names = Preprocessor.expand_modules(["Arbor.Actions.File"])

      if Code.ensure_loaded?(Arbor.Actions) do
        # dot-form names that LlmHandler.resolve_tools/definitions accepts
        assert "file.read" in names
        assert "file.write" in names
        # all File.* actions, nothing from other modules
        assert Enum.all?(names, &String.starts_with?(&1, "file."))
      else
        # arbor_actions isn't on the code path (e.g. running from inside the
        # orchestrator app, which doesn't depend on it) — the runtime registry is
        # unavailable, so the mapping correctly resolves to []. The real-registry
        # assertion runs from the umbrella root / CI.
        assert names == []
      end
    end

    test "multiple modules union and dedup" do
      names = Preprocessor.expand_modules(["Arbor.Actions.Git", "Arbor.Actions.Git"])
      # dedup holds regardless of registry availability ([] is its own uniq)
      assert names == Enum.uniq(names)
      if Code.ensure_loaded?(Arbor.Actions), do: assert("git.commit" in names)
    end

    test "an unknown module maps to nothing (no crash)" do
      assert Preprocessor.expand_modules(["Arbor.Actions.NoSuchThing"]) == []
    end

    test "empty input → empty output" do
      assert Preprocessor.expand_modules([]) == []
    end
  end

  describe "per-stage enabled toggles (consolidation)" do
    test "disabling the LLM stages makes run/2 a no-network actionable pass" do
      # With needs_tools + complexity (+ sensitivity) disabled, NO stage makes a
      # provider/network call — proving the uniform `enabled:` toggle works and that
      # a disabled gate falls back to its safe default (no LM Studio/Ollama needed).
      Application.put_env(@app, :preprocessor_enabled, true)

      Application.put_env(@app, :preprocessor,
        sensitivity: [enabled: false],
        needs_tools: [enabled: false],
        complexity: [enabled: false]
      )

      assert {:ok, result} = Preprocessor.run("delete the old logs and commit")
      # needs_tools disabled → fail-safe default true (never a wrong DIRECT skip)
      assert result["needs_tools"] == true
      # complexity disabled → default "SIMPLE"
      assert result["complexity"] == "SIMPLE"
      # derive_tier(true, "SIMPLE") → STANDARD (no fast-lane, normal tool resolution)
      assert result["tier"] == "STANDARD"
      assert result["sensitivity"] == nil
      refute Map.has_key?(result, "retrieved_tools")
    end
  end

  describe "consolidated defaults (one LM Studio model for the whole preprocessor)" do
    test "complexity defaults to LM Studio + the locked model with a generous budget" do
      Application.delete_env(@app, :preprocessor)
      cx = Config.preprocessor_stage(:complexity)
      assert cx[:provider] == :lm_studio
      assert cx[:model] == "gemma-4-e4b-it-qat"
      # generous token budget — the 3-way judgment reasons more than the binary gate
      assert cx[:max_tokens] >= 1024
    end

    test "needs_tools and complexity share one model (no multi-model VRAM needed)" do
      Application.delete_env(@app, :preprocessor)
      cfg = Config.preprocessor()
      assert cfg[:needs_tools][:model] == cfg[:complexity][:model]
      assert cfg[:needs_tools][:provider] == :lm_studio
    end
  end

  describe "config merge" do
    test "partial override merges over defaults without dropping other keys" do
      original = Application.get_env(@app, :preprocessor)

      Application.put_env(@app, :preprocessor, needs_tools: [model: "some-other-model@q4"])

      cfg = Config.preprocessor()
      ns = Keyword.get(cfg, :needs_tools)
      # overridden value present
      assert ns[:model] == "some-other-model@q4"
      # default sibling keys still present after merge
      assert ns[:provider] == :lm_studio
      # untouched stages still present
      assert Keyword.has_key?(cfg, :complexity)
      assert Keyword.get(cfg, :timeout_ms) == 30_000

      Application.put_env(@app, :preprocessor, original || [])
    end
  end
end
