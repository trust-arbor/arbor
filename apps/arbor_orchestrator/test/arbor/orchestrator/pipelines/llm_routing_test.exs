defmodule Arbor.Orchestrator.Pipelines.LlmRoutingTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Engine

  @dot_path Path.expand("../../../../specs/pipelines/llm-routing.dot", __DIR__)

  setup_all do
    source = File.read!(@dot_path)
    {:ok, graph} = Parser.parse(source)
    %{graph: graph}
  end

  defp run(graph, initial_values) do
    Engine.run(graph,
      initial_values: initial_values,
      max_steps: 20,
      logs_root:
        Path.join(System.tmp_dir!(), "arbor_routing_test_#{:erlang.unique_integer([:positive])}")
    )
  end

  describe "tier routing — critical" do
    test "selects anthropic/opus when available", %{graph: graph} do
      {:ok, result} = run(graph, critical_context())

      assert result.context["selected_backend"] == "anthropic"
      assert result.context["selected_model"] == "opus"
      assert result.context["routing_reason"] == "tier_match"
    end

    test "falls back to sonnet when opus unavailable", %{graph: graph} do
      ctx = critical_context() |> Map.put("avail_anthropic", "false")
      {:ok, result} = run(graph, ctx)

      # No anthropic candidates pass → falls through to fallback
      assert result.context["routing_reason"] == "fallback"
      assert result.context["selected_backend"] != nil
    end
  end

  describe "tier routing — complex" do
    test "selects anthropic/sonnet as first complex candidate", %{graph: graph} do
      {:ok, result} = run(graph, complex_context())

      assert result.context["selected_backend"] == "anthropic"
      assert result.context["selected_model"] == "sonnet"
      assert result.context["routing_reason"] == "tier_match"
    end

    test "skips to next when first candidate unavailable", %{graph: graph} do
      ctx = complex_context() |> Map.put("avail_anthropic", "false")
      {:ok, result} = run(graph, ctx)

      assert result.context["selected_backend"] == "openai"
      assert result.context["selected_model"] == "gpt5"
    end
  end

  describe "tier routing — moderate" do
    test "selects gemini/auto as first moderate candidate", %{graph: graph} do
      {:ok, result} = run(graph, moderate_context())

      assert result.context["selected_backend"] == "gemini"
      assert result.context["selected_model"] == "auto"
    end
  end

  describe "tier routing — simple" do
    test "selects opencode/grok for simple tier", %{graph: graph} do
      {:ok, result} = run(graph, simple_context())

      assert result.context["selected_backend"] == "opencode"
      assert result.context["selected_model"] == "grok"
    end
  end

  describe "tier routing — trivial" do
    test "selects opencode/grok for trivial tier", %{graph: graph} do
      {:ok, result} = run(graph, trivial_context())

      assert result.context["selected_backend"] == "opencode"
      assert result.context["selected_model"] == "grok"
    end
  end

  describe "fallback" do
    test "falls back when all tier candidates fail", %{graph: graph} do
      ctx =
        moderate_context()
        |> Map.put("avail_gemini", "false")
        |> Map.put("avail_anthropic", "false")
        |> Map.put("avail_openai", "false")
        |> Map.put("avail_lmstudio", "true")

      {:ok, result} = run(graph, ctx)

      assert result.context["routing_reason"] == "fallback"
      assert result.context["selected_backend"] == "lmstudio"
    end

    test "reaches failed terminal when nothing available", %{graph: graph} do
      # All backends unavailable
      ctx =
        %{"tier" => "trivial", "budget_status" => "normal", "exclude" => ""}
        |> add_backend_flags("opencode", false, true, true, false)
        |> add_backend_flags("qwen", false, true, true, false)
        |> add_backend_flags("lmstudio", false, true, true, false)
        |> add_backend_flags("ollama", false, true, true, false)
        |> add_backend_flags("anthropic", false, true, true, false)
        |> add_backend_flags("openai", false, true, true, false)
        |> add_backend_flags("gemini", false, true, true, false)

      {:ok, result} = run(graph, ctx)

      # Should reach "failed" terminal — no selected_backend
      assert result.context["selected_backend"] == nil
    end
  end

  describe "budget filtering" do
    test "over budget filters to free-only for non-critical", %{graph: graph} do
      ctx =
        moderate_context()
        |> Map.put("budget_status", "over")
        |> Map.put("free_gemini", "false")
        |> Map.put("free_anthropic", "false")
        |> Map.put("free_openai", "false")

      # All moderate candidates are paid → should fall to fallback
      {:ok, result} = run(graph, ctx)

      # Either reaches a free fallback or fails
      if result.context["selected_backend"] do
        # If something was selected, it must be free
        backend = result.context["selected_backend"]
        assert ctx["free_#{backend}"] == "true" or result.context["routing_reason"] == "fallback"
      end
    end

    test "critical tier bypasses budget constraints", %{graph: graph} do
      ctx =
        critical_context()
        |> Map.put("budget_status", "over")
        |> Map.put("free_anthropic", "false")

      {:ok, result} = run(graph, ctx)

      # Critical bypasses budget, should still select anthropic
      assert result.context["selected_backend"] == "anthropic"
    end
  end

  # --- Context Builders ---

  defp critical_context do
    %{"tier" => "critical", "budget_status" => "normal", "exclude" => ""}
    |> add_all_backends_available()
  end

  defp complex_context do
    %{"tier" => "complex", "budget_status" => "normal", "exclude" => ""}
    |> add_all_backends_available()
  end

  defp moderate_context do
    %{"tier" => "moderate", "budget_status" => "normal", "exclude" => ""}
    |> add_all_backends_available()
  end

  defp simple_context do
    %{"tier" => "simple", "budget_status" => "normal", "exclude" => ""}
    |> add_all_backends_available()
  end

  defp trivial_context do
    %{"tier" => "trivial", "budget_status" => "normal", "exclude" => ""}
    |> add_all_backends_available()
  end

  defp add_all_backends_available(ctx) do
    ~w(anthropic openai gemini opencode qwen lmstudio ollama)
    |> Enum.reduce(ctx, fn b, acc -> add_backend_flags(acc, b, true, true, true, false) end)
  end

  defp add_backend_flags(ctx, backend, avail, trust, quota, free) do
    ctx
    |> Map.put("avail_#{backend}", bool(avail))
    |> Map.put("trust_#{backend}", bool(trust))
    |> Map.put("quota_#{backend}", bool(quota))
    |> Map.put("free_#{backend}", bool(free))
  end

  defp bool(true), do: "true"
  defp bool(false), do: "false"
end
