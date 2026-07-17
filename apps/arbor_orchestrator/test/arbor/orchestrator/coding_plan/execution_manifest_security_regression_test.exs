defmodule Arbor.Orchestrator.CodingPlan.ExecutionManifestSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.TestFixtures.{
    BindingOriginalAction,
    BindingReplacementAction,
    BindingSchemaChangedAction,
    DepCycleAAction,
    DepCycleBAction,
    DepLeafAction,
    DepMidAction,
    DepRootAction,
    UnrelatedBindingAction
  }

  alias Arbor.Actions.Consensus.DecideReview
  alias Arbor.Actions.Coding.ReviewTree.{Read, Search}
  alias Arbor.Actions.Coding.ReviewedCommit
  alias Arbor.Actions.Coding.SubmitReviewReport
  alias Arbor.Actions.Git.Commit

  alias Arbor.Orchestrator.CodingPlan.{ActionCatalog, ExecutionManifest}
  alias Arbor.Orchestrator.Dot.Parser
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.IR.Compiler, as: IRCompiler

  @dot """
  digraph BindingManifest {
    start [shape=Mdiamond]
    invoke [type="exec", target="action", action="binding_action", param.value="hello"]
    done [shape=Msquare]
    start -> invoke -> done
  }
  """

  @nested_parent_dot """
  digraph NestedParent {
    graph [nested_graphs="code_review_council"]
    start [shape=Mdiamond]
    parent_exec [type="exec", target="action", action="binding_action"]
    done [shape=Msquare]
    start -> parent_exec -> done
  }
  """

  setup do
    custom_handlers = Registry.snapshot_custom_handlers()
    on_exit(fn -> Registry.restore_custom_handlers(custom_handlers) end)
    :ok
  end

  test "derives deterministic action, handler, capability, and egress bindings" do
    graph = compiled_graph!()
    catalog = catalog!([BindingOriginalAction])
    graph_hash = sha256(@dot)

    assert {:ok, {first, first_digest}} = ExecutionManifest.build(graph, catalog, graph_hash)
    assert {:ok, {second, second_digest}} = ExecutionManifest.build(graph, catalog, graph_hash)
    assert first == second
    assert first_digest == second_digest
    assert :ok = ExecutionManifest.validate(first, first_digest, graph_hash)
    assert {:ok, ^first_digest} = Arbor.Actions.execution_binding_digest(first)
    assert first["version"] == 2
    refute Map.has_key?(first, "nested_graphs")

    assert Map.keys(first) |> Enum.sort() ==
             ~w(actions capability_uris compiled_graph_hash egress graph_hash handlers nodes version)

    assert [action] = first["actions"]
    assert action["name"] == "binding_action"
    assert action["module"] == Atom.to_string(BindingOriginalAction)
    assert action["beam_sha256"] =~ ~r/^[0-9a-f]{64}$/

    assert first["capability_uris"] == [
             "arbor://action/test_fixtures/binding_original_action"
           ]

    assert [%{"action" => "binding_action", "effect_class" => "read"}] =
             Enum.map(first["egress"], &Map.take(&1, ~w(action effect_class)))

    assert Enum.any?(first["handlers"], &(&1["handler_type"] == "exec"))
  end

  test "declared nested graph closure binds its source, topology, capabilities, and egress" do
    graph = compiled_graph!(@nested_parent_dot)
    graph_hash = sha256(@nested_parent_dot)
    catalog = catalog!([DecideReview, Read, Search, SubmitReviewReport, BindingOriginalAction])

    assert {:ok, {manifest, _digest}} = ExecutionManifest.build(graph, catalog, graph_hash)
    assert {:ok, consensus} = ActionCatalog.fetch(catalog, "consensus_decide_review")
    assert consensus["resource_uri"] == "arbor://action/consensus/decide_review"

    assert consensus["parameters_schema"] == %{
             "$schema" => "https://json-schema.org/draft/2020-12/schema",
             "additionalProperties" => false,
             "properties" => %{
               "delta_ranges" => %{
                 "description" => "Changed line ranges for a recheck",
                 "type" => "object"
               },
               "finding_ledger" => %{
                 "description" => "Frozen finding ledger",
                 "type" => "object"
               },
               "results" => %{
                 "description" => "Parallel reviewer branch results",
                 "items" => %{"type" => "object"},
                 "type" => "array"
               },
               "review_cycle" => %{
                 "anyOf" => [%{"type" => "integer"}, %{"type" => "string"}],
                 "description" => "Next review cycle"
               }
             },
             "required" => [],
             "type" => "object"
           }

    assert [%{"id" => "code_review_council"} = nested_graph] = manifest["nested_graphs"]
    assert manifest["version"] == 3
    assert nested_graph["execution_manifest"]["version"] == 2
    refute Map.has_key?(nested_graph["execution_manifest"], "nested_graphs")

    consensus_binding = Map.delete(consensus, "execution_dependencies")

    assert Enum.any?(manifest["actions"], &(&1 == consensus_binding))
    assert Enum.any?(manifest["actions"], &(&1["name"] == "coding_review_tree_read"))
    assert Enum.any?(manifest["actions"], &(&1["name"] == "coding_review_tree_search"))
    assert Enum.any?(manifest["actions"], &(&1["name"] == "coding_submit_review_report"))
    assert consensus["resource_uri"] in manifest["capability_uris"]
    assert Enum.any?(manifest["egress"], &(&1["action"] == "consensus_decide_review"))
    assert "parallel" in Enum.map(manifest["handlers"], & &1["handler_type"])
    assert "compute" in Enum.map(manifest["handlers"], & &1["handler_type"])
    assert nested_graph["source_id"] == "arbor_actions:priv/pipelines/code-review-council.dot"
    assert nested_graph["source_sha256"] == sha256(code_review_council_dot())

    assert nested_graph["compiled_graph_hash"] ==
             nested_graph["execution_manifest"]["compiled_graph_hash"]
  end

  test "security regression: explicit compute tools are pinned as action bindings" do
    dot = """
    digraph BoundComputeTools {
      start [shape=Mdiamond]
      review [type="compute", simulate="true", use_tools="true", tools="binding_action"]
      done [shape=Msquare]
      start -> review -> done
    }
    """

    assert {:ok, {manifest, _digest}} =
             ExecutionManifest.build(
               compiled_graph!(dot),
               catalog!([BindingOriginalAction]),
               sha256(dot)
             )

    assert Enum.any?(manifest["actions"], &(&1["name"] == "binding_action"))
    assert "arbor://action/test_fixtures/binding_original_action" in manifest["capability_uris"]
  end

  test "security regression: tool-enabled compute nodes require an exact explicit list" do
    for tools_attr <- ["", ",binding_action", nil] do
      tools = if is_nil(tools_attr), do: "", else: ~s(, tools="#{tools_attr}")

      dot = """
      digraph UnboundedComputeTools {
        start [shape=Mdiamond]
        review [type="compute", simulate="true", use_tools="true"#{tools}]
        done [shape=Msquare]
        start -> review -> done
      }
      """

      assert {:error, {:explicit_compute_tools_required, "review"}} =
               ExecutionManifest.build(
                 compiled_graph!(dot),
                 catalog!([BindingOriginalAction]),
                 sha256(dot)
               )
    end
  end

  test "transitive execution_dependencies are bound and stripped from final actions" do
    dot = """
    digraph TransitiveDeps {
      start [shape=Mdiamond]
      root [type="exec", target="action", action="dep_root_action"]
      done [shape=Msquare]
      start -> root -> done
    }
    """

    catalog = catalog!([DepRootAction, DepMidAction, DepLeafAction, UnrelatedBindingAction])
    {:ok, root_spec} = ActionCatalog.fetch(catalog, "dep_root_action")
    assert root_spec["execution_dependencies"] == ["dep_leaf_action", "dep_mid_action"]

    assert {:ok, {manifest, digest}} =
             ExecutionManifest.build(compiled_graph!(dot), catalog, sha256(dot))

    names = Enum.map(manifest["actions"], & &1["name"])
    assert names == ["dep_leaf_action", "dep_mid_action", "dep_root_action"]
    refute "unrelated_binding_action" in names

    assert Enum.all?(manifest["actions"], fn binding ->
             not Map.has_key?(binding, "execution_dependencies")
           end)

    assert :ok = ExecutionManifest.validate(manifest, digest, sha256(dot))
  end

  test "dependency graph revisits and cycles terminate without unbounded recursion" do
    dot = """
    digraph CyclicDeps {
      start [shape=Mdiamond]
      cycle [type="exec", target="action", action="dep_cycle_a_action"]
      done [shape=Msquare]
      start -> cycle -> done
    }
    """

    catalog = catalog!([DepCycleAAction, DepCycleBAction])

    assert {:ok, {manifest, _digest}} =
             ExecutionManifest.build(compiled_graph!(dot), catalog, sha256(dot))

    names = Enum.map(manifest["actions"], & &1["name"])
    assert names == ["dep_cycle_a_action", "dep_cycle_b_action"]
  end

  test "missing transitive dependency fails closed with referenced_action_missing" do
    dot = """
    digraph MissingDep {
      start [shape=Mdiamond]
      root [type="exec", target="action", action="dep_root_action"]
      done [shape=Msquare]
      start -> root -> done
    }
    """

    catalog = catalog!([DepRootAction, DepMidAction])

    assert {:error, {:referenced_action_missing, "dep_leaf_action"}} =
             ExecutionManifest.build(compiled_graph!(dot), catalog, sha256(dot))
  end

  test "direct action worklist is sorted so missing-action errors are deterministic" do
    # Node ids are reverse-alpha relative to the missing action names so map
    # enumeration order would otherwise prefer "zebra_missing_action" first.
    dot = """
    digraph SortedMissingSeeds {
      start [shape=Mdiamond]
      z_node [type="exec", target="action", action="zebra_missing_action"]
      a_node [type="exec", target="action", action="alpha_missing_action"]
      done [shape=Msquare]
      start -> z_node -> a_node -> done
    }
    """

    catalog = catalog!([BindingOriginalAction])

    assert {:error, {:referenced_action_missing, "alpha_missing_action"}} =
             ExecutionManifest.build(compiled_graph!(dot), catalog, sha256(dot))
  end

  test "malformed catalog execution_dependencies fail closed" do
    catalog = catalog!([BindingOriginalAction])

    [action] = catalog["actions"]

    poisoned =
      Map.put(catalog, "actions", [
        Map.put(action, "execution_dependencies", ["unsorted_b", "unsorted_a"])
      ])

    assert {:error, {:invalid_action_execution_dependencies, "binding_action"}} =
             ExecutionManifest.build(compiled_graph!(), poisoned, sha256(@dot))
  end

  test "ReviewedCommit transitive binding pins git_commit without catalog-only metadata" do
    dot = """
    digraph ReviewedCommitBinding {
      start [shape=Mdiamond]
      commit [type="exec", target="action", action="coding_reviewed_commit"]
      done [shape=Msquare]
      start -> commit -> done
    }
    """

    catalog = catalog!([ReviewedCommit, Commit])

    assert {:ok, reviewed} = ActionCatalog.fetch(catalog, "coding_reviewed_commit")
    assert reviewed["execution_dependencies"] == ["git_commit"]

    assert {:ok, {manifest, _digest}} =
             ExecutionManifest.build(compiled_graph!(dot), catalog, sha256(dot))

    names = Enum.map(manifest["actions"], & &1["name"])
    assert "coding_reviewed_commit" in names
    assert "git_commit" in names

    assert Enum.all?(manifest["actions"], fn binding ->
             not Map.has_key?(binding, "execution_dependencies")
           end)
  end

  test "nested graph declarations fail closed when malformed or unknown" do
    for {declaration, reason} <- [
          {"code-review-council", :invalid_identifier},
          {"code_review_council,binding_graph", :not_sorted},
          {"code_review_council,code_review_council", :duplicate_graph}
        ] do
      dot = nested_graph_declaration_dot(declaration)

      assert {:error, {:invalid_nested_graphs_declaration, ^reason}} =
               ExecutionManifest.build(
                 compiled_graph!(dot),
                 catalog!([DecideReview, BindingOriginalAction]),
                 sha256(dot)
               )
    end

    unknown_dot = nested_graph_declaration_dot("unknown_graph")

    assert {:error, {:unknown_nested_graph, "unknown_graph"}} =
             ExecutionManifest.build(
               compiled_graph!(unknown_dot),
               catalog!([DecideReview]),
               sha256(unknown_dot)
             )
  end

  test "blank nested graph declarations bind no additional closure" do
    dot = nested_graph_declaration_dot("   ")

    assert {:ok, {manifest, _digest}} =
             ExecutionManifest.build(
               compiled_graph!(dot),
               catalog!([BindingOriginalAction]),
               sha256(dot)
             )

    assert manifest["actions"] == []
    assert manifest["version"] == 2
    refute Map.has_key?(manifest, "nested_graphs")
  end

  test "manifest versions reject ambiguous nested graph shapes" do
    graph = compiled_graph!()
    graph_hash = sha256(@dot)
    manifest = manifest_for_graph!(graph, catalog!([BindingOriginalAction]), graph_hash)

    v2_with_nested_graphs = Map.put(manifest, "nested_graphs", [])
    {:ok, v2_digest} = ExecutionManifest.digest(v2_with_nested_graphs)

    assert {:error, {:unexpected_execution_manifest_keys, :manifest}} =
             ExecutionManifest.validate(v2_with_nested_graphs, v2_digest, graph_hash)

    v3_without_nested_graphs = Map.put(manifest, "version", 3)
    {:ok, v3_missing_digest} = ExecutionManifest.digest(v3_without_nested_graphs)

    assert {:error, {:unexpected_execution_manifest_keys, :manifest}} =
             ExecutionManifest.validate(v3_without_nested_graphs, v3_missing_digest, graph_hash)

    v3_with_empty_nested_graphs = Map.put(v3_without_nested_graphs, "nested_graphs", [])
    {:ok, v3_empty_digest} = ExecutionManifest.digest(v3_with_empty_nested_graphs)

    assert {:error, {:invalid_execution_manifest_field, :nested_graphs}} =
             ExecutionManifest.validate(v3_with_empty_nested_graphs, v3_empty_digest, graph_hash)
  end

  test "nested graph declarations change the manifest digest" do
    direct_dot = @dot

    declared_dot =
      String.replace(@dot, "digraph BindingManifest {", """
      digraph BindingManifest {
        graph [nested_graphs="code_review_council"]
      """)

    catalog = catalog!([BindingOriginalAction, DecideReview, Read, Search, SubmitReviewReport])

    assert {:ok, {direct_manifest, direct_digest}} =
             ExecutionManifest.build(compiled_graph!(direct_dot), catalog, sha256(direct_dot))

    assert {:ok, {declared_manifest, declared_digest}} =
             ExecutionManifest.build(compiled_graph!(declared_dot), catalog, sha256(declared_dot))

    refute direct_manifest["actions"] == declared_manifest["actions"]
    refute direct_digest == declared_digest
  end

  test "subset is reflexive while declared child policy pins the exact nested topology" do
    catalog = catalog!([DecideReview, Read, Search, SubmitReviewReport, BindingOriginalAction])
    parent = manifest!(@nested_parent_dot, catalog)
    child_dot = code_review_council_dot()
    child_graph = compiled_graph!(child_dot)
    child = manifest_for_graph!(child_graph, catalog, canonical_graph_hash(child_graph))

    undeclared_parent_dot =
      String.replace(
        @nested_parent_dot,
        ~r/^\s*graph \[nested_graphs="code_review_council"\]\s*$/m,
        ""
      )

    refute String.contains?(undeclared_parent_dot, "nested_graphs")

    undeclared_parent = manifest!(undeclared_parent_dot, catalog)

    assert :ok = ExecutionManifest.require_subset(parent, parent)
    assert :ok = ExecutionManifest.require_subset(child, parent)
    assert :ok = ExecutionManifest.require_declared_child(child, parent)
    assert :ok = ExecutionManifest.require_declared_child(child, undeclared_parent)

    assert {:error, {:child_binding_not_pinned_by_parent, :action, "coding_review_tree_read"}} =
             ExecutionManifest.require_subset(child, undeclared_parent)

    changed_child_dot =
      String.replace(
        child_dot,
        "  collect -> decide -> done",
        "  collect -> done\n  decide -> done"
      )

    changed_child_graph = compiled_graph!(changed_child_dot)

    changed_child =
      manifest_for_graph!(
        changed_child_graph,
        catalog,
        canonical_graph_hash(changed_child_graph)
      )

    assert :ok = ExecutionManifest.require_subset(changed_child, parent)

    assert {:error, :child_graph_not_declared_by_parent} =
             ExecutionManifest.require_declared_child(changed_child, parent)
  end

  test "security regression: same-schema module replacement changes executable identity" do
    graph = compiled_graph!()
    expected_catalog = catalog!([BindingOriginalAction])
    live_catalog = catalog!([BindingReplacementAction])
    graph_hash = sha256(@dot)

    {:ok, {expected, digest}} = ExecutionManifest.build(graph, expected_catalog, graph_hash)

    assert {:error, {:execution_manifest_mismatch, sections}} =
             ExecutionManifest.verify(expected, digest, graph, live_catalog, graph_hash)

    assert "actions" in sections
    assert "capability_uris" in sections
    assert "egress" in sections

    {:ok, expected_index} = ExecutionManifest.action_binding_index(expected)

    assert {:error, {:action_binding_mismatch, "binding_action", fields}} =
             ExecutionManifest.verify_action_module(
               "binding_action",
               BindingReplacementAction,
               expected_index
             )

    assert "module" in fields
    assert "beam_sha256" in fields
    assert "effect_class" in fields
    assert "resource_uri" in fields
  end

  test "security regression: referenced schema drift fails while unrelated catalog additions remain valid" do
    graph = compiled_graph!()
    graph_hash = sha256(@dot)
    expected_catalog = catalog!([BindingOriginalAction])
    {:ok, {expected, digest}} = ExecutionManifest.build(graph, expected_catalog, graph_hash)

    assert {:error, {:execution_manifest_mismatch, sections}} =
             ExecutionManifest.verify(
               expected,
               digest,
               graph,
               catalog!([BindingSchemaChangedAction]),
               graph_hash
             )

    assert "actions" in sections

    assert {:ok, index} =
             ExecutionManifest.verify(
               expected,
               digest,
               graph,
               catalog!([BindingOriginalAction, UnrelatedBindingAction]),
               graph_hash
             )

    assert Map.keys(index) == ["binding_action"]
  end

  test "security regression: stale referenced BEAM digest fails closed" do
    graph = compiled_graph!()
    graph_hash = sha256(@dot)
    catalog = catalog!([BindingOriginalAction])
    {:ok, {manifest, _digest}} = ExecutionManifest.build(graph, catalog, graph_hash)

    stale_actions =
      Enum.map(manifest["actions"], &Map.put(&1, "beam_sha256", String.duplicate("0", 64)))

    stale_manifest = Map.put(manifest, "actions", stale_actions)
    {:ok, stale_digest} = ExecutionManifest.digest(stale_manifest)

    assert {:error, {:execution_manifest_mismatch, sections}} =
             ExecutionManifest.verify(stale_manifest, stale_digest, graph, catalog, graph_hash)

    assert "actions" in sections
  end

  test "security regression: handler registry drift changes the bound handler manifest" do
    graph_hash = sha256(@dot)
    catalog = catalog!([BindingOriginalAction])
    {:ok, {expected, digest}} = ExecutionManifest.build(compiled_graph!(), catalog, graph_hash)

    :ok = Registry.register("exec", Arbor.Orchestrator.TestHandlers.AlternateExec)
    drifted_graph = compiled_graph!()

    assert {:error, {:execution_manifest_field_mismatch, :compiled_graph_hash}} =
             ExecutionManifest.verify(expected, digest, drifted_graph, catalog, graph_hash)
  end

  test "security regression: same-module hot reload cannot satisfy a handler BEAM binding" do
    graph = compiled_graph!()
    graph_hash = sha256(@dot)

    {:ok, {manifest, _digest}} =
      ExecutionManifest.build(graph, catalog!([BindingOriginalAction]), graph_hash)

    {:ok, handler_bindings} = ExecutionManifest.handler_binding_index(manifest)
    handler_type = "start"
    handler_module = graph.nodes["start"].handler_module

    {^handler_module, original_beam, original_filename} =
      :code.get_object_code(handler_module)

    original_md5 = apply(handler_module, :module_info, [:md5])

    on_exit(fn -> restore_loaded_module!(handler_module, original_filename, original_beam) end)

    replacement_source = """
    defmodule #{inspect(handler_module)} do
      def execute(_node, _context, _graph, _opts), do: raise("replacement executed")
      def idempotency, do: :side_effecting
    end
    """

    [{^handler_module, _replacement_beam}] = Code.compile_string(replacement_source)

    refute apply(handler_module, :module_info, [:md5]) == original_md5

    assert {^handler_module, code_path_beam, _filename} =
             :code.get_object_code(handler_module)

    assert :beam_lib.md5(code_path_beam) == {:ok, {handler_module, original_md5}}

    assert {:error, {:execution_module_loaded_code_mismatch, {:handler, ^handler_type}}} =
             ExecutionManifest.verify_handler_module(
               handler_type,
               handler_module,
               handler_bindings
             )
  end

  test "security regression: child subset covers handlers, capability URIs, and egress" do
    graph = compiled_graph!()
    graph_hash = sha256(@dot)

    {:ok, {parent, _digest}} =
      ExecutionManifest.build(graph, catalog!([BindingOriginalAction]), graph_hash)

    assert :ok = ExecutionManifest.require_subset(parent, parent)

    exec_binding = Enum.find(parent["handlers"], &(&1["handler_type"] == "exec"))

    extra_handler =
      exec_binding
      |> Map.put("handler_type", "transform")

    handler_child =
      Map.update!(parent, "handlers", fn handlers ->
        Enum.sort_by([extra_handler | handlers], & &1["handler_type"])
      end)

    assert {:error, {:child_binding_not_pinned_by_parent, :handler, "transform"}} =
             ExecutionManifest.require_subset(handler_child, parent)

    capability_child =
      Map.update!(parent, "capability_uris", fn uris ->
        Enum.sort(["arbor://fs/write/unpinned" | uris])
      end)

    assert {:error,
            {:child_binding_not_pinned_by_parent, :capability_uri, "arbor://fs/write/unpinned"}} =
             ExecutionManifest.require_subset(capability_child, parent)

    extra_egress =
      parent["egress"]
      |> hd()
      |> Map.put("action", "unpinned_nested_action")

    egress_child =
      Map.update!(parent, "egress", fn egress ->
        Enum.sort_by([extra_egress | egress], & &1["action"])
      end)

    assert {:error, {:child_binding_not_pinned_by_parent, :egress, "unpinned_nested_action"}} =
             ExecutionManifest.require_subset(egress_child, parent)
  end

  defp compiled_graph!(dot \\ @dot) do
    {:ok, graph} = Parser.parse(dot)
    {:ok, compiled} = IRCompiler.compile(graph)
    compiled
  end

  defp manifest!(dot, catalog) do
    graph = compiled_graph!(dot)
    manifest_for_graph!(graph, catalog, sha256(dot))
  end

  defp manifest_for_graph!(graph, catalog, graph_hash) do
    {:ok, {manifest, _digest}} = ExecutionManifest.build(graph, catalog, graph_hash)

    manifest
  end

  defp nested_graph_declaration_dot(declaration) do
    """
    digraph NestedDeclaration {
      graph [nested_graphs="#{declaration}"]
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """
  end

  defp code_review_council_dot do
    {:ok, %{source: source}} = Arbor.Actions.reviewed_pipeline("code_review_council")
    source
  end

  defp canonical_graph_hash(graph) do
    graph
    |> Arbor.Orchestrator.Viz.DotSerializer.serialize()
    |> sha256()
  end

  defp catalog!(modules) do
    {:ok, catalog} = ActionCatalog.snapshot(modules: modules)
    catalog
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp restore_loaded_module!(module, filename, beam) do
    :code.purge(module)
    {:module, ^module} = :code.load_binary(module, filename, beam)
    :code.purge(module)
    :ok
  end
end
