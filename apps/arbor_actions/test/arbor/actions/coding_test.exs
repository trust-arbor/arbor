defmodule Arbor.Actions.CodingTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.{Acp, Coding, Council, Git, Shell}

  @moduletag :fast

  describe "ProduceReviewableChange metadata" do
    test "is discoverable as a coding action" do
      assert Coding.ProduceReviewableChange.name() == "coding_produce_reviewable_change"
      assert Coding.ProduceReviewableChange.category() == "coding"
      assert "codex" in Coding.ProduceReviewableChange.tags()

      assert {:ok, Coding.ProduceReviewableChange} =
               Arbor.Actions.name_to_module("coding.produce_reviewable_change")

      assert Arbor.Actions.canonical_uri_for(Coding.ProduceReviewableChange, %{}) ==
               "arbor://action/coding/produce_reviewable_change"
    end
  end

  describe "ProduceReviewableChange.run/2" do
    test "delegates to Codex with default ACP permissions, validates, commits, and skips PR by default",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          send(parent, {:start_session, params})
          {:ok, %{session_pid: self(), session_id: "codex-session"}}

        Acp.SendMessage, params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          send(parent, {:send_message, params})
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, params, _context ->
          send(parent, {:close_session, params})
          {:ok, %{status: "closed"}}

        Shell.Execute, params, _context ->
          send(parent, {:validation, params})
          {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

        Git.PR, params, _context ->
          send(parent, {:unexpected_pr, params})
          {:ok, %{url: "https://example.test/pr/unexpected", title: params.title, draft?: true}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   branch_name: "test/coding-agent",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: [
                     "./bin/mix test apps/arbor_actions/test/arbor/actions/coding_test.exs"
                   ],
                   pr_title: "Add feature file",
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "change_committed"
      assert result.branch == "test/coding-agent"
      refute Map.has_key?(result, :pr_url)
      assert File.exists?(Path.join(result.worktree_path, "feature.txt"))

      assert_receive {:start_session, start_params}
      assert start_params.provider == "codex"
      assert start_params.permission_mode == "default"
      assert start_params.cwd == result.worktree_path

      assert_receive {:send_message, send_params}
      assert send_params.prompt =~ "STATUS: declined"
      assert send_params.prompt =~ "STATUS: implemented"

      assert_receive {:close_session, _}

      assert_receive {:validation, validation_params}
      assert validation_params.cwd == result.worktree_path
      assert validation_params.command =~ "./bin/mix test"

      refute_received {:unexpected_pr, _}
    end

    test "opens a draft PR through the platform-agnostic git action when requested",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "codex-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, _params, _context ->
          {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

        Git.PR, params, _context ->
          send(parent, {:pr, params})
          {:ok, %{url: "https://example.test/pr/1", number: 1, draft?: true}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   branch_name: "test/coding-agent-pr",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["./bin/mix test"],
                   pr_title: "Add feature file",
                   open_pr: true,
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "pr_created"
      assert result.branch == "test/coding-agent-pr"
      assert result.pr_url == "https://example.test/pr/1"

      assert_receive {:pr, pr_params}
      assert pr_params.path == result.worktree_path
      assert pr_params.branch == "test/coding-agent-pr"
      assert pr_params.draft == true
      assert pr_params.body =~ "Human review and merge are required."
    end

    test "submits the committed diff to council review and exposes auto-proceed routing",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "codex-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, _params, _context ->
          {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

        Council.ReviewChange, params, _context ->
          send(parent, {:review, params})

          {:ok,
           %{
             status: "reviewed",
             recommendation: :keep,
             decision: "approved",
             branch: params.branch,
             files: params.files,
             approve_count: 9,
             reject_count: 1,
             abstain_count: 0,
             quorum_met: true,
             blast_radius: :low,
             tier_decision: :auto_proceed,
             human_required: false,
             security_veto: false,
             tier_reasons: []
           }}

        Git.PR, params, _context ->
          send(parent, {:unexpected_pr, params})
          {:ok, %{url: "https://example.test/pr/unexpected"}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   branch_name: "test/coding-agent-review",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["./bin/mix test"]
                 },
                 %{action_runner: runner, agent_id: "agent_coder"}
               )

      assert result.status == "change_committed"
      assert result.tier_decision == :auto_proceed
      assert result.human_required == false
      assert result.review_recommendation == :keep
      assert result.review.files == ["feature.txt"]

      assert_receive {:review, review_params}
      assert review_params.branch == "test/coding-agent-review"
      assert review_params.files == ["feature.txt"]
      assert review_params.intent == "Add feature file"
      assert review_params.agent_id == "agent_coder"
      assert review_params.diff =~ "+implemented"
      assert is_binary(review_params.base_ref)

      refute_received {:unexpected_pr, _}
    end

    test "human-review routing can still open a draft PR when requested",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "codex-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "security.txt"), "review me\n")
          {:ok, %{text: "STATUS: implemented\nCreated security.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, _params, _context ->
          {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

        Council.ReviewChange, params, _context ->
          send(parent, {:review, params})

          {:ok,
           %{
             status: "reviewed",
             recommendation: :keep,
             decision: "approved",
             branch: params.branch,
             files: params.files,
             blast_radius: :high,
             tier_decision: :human_review,
             human_required: true,
             security_veto: false,
             tier_reasons: [:high_blast_radius]
           }}

        Git.PR, params, _context ->
          send(parent, {:pr, params})
          {:ok, %{url: "https://example.test/pr/2", number: 2, draft?: true}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Touch security-sensitive code",
                   repo_path: repo,
                   branch_name: "test/coding-agent-human-review",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["./bin/mix test"],
                   submit_review: true,
                   open_pr: true
                 },
                 %{action_runner: runner}
               )

      assert result.status == "pr_created"
      assert result.pr_url == "https://example.test/pr/2"
      assert result.tier_decision == :human_review
      assert result.human_required == true
      assert result.blast_radius == :high

      assert_receive {:review, _review_params}
      assert_receive {:pr, pr_params}
      assert pr_params.branch == "test/coding-agent-human-review"
      assert pr_params.draft == true
    end

    test "review rework and stop routes skip draft PR creation", %{tmp_dir: tmp_dir} do
      for {tier_decision, expected_status} <- [
            {:rework, "review_requires_rework"},
            {:stop, "review_rejected"}
          ] do
        repo = create_git_repo(Path.join(tmp_dir, "repo-#{tier_decision}"))
        parent = self()
        branch = "test/coding-agent-#{tier_decision}"
        file_name = "#{tier_decision}.txt"

        runner = fn
          Acp.StartSession, params, _context ->
            Process.put(:coding_test_worktree, params.cwd)
            {:ok, %{session_pid: self(), session_id: "codex-session"}}

          Acp.SendMessage, _params, _context ->
            worktree = Process.get(:coding_test_worktree)
            File.write!(Path.join(worktree, file_name), "#{tier_decision}\n")
            {:ok, %{text: "STATUS: implemented\nCreated #{file_name}"}}

          Acp.CloseSession, _params, _context ->
            {:ok, %{status: "closed"}}

          Shell.Execute, _params, _context ->
            {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

          Council.ReviewChange, params, _context ->
            send(parent, {:review, tier_decision, params})

            recommendation = if tier_decision == :rework, do: :revise, else: :reject
            decision = if tier_decision == :rework, do: "deadlock", else: "rejected"

            {:ok,
             %{
               status: "reviewed",
               recommendation: recommendation,
               decision: decision,
               branch: params.branch,
               files: params.files,
               blast_radius: :low,
               tier_decision: tier_decision,
               human_required: false,
               security_veto: false,
               tier_reasons: []
             }}

          Git.PR, params, _context ->
            send(parent, {:unexpected_pr, tier_decision, params})
            {:ok, %{url: "https://example.test/pr/unexpected"}}

          module, params, context ->
            module.run(params, Map.delete(context, :action_runner))
        end

        assert {:ok, result} =
                 Coding.ProduceReviewableChange.run(
                   %{
                     task: "Exercise #{tier_decision} routing",
                     repo_path: repo,
                     branch_name: branch,
                     worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                     validation_commands: ["./bin/mix test"],
                     submit_review: true,
                     open_pr: true
                   },
                   %{action_runner: runner}
                 )

        assert result.status == expected_status
        assert result.tier_decision == tier_decision
        assert result.review.files == [file_name]

        assert_receive {:review, ^tier_decision, _review_params}
        refute_received {:unexpected_pr, ^tier_decision, _}
      end
    end

    test "returns declined without committing or opening a PR", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "codex-session"}}

        Acp.SendMessage, _params, _context ->
          {:ok, %{text: "STATUS: declined\nThe task needs a clearer target."}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Git.PR, _params, _context ->
          send(parent, :unexpected_pr)
          {:ok, %{url: "https://example.test/pr/unexpected"}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Change the thing",
                   repo_path: repo,
                   branch_name: "test/declined",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{action_runner: runner}
               )

      assert result.status == "declined"
      assert result.response_text =~ "needs a clearer target"
      refute_received :unexpected_pr
    end

    test "returns no_changes when Codex edits nothing", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "codex-session"}}

        Acp.SendMessage, _params, _context ->
          {:ok, %{text: "STATUS: implemented\nNo edit was necessary."}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Inspect only",
                   repo_path: repo,
                   branch_name: "test/no-changes",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees")
                 },
                 %{action_runner: runner}
               )

      assert result.status == "no_changes"
    end

    test "returns validation_failed and skips PR creation when validation fails", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "codex-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "broken.txt"), "broken\n")
          {:ok, %{text: "STATUS: implemented\nBut validation will fail."}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, params, _context ->
          send(parent, {:validation, params})
          {:ok, %{exit_code: 1, stdout: "", stderr: "failed\n"}}

        Git.PR, _params, _context ->
          send(parent, :unexpected_pr)
          {:ok, %{url: "https://example.test/pr/unexpected"}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add broken file",
                   repo_path: repo,
                   branch_name: "test/validation-fails",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["./bin/mix test"]
                 },
                 %{action_runner: runner}
               )

      assert result.status == "validation_failed"
      assert [%{command: "./bin/mix test", passed: false}] = result.validation
      assert_receive {:validation, _}
      refute_received :unexpected_pr
    end
  end
end
