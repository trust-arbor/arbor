defmodule Arbor.Orchestrator.CodingPlan.ExecutionManifestSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.Actions.TestFixtures.{
    BindingOriginalAction,
    BindingReplacementAction,
    BindingSchemaChangedAction,
    UnrelatedBindingAction
  }

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

  defp compiled_graph! do
    {:ok, graph} = Parser.parse(@dot)
    {:ok, compiled} = IRCompiler.compile(graph)
    compiled
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
