defmodule Arbor.Pipelines.UpstreamDepsSummaryTest do
  @moduledoc """
  Smoke checks for the upstream-deps-summary reference pipeline.

  Unlike the original upstream-deps-check (which runs a self-contained
  shell script), this pipeline calls an LLM via a `compute` node, so
  end-to-end execution is gated on a running LLM provider (LM Studio
  with Gemma 4 31B by default). These tests cover what we can assert
  without that dependency: the DOT parses, has the expected node
  shape, and references the expected configuration.
  """

  use ExUnit.Case, async: true

  alias Arbor.Orchestrator

  @pipeline_path "priv/pipelines/upstream_deps_summary.dot"

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

      # Sentinel nodes
      assert Map.has_key?(graph.nodes, "start")
      assert Map.has_key?(graph.nodes, "done")

      # Path-construction shells
      assert Map.has_key?(graph.nodes, "build_input_path")
      assert Map.has_key?(graph.nodes, "build_output_path")

      # File I/O actions
      assert Map.has_key?(graph.nodes, "read_report")
      assert Map.has_key?(graph.nodes, "write_summary")

      # The LLM categorization step
      assert Map.has_key?(graph.nodes, "categorize")
    end

    test "categorize is a compute node with the expected LLM config", %{
      pipeline_abs: pipeline_abs
    } do
      source = File.read!(pipeline_abs)
      {:ok, graph} = Orchestrator.parse(source)

      categorize = graph.nodes["categorize"]

      assert categorize.attrs["type"] == "compute"
      assert categorize.attrs["purpose"] == "llm"
      assert categorize.attrs["simulate"] == "false"
      assert categorize.attrs["llm_provider"] == "lm_studio"
      # The exact model id can drift over time; assert it's at least a
      # Gemma family member so accidental edits to a different model
      # surface in code review.
      assert categorize.attrs["llm_model"] =~ "gemma"
      assert categorize.attrs["prompt_context_key"] == "exec.read_report.content"
    end

    test "read_report + write_summary reference the file_read/file_write actions", %{
      pipeline_abs: pipeline_abs
    } do
      source = File.read!(pipeline_abs)
      {:ok, graph} = Orchestrator.parse(source)

      read = graph.nodes["read_report"]
      assert read.attrs["type"] == "exec"
      assert read.attrs["action"] == "file_read"

      write = graph.nodes["write_summary"]
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
