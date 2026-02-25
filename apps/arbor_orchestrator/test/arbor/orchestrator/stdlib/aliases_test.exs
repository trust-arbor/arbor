defmodule Arbor.Orchestrator.Stdlib.AliasesTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Stdlib.Aliases

  @canonical_types ~w(
    start exit branch parallel fan_in
    compute transform exec
    read write
    compose map adapt
    wait
    gate
  )

  describe "canonical_types/0" do
    test "returns exactly 15 canonical types" do
      assert length(Aliases.canonical_types()) == 15
    end

    test "contains all expected types" do
      for type <- @canonical_types do
        assert type in Aliases.canonical_types(), "missing canonical type: #{type}"
      end
    end
  end

  describe "canonical_type/1" do
    test "canonical types map to themselves" do
      for type <- @canonical_types do
        assert Aliases.canonical_type(type) == type,
               "canonical type #{type} should map to itself"
      end
    end

    test "unknown types pass through unchanged" do
      assert Aliases.canonical_type("unknown.type") == "unknown.type"
      assert Aliases.canonical_type("custom.handler") == "custom.handler"
    end

    # Control flow aliases
    test "conditional → branch" do
      assert Aliases.canonical_type("conditional") == "branch"
    end

    test "parallel.fan_in → fan_in" do
      assert Aliases.canonical_type("parallel.fan_in") == "fan_in"
    end

    # Computation aliases
    test "codergen → compute" do
      assert Aliases.canonical_type("codergen") == "compute"
    end

    test "routing.select → compute" do
      assert Aliases.canonical_type("routing.select") == "compute"
    end

    test "prompt.ab_test → compose" do
      assert Aliases.canonical_type("prompt.ab_test") == "compose"
    end

    test "drift_detect → compose" do
      assert Aliases.canonical_type("drift_detect") == "compose"
    end

    test "retry.escalate → compose" do
      assert Aliases.canonical_type("retry.escalate") == "compose"
    end

    # Execution aliases
    test "tool → exec" do
      assert Aliases.canonical_type("tool") == "exec"
    end

    test "shell → exec" do
      assert Aliases.canonical_type("shell") == "exec"
    end

    # Write aliases
    test "file.write → write" do
      assert Aliases.canonical_type("file.write") == "write"
    end

    test "accumulator → write" do
      assert Aliases.canonical_type("accumulator") == "write"
    end

    # Composition aliases
    test "graph.invoke → compose" do
      assert Aliases.canonical_type("graph.invoke") == "compose"
    end

    test "graph.compose → compose" do
      assert Aliases.canonical_type("graph.compose") == "compose"
    end

    test "graph.adapt → adapt" do
      assert Aliases.canonical_type("graph.adapt") == "adapt"
    end

    test "pipeline.run → compose" do
      assert Aliases.canonical_type("pipeline.run") == "compose"
    end

    test "feedback.loop → compose" do
      assert Aliases.canonical_type("feedback.loop") == "compose"
    end

    test "stack.manager_loop → compose" do
      assert Aliases.canonical_type("stack.manager_loop") == "compose"
    end

    test "consensus types → compose" do
      for type <-
            ~w(consensus.propose consensus.ask consensus.await consensus.check consensus.decide) do
        assert Aliases.canonical_type(type) == "compose",
               "#{type} should map to compose"
      end
    end

    test "session types → compose" do
      session_types = ~w(
        session.classify session.memory_recall session.mode_select
        session.llm_call session.tool_dispatch session.format
        session.memory_update session.checkpoint session.background_checks
        session.process_results session.route_actions session.update_goals
        session.store_decompositions session.process_proposal_decisions
        session.consolidate session.update_working_memory session.store_identity
      )

      for type <- session_types do
        assert Aliases.canonical_type(type) == "compose",
               "#{type} should map to compose"
      end
    end

    # Coordination aliases
    test "wait.human → wait" do
      assert Aliases.canonical_type("wait.human") == "wait"
    end

    # Governance aliases
    test "output.validate → gate" do
      assert Aliases.canonical_type("output.validate") == "gate"
    end

    test "pipeline.validate → gate" do
      assert Aliases.canonical_type("pipeline.validate") == "gate"
    end
  end

  describe "resolve/1" do
    test "canonical types return :passthrough" do
      for type <- @canonical_types do
        assert Aliases.resolve(type) == :passthrough,
               "canonical type #{type} should be :passthrough"
      end
    end

    test "unknown types return :passthrough" do
      assert Aliases.resolve("unknown.type") == :passthrough
    end

    test "tool resolves with target=tool" do
      assert {"exec", %{"target" => "tool"}} = Aliases.resolve("tool")
    end

    test "shell resolves with target=shell" do
      assert {"exec", %{"target" => "shell"}} = Aliases.resolve("shell")
    end

    test "file.write resolves with target=file" do
      assert {"write", %{"target" => "file"}} = Aliases.resolve("file.write")
    end

    test "accumulator resolves with mode=append" do
      assert {"write", %{"target" => "accumulator", "mode" => "append"}} =
               Aliases.resolve("accumulator")
    end

    test "codergen resolves with purpose=llm" do
      assert {"compute", %{"purpose" => "llm"}} = Aliases.resolve("codergen")
    end

    test "routing.select resolves with purpose=routing" do
      assert {"compute", %{"purpose" => "routing"}} = Aliases.resolve("routing.select")
    end

    test "graph.invoke resolves with mode=invoke" do
      assert {"compose", %{"mode" => "invoke"}} = Aliases.resolve("graph.invoke")
    end

    test "pipeline.run resolves with mode=pipeline" do
      assert {"compose", %{"mode" => "pipeline"}} = Aliases.resolve("pipeline.run")
    end

    test "wait.human resolves with source=human" do
      assert {"wait", %{"source" => "human"}} = Aliases.resolve("wait.human")
    end

    test "output.validate resolves with predicate=output_valid" do
      assert {"gate", %{"predicate" => "output_valid"}} = Aliases.resolve("output.validate")
    end

    test "pipeline.validate resolves with predicate=pipeline_valid" do
      assert {"gate", %{"predicate" => "pipeline_valid"}} = Aliases.resolve("pipeline.validate")
    end
  end

  describe "aliases_for/1" do
    test "returns all aliases for a canonical type" do
      branch_aliases = Aliases.aliases_for("branch")
      assert "branch" in branch_aliases
      assert "conditional" in branch_aliases
    end

    test "exec includes tool and shell" do
      exec_aliases = Aliases.aliases_for("exec")
      assert "exec" in exec_aliases
      assert "tool" in exec_aliases
      assert "shell" in exec_aliases
    end

    test "compose includes graph, consensus, session, pipeline types" do
      compose_aliases = Aliases.aliases_for("compose")
      assert "compose" in compose_aliases
      assert "graph.invoke" in compose_aliases
      assert "graph.compose" in compose_aliases
      assert "pipeline.run" in compose_aliases
      assert "consensus.ask" in compose_aliases
      assert "session.llm_call" in compose_aliases
    end

    test "returns empty list for unknown type" do
      assert Aliases.aliases_for("nonexistent") == []
    end

    test "results are sorted" do
      aliases = Aliases.aliases_for("compute")
      assert aliases == Enum.sort(aliases)
    end
  end

  describe "canonical?/1" do
    test "returns true for canonical types" do
      for type <- @canonical_types do
        assert Aliases.canonical?(type), "#{type} should be canonical"
      end
    end

    test "returns false for aliases" do
      refute Aliases.canonical?("conditional")
      refute Aliases.canonical?("codergen")
      refute Aliases.canonical?("tool")
    end

    test "returns false for unknown types" do
      refute Aliases.canonical?("unknown")
    end
  end

  describe "completeness" do
    test "every type in Registry has a canonical mapping" do
      alias_map = Aliases.alias_map()
      known_types = Map.keys(alias_map)

      # Verify all canonical types are included
      for type <- @canonical_types do
        assert type in known_types,
               "canonical type #{type} missing from alias map"
      end
    end

    test "all mapped values are canonical types" do
      canonical = MapSet.new(@canonical_types)

      for {alias_name, mapped_to} <- Aliases.alias_map() do
        assert MapSet.member?(canonical, mapped_to),
               "#{alias_name} maps to #{mapped_to} which is not a canonical type"
      end
    end

    test "every canonical type has at least itself as an alias" do
      for type <- @canonical_types do
        aliases = Aliases.aliases_for(type)
        assert type in aliases, "canonical type #{type} missing from its own aliases"
      end
    end
  end
end
