defmodule Arbor.Memory.KnowledgeGraphAuthorityArchitectureTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  test "GraphOps cannot regain ETS or legacy MemoryStore authority" do
    source = source!("graph_ops.ex")

    refute source =~ ":arbor_memory_graphs"
    refute source =~ ":ets."
    refute source =~ "MemoryStore"
    refute source =~ ~s("knowledge_graph")

    assert source =~ "KnowledgeGraphStore.get_graph"
    assert source =~ "KnowledgeGraphStore.add_node"
    assert source =~ "KnowledgeGraphStore.add_edge"
    assert source =~ "KnowledgeGraphStore.reinforce"
    assert source =~ "KnowledgeGraphStore.approve_pending"
    assert source =~ "KnowledgeGraphStore.reject_pending"
    assert source =~ "KnowledgeGraphStore.cascade_recall"
    assert source =~ "KnowledgeGraphStore.import_legacy_graph"
  end

  test "raw knowledge_graph MemoryStore access is confined to the authority owner" do
    memory_root = Path.expand("../../../lib/arbor/memory", __DIR__)

    violations =
      memory_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&raw_knowledge_graph_memory_store_access?/1)

    assert violations == []

    owner = source!("knowledge_graph_store.ex")
    assert owner =~ "MemoryStore.load_tainted_authoritative_with_status(@namespace"
    assert owner =~ "MemoryStore.compare_and_swap_tainted("
    assert owner =~ "MemoryStore.delete_tainted_authoritative(@namespace"
    refute owner =~ "MemoryStore.persist_async"
    refute owner =~ "MemoryStore.load("
  end

  test "projection access is confined to the owner and packet-assigned compatibility seams" do
    memory_root = Path.expand("../../../lib/arbor/memory", __DIR__)

    projection_files =
      (Path.wildcard(Path.join(memory_root, "**/*.ex")) ++ [facade_path()])
      |> Enum.filter(&graph_projection_access?/1)
      |> Enum.map(&Path.basename/1)
      |> Enum.sort()

    assert projection_files == [
             "application.ex",
             "knowledge_graph_store.ex",
             "memory.ex",
             "proposal.ex"
           ]

    owner = source!("knowledge_graph_store.ex")
    assert owner =~ ":ets.insert(@graph_ets"
    assert owner =~ ":ets.delete(@graph_ets"

    # C3B owns lifecycle initialization and cleanup in the public facade.
    lifecycle = source!("../memory.ex")
    assert lifecycle =~ "GraphOps.save_graph"
    assert lifecycle =~ ":ets.delete(:arbor_memory_graphs"
    refute lifecycle =~ ":ets.insert(:arbor_memory_graphs"
    refute lifecycle =~ ":ets.lookup(:arbor_memory_graphs"

    # C3H-H2 owns proposal transfer; it is the only remaining caller-side
    # projection reader/writer and must disappear with that packet.
    proposal = source!("proposal.ex")
    assert proposal =~ ":ets.lookup(@graph_ets"
    assert proposal =~ ":ets.insert(@graph_ets"

    application = source!("application.ex")
    refute application =~ ":ets.lookup(@graph_ets"
    refute application =~ ":ets.insert(@graph_ets"
    refute application =~ ":ets.delete(@graph_ets"
  end

  test "create-only compatibility save remains confined to C3B initialization" do
    memory_root = Path.expand("../../../lib/arbor/memory", __DIR__)

    callers =
      (Path.wildcard(Path.join(memory_root, "**/*.ex")) ++ [facade_path()])
      |> Enum.filter(&(File.read!(&1) =~ "GraphOps.save_graph"))
      |> Enum.map(&Path.basename/1)

    assert callers == ["memory.ex"]
  end

  defp raw_knowledge_graph_memory_store_access?(path) do
    source = File.read!(path)

    Regex.match?(
      ~r/MemoryStore\.[a-zA-Z0-9_!?]+\(\s*"knowledge_graph"/,
      source
    )
  end

  defp graph_projection_access?(path) do
    source = File.read!(path)

    source =~ "@graph_ets :arbor_memory_graphs" or
      Regex.match?(
        ~r/:ets\.(?:delete|insert|lookup)\([^\n]*:arbor_memory_graphs/,
        source
      )
  end

  defp facade_path do
    Path.expand("../../../lib/arbor/memory.ex", __DIR__)
  end

  defp source!(filename) do
    __DIR__
    |> Path.join("../../../lib/arbor/memory/#{filename}")
    |> Path.expand()
    |> File.read!()
  end
end
