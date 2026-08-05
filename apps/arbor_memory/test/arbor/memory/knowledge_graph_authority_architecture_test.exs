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

  defp raw_knowledge_graph_memory_store_access?(path) do
    source = File.read!(path)

    Regex.match?(
      ~r/MemoryStore\.[a-zA-Z0-9_!?]+\(\s*"knowledge_graph"/,
      source
    )
  end

  defp source!(filename) do
    __DIR__
    |> Path.join("../../../lib/arbor/memory/#{filename}")
    |> Path.expand()
    |> File.read!()
  end
end
