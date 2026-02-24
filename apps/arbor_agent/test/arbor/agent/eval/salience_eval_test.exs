defmodule Arbor.Agent.Eval.SalienceEvalTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ContextCompactor
  alias Arbor.Agent.Eval.{SalienceEval, SalienceTranscript}

  # ── compute_salience/2 ─────────────────────────────────────

  describe "compute_salience/2" do
    setup do
      %{compactor: ContextCompactor.new()}
    end

    test "returns 0.0 for routine tool messages", %{compactor: c} do
      msg = %{role: :tool, name: "shell_execute", content: "ok — 42 tests, 0 failures"}
      assert ContextCompactor.compute_salience(msg, c) == 0.0
    end

    test "boosts error messages", %{compactor: c} do
      msg = %{
        role: :tool,
        name: "shell_execute",
        content: "ERROR: ** (UndefinedFunctionError) function Foo.bar/1 is undefined"
      }

      salience = ContextCompactor.compute_salience(msg, c)
      assert salience >= 0.3
    end

    test "boosts decision language", %{compactor: c} do
      msg = %{
        role: :user,
        content: "I've decided to use GenServer.start instead of start_link"
      }

      salience = ContextCompactor.compute_salience(msg, c)
      # user (+0.15) + decision (+0.15) = 0.3
      assert salience >= 0.3
    end

    test "boosts messages with person names", %{compactor: c} do
      msg = %{
        role: :tool,
        name: "relationship_save",
        content: Jason.encode!(%{"name" => "Hysun", "saved" => true})
      }

      salience = ContextCompactor.compute_salience(msg, c)
      assert salience >= 0.1
    end

    test "boosts messages with emotional markers", %{compactor: c} do
      msg = %{
        role: :tool,
        name: "relationship_moment",
        content: "A moment of trust and gratitude with collaborative spirit"
      }

      salience = ContextCompactor.compute_salience(msg, c)
      assert salience >= 0.05
    end

    test "boosts user messages", %{compactor: c} do
      msg = %{role: :user, content: "Please read the file"}
      salience = ContextCompactor.compute_salience(msg, c)
      assert salience >= 0.15
    end

    test "boosts system messages", %{compactor: c} do
      msg = %{role: :system, content: "You are a helpful agent"}
      salience = ContextCompactor.compute_salience(msg, c)
      assert salience >= 0.2
    end

    test "boosts novel file paths", %{compactor: c} do
      msg = %{
        role: :tool,
        name: "file_read",
        content: "apps/new_file.ex\ndefmodule NewFile do\nend"
      }

      salience = ContextCompactor.compute_salience(msg, c)
      assert salience >= 0.1
    end

    test "does not boost already-indexed file paths" do
      c = ContextCompactor.new()
      # Index the file first
      first_msg = %{
        role: :tool,
        name: "file_read",
        content: "apps/known.ex\ndefmodule Known do\nend"
      }

      c = ContextCompactor.append(c, first_msg)

      # Same path again — not novel
      second_msg = %{
        role: :tool,
        name: "file_read",
        content: "apps/known.ex\ndefmodule Known do\n  def new, do: :ok\nend"
      }

      salience = ContextCompactor.compute_salience(second_msg, c)
      # Should NOT get the +0.1 novel file boost
      assert salience < 0.1
    end

    test "clamps to max 0.5", %{compactor: c} do
      # Error (+0.3) + user (+0.15) + decision (+0.15) = 0.6 → clamped to 0.5
      msg = %{
        role: :user,
        content: "I've decided this ERROR is resolved and confirmed the fix"
      }

      salience = ContextCompactor.compute_salience(msg, c)
      assert salience == 0.5
    end

    test "handles non-binary content gracefully", %{compactor: c} do
      msg = %{role: :assistant, content: [%{type: "text", text: "hello"}]}
      salience = ContextCompactor.compute_salience(msg, c)
      assert is_float(salience) or salience == 0.0
    end
  end

  # ── effective_detail/3 ──────────────────────────────────────

  describe "effective_detail/3" do
    test "with zero salience equals detail_level" do
      assert ContextCompactor.effective_detail(10, 100, 0.0) ==
               ContextCompactor.detail_level(10, 100)
    end

    test "boosts detail for high-salience messages" do
      base = ContextCompactor.detail_level(50, 100)
      boosted = ContextCompactor.effective_detail(50, 100, 0.3)
      assert boosted > base
    end

    test "clamps to 1.0 max" do
      # detail_level(0, 100) = 1.0, salience = 0.5 → would be 1.5 → clamped to 1.0
      result = ContextCompactor.effective_detail(0, 100, 0.5)
      assert result == 1.0
    end

    test "old messages with high salience get meaningfully boosted" do
      # An old message (index 80 of 100) with salience 0.4
      base = ContextCompactor.detail_level(80, 100)
      boosted = ContextCompactor.effective_detail(80, 100, 0.4)

      # base = 0.2, boosted = 0.2 * 1.4 = 0.28
      assert boosted > base
      assert_in_delta boosted, base * 1.4, 0.01
    end
  end

  # ── salience_scores in compactor ────────────────────────────

  describe "salience_scores integration" do
    test "append populates salience_scores for salient messages" do
      c = ContextCompactor.new()

      # Routine message — should NOT populate
      c = ContextCompactor.append(c, %{role: :tool, name: "shell", content: "ok"})
      assert c.salience_scores == %{}

      # Error message — should populate
      c = ContextCompactor.append(c, %{role: :tool, name: "shell", content: "ERROR: crash"})
      assert map_size(c.salience_scores) == 1
      assert Map.has_key?(c.salience_scores, 2)
    end

    test "salience_scores are backwards compatible when empty" do
      c = ContextCompactor.new(effective_window: 100)

      c = ContextCompactor.append(c, %{role: :system, content: "S"})
      c = ContextCompactor.append(c, %{role: :user, content: "T"})

      Enum.reduce(1..10, c, fn i, acc ->
        acc
        |> ContextCompactor.append(%{role: :assistant, content: "step #{i}"})
        |> ContextCompactor.append(%{role: :tool, name: "test", content: "ok #{i}"})
        |> ContextCompactor.maybe_compact()
      end)

      # Should not crash — backwards compat
    end
  end

  # ── SalienceTranscript ──────────────────────────────────────

  describe "SalienceTranscript.generate/0" do
    test "produces messages with both salience labels" do
      transcript = SalienceTranscript.generate()
      tool_calls = transcript["tool_calls"]

      high = Enum.filter(tool_calls, &(&1["salience_label"] == "high"))
      low = Enum.filter(tool_calls, &(&1["salience_label"] == "low"))

      assert length(high) > 0, "Should have high-salience messages"
      assert length(low) > 0, "Should have low-salience messages"
      assert length(high) + length(low) == length(tool_calls)
    end

    test "high-salience messages contain expected content" do
      transcript = SalienceTranscript.generate()
      high = Enum.filter(transcript["tool_calls"], &(&1["salience_label"] == "high"))

      all_results = Enum.map_join(high, " ", & &1["result"])

      # Should contain errors
      assert String.contains?(all_results, "ERROR")
      # Should contain person names
      assert String.contains?(all_results, "Hysun")
    end

    test "low-salience messages contain routine content" do
      transcript = SalienceTranscript.generate()
      low = Enum.filter(transcript["tool_calls"], &(&1["salience_label"] == "low"))

      # Should be routine file reads and status messages
      names = Enum.map(low, & &1["name"])
      assert "file_read" in names or "shell_execute" in names or "file_list" in names
    end

    test "has required transcript fields" do
      transcript = SalienceTranscript.generate()

      assert is_binary(transcript["task"])
      assert is_binary(transcript["text"])
      assert is_list(transcript["tool_calls"])
      assert is_integer(transcript["turns"])
    end

    test "tool calls have sequential turn numbers" do
      transcript = SalienceTranscript.generate()
      turns = Enum.map(transcript["tool_calls"], & &1["turn"])

      assert turns == Enum.to_list(1..length(turns))
    end
  end

  # ── SalienceEval ground truth extraction ────────────────────

  describe "extract_salience_ground_truth/1" do
    test "partitions facts by salience label" do
      transcript = SalienceTranscript.generate()
      {high_facts, low_facts} = SalienceEval.extract_salience_ground_truth(transcript)

      assert length(high_facts) > 0
      assert length(low_facts) > 0
    end

    test "high facts include error patterns" do
      transcript = SalienceTranscript.generate()
      {high_facts, _} = SalienceEval.extract_salience_ground_truth(transcript)

      error_facts = Enum.filter(high_facts, fn {type, _} -> type == :error end)
      assert length(error_facts) > 0
    end

    test "high facts include person names" do
      transcript = SalienceTranscript.generate()
      {high_facts, _} = SalienceEval.extract_salience_ground_truth(transcript)

      person_facts = Enum.filter(high_facts, fn {type, _} -> type == :person end)
      assert length(person_facts) > 0
    end
  end
end
