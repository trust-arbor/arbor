defmodule Arbor.Orchestrator.Eval.SpecSplitterTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Eval.SpecSplitter

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "spec_splitter_test_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  @sample_spec """
  # Attractor Spec

  Some preamble text.

  ## 1. Overview and Goals

  This is the overview section describing the system.

  ## 2. DOT DSL Schema

  The DOT DSL defines the pipeline format.

  ## 3. Pipeline Execution Engine

  The engine runs pipelines step by step.

  ## 4. Node Handlers

  Handlers execute individual nodes.

  ## 7. Validation and Linting

  Validation ensures pipelines are correct.
  """

  describe "split/1" do
    test "splits spec into subsystem map", %{tmp: tmp} do
      path = Path.join(tmp, "spec.md")
      File.write!(path, @sample_spec)

      {:ok, map} = SpecSplitter.split(path)

      assert is_map(map)
      assert map["dot"] =~ "DOT DSL"
      assert map["engine"] =~ "engine runs pipelines"
      assert map["handlers"] =~ "Handlers execute"
      assert map["validation"] =~ "Validation ensures"
    end

    test "unmapped subsystems get empty string", %{tmp: tmp} do
      path = Path.join(tmp, "spec.md")
      File.write!(path, @sample_spec)

      {:ok, map} = SpecSplitter.split(path)

      # unified_llm has no spec section mapped
      assert map["unified_llm"] == ""
      assert map["agent_loop"] == ""
    end

    test "returns error for missing file" do
      assert {:error, _} = SpecSplitter.split("/nonexistent/spec.md")
    end
  end

  describe "split_with_preamble/1" do
    test "prepends overview to non-empty subsystems", %{tmp: tmp} do
      path = Path.join(tmp, "spec.md")
      File.write!(path, @sample_spec)

      {:ok, map} = SpecSplitter.split_with_preamble(path)

      # dot subsystem should have the preamble prepended
      assert map["dot"] =~ "overview section"
      assert map["dot"] =~ "DOT DSL"

      # empty subsystems stay empty
      assert map["unified_llm"] == ""
    end
  end

  describe "list_unmapped_subsystems/1" do
    test "returns subsystems with no spec coverage", %{tmp: tmp} do
      path = Path.join(tmp, "spec.md")
      File.write!(path, @sample_spec)

      {:ok, unmapped} = SpecSplitter.list_unmapped_subsystems(path)

      assert is_list(unmapped)
      assert "unified_llm" in unmapped
      assert "agent_loop" in unmapped
      refute "dot" in unmapped
      refute "engine" in unmapped
    end
  end

  describe "all_subsystems/0" do
    test "returns all known subsystem names" do
      subs = SpecSplitter.all_subsystems()
      assert "dot" in subs
      assert "engine" in subs
      assert "handlers" in subs
      assert "eval" in subs
      assert "validation" in subs
      assert length(subs) == 11
    end
  end

  describe "with real spec" do
    test "splits attractor-spec.md if present" do
      spec_path = "specs/attractor/attractor-spec.md"

      if File.exists?(spec_path) do
        {:ok, map} = SpecSplitter.split(spec_path)

        assert map["dot"] != ""
        assert map["engine"] != ""
        assert map["handlers"] != ""

        {:ok, unmapped} = SpecSplitter.list_unmapped_subsystems(spec_path)
        assert is_list(unmapped)
      end
    end
  end
end
