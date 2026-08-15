defmodule Arbor.Actions.Coding.DependencyBaselineAdmissionTest do
  use Arbor.Actions.ActionCase, async: false
  @moduletag :fast

  alias Arbor.Actions.Coding.DependencyBaselineAdmission
  alias Arbor.Actions.TestLinuxDependencyBaselineDigestSource, as: FakeDigestSource

  setup_all do
    previous = Application.get_env(:arbor_actions, :dependency_baseline_digest_module)
    Application.put_env(:arbor_actions, :dependency_baseline_digest_module, FakeDigestSource)

    on_exit(fn ->
      restore_env(:arbor_actions, :dependency_baseline_digest_module, previous)
    end)

    :ok
  end

  setup do
    Application.put_env(:arbor_actions, :dependency_baseline_digest_module, FakeDigestSource)
    FakeDigestSource.reset()
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "repo")
    create_git_repo(repo_path)
    {:ok, repo_path: repo_path}
  end

  defp mix_lock_digest(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  end

  defp commit_mix_lock(repo_path, contents) do
    File.write!(Path.join(repo_path, "mix.lock"), contents)
    {_, 0} = System.cmd("git", ["add", "mix.lock"], cd: repo_path)
    {_, 0} = System.cmd("git", ["commit", "-m", "add mix.lock"], cd: repo_path)
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
    String.trim(commit)
  end

  describe "run/2" do
    test "matching baseline digest admits", %{repo_path: repo_path} do
      contents = "%{\"a\" => \"1\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      FakeDigestSource.set_digest(mix_lock_digest(contents))

      assert {:ok, %{"matched" => true}} =
               DependencyBaselineAdmission.run(
                 %{repo_path: repo_path, base_commit: base_commit},
                 %{}
               )
    end

    test "mismatched baseline digest is rejected and never leaks either digest", %{
      repo_path: repo_path
    } do
      contents = "%{\"a\" => \"1\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      actual_digest = mix_lock_digest(contents)
      expected_digest = mix_lock_digest("%{\"different\" => \"2\"}\n")
      FakeDigestSource.set_digest(expected_digest)

      result =
        DependencyBaselineAdmission.run(
          %{repo_path: repo_path, base_commit: base_commit},
          %{}
        )

      assert {:error, {:dependency_baseline_admission_failed, :digest_mismatch}} = result
      refute inspect(result) =~ actual_digest
      refute inspect(result) =~ expected_digest
    end

    test "unavailable baseline is rejected, never treated as a pass", %{repo_path: repo_path} do
      contents = "%{\"a\" => \"1\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      FakeDigestSource.set_unavailable()

      assert {:error, {:dependency_baseline_admission_failed, :baseline_unavailable}} =
               DependencyBaselineAdmission.run(
                 %{repo_path: repo_path, base_commit: base_commit},
                 %{}
               )
    end

    test "misconfigured digest facade fails closed as baseline unavailable", %{
      repo_path: repo_path
    } do
      contents = "%{\"a\" => \"1\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)

      for invalid_module <- ["not-a-module", __MODULE__] do
        Application.put_env(
          :arbor_actions,
          :dependency_baseline_digest_module,
          invalid_module
        )

        assert {:error, {:dependency_baseline_admission_failed, :baseline_unavailable}} =
                 DependencyBaselineAdmission.run(
                   %{repo_path: repo_path, base_commit: base_commit},
                   %{}
                 )
      end
    end

    test "malformed digest evidence fails closed as baseline unavailable", %{repo_path: repo_path} do
      contents = "%{\"a\" => \"1\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      FakeDigestSource.set_digest("not-a-hex64-digest")

      assert {:error, {:dependency_baseline_admission_failed, :baseline_unavailable}} =
               DependencyBaselineAdmission.run(
                 %{repo_path: repo_path, base_commit: base_commit},
                 %{}
               )
    end

    test "mix.lock unreadable at the base commit is rejected with a bounded reason", %{
      repo_path: repo_path
    } do
      {initial_commit, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      initial_commit = String.trim(initial_commit)

      assert {:error,
              {:dependency_baseline_admission_failed, :mix_lock_unreadable_at_base_commit}} =
               DependencyBaselineAdmission.run(
                 %{repo_path: repo_path, base_commit: initial_commit},
                 %{}
               )
    end

    @tag :security_regression
    test "security regression: dirty live-file substitution against a stale base commit cannot make admission pass",
         %{repo_path: repo_path} do
      stale_contents = "%{\"stale\" => \"lock\"}\n"
      base_commit = commit_mix_lock(repo_path, stale_contents)

      baseline_contents = "%{\"baseline\" => \"pinned\"}\n"
      FakeDigestSource.set_digest(mix_lock_digest(baseline_contents))

      # Dirty replacement on disk, never committed — a TOCTOU-style substitution
      # that makes the live worktree file match the pinned baseline exactly.
      File.write!(Path.join(repo_path, "mix.lock"), baseline_contents)

      assert {:error, {:dependency_baseline_admission_failed, :digest_mismatch}} =
               DependencyBaselineAdmission.run(
                 %{repo_path: repo_path, base_commit: base_commit},
                 %{}
               )
    end

    test "regression: canonical repository storage admits the base used by a linked workspace",
         %{repo_path: repo_path, tmp_dir: tmp_dir} do
      contents = "%{\"linked\" => \"workspace\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      linked_worktree = Path.join(tmp_dir, "linked-worktree")
      FakeDigestSource.set_digest(mix_lock_digest(contents))

      {output, status} =
        System.cmd("git", ["worktree", "add", "--detach", linked_worktree, base_commit],
          cd: repo_path,
          stderr_to_stdout: true
        )

      assert status == 0, output

      assert {:ok, %{"matched" => true}} =
               DependencyBaselineAdmission.run(
                 %{repo_path: repo_path, base_commit: base_commit},
                 %{}
               )
    end
  end

  describe "Arbor.Actions.coding_dependency_baseline_admission/2" do
    test "matching exact commit admits without acquiring a workspace or emitting signals",
         %{repo_path: repo_path} do
      contents = "%{\"facade\" => \"match\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      FakeDigestSource.set_digest(mix_lock_digest(contents))

      parent = self()

      {:ok, started_id} =
        Arbor.Signals.subscribe("action.started", fn signal ->
          send(parent, {:action_signal, :started, signal})
          :ok
        end)

      {:ok, completed_id} =
        Arbor.Signals.subscribe("action.completed", fn signal ->
          send(parent, {:action_signal, :completed, signal})
          :ok
        end)

      {:ok, failed_id} =
        Arbor.Signals.subscribe("action.failed", fn signal ->
          send(parent, {:action_signal, :failed, signal})
          :ok
        end)

      on_exit(fn ->
        Arbor.Signals.unsubscribe(started_id)
        Arbor.Signals.unsubscribe(completed_id)
        Arbor.Signals.unsubscribe(failed_id)
      end)

      before_files = File.ls!(repo_path)
      {before_worktrees, 0} = System.cmd("git", ["worktree", "list"], cd: repo_path)

      assert {:ok, resolved} =
               Arbor.Actions.Coding.Workspace.resolve_base_ref(repo_path, base_commit)

      assert resolved == base_commit

      assert {:ok, %{"matched" => true}} =
               Arbor.Actions.coding_dependency_baseline_admission(repo_path, base_commit)

      assert File.ls!(repo_path) == before_files
      {after_worktrees, 0} = System.cmd("git", ["worktree", "list"], cd: repo_path)
      assert after_worktrees == before_worktrees
      refute_received {:action_signal, _, _}
    end

    test "symbolic base_ref uses the same workspace resolver as acquisition", %{
      repo_path: repo_path
    } do
      contents = "%{\"branch\" => \"lock\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      FakeDigestSource.set_digest(mix_lock_digest(contents))
      {_, 0} = System.cmd("git", ["branch", "feature-base", base_commit], cd: repo_path)

      assert {:ok, ^base_commit} =
               Arbor.Actions.Coding.Workspace.resolve_base_ref(repo_path, "feature-base")

      assert {:ok, %{"matched" => true}} =
               Arbor.Actions.coding_dependency_baseline_admission(repo_path, "feature-base")
    end

    test "mismatched mix.lock is rejected without leaking digests or git output", %{
      repo_path: repo_path
    } do
      contents = "%{\"a\" => \"1\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)
      actual_digest = mix_lock_digest(contents)
      expected_digest = mix_lock_digest("%{\"different\" => \"2\"}\n")
      FakeDigestSource.set_digest(expected_digest)

      result = Arbor.Actions.coding_dependency_baseline_admission(repo_path, base_commit)

      assert {:error, :digest_mismatch} = result
      refute inspect(result) =~ actual_digest
      refute inspect(result) =~ expected_digest
      refute inspect(result) =~ repo_path
    end

    test "unavailable baseline, unreadable mix.lock, and unresolvable refs fail closed", %{
      repo_path: repo_path
    } do
      contents = "%{\"a\" => \"1\"}\n"
      base_commit = commit_mix_lock(repo_path, contents)

      FakeDigestSource.set_unavailable()

      assert {:error, :baseline_unavailable} =
               Arbor.Actions.coding_dependency_baseline_admission(repo_path, base_commit)

      {initial_commit, 0} =
        System.cmd("git", ["rev-list", "--max-parents=0", "HEAD"], cd: repo_path)

      initial_commit = String.trim(initial_commit)

      FakeDigestSource.set_digest(mix_lock_digest(contents))

      assert {:error, :mix_lock_unreadable_at_base_commit} =
               Arbor.Actions.coding_dependency_baseline_admission(repo_path, initial_commit)

      result = Arbor.Actions.coding_dependency_baseline_admission(repo_path, "missing-ref")
      assert {:error, :base_ref_unresolvable} = result
      refute inspect(result) =~ "fatal"
      refute inspect(result) =~ repo_path

      assert {:error, :base_ref_unresolvable} =
               Arbor.Actions.coding_dependency_baseline_admission(:not_a_path, "HEAD")
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
