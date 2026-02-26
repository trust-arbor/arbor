defmodule Arbor.Orchestrator.Pipelines.LLMRoutingExecutionTest do
  @moduledoc """
  Tier 2 execution tests for llm-routing.dot.

  The LLM routing graph is pure decision-making — all filter data is pre-computed
  and passed via initial_values. No LLM calls or I/O involved.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Test.DotTestHelper

  @moduletag :dot_execution

  describe "tier-based routing" do
    test "critical tier selects anthropic/opus when available" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "critical",
            "budget_status" => "normal",
            "avail_anthropic" => "true",
            "trust_anthropic" => "true",
            "quota_anthropic" => "true"
          }
        )

      assert DotTestHelper.visited?(result, "select_critical")
      assert DotTestHelper.context_value(result, "selected_backend") == "anthropic"
      assert DotTestHelper.context_value(result, "selected_model") == "opus"
      assert DotTestHelper.context_value(result, "routing_reason") == "tier_match"
      assert DotTestHelper.visited?(result, "done")
      refute DotTestHelper.visited?(result, "failed")
    end

    test "critical tier falls back to sonnet when opus unavailable" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "critical",
            "budget_status" => "normal",
            "avail_anthropic" => "true",
            "trust_anthropic" => "true",
            "quota_anthropic" => "true"
          }
        )

      # Both opus and sonnet are anthropic — first passing candidate wins
      assert DotTestHelper.context_value(result, "selected_backend") == "anthropic"
    end

    test "complex tier selects first available candidate" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "complex",
            "budget_status" => "normal",
            "avail_anthropic" => "true",
            "avail_openai" => "true",
            "avail_gemini" => "true",
            "trust_anthropic" => "true",
            "trust_openai" => "true",
            "trust_gemini" => "true",
            "quota_anthropic" => "true",
            "quota_openai" => "true",
            "quota_gemini" => "true"
          }
        )

      assert DotTestHelper.visited?(result, "select_complex")
      assert DotTestHelper.context_value(result, "selected_backend") == "anthropic"
      assert DotTestHelper.context_value(result, "selected_model") == "sonnet"
    end

    test "simple tier routes to cost-effective models" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "simple",
            "budget_status" => "normal",
            "avail_opencode" => "true",
            "avail_qwen" => "true",
            "trust_opencode" => "true",
            "trust_qwen" => "true",
            "quota_opencode" => "true",
            "quota_qwen" => "true"
          }
        )

      assert DotTestHelper.visited?(result, "select_simple")
      assert DotTestHelper.context_value(result, "selected_backend") == "opencode"
      assert DotTestHelper.context_value(result, "selected_model") == "grok"
    end

    test "trivial tier uses cheapest models" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "trivial",
            "budget_status" => "normal",
            "avail_opencode" => "true",
            "avail_qwen" => "true",
            "trust_opencode" => "true",
            "trust_qwen" => "true",
            "quota_opencode" => "true",
            "quota_qwen" => "true"
          }
        )

      assert DotTestHelper.visited?(result, "select_trivial")
      refute DotTestHelper.visited?(result, "select_critical")
    end
  end

  describe "fallback routing" do
    test "falls back when tier-specific selection fails" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "critical",
            "budget_status" => "normal",
            # anthropic unavailable — critical selection fails
            "avail_anthropic" => "false",
            # fallback candidates
            "avail_lmstudio" => "true",
            "trust_lmstudio" => "true",
            "quota_lmstudio" => "true"
          }
        )

      assert DotTestHelper.visited?(result, "select_critical")
      assert DotTestHelper.visited?(result, "select_fallback")
      assert DotTestHelper.context_value(result, "selected_backend") == "lmstudio"
      assert DotTestHelper.context_value(result, "routing_reason") == "fallback"
    end

    test "routes to failed when all backends unavailable" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "moderate",
            "budget_status" => "normal"
            # No backends available — all default to "false"
          }
        )

      assert DotTestHelper.visited?(result, "select_moderate")
      assert DotTestHelper.visited?(result, "select_fallback")
      assert DotTestHelper.visited?(result, "failed")
      refute DotTestHelper.visited?(result, "done")
    end
  end

  describe "budget filtering" do
    test "over budget only selects free backends" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "moderate",
            "budget_status" => "over",
            # gemini available but not free
            "avail_gemini" => "true",
            "trust_gemini" => "true",
            "quota_gemini" => "true",
            "free_gemini" => "false",
            # anthropic available but not free
            "avail_anthropic" => "true",
            "trust_anthropic" => "true",
            "quota_anthropic" => "true",
            "free_anthropic" => "false"
          }
        )

      # No free candidates, should fail through to fallback
      assert DotTestHelper.visited?(result, "select_fallback")
    end

    test "critical tier ignores budget constraints" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "critical",
            "budget_status" => "over",
            "avail_anthropic" => "true",
            "trust_anthropic" => "true",
            "quota_anthropic" => "true",
            "free_anthropic" => "false"
          }
        )

      # Critical ignores budget — should succeed despite being over budget
      assert DotTestHelper.visited?(result, "select_critical")
      assert DotTestHelper.context_value(result, "selected_backend") == "anthropic"
      assert DotTestHelper.visited?(result, "done")
    end
  end

  describe "exclusion filtering" do
    test "excluded backends are skipped" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "complex",
            "budget_status" => "normal",
            "exclude" => "anthropic",
            "avail_anthropic" => "true",
            "avail_openai" => "true",
            "avail_gemini" => "true",
            "trust_anthropic" => "true",
            "trust_openai" => "true",
            "trust_gemini" => "true",
            "quota_anthropic" => "true",
            "quota_openai" => "true",
            "quota_gemini" => "true"
          }
        )

      # anthropic excluded, should select openai (next in complex tier)
      assert DotTestHelper.context_value(result, "selected_backend") == "openai"
      assert DotTestHelper.context_value(result, "selected_model") == "gpt5"
    end
  end

  describe "trust filtering" do
    test "untrusted backends are skipped" do
      {:ok, result} =
        DotTestHelper.run_pipeline("llm-routing.dot",
          simulate_compute: false,
          skip_validation: true,
          initial_values: %{
            "tier" => "complex",
            "budget_status" => "normal",
            "avail_anthropic" => "true",
            "avail_openai" => "true",
            "avail_gemini" => "true",
            "trust_anthropic" => "false",
            "trust_openai" => "true",
            "trust_gemini" => "true",
            "quota_openai" => "true",
            "quota_gemini" => "true"
          }
        )

      # anthropic untrusted, should skip to openai
      assert DotTestHelper.context_value(result, "selected_backend") == "openai"
    end
  end
end
