defmodule Arbor.Actions.CodingGrokSandboxTest do
  use Arbor.Actions.ActionCase, async: false

  defmodule FakeAI do
    def bind_grok_worktree(repo_root, worktree_path) do
      notify({:grok_worktree_bound, repo_root, worktree_path})
      :persistent_term.get({__MODULE__, :bind_result}, {:ok, :opaque_grok_sandbox_authority})
    end

    defp notify(msg) do
      case :persistent_term.get({__MODULE__, :parent}, nil) do
        pid when is_pid(pid) -> send(pid, msg)
        _ -> :ok
      end
    end
  end

  alias Arbor.Actions.{Acp, Coding, Shell}

  @moduletag :fast

  defp with_fake_ai(parent, bind_result, fun) do
    previous_ai = Application.get_env(:arbor_actions, :ai_module)

    try do
      Application.put_env(:arbor_actions, :ai_module, FakeAI)
      :persistent_term.put({FakeAI, :parent}, parent)
      :persistent_term.put({FakeAI, :bind_result}, bind_result)

      fun.()
    after
      if is_nil(previous_ai) do
        Application.delete_env(:arbor_actions, :ai_module)
      else
        Application.put_env(:arbor_actions, :ai_module, previous_ai)
      end

      :persistent_term.erase({FakeAI, :parent})
      :persistent_term.erase({FakeAI, :bind_result})
    end
  end

  describe "ProduceReviewableChange.run/2 Grok worktree binding" do
    test "security regression: binds Grok worktrees before starting ACP and threads opaque authority through internal context only",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, context ->
          send(
            parent,
            {:start_session, params, Map.get(context, :acp_grok_sandbox_authority),
             Map.get(context, "acp_grok_sandbox_authority")}
          )

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

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      result =
        with_fake_ai(parent, {:ok, :opaque_grok_authority}, fn ->
          assert {:ok, value} =
                   Coding.ProduceReviewableChange.run(
                     %{
                       task: "Add feature file",
                       acp_agent: "grok",
                       repo_path: repo,
                       branch_name: "test/grok-worktree-bind",
                       worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                       validation_commands: ["true"],
                       submit_review: false
                     },
                     %{action_runner: runner}
                   )

          value
        end)

      assert result.status == "change_committed"

      assert_receive {:start_session, _start_params, atom_authority, string_authority}
      assert atom_authority == :opaque_grok_authority
      assert string_authority == nil

      assert_receive {:grok_worktree_bound, bound_repo_root, bound_worktree}
      assert {:ok, canonical_repo} = Arbor.Common.SafePath.resolve_real(repo)
      assert bound_repo_root == canonical_repo
      assert bound_worktree == result.worktree_path

      refute Map.has_key?(result, :acp_grok_sandbox_authority)
      refute Map.has_key?(result, "acp_grok_sandbox_authority")
    end

    test "security regression: fails closed when Grok worktree binding fails before ACP start", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, _params, _context ->
          send(parent, :unexpected_start_session)
          {:ok, %{session_pid: self(), session_id: "acp-session"}}

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      with_fake_ai(parent, {:error, :binding_blocked}, fn ->
        assert {:error, :binding_blocked} ==
                 Coding.ProduceReviewableChange.run(
                   %{
                     task: "Add feature file",
                     acp_agent: "grok",
                     repo_path: repo,
                     branch_name: "test/grok-worktree-bind-fails",
                     worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                     validation_commands: ["true"],
                     submit_review: false
                   },
                   %{action_runner: runner}
                 )
      end)

      refute_receive {:start_session, _}
      assert_receive {:grok_worktree_bound, bound_repo_root, _bound_worktree}
      assert {:ok, canonical_repo} = Arbor.Common.SafePath.resolve_real(repo)
      assert bound_repo_root == canonical_repo
    end

    test "non-Grok provider never binds worktree and does not receive grok authority context", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      parent = self()

      runner = fn
        Acp.StartSession, params, context ->
          send(
            parent,
            {:start_session, params, Map.get(context, :acp_grok_sandbox_authority),
             Map.get(context, "acp_grok_sandbox_authority")}
          )

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

        module, params, context ->
          module.run(params, Map.delete(context, :action_runner))
      end

      result =
        with_fake_ai(parent, {:ok, :grok_should_not_be_used}, fn ->
          assert {:ok, value} =
                   Coding.ProduceReviewableChange.run(
                     %{
                       task: "Add feature file",
                       acp_agent: "codex",
                       repo_path: repo,
                       branch_name: "test/codex-no-grok-worktree-bind",
                       worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                       validation_commands: ["true"],
                       submit_review: false
                     },
                     %{action_runner: runner}
                   )

          value
        end)

      assert result.status == "change_committed"

      assert_receive {:start_session, _start_params, atom_authority, string_authority}
      assert atom_authority == nil
      assert string_authority == nil

      refute_receive {:grok_worktree_bound, _, _}
    end
  end
end
