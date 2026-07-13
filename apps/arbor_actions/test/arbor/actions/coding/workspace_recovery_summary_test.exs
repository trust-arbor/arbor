defmodule Arbor.Actions.Coding.WorkspaceRecoverySummaryTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.Workspace

  @moduletag :fast

  describe "discovery and canonical URI" do
    test "registers under the existing coding workspace namespace" do
      assert Workspace.RecoverySummary in Actions.list_actions().coding

      assert {:ok, Workspace.RecoverySummary} =
               Actions.name_to_module("coding.workspace.recovery_summary")

      assert {:ok, Workspace.RecoverySummary} =
               Actions.name_to_module("coding_workspace_recovery_summary")

      assert Actions.canonical_uri_for(Workspace.RecoverySummary, %{}) ==
               "arbor://action/coding/workspace/recovery_summary"
    end
  end

  describe "run/2" do
    test "returns deterministic bounded authoritative state without raw diff or absolute paths",
         %{
           tmp_dir: tmp_dir
         } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/recovery-summary"
      base = git!(repo, ["rev-parse", "HEAD"])

      assert {:ok, lease} = acquire(repo, branch, tmp_dir)

      secret_diff_line = "RAW_DIFF_CONTENT_MUST_NOT_APPEAR"
      File.write!(Path.join(lease.worktree_path, "committed.txt"), secret_diff_line <> "\n")
      git!(lease.worktree_path, ["add", "committed.txt"])
      git!(lease.worktree_path, ["commit", "-m", "Implement recovery state"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      File.write!(Path.join(lease.worktree_path, "README.md"), "dirty tracked\n")
      File.mkdir_p!(Path.join(lease.worktree_path, "notes"))
      File.write!(Path.join(lease.worktree_path, "notes/recovery.txt"), "untracked\n")

      params = %{
        workspace_id: lease.workspace_id,
        task: "Finish B3 recovery",
        pending_prompt: "Continue from the authoritative worktree state.",
        validation_feedback_json: ~s({"passed":false,"message":"rerun focused tests"}),
        review_feedback_json: ~s({"status":"changes_requested","note":"cover refs"})
      }

      assert {:ok, first} = Workspace.RecoverySummary.run(params, %{})
      assert {:ok, second} = Workspace.RecoverySummary.run(params, %{})
      assert first == second

      prompt = first.recovery_prompt
      assert prompt =~ "Prior conversation was lost"
      assert prompt =~ "worktree state as authoritative"
      assert prompt =~ "Steering history and the prior transcript are unavailable"
      assert prompt =~ "- Branch: #{branch}"
      assert prompt =~ "- Base: #{base}"
      assert prompt =~ "- HEAD: #{head}"
      assert prompt =~ "#{head} Implement recovery state"
      assert prompt =~ "1 file changed"
      assert prompt =~ " M README.md"
      assert prompt =~ "?? notes/recovery.txt"
      assert prompt =~ "Finish B3 recovery"
      assert prompt =~ "rerun focused tests"
      assert prompt =~ "changes_requested"

      refute prompt =~ secret_diff_line
      refute prompt =~ repo
      refute prompt =~ lease.worktree_path
      refute prompt =~ "GIT_"
      assert byte_size(prompt) <= 24_576

      release(lease.workspace_id)
    end

    test "security regression: opaque workspace id and task id alone do not authorize recovery",
         %{
           tmp_dir: tmp_dir
         } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()
      task_id = "task_recovery_#{System.unique_integer([:positive])}"
      principal_id = "agent_recovery_#{System.unique_integer([:positive])}"

      owner =
        spawn(fn ->
          {:ok, lease} =
            Workspace.Acquire.run(
              %{
                repo_path: repo,
                branch_name: "test/recovery-authority",
                worktree_base_dir: Path.join(tmp_dir, "worktrees")
              },
              %{task_id: task_id, agent_id: principal_id}
            )

          send(parent, {:leased, lease})

          receive do
            :release ->
              Workspace.Release.run(%{workspace_id: lease.workspace_id, mode: "remove"}, %{})
          after
            5_000 -> :ok
          end
        end)

      assert_receive {:leased, lease}, 2_000
      params = recovery_params(lease.workspace_id)

      assert {:error, :not_authorized} = Workspace.RecoverySummary.run(params, %{})

      assert {:error, :not_authorized} =
               Workspace.RecoverySummary.run(params, %{task_id: task_id})

      assert {:error, :not_authorized} =
               Workspace.RecoverySummary.run(params, %{
                 task_id: task_id,
                 agent_id: "agent_other"
               })

      assert {:ok, result} =
               Workspace.RecoverySummary.run(params, %{
                 task_id: task_id,
                 agent_id: principal_id
               })

      assert result.recovery_prompt =~ "Prior conversation was lost"
      send(owner, :release)
    end

    test "caps commits, status paths, and supplied prompt material", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      assert {:ok, lease} = acquire(repo, "test/recovery-bounds", tmp_dir)

      for index <- 1..22 do
        File.write!(Path.join(lease.worktree_path, "commit-#{index}.txt"), "#{index}\n")
        git!(lease.worktree_path, ["add", "commit-#{index}.txt"])
        git!(lease.worktree_path, ["commit", "-m", "bounded commit #{index}"])
      end

      for index <- 1..14 do
        File.write!(Path.join(lease.worktree_path, "untracked-#{index}.txt"), "#{index}\n")
      end

      long_name = String.duplicate("p", 180) <> ".txt"
      File.write!(Path.join(lease.worktree_path, long_name), "long path\n")

      params = %{
        workspace_id: lease.workspace_id,
        task: String.duplicate("task", 2_000),
        pending_prompt: String.duplicate("prompt", 2_000),
        validation_feedback_json: Jason.encode!(%{"message" => String.duplicate("v", 4_000)}),
        review_feedback_json: Jason.encode!(%{"message" => String.duplicate("r", 4_000)})
      }

      assert {:ok, result} = Workspace.RecoverySummary.run(params, %{})
      prompt = result.recovery_prompt

      assert length(Regex.scan(~r/^- [0-9a-f]{40} /m, prompt)) == 20
      assert prompt =~ "Untracked entries (showing at most 10 of 15, repository-relative)"
      assert length(Regex.scan(~r/^- \?\? /m, prompt)) == 10
      assert prompt =~ "[truncated]"
      assert byte_size(prompt) <= 24_576

      assert %{"truncated" => true, "preview" => validation_preview} =
               prompt
               |> tagged_value("validation_feedback_json")
               |> Jason.decode!()

      assert validation_preview =~ ~s({"message":"vvv)

      assert %{"truncated" => true, "preview" => review_preview} =
               prompt
               |> tagged_value("review_feedback_json")
               |> Jason.decode!()

      assert review_preview =~ ~s({"message":"rrr)

      release(lease.workspace_id)
    end

    test "rejects malformed feedback JSON", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      assert {:ok, lease} = acquire(repo, "test/recovery-json", tmp_dir)

      assert {:error, :invalid_validation_feedback_json} =
               Workspace.RecoverySummary.run(
                 Map.put(recovery_params(lease.workspace_id), :validation_feedback_json, "{"),
                 %{}
               )

      release(lease.workspace_id)
    end

    test "invalid-ref regression: detached HEAD fails closed", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      assert {:ok, lease} = acquire(repo, "test/recovery-detached", tmp_dir)
      git!(lease.worktree_path, ["checkout", "--detach"])

      assert {:error, :invalid_branch_state} =
               Workspace.RecoverySummary.run(recovery_params(lease.workspace_id), %{})

      release(lease.workspace_id)
    end

    test "invalid-ref regression: base outside HEAD ancestry fails closed", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      assert {:ok, lease} = acquire(repo, "test/recovery-unrelated", tmp_dir)

      tree = git!(lease.worktree_path, ["rev-parse", "HEAD^{tree}"])
      unrelated = git!(lease.worktree_path, ["commit-tree", tree, "-m", "unrelated root"])
      git!(lease.worktree_path, ["reset", "--hard", unrelated])

      assert {:error, :base_not_ancestor_of_head} =
               Workspace.RecoverySummary.run(recovery_params(lease.workspace_id), %{})

      release(lease.workspace_id)
    end
  end

  defp acquire(repo, branch, tmp_dir) do
    Workspace.Acquire.run(
      %{
        repo_path: repo,
        branch_name: branch,
        worktree_base_dir: Path.join(tmp_dir, "worktrees")
      },
      %{}
    )
  end

  defp release(workspace_id) do
    Workspace.Release.run(%{workspace_id: workspace_id, mode: "remove"}, %{})
  end

  defp recovery_params(workspace_id) do
    %{
      workspace_id: workspace_id,
      task: "Resume coding task",
      pending_prompt: "Continue implementation"
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp tagged_value(prompt, tag) do
    pattern = ~r/<#{tag}>\n(.*?)\n<\/#{tag}>/s
    [_, value] = Regex.run(pattern, prompt)
    value
  end
end
