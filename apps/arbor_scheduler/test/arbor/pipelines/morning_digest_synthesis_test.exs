defmodule Arbor.Pipelines.MorningDigestSynthesisTest do
  @moduledoc """
  Smoke checks for the morning-digest synthesis reference pipeline.

  Like `upstream-deps-summary`, this pipeline calls an LLM via a
  `compute` node, so end-to-end execution is gated on a running LLM
  provider. Tests cover what we can assert offline: DOT parses, node
  shape, expected LLM configuration.
  """

  use ExUnit.Case, async: true

  alias Arbor.Orchestrator

  @pipeline_path "priv/pipelines/morning_digest_synthesis.dot"

  setup do
    app_dir = Path.expand("../../..", __DIR__)
    %{pipeline_abs: Path.join(app_dir, @pipeline_path)}
  end

  describe "pipeline artifact" do
    test "DOT file exists", %{pipeline_abs: pipeline_abs} do
      assert File.exists?(pipeline_abs)
    end

    test "DOT parses successfully", %{pipeline_abs: pipeline_abs} do
      source = File.read!(pipeline_abs)
      assert {:ok, _graph} = Orchestrator.parse(source)
    end

    test "graph carries the expected top-level shape", %{pipeline_abs: pipeline_abs} do
      source = File.read!(pipeline_abs)
      {:ok, graph} = Orchestrator.parse(source)

      assert Map.has_key?(graph.nodes, "start")
      assert Map.has_key?(graph.nodes, "done")
      assert Map.has_key?(graph.nodes, "build_input_path")
      assert Map.has_key?(graph.nodes, "build_output_path")
      assert Map.has_key?(graph.nodes, "read_digest")
      assert Map.has_key?(graph.nodes, "write_synthesis")
      assert Map.has_key?(graph.nodes, "synthesize")
    end

    test "synthesize is a compute node with the expected LLM config", %{
      pipeline_abs: pipeline_abs
    } do
      source = File.read!(pipeline_abs)
      {:ok, graph} = Orchestrator.parse(source)

      synth = graph.nodes["synthesize"]

      assert synth.attrs["type"] == "compute"
      assert synth.attrs["purpose"] == "llm"
      assert synth.attrs["simulate"] == "false"
      assert synth.attrs["llm_provider"] == "lm_studio"
      assert synth.attrs["llm_model"] =~ "gemma"
      assert synth.attrs["prompt_context_key"] == "exec.read_digest.content"
    end

    test "read_digest + write_synthesis reference the expected file actions", %{
      pipeline_abs: pipeline_abs
    } do
      source = File.read!(pipeline_abs)
      {:ok, graph} = Orchestrator.parse(source)

      read = graph.nodes["read_digest"]
      assert read.attrs["type"] == "exec"
      assert read.attrs["action"] == "file_read"

      write = graph.nodes["write_synthesis"]
      assert write.attrs["type"] == "exec"
      assert write.attrs["action"] == "file_write"
    end

    test "validates without errors", %{pipeline_abs: pipeline_abs} do
      source = File.read!(pipeline_abs)
      diagnostics = Orchestrator.validate(source)
      errors = Enum.filter(diagnostics, &(&1.severity == :error))

      assert errors == [], "Expected no validation errors, got: #{inspect(errors)}"
    end
  end
end
