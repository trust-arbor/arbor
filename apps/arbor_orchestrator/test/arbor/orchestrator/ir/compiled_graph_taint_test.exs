defmodule Arbor.Orchestrator.IR.CompiledGraphTaintTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.{Edge, Node}
  alias Arbor.Orchestrator.IR.{Compiler, TaintProfile, Validator}

  # ── Helpers ──────────────────────────────────────────────────────────

  defp compile!(graph) do
    {:ok, compiled} = Compiler.compile(graph)
    compiled
  end

  defp simple_graph do
    %Graph{id: "Test"}
    |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
    |> Graph.add_node(%Node{id: "work", attrs: %{"prompt" => "Do something"}})
    |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
    |> Graph.add_edge(%Edge{from: "start", to: "work"})
    |> Graph.add_edge(%Edge{from: "work", to: "done"})
  end

  # ── Compiler: taint_profile population ─────────────────────────────

  describe "compile/1 — taint_profile on standard nodes" do
    test "all compiled nodes have non-nil taint_profile" do
      compiled = compile!(simple_graph())

      for {_id, node} <- compiled.nodes do
        assert node.taint_profile != nil,
               "Node #{node.id} should have a taint_profile after compilation"
      end
    end

    test "start node gets public sensitivity" do
      compiled = compile!(simple_graph())
      profile = compiled.nodes["start"].taint_profile
      assert profile.sensitivity == :public
      assert profile.wipes_sanitizations == false
    end

    test "codergen node (LLM) gets wipes_sanitizations from schema" do
      compiled = compile!(simple_graph())
      # "work" resolves to codergen which has wipes_sanitizations: true
      profile = compiled.nodes["work"].taint_profile
      assert profile.wipes_sanitizations == true
      assert profile.sensitivity == :internal
    end

    test "exit node gets public sensitivity" do
      compiled = compile!(simple_graph())
      profile = compiled.nodes["done"].taint_profile
      assert profile.sensitivity == :public
    end
  end

  describe "compile/1 — adapt node taint_profile" do
    test "adapt node gets pessimistic profile" do
      graph =
        %Graph{id: "Adapt"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "mutate",
          attrs: %{"type" => "adapt", "mutation" => "{}"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "mutate"})
        |> Graph.add_edge(%Edge{from: "mutate", to: "done"})

      compiled = compile!(graph)
      profile = compiled.nodes["mutate"].taint_profile

      assert profile == TaintProfile.pessimistic()
      assert profile.sensitivity == :restricted
      assert profile.wipes_sanitizations == true
      assert profile.provider_constraint == :can_see_restricted
    end
  end

  describe "compile/1 — taint_requires DOT attr" do
    test "taint_requires attr parsed into bitmask" do
      graph =
        %Graph{id: "TaintReq"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "work",
          attrs: %{
            "type" => "exec",
            "target" => "tool",
            "tool_command" => "echo test",
            "taint_requires" => "command_injection,path_traversal"
          }
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "work"})
        |> Graph.add_edge(%Edge{from: "work", to: "done"})

      compiled = compile!(graph)
      profile = compiled.nodes["work"].taint_profile

      # command_injection=0b100, path_traversal=0b1000
      assert TaintProfile.satisfies?(profile.required_sanitizations, 0b00001100)
    end
  end

  describe "compile/1 — sensitivity DOT attr override" do
    test "sensitivity attr overrides schema default" do
      graph =
        %Graph{id: "SensOverride"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "work",
          attrs: %{"prompt" => "x", "sensitivity" => "confidential"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "work"})
        |> Graph.add_edge(%Edge{from: "work", to: "done"})

      compiled = compile!(graph)
      assert compiled.nodes["work"].taint_profile.sensitivity == :confidential
    end
  end

  describe "compile/1 — refinements" do
    test "exec + target=shell gets command_injection + path_traversal required" do
      graph =
        %Graph{id: "ShellExec"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "run_shell",
          attrs: %{"type" => "exec", "target" => "shell", "tool_command" => "ls"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "run_shell"})
        |> Graph.add_edge(%Edge{from: "run_shell", to: "done"})

      compiled = compile!(graph)
      profile = compiled.nodes["run_shell"].taint_profile

      missing = TaintProfile.missing_sanitizations(0, profile.required_sanitizations)
      assert :command_injection in missing
      assert :path_traversal in missing
    end

    test "exec + target=tool does NOT get shell refinement" do
      graph =
        %Graph{id: "ToolExec"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "run_tool",
          attrs: %{"type" => "exec", "target" => "tool", "tool_command" => "echo"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "run_tool"})
        |> Graph.add_edge(%Edge{from: "run_tool", to: "done"})

      compiled = compile!(graph)
      profile = compiled.nodes["run_tool"].taint_profile
      # exec schema has 0 base required_sanitizations, only shell refinement adds them
      assert profile.required_sanitizations == 0
    end

    test "compute + purpose=llm gets wipes_sanitizations" do
      graph =
        %Graph{id: "LLMCompute"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "llm",
          attrs: %{"type" => "compute", "purpose" => "llm", "prompt" => "x"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "llm"})
        |> Graph.add_edge(%Edge{from: "llm", to: "done"})

      compiled = compile!(graph)
      assert compiled.nodes["llm"].taint_profile.wipes_sanitizations == true
    end

    test "compute without purpose=llm does NOT wipe" do
      graph =
        %Graph{id: "NonLLMCompute"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "calc",
          attrs: %{"type" => "compute", "purpose" => "routing"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "calc"})
        |> Graph.add_edge(%Edge{from: "calc", to: "done"})

      compiled = compile!(graph)
      assert compiled.nodes["calc"].taint_profile.wipes_sanitizations == false
    end
  end

  describe "compile/1 — all 15 canonical types produce non-nil taint_profile" do
    for type <- ~w(start exit branch parallel fan_in compute transform exec
                   read write compose map adapt wait gate) do
      test "canonical type '#{type}' gets taint_profile" do
        node_attrs =
          case unquote(type) do
            "start" -> %{"shape" => "Mdiamond"}
            "exit" -> %{"shape" => "Msquare"}
            "branch" -> %{"shape" => "diamond"}
            "adapt" -> %{"type" => "adapt", "mutation" => "{}"}
            _ -> %{"type" => unquote(type)}
          end

        graph =
          %Graph{id: "Canonical_#{unquote(type)}"}
          |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
          |> Graph.add_node(%Node{id: "target", attrs: node_attrs})
          |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
          |> Graph.add_edge(%Edge{from: "start", to: "target"})
          |> Graph.add_edge(%Edge{from: "target", to: "done"})

        compiled = compile!(graph)

        assert compiled.nodes["target"].taint_profile != nil,
               "Type '#{unquote(type)}' should produce non-nil taint_profile"
      end
    end
  end

  # ── Validator: sanitization flow ────────────────────────────────────

  describe "validator — sanitization warnings" do
    test "LLM node → shell node produces sanitization_wiped warning" do
      graph =
        %Graph{id: "LLMToShell"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "llm", attrs: %{"prompt" => "generate command"}})
        |> Graph.add_node(%Node{
          id: "shell",
          attrs: %{
            "type" => "tool",
            "tool_command" => "run"
          }
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "llm"})
        |> Graph.add_edge(%Edge{from: "llm", to: "shell"})
        |> Graph.add_edge(%Edge{from: "shell", to: "done"})

      diags = graph |> compile!() |> Validator.validate()
      sanitization_diags = Enum.filter(diags, &(&1.rule == "sanitization_wiped"))
      assert [diag | _] = sanitization_diags
      assert diag.message =~ "wipes all sanitizations"
      assert diag.fix =~ "sanitizer"
    end

    test "no sanitization warning when target has no requirements" do
      compiled = compile!(simple_graph())
      diags = Validator.validate(compiled)

      sanitization_diags =
        Enum.filter(diags, &(&1.rule in ["sanitization_wiped", "missing_sanitization"]))

      # work→done: done (exit) has 0 required_sanitizations, so no warning
      exit_related =
        Enum.filter(sanitization_diags, fn d ->
          d.edge == {"work", "done"}
        end)

      assert exit_related == []
    end

    test "existing classification checks still work (regression)" do
      graph =
        %Graph{id: "TaintRegression"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{
          id: "secret",
          attrs: %{"prompt" => "x", "data_class" => "secret"}
        })
        |> Graph.add_node(%Node{
          id: "public",
          attrs: %{"prompt" => "y", "data_class" => "public"}
        })
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "secret"})
        |> Graph.add_edge(%Edge{from: "secret", to: "public"})
        |> Graph.add_edge(%Edge{from: "public", to: "done"})

      diags = graph |> compile!() |> Validator.validate()
      taint_errors = Enum.filter(diags, &(&1.rule == "taint_flow"))
      assert [_ | _] = taint_errors
    end
  end

  describe "validator — confidence warnings" do
    test "confidence gap produces warning" do
      # Build nodes with custom taint profiles via direct struct manipulation
      graph =
        %Graph{id: "ConfidenceGap"}
        |> Graph.add_node(%Node{id: "start", attrs: %{"shape" => "Mdiamond"}})
        |> Graph.add_node(%Node{id: "source", attrs: %{"prompt" => "x"}})
        |> Graph.add_node(%Node{id: "target", attrs: %{"prompt" => "y"}})
        |> Graph.add_node(%Node{id: "done", attrs: %{"shape" => "Msquare"}})
        |> Graph.add_edge(%Edge{from: "start", to: "source"})
        |> Graph.add_edge(%Edge{from: "source", to: "target"})
        |> Graph.add_edge(%Edge{from: "target", to: "done"})

      {:ok, compiled} = Compiler.compile(graph)

      # Manually set confidence profiles to create a gap
      source_node = %{
        compiled.nodes["source"]
        | taint_profile: %TaintProfile{min_confidence: :unverified}
      }

      target_node = %{
        compiled.nodes["target"]
        | taint_profile: %TaintProfile{min_confidence: :verified}
      }

      modified = %{
        compiled
        | nodes: Map.merge(compiled.nodes, %{"source" => source_node, "target" => target_node})
      }

      diags = Validator.validate(modified)
      confidence_diags = Enum.filter(diags, &(&1.rule == "confidence_gap"))
      assert [diag | _] = confidence_diags
      assert diag.message =~ "verified"
      assert diag.message =~ "unverified"
    end

    test "no warning when confidence levels match" do
      compiled = compile!(simple_graph())
      diags = Validator.validate(compiled)
      confidence_diags = Enum.filter(diags, &(&1.rule == "confidence_gap"))
      assert confidence_diags == []
    end
  end
end
