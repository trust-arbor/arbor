defmodule Arbor.Actions.CodingTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.{Acp, Coding, Council, Git, Shell}
  alias Arbor.Actions.Mix, as: MixActions

  @moduletag :fast

  describe "ProduceReviewableChange metadata" do
    test "is discoverable as a coding action" do
      assert Coding.ProduceReviewableChange.name() == "coding_produce_reviewable_change"
      assert Coding.ProduceReviewableChange.category() == "coding"
      assert "acp" in Coding.ProduceReviewableChange.tags()
      assert "agent" in Coding.ProduceReviewableChange.tags()

      assert {:ok, Coding.ProduceReviewableChange} =
               Arbor.Actions.name_to_module("coding.produce_reviewable_change")

      assert Arbor.Actions.canonical_uri_for(Coding.ProduceReviewableChange, %{}) ==
               "arbor://action/coding/produce_reviewable_change"
    end
  end

  describe "ProduceReviewableChange.run/2" do
    test "delegates to default ACP agent with default permissions, validates, commits, and skips PR by default",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base_branch = git!(repo, ["branch", "--show-current"])
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          send(parent, {:start_session, params})
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

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
                   base_ref: base_branch,
                   branch_name: "test/coding-agent",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: [
                     "./bin/mix test apps/arbor_actions/test/arbor/actions/coding_test.exs"
                   ],
                   pr_title: "",
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "change_committed"
      assert result.branch == "test/coding-agent"
      assert result.acp_agent == "codex"
      refute Map.has_key?(result, :pr_url)
      assert File.exists?(Path.join(result.worktree_path, "feature.txt"))
      assert result.commit == git!(result.worktree_path, ["rev-parse", "HEAD"])

      assert git!(result.worktree_path, ["rev-list", "--count", "HEAD", "^#{base_branch}"]) ==
               "1"

      assert git!(result.worktree_path, ["branch", "--show-current"]) == "test/coding-agent"

      assert_receive {:start_session, start_params}
      assert start_params.provider == "codex"
      assert start_params.permission_mode == "default"
      assert start_params.cwd == result.worktree_path

      assert_receive {:send_message, send_params}
      assert send_params.prompt =~ "STATUS: declined"
      assert send_params.prompt =~ "STATUS: implemented"
      refute Map.has_key?(send_params, :timeout)

      assert_receive {:close_session, _}

      assert_receive {:validation, validation_params}
      assert validation_params.cwd == result.worktree_path
      assert validation_params.command =~ "./bin/mix test"

      refute_received {:unexpected_pr, _}
    end

    test "routes default mix compile validation through schema-bounded Mix action",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        MixActions.Compile, params, _context ->
          send(parent, {:mix_compile_validation, params})
          {:ok, %{exit_code: 0, stdout: "compiled\n", stderr: ""}}

        Shell.Execute, params, _context ->
          send(parent, {:unexpected_shell_validation, params})
          {:ok, %{exit_code: 0, stdout: "shell\n", stderr: ""}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   branch_name: "test/default-mix-compile-validation",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "change_committed"

      assert_receive {:mix_compile_validation, validation_params}
      assert validation_params.path == result.worktree_path
      assert validation_params.warnings_as_errors == true
      assert validation_params.timeout == 300_000

      refute_received {:unexpected_shell_validation, _}
    end

    test "threads an explicit ACP hard timeout only when requested", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          send(parent, {:start_session, params})
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        Acp.SendMessage, params, _context ->
          send(parent, {:send_message, params})
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, _params, _context ->
          {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   branch_name: "test/coding-agent-timeout",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["true"],
                   timeout: 123_456,
                   inactivity_timeout_ms: 654_321,
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "change_committed"

      assert_receive {:start_session, start_params}
      assert start_params.timeout == 123_456

      assert_receive {:send_message, send_params}
      assert send_params.timeout == 123_456
      assert send_params.inactivity_timeout_ms == 654_321
    end

    test "uses the requested ACP agent provider", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          send(parent, {:start_session, params})
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, _params, _context ->
          {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   acp_agent: "claude",
                   repo_path: repo,
                   branch_name: "test/custom-acp-agent",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["true"],
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "change_committed"
      assert result.acp_agent == "claude"

      assert_receive {:start_session, start_params}
      assert start_params.provider == "claude"
      assert start_params.permission_mode == "default"
      assert start_params.cwd == result.worktree_path
    end

    test "opens a draft PR through the platform-agnostic git action when requested",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

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

    test "retries reuse one requested branch and reset to one review commit", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base_branch = git!(repo, ["branch", "--show-current"])
      parent = self()
      run_number = :counters.new(1, [])

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        Acp.SendMessage, _params, _context ->
          :counters.add(run_number, 1, 1)
          worktree = Process.get(:coding_test_worktree)
          run = :counters.get(run_number, 1)
          File.write!(Path.join(worktree, "feature.txt"), "implemented #{run}\n")
          {:ok, %{text: "STATUS: implemented\nRun #{run}"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, _params, _context ->
          {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}

        Git.PR, params, _context ->
          send(parent, {:pr, params})

          {:ok,
           %{
             url: "https://example.test/pr/#{:counters.get(run_number, 1)}",
             draft?: true
           }}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      params = %{
        task: "Add feature file",
        repo_path: repo,
        base_ref: base_branch,
        branch_name: "test/idempotent-coding-agent",
        worktree_base_dir: Path.join(tmp_dir, "worktrees"),
        validation_commands: ["true"],
        open_pr: true,
        submit_review: false
      }

      assert {:ok, first} = Coding.ProduceReviewableChange.run(params, %{action_runner: runner})
      assert {:ok, second} = Coding.ProduceReviewableChange.run(params, %{action_runner: runner})

      assert first.status == "pr_created"
      assert second.status == "pr_created"
      assert first.branch == second.branch
      assert first.worktree_path == second.worktree_path
      assert first.commit != second.commit

      assert git!(repo, ["branch", "--list", "test/idempotent-coding-agent"]) =~
               "test/idempotent-coding-agent"

      assert git!(second.worktree_path, ["rev-list", "--count", "HEAD", "^#{base_branch}"]) ==
               "1"

      assert File.read!(Path.join(second.worktree_path, "feature.txt")) == "implemented 2\n"
      assert_receive {:pr, %{branch: "test/idempotent-coding-agent"}}
      assert_receive {:pr, %{branch: "test/idempotent-coding-agent"}}
    end

    test "submits the committed diff to council review and exposes auto-proceed routing",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

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
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

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
            {:ok, %{session_pid: self(), session_id: "acp-session"}}

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
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

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

    test "returns no_changes when ACP agent edits nothing", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

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
      base_branch = git!(repo, ["branch", "--show-current"])
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

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
                   base_ref: base_branch,
                   branch_name: "test/validation-fails",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["./bin/mix test"]
                 },
                 %{action_runner: runner}
               )

      assert result.status == "validation_failed"
      assert [%{command: "./bin/mix test", passed: false}] = result.validation

      assert git!(result.worktree_path, ["rev-list", "--count", "HEAD", "^#{base_branch}"]) ==
               "0"

      assert git!(result.worktree_path, ["status", "--porcelain"]) =~ "broken.txt"
      assert_receive {:validation, _}
      refute_received :unexpected_pr
    end

    test "waits for pending validation approval and retries with approved invocation", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base_branch = git!(repo, ["branch", "--show-current"])
      parent = self()
      validation_count = :counters.new(1, [])

      approval_awaiter = fn proposal_id, resource_uri, context, timeout ->
        send(parent, {:await_approval, proposal_id, resource_uri, context[:agent_id], timeout})
        :approved
      end

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, params, context ->
          :counters.add(validation_count, 1, 1)
          count = :counters.get(validation_count, 1)
          send(parent, {:validation, count, params, Map.get(context, :approved_invocation)})

          case count do
            1 -> {:ok, :pending_approval, "irq_validation"}
            2 -> {:ok, %{exit_code: 0, stdout: "ok\n", stderr: ""}}
          end

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   base_ref: base_branch,
                   branch_name: "test/validation-approval",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["grep implemented feature.txt"],
                   submit_review: false
                 },
                 %{
                   action_runner: runner,
                   agent_id: "agent_test",
                   approval_awaiter: approval_awaiter
                 }
               )

      assert result.status == "change_committed"
      assert [%{command: "grep implemented feature.txt", passed: true}] = result.validation

      assert_receive {:validation, 1, %{command: "grep implemented feature.txt"}, nil}

      assert_receive {:await_approval, "irq_validation", "arbor://shell/exec/grep", "agent_test",
                      timeout}

      assert is_integer(timeout)

      assert_receive {:validation, 2, %{command: "grep implemented feature.txt"},
                      %{
                        request_id: "irq_validation",
                        principal_id: "agent_test",
                        resource_uri: "arbor://shell/exec/grep",
                        decision: :approved
                      }}
    end

    test "security regression: validation_timeout 0/1 does not force exit 137 on short commands",
         %{tmp_dir: tmp_dir} do
      # Live E2E saw `ls …` fail with exit 137 — that is Shell.Executor's timeout
      # kill code, not a flaky ls. LLM tool args filled validation_timeout with
      # 0/1; Elixir `0 || default` keeps 0, and receive after 0 fires immediately.
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, params, _context ->
          send(parent, {:validation, params})
          # Assert the action floored the absurd timeout before invoking shell.
          assert params.timeout >= 10_000

          {:ok,
           %{
             exit_code: 0,
             stdout: "ok\n",
             stderr: "",
             timed_out: false,
             killed: false
           }}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   branch_name: "test/validation-timeout-floor",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["ls feature.txt"],
                   validation_timeout: 1,
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "change_committed"
      assert_receive {:validation, %{timeout: timeout, command: "ls feature.txt"}}
      assert timeout >= 10_000
    end

    test "labels timeout kills clearly in validation results", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      runner = fn
        Acp.StartSession, params, _context ->
          Process.put(:coding_test_worktree, params.cwd)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        Acp.SendMessage, _params, _context ->
          worktree = Process.get(:coding_test_worktree)
          File.write!(Path.join(worktree, "feature.txt"), "implemented\n")
          {:ok, %{text: "STATUS: implemented\nCreated feature.txt"}}

        Acp.CloseSession, _params, _context ->
          {:ok, %{status: "closed"}}

        Shell.Execute, _params, _context ->
          {:ok,
           %{
             exit_code: 137,
             stdout: "",
             stderr: "",
             timed_out: true,
             killed: true
           }}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      assert {:ok, result} =
               Coding.ProduceReviewableChange.run(
                 %{
                   task: "Add feature file",
                   repo_path: repo,
                   branch_name: "test/validation-timeout-label",
                   worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                   validation_commands: ["ls feature.txt"],
                   submit_review: false
                 },
                 %{action_runner: runner}
               )

      assert result.status == "validation_failed"

      assert [%{passed: false, exit_code: 137, timed_out: true, stderr: stderr}] =
               result.validation

      assert stderr =~ "timed out"
      assert stderr =~ "137"
    end
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end
end
