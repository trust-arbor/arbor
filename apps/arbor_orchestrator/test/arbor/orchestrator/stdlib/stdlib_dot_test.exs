defmodule Arbor.Orchestrator.Stdlib.StdlibDotTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Stdlib.Aliases
  alias Arbor.Orchestrator.Validation.Validator

  @stdlib_dir Path.join([
                File.cwd!(),
                "specs",
                "pipelines",
                "stdlib"
              ])

  @stdlib_files [
    # Core patterns
    "retry-escalate.dot",
    "feedback-loop.dot",
    "propose-approve.dot",
    "map-reduce.dot",
    # LLM patterns
    "llm-with-tools.dot",
    "llm-validate.dot",
    "llm-chain.dot",
    # Agent patterns
    "goal-decompose.dot",
    "observe-decide-act.dot",
    # Data patterns
    "etl.dot",
    "drift-detect.dot",
    "ab-test.dot"
  ]

  # Resolve the stdlib directory — handle CWD variance in umbrella
  defp resolve_stdlib_dir do
    candidates = [
      @stdlib_dir,
      Path.join([File.cwd!(), "apps", "arbor_orchestrator", "specs", "pipelines", "stdlib"])
    ]

    Enum.find(candidates, fn dir -> File.dir?(dir) end) ||
      raise "Could not find stdlib directory. Tried: #{inspect(candidates)}"
  end

  defp parse_stdlib(filename) do
    path = Path.join(resolve_stdlib_dir(), filename)
    source = File.read!(path)
    Parser.parse(source)
  end

  describe "all stdlib DOTs exist" do
    test "stdlib directory contains exactly 12 DOT files" do
      dir = resolve_stdlib_dir()
      files = dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".dot")) |> Enum.sort()

      assert length(files) == 12,
             "Expected 12 stdlib DOTs, got #{length(files)}: #{inspect(files)}"
    end

    test "all expected files are present" do
      dir = resolve_stdlib_dir()
      existing = File.ls!(dir) |> MapSet.new()

      for file <- @stdlib_files do
        assert MapSet.member?(existing, file), "Missing stdlib DOT: #{file}"
      end
    end
  end

  for file <- @stdlib_files do
    describe "#{file}" do
      test "parses without error" do
        assert {:ok, _graph} = parse_stdlib(unquote(file))
      end

      test "validates without errors" do
        {:ok, graph} = parse_stdlib(unquote(file))
        diagnostics = Validator.validate(graph)
        errors = Enum.filter(diagnostics, &(&1.severity == :error))

        assert errors == [],
               "Validation errors in #{unquote(file)}: #{inspect(Enum.map(errors, & &1.message))}"
      end

      test "uses only canonical handler types" do
        {:ok, graph} = parse_stdlib(unquote(file))

        for {node_id, node} <- graph.nodes do
          type = node.type || Map.get(node.attrs, "type")

          if type && type not in ["", nil] do
            assert Aliases.canonical?(type),
                   "Node #{node_id} in #{unquote(file)} uses non-canonical type: #{inspect(type)}"
          end
        end
      end

      test "has start and exit nodes" do
        {:ok, graph} = parse_stdlib(unquote(file))
        node_ids = Map.keys(graph.nodes)

        # Validator identifies start by shape=Mdiamond or id="start"
        has_start =
          Enum.any?(graph.nodes, fn {id, node} ->
            Map.get(node.attrs, "shape") == "Mdiamond" ||
              String.downcase(id) == "start"
          end)

        # Validator identifies terminal by shape=Msquare or id in ["exit", "end"]
        has_exit =
          Enum.any?(graph.nodes, fn {id, node} ->
            Map.get(node.attrs, "shape") == "Msquare" ||
              String.downcase(id) in ["exit", "end"]
          end)

        assert has_start,
               "#{unquote(file)} missing start node. Nodes: #{inspect(node_ids)}"

        assert has_exit,
               "#{unquote(file)} missing exit node. Nodes: #{inspect(node_ids)}"
      end

      test "has no unreachable nodes" do
        {:ok, graph} = parse_stdlib(unquote(file))
        diagnostics = Validator.validate(graph)

        reachability_errors =
          Enum.filter(diagnostics, fn d ->
            d.severity == :error && d.rule == "reachability"
          end)

        assert reachability_errors == [],
               "Unreachable nodes in #{unquote(file)}: #{inspect(Enum.map(reachability_errors, & &1.message))}"
      end
    end
  end
end
