defmodule Arbor.Memory.FactExtractorKnowledgeGraphTest do
  @moduledoc """
  Regression: compression-extracted facts reach the knowledge graph.

  FactExtractor used to run during compression and only emit a signal.
  The last mile is `GraphOps.add_pending_fact/2` — auto-extracted facts
  stay pending until the agent approves them.
  """
  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.{ContextWindow, FactExtractor, KnowledgeGraphStore}
  alias Arbor.Memory.ContextWindow.Compression
  alias Arbor.Memory.Test.DurableGraphAuthority

  @moduletag :fast

  setup do
    DurableGraphAuthority.start!()

    agent_id = "agent_fact_kg_#{System.unique_integer([:positive])}"
    {:ok, _pid} = Memory.init_for_agent(agent_id, auto_embed: false)

    on_exit(fn ->
      _ = Memory.cleanup_for_agent(agent_id)
      _ = KnowledgeGraphStore.delete_graph(agent_id)
    end)

    %{agent_id: agent_id}
  end

  test "ingest_extracted_facts proposes FactExtractor output as pending graph facts", %{
    agent_id: agent_id
  } do
    facts =
      FactExtractor.extract(
        "My name is Alice and I work at Acme Corporation",
        method: :regex
      )

    assert facts != []
    assert :ok = Compression.ingest_extracted_facts(agent_id, facts)

    {:ok, pending} = Memory.get_pending_proposals(agent_id)
    contents = Enum.map(pending, & &1.content)

    assert Enum.any?(contents, &(&1 =~ "Alice"))
    assert Enum.any?(pending, &(&1.type == :fact))

    assert Enum.any?(pending, fn item ->
             ingested_from(item) == "fact_extractor"
           end)
  end

  test "compression last-mile writes extracted facts onto the knowledge graph", %{
    agent_id: agent_id
  } do
    window =
      ContextWindow.new(agent_id,
        multi_layer: true,
        max_tokens: 200,
        summarization_enabled: false,
        fact_extraction_enabled: true,
        min_fact_confidence: 0.7,
        ratios: %{
          full_detail: 0.50,
          recent_summary: 0.25,
          distant_summary: 0.15,
          retrieved: 0.10
        }
      )

    window =
      Enum.reduce(1..6, window, fn i, acc ->
        ContextWindow.add_message(acc, %{
          role: :user,
          content:
            "Message #{i}: My name is Alice and I work at Acme Corporation. " <>
              "We are using Elixir for the backend and the project is called Arbor. " <>
              "This extra padding keeps the full-detail budget exceeded so compression runs."
        })
      end)

    # Phase-1 compression (summarization disabled) runs inline in add_message
    # once the full-detail budget is exceeded. Do not require a second cycle.
    assert window.compression_count >= 1
    refute ContextWindow.needs_compression?(window)

    {:ok, pending} = Memory.get_pending_proposals(agent_id)
    contents = Enum.map(pending, & &1.content)

    assert pending != []

    assert Enum.any?(contents, fn content ->
             content =~ "Alice" or content =~ "Acme" or content =~ "Elixir" or
               content =~ "Arbor"
           end)

    assert Enum.any?(pending, fn item ->
             ingested_from(item) == "fact_extractor"
           end)
  end

  test "ingest is a no-op when the agent has no knowledge graph" do
    facts = FactExtractor.extract("My name is Alice", method: :regex)
    assert facts != []
    assert :ok = Compression.ingest_extracted_facts("agent_missing_graph", facts)
  end

  defp ingested_from(item) when is_map(item) do
    metadata = Map.get(item, :metadata) || Map.get(item, "metadata") || %{}
    Map.get(metadata, "ingested_from") || Map.get(metadata, :ingested_from)
  end
end
