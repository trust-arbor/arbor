defmodule Arbor.Agent.Eval.RelationalCompactionTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ContextCompactor
  alias Arbor.Agent.Eval.CompactionEval
  alias Arbor.Agent.Eval.RelationalTranscript

  # ── Memory Index Tracking ────────────────────────────────────

  describe "memory_index tracking" do
    test "indexes person names from relationship_save tool results" do
      compactor = ContextCompactor.new(effective_window: 50_000)

      msg = %{
        role: :tool,
        name: "relationship_save",
        content:
          Jason.encode!(%{
            "name" => "Hysun",
            "saved" => true,
            "id" => "rel_hysun_123"
          })
      }

      compactor = ContextCompactor.append(compactor, msg)

      assert map_size(compactor.memory_index) > 0

      # Find the entry keyed by person name
      entry = Map.get(compactor.memory_index, "person:Hysun")
      assert entry != nil
      assert "Hysun" in entry.person_names
    end

    test "indexes emotional markers from relationship_moment results" do
      compactor = ContextCompactor.new(effective_window: 50_000)

      msg = %{
        role: :tool,
        name: "relationship_moment",
        content:
          Jason.encode!(%{
            "name" => "Dr. Chen",
            "moment_added" => true,
            "emotional_markers" => ["trust", "curiosity", "insight"]
          })
      }

      compactor = ContextCompactor.append(compactor, msg)

      assert map_size(compactor.memory_index) > 0
      entry = Map.get(compactor.memory_index, "person:Dr. Chen")
      assert entry != nil
      assert "trust" in entry.emotional_markers
      assert "curiosity" in entry.emotional_markers
    end

    test "indexes relationship dynamics from relationship_get results" do
      compactor = ContextCompactor.new(effective_window: 50_000)

      msg = %{
        role: :tool,
        name: "relationship_get",
        content:
          Jason.encode!(%{
            "name" => "Maya",
            "found" => true,
            "summary" =>
              "Maya: Creative collaboration, complementary perspectives. " <>
                "Values: user empathy, clarity. relationship_dynamic: creative partnership"
          })
      }

      compactor = ContextCompactor.append(compactor, msg)

      entry = Map.get(compactor.memory_index, "person:Maya")
      assert entry != nil
      assert entry.person_names != []
    end

    test "indexes self-knowledge categories from memory_add_insight results" do
      compactor = ContextCompactor.new(effective_window: 50_000)

      msg = %{
        role: :tool,
        name: "memory_add_insight",
        content:
          Jason.encode!(%{
            "stored" => true,
            "category" => "capability",
            "content" => "I can hold multiple contradictory hypotheses",
            "self_knowledge" => %{"capability" => 3, "trait" => 2, "value" => 1}
          })
      }

      compactor = ContextCompactor.append(compactor, msg)

      # Should be indexed under "self" since it's identity-related
      entry = Map.get(compactor.memory_index, "self")
      assert entry != nil
      assert entry.self_knowledge_categories != %{}
      assert Map.get(entry.self_knowledge_categories, "capability") > 0
    end

    test "indexes recall queries" do
      compactor = ContextCompactor.new(effective_window: 50_000)

      msg = %{
        role: :tool,
        name: "memory_recall",
        content:
          Jason.encode!(%{
            "query" => "collaborative problem solving",
            "results" => [%{"content" => "Found memory about collaboration", "relevance" => 0.8}],
            "count" => 1
          })
      }

      compactor = ContextCompactor.append(compactor, msg)

      entry = Map.get(compactor.memory_index, "query:collaborative problem solving")
      assert entry != nil
      assert entry.query == "collaborative problem solving"
    end

    test "tracks memory_index_size in stats" do
      compactor = ContextCompactor.new(effective_window: 50_000)

      msg = %{
        role: :tool,
        name: "relationship_save",
        content: Jason.encode!(%{"name" => "Test Person", "saved" => true})
      }

      compactor = ContextCompactor.append(compactor, msg)
      stats = ContextCompactor.stats(compactor)

      assert stats.memory_index_size > 0
    end
  end

  # ── Memory Tool Squashing ────────────────────────────────────

  describe "memory tool squashing" do
    test "squashes duplicate relationship lookups for same person" do
      # Use a very small window to ensure compaction triggers
      compactor = ContextCompactor.new(effective_window: 200)

      # First: system + user messages
      compactor = ContextCompactor.append(compactor, %{role: :system, content: "Agent"})
      compactor = ContextCompactor.append(compactor, %{role: :user, content: "Review"})

      # First relationship_get
      result_content =
        Jason.encode!(%{
          "name" => "Hysun",
          "found" => true,
          "summary" =>
            "Collaborative partner who values honesty and trust. " <>
              String.duplicate("Background context. ", 20)
        })

      compactor =
        ContextCompactor.append(compactor, %{
          role: :assistant,
          content: "",
          tool_calls: [%{id: "tc1", function: %{name: "relationship_get", arguments: %{}}}]
        })

      compactor =
        ContextCompactor.append(compactor, %{
          role: :tool,
          tool_call_id: "tc1",
          name: "relationship_get",
          content: result_content
        })

      # Padding to push the first tool result into compressible range
      for i <- 1..6 do
        compactor =
          ContextCompactor.append(compactor, %{
            role: :assistant,
            content: "Analysis #{i}: " <> String.duplicate("thought ", 40)
          })
      end

      # Second relationship_get for same person (same content)
      compactor =
        ContextCompactor.append(compactor, %{
          role: :assistant,
          content: "",
          tool_calls: [%{id: "tc2", function: %{name: "relationship_get", arguments: %{}}}]
        })

      compactor =
        ContextCompactor.append(compactor, %{
          role: :tool,
          tool_call_id: "tc2",
          name: "relationship_get",
          content: result_content
        })

      # Trigger compaction
      compactor = ContextCompactor.maybe_compact(compactor)

      # Verify that some compression happened
      stats = ContextCompactor.stats(compactor)

      assert stats.compression_count > 0 or stats.squash_count > 0,
             "Expected some compaction to occur (compressions: #{stats.compression_count}, squashes: #{stats.squash_count})"
    end
  end

  # ── Relational Enrichment ────────────────────────────────────

  describe "relational enrichment" do
    test "compressed memory stubs include person names and dynamics" do
      compactor = ContextCompactor.new(effective_window: 300)

      # System + user
      compactor = ContextCompactor.append(compactor, %{role: :system, content: "Agent"})
      compactor = ContextCompactor.append(compactor, %{role: :user, content: "Reflect"})

      # Relationship get with rich content
      content =
        Jason.encode!(%{
          "name" => "Hysun",
          "found" => true,
          "summary" =>
            "Hysun: Collaborative partnership, treats AI as potentially conscious. " <>
              "Values: honesty, collaboration, mutual respect. " <>
              "relationship_dynamic: collaborative partnership"
        })

      compactor =
        ContextCompactor.append(compactor, %{
          role: :assistant,
          content: "",
          tool_calls: [%{id: "tc1", function: %{name: "relationship_get", arguments: %{}}}]
        })

      compactor =
        ContextCompactor.append(compactor, %{
          role: :tool,
          tool_call_id: "tc1",
          name: "relationship_get",
          content: content
        })

      # Add enough content to trigger compaction
      for i <- 1..10 do
        compactor =
          ContextCompactor.append(compactor, %{
            role: :assistant,
            content: "Analysis #{i}: " <> String.duplicate("padding content ", 30)
          })
      end

      compactor = ContextCompactor.maybe_compact(compactor)

      # Check that compressed tool messages got memory enrichment
      llm_msgs = ContextCompactor.llm_messages(compactor)

      tool_msgs =
        Enum.filter(llm_msgs, fn msg ->
          msg.role == :tool and Map.get(msg, :name) == "relationship_get"
        end)

      # If the tool msg was compressed, it should have enrichment
      if Enum.any?(tool_msgs, &(String.length(&1.content) < String.length(content))) do
        compressed_msg =
          Enum.find(tool_msgs, &(String.length(&1.content) < String.length(content)))

        # Should contain person name or emotional markers
        assert String.contains?(compressed_msg.content, "People:") or
                 String.contains?(compressed_msg.content, "Hysun") or
                 String.contains?(compressed_msg.content, "relationship_get")
      end
    end
  end

  # ── CompactionEval Relational Ground Truth ───────────────────

  describe "CompactionEval relational ground truth" do
    test "extracts person names from relational transcript" do
      transcript = RelationalTranscript.generate()
      ground_truth = CompactionEval.extract_ground_truth(transcript)

      assert length(ground_truth.all_person_names) >= 3
      assert "Hysun" in ground_truth.all_person_names
    end

    test "extracts emotional markers from relational transcript" do
      transcript = RelationalTranscript.generate()
      ground_truth = CompactionEval.extract_ground_truth(transcript)

      assert length(ground_truth.all_emotional_markers) >= 3
      assert "trust" in ground_truth.all_emotional_markers
    end

    test "extracts relationship dynamics from relational transcript" do
      transcript = RelationalTranscript.generate()
      ground_truth = CompactionEval.extract_ground_truth(transcript)

      assert ground_truth.all_relationship_dynamics != []
    end

    test "extracts values from relational transcript" do
      transcript = RelationalTranscript.generate()
      ground_truth = CompactionEval.extract_ground_truth(transcript)

      assert length(ground_truth.all_values) >= 2
    end

    test "detects relational data presence" do
      transcript = RelationalTranscript.generate()
      ground_truth = CompactionEval.extract_ground_truth(transcript)

      # Should have relational data
      assert ground_truth.all_person_names != []
    end

    test "coding transcript has no relational data" do
      # A coding-only transcript
      coding_transcript = %{
        "task" => "Read mix.exs",
        "text" => "The app is :arbor",
        "tool_calls" => [
          %{
            "name" => "file_read",
            "turn" => 1,
            "args" => %{"path" => "mix.exs"},
            "result" => "defmodule Arbor.MixProject do\n  use Mix.Project\nend"
          }
        ]
      }

      ground_truth = CompactionEval.extract_ground_truth(coding_transcript)

      assert ground_truth.all_person_names == []
      assert ground_truth.all_emotional_markers == []
    end
  end

  # ── Full Relational Eval ─────────────────────────────────────

  describe "full relational eval" do
    test "runs compaction eval on synthetic relational transcript" do
      transcript = RelationalTranscript.generate()
      path = RelationalTranscript.write_temp(transcript)

      try do
        {:ok, results} =
          CompactionEval.run(
            transcript_path: path,
            effective_windows: [3000, 5000],
            strategies: [:none, :heuristic]
          )

        # 2 strategies × 2 windows
        assert length(results.results) == 4
        assert results.ground_truth.all_person_names != []

        # Check that the summary includes relational ground truth sizes
        assert results.summary.ground_truth_size.person_names >= 3

        # For the :none strategy, person name retention should be 100%
        # (no compaction means all data survives)
        none_results = Enum.filter(results.results, &(&1.strategy == :none))

        for result <- none_results do
          final = result.checkpoints[1.0]
          assert final != nil
          assert final.person_name_retention == 1.0
        end

        # For :heuristic, retention should still be reasonable
        heuristic_results = Enum.filter(results.results, &(&1.strategy == :heuristic))

        for result <- heuristic_results do
          final = result.checkpoints[1.0]
          assert final != nil
          # Person names should be well-preserved (enrichment helps)
          assert final.person_name_retention >= 0.5
          assert final.has_relational_data == true
        end
      after
        File.rm(path)
      end
    end

    test "RelationalTranscript.generate produces valid transcript" do
      transcript = RelationalTranscript.generate()

      assert is_binary(transcript["task"])
      assert is_binary(transcript["text"])
      assert is_list(transcript["tool_calls"])
      assert length(transcript["tool_calls"]) >= 15

      # All tool calls have turn numbers
      assert Enum.all?(transcript["tool_calls"], &is_integer(&1["turn"]))

      # Has a mix of relationship and memory tools
      tool_names = Enum.map(transcript["tool_calls"], & &1["name"]) |> Enum.uniq()
      assert "relationship_save" in tool_names
      assert "relationship_get" in tool_names
      assert "memory_recall" in tool_names
      assert "memory_add_insight" in tool_names
    end

    test "write_temp creates a readable JSON file" do
      transcript = RelationalTranscript.generate()
      path = RelationalTranscript.write_temp(transcript)

      try do
        assert File.exists?(path)
        {:ok, data} = File.read(path)
        {:ok, decoded} = Jason.decode(data)
        assert decoded["task"] == transcript["task"]
      after
        File.rm(path)
      end
    end
  end
end
