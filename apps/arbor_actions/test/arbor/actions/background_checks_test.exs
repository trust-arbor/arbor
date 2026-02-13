defmodule Arbor.Actions.BackgroundChecksTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.BackgroundChecks

  @moduletag :fast

  @all_checks ~w(memory_freshness journal_continuity memory_md_health session_patterns roadmap_staleness system_health)

  defp skip_all_except(check) do
    Enum.reject(@all_checks, &(&1 == check))
  end

  defp run_check(tmp_dir, check, extra_params \\ %{}) do
    params =
      Map.merge(
        %{
          personal_dir: tmp_dir,
          session_dir: tmp_dir,
          project_dir: tmp_dir,
          skip: skip_all_except(check)
        },
        extra_params
      )

    BackgroundChecks.Run.run(params, %{})
  end

  defp old_erl_datetime(days_ago) do
    seconds =
      :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) - days_ago * 86400

    :calendar.gregorian_seconds_to_datetime(seconds)
  end

  # ===========================================================================
  # Metadata
  # ===========================================================================

  describe "metadata" do
    test "action name" do
      assert BackgroundChecks.Run.name() == "background_checks_run"
    end

    test "category" do
      assert BackgroundChecks.Run.category() == "background_checks"
    end

    test "tags include background" do
      assert "background" in BackgroundChecks.Run.tags()
    end

    test "all taint_roles are :data" do
      roles = BackgroundChecks.Run.taint_roles()
      assert Enum.all?(Map.values(roles), &(&1 == :data))
    end
  end

  # ===========================================================================
  # Result Structure
  # ===========================================================================

  describe "result structure" do
    test "returns {:ok, result} with all expected keys", %{tmp_dir: tmp_dir} do
      assert {:ok, result} =
               BackgroundChecks.Run.run(
                 %{personal_dir: tmp_dir, session_dir: tmp_dir, project_dir: tmp_dir},
                 %{}
               )

      assert is_list(result.actions)
      assert is_list(result.warnings)
      assert is_list(result.suggestions)
      assert is_binary(result.markdown)
      assert is_integer(result.duration_ms)
      assert is_list(result.checks_run)
      assert is_list(result.checks_skipped)
    end

    test "markdown starts with report header", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BackgroundChecks.Run.run(
          %{personal_dir: tmp_dir, session_dir: tmp_dir, project_dir: tmp_dir},
          %{}
        )

      assert String.starts_with?(result.markdown, "# Background Check Report")
    end
  end

  # ===========================================================================
  # Memory Freshness
  # ===========================================================================

  describe "memory_freshness" do
    test "detects stale self_knowledge.json", %{tmp_dir: tmp_dir} do
      memory_dir = Path.join(tmp_dir, "memory")
      File.mkdir_p!(memory_dir)
      sk_path = Path.join(memory_dir, "self_knowledge.json")
      File.write!(sk_path, Jason.encode!(%{"learnings" => [], "reminders" => []}))
      File.touch!(sk_path, old_erl_datetime(4))

      {:ok, result} = run_check(tmp_dir, "memory_freshness")

      assert Enum.any?(result.warnings, &(&1.type == :self_knowledge_stale))
    end

    test "detects recent self_knowledge as info", %{tmp_dir: tmp_dir} do
      memory_dir = Path.join(tmp_dir, "memory")
      File.mkdir_p!(memory_dir)
      sk_path = Path.join(memory_dir, "self_knowledge.json")
      File.write!(sk_path, Jason.encode!(%{"learnings" => [], "reminders" => []}))
      # Set to 30 hours ago (> 24h info threshold, < 72h critical)
      seconds = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time()) - 30 * 3600

      File.touch!(sk_path, :calendar.gregorian_seconds_to_datetime(seconds))

      {:ok, result} = run_check(tmp_dir, "memory_freshness")

      assert Enum.any?(result.warnings, &(&1.type == :self_knowledge_not_recent))
    end

    test "detects learnings bloat", %{tmp_dir: tmp_dir} do
      memory_dir = Path.join(tmp_dir, "memory")
      File.mkdir_p!(memory_dir)
      sk_path = Path.join(memory_dir, "self_knowledge.json")
      learnings = Enum.map(1..160, &%{"content" => "Learning #{&1}"})
      File.write!(sk_path, Jason.encode!(%{"learnings" => learnings}))

      {:ok, result} = run_check(tmp_dir, "memory_freshness")

      assert Enum.any?(result.warnings, &(&1.type == :self_knowledge_bloat))
    end

    test "detects missing self_knowledge.json", %{tmp_dir: tmp_dir} do
      {:ok, result} = run_check(tmp_dir, "memory_freshness")

      assert Enum.any?(result.warnings, &(&1.type == :self_knowledge_missing))
    end

    test "detects stale relationship files", %{tmp_dir: tmp_dir} do
      memory_dir = Path.join(tmp_dir, "memory")
      File.mkdir_p!(memory_dir)

      # Create fresh self_knowledge to avoid that warning
      sk_path = Path.join(memory_dir, "self_knowledge.json")
      File.write!(sk_path, Jason.encode!(%{"learnings" => []}))

      # Create stale relationship file
      rel_path = Path.join(memory_dir, "rel_test.json")
      File.write!(rel_path, Jason.encode!(%{"name" => "test"}))
      File.touch!(rel_path, old_erl_datetime(10))

      {:ok, result} = run_check(tmp_dir, "memory_freshness")

      assert Enum.any?(result.suggestions, &(&1.type == :stale_relationship))
    end
  end

  # ===========================================================================
  # Journal Continuity
  # ===========================================================================

  describe "journal_continuity" do
    test "detects no journal entries", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "journal"))

      {:ok, result} = run_check(tmp_dir, "journal_continuity")

      assert Enum.any?(result.warnings, &(&1.type == :no_journal_entries))
    end

    test "detects stale journal (last entry > 48h)", %{tmp_dir: tmp_dir} do
      journal_dir = Path.join(tmp_dir, "journal")
      File.mkdir_p!(journal_dir)

      path = Path.join(journal_dir, "2026-02-08-old-entry.md")
      File.write!(path, "# Old Entry")
      File.touch!(path, old_erl_datetime(5))

      {:ok, result} = run_check(tmp_dir, "journal_continuity")

      assert Enum.any?(result.warnings, &(&1.type == :journal_stale))
    end

    test "detects date gaps in journal", %{tmp_dir: tmp_dir} do
      journal_dir = Path.join(tmp_dir, "journal")
      File.mkdir_p!(journal_dir)

      # Create entries with a 5-day gap
      File.write!(Path.join(journal_dir, "2026-02-01-entry.md"), "content")
      File.write!(Path.join(journal_dir, "2026-02-06-entry.md"), "content")

      recent = Path.join(journal_dir, "2026-02-12-entry.md")
      File.write!(recent, "content")
      # Touch to now so it doesn't trigger stale warning
      File.touch!(recent)

      {:ok, result} = run_check(tmp_dir, "journal_continuity")

      assert Enum.any?(result.suggestions, &(&1.type == :journal_gap))
    end

    test "no warning for fresh journal", %{tmp_dir: tmp_dir} do
      journal_dir = Path.join(tmp_dir, "journal")
      File.mkdir_p!(journal_dir)

      path = Path.join(journal_dir, "2026-02-12-fresh.md")
      File.write!(path, "# Fresh Entry")
      File.touch!(path)

      {:ok, result} = run_check(tmp_dir, "journal_continuity")

      refute Enum.any?(result.warnings, &(&1.type == :journal_stale))
    end

    test "sorts by date not filename string", %{tmp_dir: tmp_dir} do
      journal_dir = Path.join(tmp_dir, "journal")
      File.mkdir_p!(journal_dir)

      # "overnight-..." sorts after "2026-..." alphabetically but has older date
      File.write!(Path.join(journal_dir, "overnight-2026-01-27.md"), "old")
      File.touch!(Path.join(journal_dir, "overnight-2026-01-27.md"), old_erl_datetime(20))

      recent = Path.join(journal_dir, "2026-02-12-entry.md")
      File.write!(recent, "new")
      File.touch!(recent)

      {:ok, result} = run_check(tmp_dir, "journal_continuity")

      # Should NOT flag as stale because 2026-02-12 is recent
      refute Enum.any?(result.warnings, &(&1.type == :journal_stale))
    end
  end

  # ===========================================================================
  # MEMORY.md Health
  # ===========================================================================

  describe "memory_md_health" do
    test "detects full MEMORY.md (>= 200 lines)", %{tmp_dir: tmp_dir} do
      memory_dir = Path.join(tmp_dir, "memory")
      File.mkdir_p!(memory_dir)
      content = Enum.map_join(1..210, "\n", &"Line #{&1}")
      File.write!(Path.join(memory_dir, "MEMORY.md"), content)

      {:ok, result} = run_check(tmp_dir, "memory_md_health")

      assert Enum.any?(result.warnings, &(&1.type == :memory_md_full))
      assert Enum.any?(result.actions, &(&1.type == :prune_memory_md))
    end

    test "detects approaching limit (>= 190 lines)", %{tmp_dir: tmp_dir} do
      memory_dir = Path.join(tmp_dir, "memory")
      File.mkdir_p!(memory_dir)
      content = Enum.map_join(1..195, "\n", &"Line #{&1}")
      File.write!(Path.join(memory_dir, "MEMORY.md"), content)

      {:ok, result} = run_check(tmp_dir, "memory_md_health")

      assert Enum.any?(result.suggestions, &(&1.type == :memory_md_approaching_limit))
    end

    test "detects missing MEMORY.md", %{tmp_dir: tmp_dir} do
      {:ok, result} = run_check(tmp_dir, "memory_md_health")

      assert Enum.any?(result.warnings, &(&1.type == :memory_md_missing))
    end

    test "reports stats as suggestion", %{tmp_dir: tmp_dir} do
      memory_dir = Path.join(tmp_dir, "memory")
      File.mkdir_p!(memory_dir)
      content = "# Title\n\n## Section 1\nContent\n\n## Section 2\nMore content"
      File.write!(Path.join(memory_dir, "MEMORY.md"), content)

      {:ok, result} = run_check(tmp_dir, "memory_md_health")

      assert Enum.any?(result.suggestions, &(&1.type == :memory_md_stats))
    end
  end

  # ===========================================================================
  # Session Patterns
  # ===========================================================================

  describe "session_patterns" do
    test "extracts tool usage from JSONL", %{tmp_dir: tmp_dir} do
      session_file = Path.join(tmp_dir, "test-session.jsonl")

      entries =
        [
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "name" => "Read", "id" => "1"},
                %{"type" => "tool_use", "name" => "Read", "id" => "2"}
              ]
            }
          },
          %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "name" => "Bash", "id" => "3"}
              ]
            }
          }
        ]

      content = Enum.map_join(entries, "\n", &Jason.encode!/1)
      File.write!(session_file, content)

      {:ok, result} = run_check(tmp_dir, "session_patterns")

      assert Enum.any?(result.suggestions, &(&1.type == :tool_usage))

      tool_suggestion = Enum.find(result.suggestions, &(&1.type == :tool_usage))
      assert String.contains?(tool_suggestion.content, "Read")
      assert String.contains?(tool_suggestion.content, "Bash")
    end

    test "reports no sessions found", %{tmp_dir: tmp_dir} do
      {:ok, result} = run_check(tmp_dir, "session_patterns")

      assert Enum.any?(result.warnings, &(&1.type == :no_sessions))
    end
  end

  # ===========================================================================
  # Roadmap Staleness
  # ===========================================================================

  describe "roadmap_staleness" do
    test "detects stale inbox items", %{tmp_dir: tmp_dir} do
      inbox_dir = Path.join(tmp_dir, ".arbor/roadmap/0-inbox")
      File.mkdir_p!(inbox_dir)

      for stage <- ~w(1-brainstorming 2-planned 3-in-progress 5-completed) do
        File.mkdir_p!(Path.join(tmp_dir, ".arbor/roadmap/#{stage}"))
      end

      item = Path.join(inbox_dir, "old-item.md")
      File.write!(item, "# Old Item")
      File.touch!(item, old_erl_datetime(10))

      {:ok, result} = run_check(tmp_dir, "roadmap_staleness")

      assert Enum.any?(result.warnings, &(&1.type == :stale_inbox))
    end

    test "detects stale in-progress items", %{tmp_dir: tmp_dir} do
      for stage <- ~w(0-inbox 1-brainstorming 2-planned 3-in-progress 5-completed) do
        File.mkdir_p!(Path.join(tmp_dir, ".arbor/roadmap/#{stage}"))
      end

      wip_dir = Path.join(tmp_dir, ".arbor/roadmap/3-in-progress")
      item = Path.join(wip_dir, "stale-work.md")
      File.write!(item, "# Stale WIP")
      File.touch!(item, old_erl_datetime(6))

      {:ok, result} = run_check(tmp_dir, "roadmap_staleness")

      assert Enum.any?(result.warnings, &(&1.type == :stale_wip))
    end

    test "reports roadmap summary", %{tmp_dir: tmp_dir} do
      inbox_dir = Path.join(tmp_dir, ".arbor/roadmap/0-inbox")
      File.mkdir_p!(inbox_dir)
      File.write!(Path.join(inbox_dir, "item.md"), "content")

      for stage <- ~w(1-brainstorming 2-planned 3-in-progress 5-completed) do
        File.mkdir_p!(Path.join(tmp_dir, ".arbor/roadmap/#{stage}"))
      end

      {:ok, result} = run_check(tmp_dir, "roadmap_staleness")

      assert Enum.any?(result.suggestions, &(&1.type == :roadmap_summary))
    end
  end

  # ===========================================================================
  # Skip Parameter
  # ===========================================================================

  describe "skip parameter" do
    test "skips all checks when all names provided", %{tmp_dir: tmp_dir} do
      {:ok, result} =
        BackgroundChecks.Run.run(
          %{
            personal_dir: tmp_dir,
            session_dir: tmp_dir,
            project_dir: tmp_dir,
            skip: @all_checks
          },
          %{}
        )

      assert result.checks_run == []
      assert Enum.sort(result.checks_skipped) == Enum.sort(@all_checks)
      assert result.actions == []
      assert result.warnings == []
      assert result.suggestions == []
    end
  end

  # ===========================================================================
  # Graceful Degradation
  # ===========================================================================

  describe "graceful degradation" do
    test "non-existent paths don't crash", _ctx do
      assert {:ok, result} =
               BackgroundChecks.Run.run(
                 %{
                   personal_dir: "/nonexistent/path/#{System.unique_integer([:positive])}",
                   session_dir: "/nonexistent/session/#{System.unique_integer([:positive])}",
                   project_dir: "/nonexistent/project/#{System.unique_integer([:positive])}"
                 },
                 %{}
               )

      assert is_list(result.warnings)
      assert is_binary(result.markdown)
    end
  end
end
