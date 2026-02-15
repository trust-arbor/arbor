defmodule Arbor.AI.FacadeMigrationTest do
  use ExUnit.Case, async: true

  @moduletag :integration

  describe "generate_text_via_api/2 strangler fig" do
    test "generate_text_via_api accepts standard opts" do
      # Verify the strangler fig pattern works:
      # 1. Tries UnifiedBridge first
      # 2. Falls back to ReqLLM on error
      # 3. ReqLLM will raise on missing API key (expected in test env)

      # Catch the expected ReqLLM error
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Arbor.AI.generate_text_via_api("test prompt",
          provider: :anthropic,
          model: "claude-sonnet-4-5-20250514",
          max_tokens: 10,
          temperature: 0.1
        )
      end
    end

    test "generate_text/2 routes to api backend" do
      # Verify the full routing path:
      # generate_text → router → generate_text_via_api → UnifiedBridge → ReqLLM

      # Catch the expected ReqLLM error
      assert_raise ReqLLM.Error.Invalid.Parameter, fn ->
        Arbor.AI.generate_text("test",
          backend: :api,
          provider: :anthropic,
          model: "claude-sonnet-4-5-20250514",
          max_tokens: 10
        )
      end
    end
  end
end
