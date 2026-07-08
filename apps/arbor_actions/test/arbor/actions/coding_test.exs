defmodule Arbor.Actions.CodingTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.{Acp, Coding, Git, Shell}

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
                   pr_title: "Add feature file"
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
                   open_pr: true
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
