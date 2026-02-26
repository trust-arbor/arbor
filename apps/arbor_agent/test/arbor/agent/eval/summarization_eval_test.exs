defmodule Arbor.Agent.Eval.SummarizationEvalTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.Eval.CompactionEval
  alias Arbor.Agent.Eval.SummarizationEval

  # ── Transcript Generation ──────────────────────────────────────

  describe "generate_test_transcripts/1" do
    test "returns all three transcript types" do
      transcripts = SummarizationEval.generate_test_transcripts()

      assert Map.has_key?(transcripts, :coding)
      assert Map.has_key?(transcripts, :relational)
      assert Map.has_key?(transcripts, :mixed)
    end

    test "returns only requested types" do
      transcripts = SummarizationEval.generate_test_transcripts([:coding])

      assert Map.has_key?(transcripts, :coding)
      refute Map.has_key?(transcripts, :relational)
      refute Map.has_key?(transcripts, :mixed)
    end

    test "coding transcript has file read tool calls" do
      transcripts = SummarizationEval.generate_test_transcripts([:coding])
      coding = transcripts[:coding]

      assert coding["task"] != ""
      assert coding["text"] != ""
      assert coding["tool_calls"] != []

      file_reads =
        Enum.filter(coding["tool_calls"], &(&1["name"] in ["file_read", "file.read"]))

      assert file_reads != []
    end

    test "relational transcript has relationship/memory tool calls" do
      transcripts = SummarizationEval.generate_test_transcripts([:relational])
      relational = transcripts[:relational]

      assert relational["task"] != ""
      assert relational["tool_calls"] != []

      rel_tools =
        ~w(relationship_save relationship_get relationship_moment
           memory_recall memory_add_insight memory_reflect memory_connect)

      has_relational =
        Enum.any?(relational["tool_calls"], &(&1["name"] in rel_tools))

      assert has_relational
    end

    test "mixed transcript has both coding and relational tool calls" do
      transcripts = SummarizationEval.generate_test_transcripts([:mixed])
      mixed = transcripts[:mixed]

      tool_names = Enum.map(mixed["tool_calls"], & &1["name"])

      has_file =
        Enum.any?(tool_names, &(&1 in ["file_read", "file.read", "file_list", "file.list"]))

      has_rel = Enum.any?(tool_names, &String.starts_with?(&1, "relationship"))

      assert has_file, "Mixed transcript should have file tool calls"
      assert has_rel, "Mixed transcript should have relationship tool calls"
    end
  end

  # ── Batch Extraction ──────────────────────────────────────────

  describe "extract_batches/2" do
    test "extracts batch of requested size" do
      transcript = SummarizationEval.generate_transcript(:coding)
      messages = CompactionEval.reconstruct_messages(transcript)

      batches = SummarizationEval.extract_batches(messages, 4)

      assert length(batches) == 1
      {batch_msgs, 0} = hd(batches)
      assert length(batch_msgs) == 4
    end

    test "returns empty list when not enough messages" do
      transcript = SummarizationEval.generate_transcript(:coding)
      messages = CompactionEval.reconstruct_messages(transcript)

      # Request a batch bigger than available compactable messages
      batches = SummarizationEval.extract_batches(messages, 999)

      assert batches == []
    end

    test "skips system and user messages" do
      transcript = SummarizationEval.generate_transcript(:coding)
      messages = CompactionEval.reconstruct_messages(transcript)

      batches = SummarizationEval.extract_batches(messages, 4)
      {batch_msgs, _} = hd(batches)

      roles = Enum.map(batch_msgs, & &1.role)
      refute :system in roles
      # First user message should be skipped
      assert Enum.all?(batch_msgs, fn msg ->
               msg.role in [:assistant, :tool]
             end)
    end
  end

  # ── Scoring ──────────────────────────────────────────────────

  describe "score_summary/3" do
    setup do
      transcript = SummarizationEval.generate_transcript(:coding)
      messages = CompactionEval.reconstruct_messages(transcript)
      ground_truth = CompactionEval.extract_ground_truth(transcript)

      %{messages: messages, ground_truth: ground_truth}
    end

    test "good summary gets high retention", %{messages: messages, ground_truth: ground_truth} do
      # A summary that preserves key information
      good_summary =
        "Read apps/arbor_agent/lib/arbor/agent/api_agent.ex containing " <>
          "Arbor.Agent.APIAgent GenServer. Also read lifecycle.ex with " <>
          "Arbor.Agent.Lifecycle, context_compactor.ex with Arbor.Agent.ContextCompactor, " <>
          "executor.ex with Arbor.Agent.Executor, and action_cycle_server.ex with " <>
          "Arbor.Agent.ActionCycleServer. Found three-loop architecture with " <>
          "heartbeat, supervisor tree, and memory persistence via BufferedStore."

      retention = SummarizationEval.score_summary(good_summary, messages, ground_truth)

      assert retention.retention_score > 0.3
      assert retention.path_retention > 0.0
      assert retention.module_retention > 0.0
    end

    test "empty summary gets low retention", %{messages: messages, ground_truth: ground_truth} do
      retention = SummarizationEval.score_summary("", messages, ground_truth)

      assert retention.retention_score == 0.0
      assert retention.path_retention == 0.0
      assert retention.module_retention == 0.0
    end

    test "garbage summary gets low retention", %{messages: messages, ground_truth: ground_truth} do
      garbage = "The quick brown fox jumps over the lazy dog. Lorem ipsum dolor sit amet."
      retention = SummarizationEval.score_summary(garbage, messages, ground_truth)

      assert retention.retention_score < 0.3
    end

    test "returns all expected metric keys", %{messages: messages, ground_truth: ground_truth} do
      retention = SummarizationEval.score_summary("test summary", messages, ground_truth)

      assert Map.has_key?(retention, :path_retention)
      assert Map.has_key?(retention, :module_retention)
      assert Map.has_key?(retention, :concept_retention)
      assert Map.has_key?(retention, :person_name_retention)
      assert Map.has_key?(retention, :emotional_retention)
      assert Map.has_key?(retention, :dynamic_retention)
      assert Map.has_key?(retention, :value_retention)
      assert Map.has_key?(retention, :compression_ratio)
      assert Map.has_key?(retention, :retention_score)
    end
  end

  describe "score_summary/3 relational" do
    setup do
      transcript = SummarizationEval.generate_transcript(:relational)
      messages = CompactionEval.reconstruct_messages(transcript)
      ground_truth = CompactionEval.extract_ground_truth(transcript)

      %{messages: messages, ground_truth: ground_truth}
    end

    test "summary with person names gets high people retention", %{
      messages: messages,
      ground_truth: ground_truth
    } do
      summary =
        "Learned about Hysun who values building over tearing down, " <>
          "Dr. Chen who is a collaborator, and Maya who works on creative projects. " <>
          "Relationships involve trust, connection, and philosophical exploration."

      retention = SummarizationEval.score_summary(summary, messages, ground_truth)

      assert retention.person_name_retention > 0.0
      assert retention.has_relational_data
    end
  end

  # ── Prompt Strategies ──────────────────────────────────────────

  describe "build_prompt/2" do
    test "narrative strategy includes summary instructions" do
      messages = [
        %{role: :assistant, content: "Reading file...", tool_calls: []},
        %{role: :tool, name: "file_read", content: "file content here"}
      ]

      prompt = SummarizationEval.build_prompt(messages, :narrative)

      assert String.contains?(prompt, "Summarize these agent actions")
      assert String.contains?(prompt, "[assistant]")
      assert String.contains?(prompt, "[tool:file_read]")
      assert String.contains?(prompt, "Write only the summary paragraph")
    end

    test "structured strategy requests file paths and modules" do
      messages = [
        %{role: :tool, name: "file_read", content: "defmodule Foo do end"}
      ]

      prompt = SummarizationEval.build_prompt(messages, :structured)

      assert String.contains?(prompt, "Every file path")
      assert String.contains?(prompt, "Every module or class name")
      assert String.contains?(prompt, "Do not omit any file paths")
    end

    test "extractive strategy uses numbered sections" do
      messages = [
        %{role: :tool, name: "file_read", content: "defmodule Foo do end"}
      ]

      prompt = SummarizationEval.build_prompt(messages, :extractive)

      assert String.contains?(prompt, "1. FILES:")
      assert String.contains?(prompt, "2. MODULES:")
      assert String.contains?(prompt, "3. CONCEPTS:")
      assert String.contains?(prompt, "4. PEOPLE:")
      assert String.contains?(prompt, "5. SUMMARY:")
      assert String.contains?(prompt, "Do NOT omit any file paths")
    end

    test "defaults to narrative" do
      messages = [%{role: :assistant, content: "hello"}]

      narrative = SummarizationEval.build_prompt(messages, :narrative)
      default = SummarizationEval.build_prompt(messages)

      assert narrative == default
    end

    test "truncates long content to 300 chars" do
      long_content = String.duplicate("x", 500)

      messages = [
        %{role: :tool, name: "file_read", content: long_content}
      ]

      prompt = SummarizationEval.build_prompt(messages, :narrative)

      # The formatted content should be truncated
      # (300 chars max per message, not the full 500)
      refute String.contains?(prompt, long_content)
    end

    test "handles string-keyed messages" do
      messages = [
        %{"role" => "assistant", "content" => "thinking..."}
      ]

      prompt = SummarizationEval.build_prompt(messages, :structured)

      assert String.contains?(prompt, "[assistant]")
      assert String.contains?(prompt, "thinking...")
    end
  end

  describe "build_narrative_prompt/1 (legacy)" do
    test "delegates to build_prompt with :narrative" do
      messages = [%{role: :assistant, content: "hello"}]

      assert SummarizationEval.build_narrative_prompt(messages) ==
               SummarizationEval.build_prompt(messages, :narrative)
    end
  end

  # ── Result Structure ──────────────────────────────────────────

  describe "run_single/9" do
    test "returns error result when LLM unavailable" do
      transcript = SummarizationEval.generate_transcript(:coding)
      messages = CompactionEval.reconstruct_messages(transcript)
      ground_truth = CompactionEval.extract_ground_truth(transcript)
      batch_messages = Enum.take(Enum.drop(messages, 2), 4)

      result =
        SummarizationEval.run_single(
          "fake_provider",
          "fake_model",
          batch_messages,
          messages,
          ground_truth,
          :coding,
          4,
          :narrative,
          1000
        )

      assert result.transcript_type == :coding
      assert result.batch_size == 4
      assert result.prompt_strategy == :narrative
      assert result.error != nil
      assert result.retention_score == 0.0
      assert result.timing_ms >= 0
    end

    test "includes prompt_strategy in result for all strategies" do
      transcript = SummarizationEval.generate_transcript(:coding)
      messages = CompactionEval.reconstruct_messages(transcript)
      ground_truth = CompactionEval.extract_ground_truth(transcript)
      batch_messages = Enum.take(Enum.drop(messages, 2), 4)

      for strategy <- [:narrative, :structured, :extractive] do
        result =
          SummarizationEval.run_single(
            "fake_provider",
            "fake_model",
            batch_messages,
            messages,
            ground_truth,
            :coding,
            4,
            strategy,
            1000
          )

        assert result.prompt_strategy == strategy
      end
    end
  end

  # ── Output Formatting ──────────────────────────────────────────

  describe "output formatting" do
    test "generate_transcript returns valid transcript format for all types" do
      for type <- [:coding, :relational, :mixed] do
        transcript = SummarizationEval.generate_transcript(type)

        assert is_binary(transcript["task"]), "#{type}: task should be a string"
        assert is_binary(transcript["text"]), "#{type}: text should be a string"
        assert is_list(transcript["tool_calls"]), "#{type}: tool_calls should be a list"
        assert is_binary(transcript["model"]), "#{type}: model should be a string"
        assert transcript["status"] == "completed"

        # Each tool call should have required fields
        for tc <- transcript["tool_calls"] do
          assert Map.has_key?(tc, "turn"), "#{type}: tool_call missing turn"
          assert Map.has_key?(tc, "name"), "#{type}: tool_call missing name"
          assert Map.has_key?(tc, "args"), "#{type}: tool_call missing args"
          assert Map.has_key?(tc, "result"), "#{type}: tool_call missing result"
        end
      end
    end
  end
end
