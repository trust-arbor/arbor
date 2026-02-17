defmodule Arbor.Orchestrator.Engine.FidelityTransformerTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.{Context, FidelityTransformer}

  defp context_with_data do
    Context.new(%{
      "current_node" => "test",
      "graph.goal" => "build feature",
      "workdir" => "/tmp",
      "last_response" => String.duplicate("x", 5000),
      "code_output" => "def hello, do: :world",
      "items" => [1, 2, 3],
      "metadata" => %{"key" => "value", "nested" => %{"a" => 1}}
    })
  end

  describe "full mode" do
    test "returns context unchanged" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "full")
      assert result == ctx
    end
  end

  describe "truncate mode" do
    test "truncates long string values" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "truncate", truncate_limit: 100)

      response = Context.get(result, "last_response")
      assert String.length(response) < 5000
      assert String.contains?(response, "[truncated at 100 chars]")
    end

    test "preserves short string values" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "truncate", truncate_limit: 100)

      assert Context.get(result, "code_output") == "def hello, do: :world"
    end

    test "preserves passthrough keys regardless of length" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "truncate", truncate_limit: 5)

      assert Context.get(result, "graph.goal") == "build feature"
      assert Context.get(result, "current_node") == "test"
      assert Context.get(result, "workdir") == "/tmp"
    end
  end

  describe "compact mode" do
    test "summarizes long strings with length info" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "compact")

      response = Context.get(result, "last_response")
      assert String.contains?(response, "5000 chars total")
    end

    test "preserves short strings" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "compact")

      assert Context.get(result, "code_output") == "def hello, do: :world"
    end

    test "summarizes lists as item count" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "compact")

      assert Context.get(result, "items") == "[3 items]"
    end

    test "summarizes maps as key count" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "compact")

      assert Context.get(result, "metadata") == "%{2 keys}"
    end

    test "preserves passthrough keys" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "compact")

      assert Context.get(result, "graph.goal") == "build feature"
    end
  end

  describe "summary modes" do
    test "falls back to compact when no llm_backend" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "summary:medium")

      # Should behave like compact
      assert Context.get(result, "items") == "[3 items]"
    end

    test "calls llm_backend when provided" do
      ctx = context_with_data()

      llm_fn = fn _prompt, _opts ->
        {:ok, "Pipeline is building a feature with code output."}
      end

      result = FidelityTransformer.transform(ctx, "summary:medium", llm_backend: llm_fn)

      assert Context.get(result, "context.summary") ==
               "Pipeline is building a feature with code output."

      assert Context.get(result, "context.summary.level") == "medium"
      # Passthrough keys survive
      assert Context.get(result, "graph.goal") == "build feature"
    end

    test "falls back to compact on llm failure" do
      ctx = context_with_data()
      llm_fn = fn _prompt, _opts -> {:error, :timeout} end

      result = FidelityTransformer.transform(ctx, "summary:high", llm_backend: llm_fn)

      # Should behave like compact
      assert Context.get(result, "items") == "[3 items]"
    end

    test "summary:low prompt requests brief output" do
      ctx = context_with_data()
      received_prompt = :ets.new(:prompt_capture, [:set, :public])

      llm_fn = fn prompt, _opts ->
        :ets.insert(received_prompt, {:prompt, prompt})
        {:ok, "brief"}
      end

      FidelityTransformer.transform(ctx, "summary:low", llm_backend: llm_fn)

      [{:prompt, prompt}] = :ets.lookup(received_prompt, :prompt)
      assert String.contains?(prompt, "very brief")
      :ets.delete(received_prompt)
    end

    test "summary:high prompt requests detailed output" do
      ctx = context_with_data()
      received_prompt = :ets.new(:prompt_capture, [:set, :public])

      llm_fn = fn prompt, _opts ->
        :ets.insert(received_prompt, {:prompt, prompt})
        {:ok, "detailed"}
      end

      FidelityTransformer.transform(ctx, "summary:high", llm_backend: llm_fn)

      [{:prompt, prompt}] = :ets.lookup(received_prompt, :prompt)
      assert String.contains?(prompt, "detailed summary")
      :ets.delete(received_prompt)
    end
  end

  describe "unknown mode" do
    test "falls back to compact" do
      ctx = context_with_data()
      result = FidelityTransformer.transform(ctx, "invalid_mode")

      assert Context.get(result, "items") == "[3 items]"
    end
  end

  describe "edge cases" do
    test "empty context" do
      ctx = Context.new()
      result = FidelityTransformer.transform(ctx, "compact")
      assert Context.snapshot(result) == %{}
    end

    test "preserves lineage through transform" do
      ctx = %{Context.new(%{"key" => "value"}) | lineage: %{"key" => "node_1"}}
      result = FidelityTransformer.transform(ctx, "compact")
      assert Context.origin(result, "key") == "node_1"
    end
  end
end
