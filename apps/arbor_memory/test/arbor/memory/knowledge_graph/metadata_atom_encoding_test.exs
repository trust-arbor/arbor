defmodule Arbor.Memory.KnowledgeGraph.MetadataAtomEncodingTest do
  @moduledoc """
  Regression guard for the durable codec's `@semantic_atoms` allowlist.

  `Codec.encode_generic/3` can only encode atoms on that allowlist; every other
  atom falls through to a catch-all returning `{:error, :invalid_graph}`. That
  makes the allowlist a hard contract with every production caller that writes
  atom-valued knowledge-graph metadata.

  `:agent_tool` was missing from it. `Arbor.Actions.Memory.Remember` sets
  `metadata: %{source: :agent_tool}` on **every** agent remember call, so from
  2026-08-05 (when the durable authority landed) until 2026-08-06 every such
  call failed — and failed with `:invalid_graph`, which names the wrong thing
  entirely: the graph is fine, an atom just wasn't encodable.

  This test pins the atoms that production actually writes. Adding a new
  atom-valued metadata source without allowlisting it should turn this red.
  """

  use ExUnit.Case, async: false

  alias Arbor.Memory
  alias Arbor.Memory.Test.DurableGraphAuthority

  @moduletag :fast

  setup do
    DurableGraphAuthority.start!()
    agent_id = "metadata_atom_#{System.unique_integer([:positive])}"
    {:ok, _} = Memory.init_for_agent(agent_id)
    on_exit(fn -> Memory.cleanup_for_agent(agent_id) end)
    {:ok, agent_id: agent_id}
  end

  describe "atom-valued knowledge metadata (regression)" do
    test "the exact shape Arbor.Actions.Memory.Remember writes is storable",
         %{agent_id: agent_id} do
      # Verbatim from apps/arbor_actions/lib/arbor/actions/memory.ex — if that
      # literal changes, this test should be updated in the same commit.
      node_data = %{
        type: :fact,
        content: "Elixir uses pattern matching",
        relevance: 0.5,
        metadata: %{source: :agent_tool}
      }

      assert {:ok, node_id} = Memory.add_knowledge(agent_id, node_data)
      assert is_binary(node_id)
    end

    test "every source atom production writes to the graph round-trips",
         %{agent_id: agent_id} do
      # Each of these is a real `metadata: %{source: <atom>}` written on a path
      # that reaches add_knowledge/2. Grep for `metadata: %{source: :` before
      # adding to this list — most such literals are CAPABILITY metadata, which
      # never touches the codec.
      for source <- [:agent_tool, :reflection_learning] do
        assert {:ok, _} =
                 Memory.add_knowledge(agent_id, %{
                   type: :fact,
                   content: "content for #{source}",
                   metadata: %{source: source}
                 }),
               "#{inspect(source)} is not in Codec's @semantic_atoms allowlist, so " <>
                 "every write carrying it fails with a misleading :invalid_graph"
      end
    end

    test "an atom NOT on the allowlist is still rejected", %{agent_id: agent_id} do
      # The allowlist is a real boundary (it bounds atom creation on decode), so
      # this must stay closed. If this ever passes, the catch-all was widened and
      # the protection is gone.
      assert {:error, :invalid_graph} =
               Memory.add_knowledge(agent_id, %{
                 type: :fact,
                 content: "unlisted atom value",
                 metadata: %{source: :definitely_not_allowlisted_xyzzy}
               })
    end

    test "string-valued metadata is always safe", %{agent_id: agent_id} do
      # The escape hatch for callers that don't want to touch the allowlist.
      assert {:ok, _} =
               Memory.add_knowledge(agent_id, %{
                 type: :fact,
                 content: "string source",
                 metadata: %{source: "any_string_works"}
               })
    end
  end
end
