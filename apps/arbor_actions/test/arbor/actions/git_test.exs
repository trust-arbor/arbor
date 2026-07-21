defmodule Arbor.Actions.GitTest do
  use Arbor.Actions.ActionCase, async: false
  @moduletag :fast

  alias Arbor.Actions.Egress
  alias Arbor.Actions.Git

  # Start shell system for tests
  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil ->
        {:ok, _} = Application.ensure_all_started(:arbor_shell)

      _pid ->
        :ok
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    repo_path = Path.join(tmp_dir, "repo")
    create_git_repo(repo_path)
    {:ok, repo_path: repo_path}
  end

  describe "closed worktree removal" do
    @tag :security_regression
    test "removes a registered linked worktree with its bound lstat identity", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      worktree_path = Path.join(tmp_dir, "identity-bound-worktree")
      create_linked_worktree(repo_path, worktree_path, "test/identity-bound-remove")
      identity = worktree_removal_identity(repo_path, worktree_path)

      assert :ok = Git.remove_worktree(repo_path, worktree_path, identity)
      refute File.dir?(worktree_path)
    end

    @tag :security_regression
    test "security regression: rejects a replacement inode at the registered path", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      worktree_path = Path.join(tmp_dir, "identity-replaced-worktree")
      replacement_path = Path.join(tmp_dir, "replacement-copy")
      marker_path = Path.join(worktree_path, "replacement-marker.txt")
      create_linked_worktree(repo_path, worktree_path, "test/identity-replaced-remove")

      original_identity = worktree_removal_identity(repo_path, worktree_path)
      git_pointer = File.read!(Path.join(worktree_path, ".git"))
      File.cp_r!(worktree_path, replacement_path)
      File.write!(Path.join(replacement_path, "replacement-marker.txt"), "replacement survives\n")
      File.rm_rf!(worktree_path)
      File.rename!(replacement_path, worktree_path)

      replacement_identity = worktree_lstat_identity(worktree_path)
      refute replacement_identity == original_identity.lstat_identity
      assert File.read!(Path.join(worktree_path, ".git")) == git_pointer

      assert {:error, :git_worktree_identity_mismatch} =
               Git.remove_worktree(repo_path, worktree_path, original_identity)

      assert worktree_lstat_identity(worktree_path) == replacement_identity
      assert File.read!(marker_path) == "replacement survives\n"
    end

    test "rejects malformed bound lstat identities without removing the worktree", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      worktree_path = Path.join(tmp_dir, "malformed-identity-worktree")
      create_linked_worktree(repo_path, worktree_path, "test/malformed-identity-remove")
      identity = worktree_removal_identity(repo_path, worktree_path)

      malformed_identities = [
        Map.update!(identity, :lstat_identity, &Map.delete(&1, :inode)),
        Map.put(identity, :unexpected, true),
        Map.update!(identity, :lstat_identity, &%{&1 | type: "directory"}),
        Map.new(identity, fn {key, value} -> {Atom.to_string(key), value} end)
      ]

      for malformed_identity <- malformed_identities do
        assert {:error, :invalid_git_worktree_identity} =
                 Git.remove_worktree(repo_path, worktree_path, malformed_identity)

        assert File.dir?(worktree_path)
      end
    end

    @tag :security_regression
    test "rejects primary and unrelated repositories without removing either", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      unrelated_path = Path.join(tmp_dir, "unrelated-repo")
      create_git_repo(unrelated_path)
      primary_identity = worktree_removal_identity(repo_path, repo_path)
      unrelated_identity = worktree_removal_identity(unrelated_path, unrelated_path)

      assert {:error, :primary_checkout_not_removable} =
               Git.remove_worktree(repo_path, repo_path, primary_identity)

      assert {:error, :unrelated_git_worktree} =
               Git.remove_worktree(repo_path, unrelated_path, unrelated_identity)

      assert File.read!(Path.join(repo_path, "README.md")) == "# Test Repository\n"
      assert File.read!(Path.join(unrelated_path, "README.md")) == "# Test Repository\n"
    end

    @tag :security_regression
    test "security regression: final removal rejects a branch changed to detached", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      worktree_path = Path.join(tmp_dir, "branch-bound-worktree")
      create_linked_worktree(repo_path, worktree_path, "test/branch-bound-remove")
      identity = worktree_removal_identity(repo_path, worktree_path)

      {_, 0} = System.cmd("git", ["checkout", "--detach", "HEAD"], cd: worktree_path)

      assert {:error, :git_worktree_registration_mismatch} =
               Git.remove_worktree(repo_path, worktree_path, identity)

      assert File.dir?(worktree_path)
      assert {:ok, %{detached: true}} = Git.worktree_registration(repo_path, worktree_path)
    end

    @tag :security_regression
    test "newline paths do not corrupt branch worktree lookup", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      branch = "test/newline-worktree-lookup"
      worktree_path = Path.join(tmp_dir, "linked\nworktree")
      create_linked_worktree(repo_path, worktree_path, branch)

      assert {:ok, registration} = Git.worktree_registration(repo_path, worktree_path)
      assert registration.branch == branch
      assert {:ok, registration.path} == Git.worktree_for_branch(repo_path, branch)
    end

    @tag :security_regression
    test "generic execute still rejects worktree remove force", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      target = Path.join(tmp_dir, "must-not-dispatch")

      assert {:error, {:dangerous_flags, flags}} =
               Git.execute(repo_path, ["worktree", "remove", "--force", target])

      assert "--force" in flags
      refute File.exists?(target)
    end
  end

  describe "delete_branch_ref" do
    @tag :security_regression
    test "security regression: retires a free branch at the expected OID only", %{
      repo_path: repo_path
    } do
      branch = "test/delete-ref-ok"
      head = git_rev_parse(repo_path, "HEAD")
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)

      assert :ok = Git.delete_branch_ref(repo_path, branch, head)
      assert :ok = Git.delete_branch_ref(repo_path, branch, head)
      refute branch_exists?(repo_path, branch)
    end

    @tag :security_regression
    test "security regression: expected-OID replacement race fails closed", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      branch = "test/delete-ref-oid-race"
      head = git_rev_parse(repo_path, "HEAD")
      worktree_path = Path.join(tmp_dir, "oid-race-wt")
      create_linked_worktree(repo_path, worktree_path, branch)

      File.write!(Path.join(worktree_path, "moved.txt"), "moved\n")
      {_, 0} = System.cmd("git", ["add", "moved.txt"], cd: worktree_path)
      {_, 0} = System.cmd("git", ["commit", "-m", "advance tip"], cd: worktree_path)
      new_tip = git_rev_parse(worktree_path, "HEAD")
      refute new_tip == head

      # Unregister the worktree checkout so the ref is free, then attempt
      # deletion with the stale expected OID.
      identity = worktree_removal_identity(repo_path, worktree_path)
      assert :ok = Git.remove_worktree(repo_path, worktree_path, identity)

      assert {:error, :branch_ref_oid_mismatch} =
               Git.delete_branch_ref(repo_path, branch, head)

      assert branch_exists?(repo_path, branch)
      assert git_rev_parse(repo_path, branch) == new_tip
    end

    @tag :security_regression
    test "security regression: checked-out branch is rejected", %{
      repo_path: repo_path,
      tmp_dir: tmp_dir
    } do
      branch = "test/delete-ref-checked-out"
      head = git_rev_parse(repo_path, "HEAD")
      worktree_path = Path.join(tmp_dir, "checked-out-wt")
      create_linked_worktree(repo_path, worktree_path, branch)

      assert {:error, :branch_checked_out} =
               Git.delete_branch_ref(repo_path, branch, head)

      assert branch_exists?(repo_path, branch)
      assert File.dir?(worktree_path)
    end

    @tag :security_regression
    test "security regression: exit-0 dirty update-ref output is rejected, not reclassified as success",
         %{repo_path: repo_path} do
      branch = "test/delete-ref-dirty-success"
      head = git_rev_parse(repo_path, "HEAD")
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)

      # One-shot process flag that APPENDS synthetic stderr to the real
      # update-ref exit-0 result.  This can only force fail-closed — never
      # force false success or alter a real failure.  Production builds do
      # not compile this seam.
      Process.put(
        {Git, {:update_ref_delete, :dirty_output}},
        {"", "warning: suspicious output\n"}
      )

      assert {:error, :git_update_ref_dirty_success} =
               Git.delete_branch_ref(repo_path, branch, head)

      # The exact eligible delete may already have happened before Git emitted
      # the unexpected output. The critical contract is that it is not reported
      # as a clean success; durable settlement can reconcile the exact ref.
      refute branch_exists?(repo_path, branch)
    end

    @tag :security_regression
    test "security regression: exit-0 dirty restore output is rejected on checkout-race CAS-restore",
         %{repo_path: repo_path, tmp_dir: tmp_dir} do
      branch = "test/delete-ref-restore-dirty"
      head = git_rev_parse(repo_path, "HEAD")
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)
      race_worktree = Path.join(tmp_dir, "restore-dirty-worktree")

      # Trigger the checkout race: a worktree checkout lands inside the
      # precheck -> CAS-delete window so the CAS-restore path runs.
      Process.put(
        {Git, :pre_delete_branch_ref_hook},
        fn _repo, br ->
          {_, 0} = System.cmd("git", ["worktree", "add", race_worktree, br], cd: repo_path)
        end
      )

      # Append synthetic stderr to the real CAS-restore exit-0 result.
      Process.put({Git, {:update_ref_restore, :dirty_output}}, {"", "warning: dirty restore\n"})

      assert {:error, :git_update_ref_restore_dirty_success} =
               Git.delete_branch_ref(repo_path, branch, head)

      # Branch is preserved — the dirty restore output surfaced explicit
      # residue rather than silently accepting the restore.
      assert {:ok, {:present, ^head}} = Git.observe_branch_ref(repo_path, branch)

      _ = System.cmd("git", ["worktree", "remove", "--force", race_worktree], cd: repo_path)
      _ = System.cmd("git", ["branch", "-D", branch], cd: repo_path)
    end
  end

  describe "observe_branch_ref" do
    @tag :security_regression
    test "returns the present OID for a live branch", %{repo_path: repo_path} do
      branch = "test/observe-present"
      head = git_rev_parse(repo_path, "HEAD")
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)

      assert {:ok, {:present, ^head}} = Git.observe_branch_ref(repo_path, branch)
    end

    @tag :security_regression
    test "returns exact absence for a missing branch", %{repo_path: repo_path} do
      assert {:ok, :absent} = Git.observe_branch_ref(repo_path, "test/observe-missing")
    end

    @tag :security_regression
    test "security regression: corrupt ref is NOT absence (fail closed)", %{
      repo_path: repo_path
    } do
      # A broken loose ref shares rev-parse's exit code with a genuinely absent
      # ref; the only distinguishing signal is the broken-ref warning on
      # stderr. Observation must surface an error rather than report absence,
      # so settlement never treats a corrupt ref as already-retired.
      corrupt_ref = Path.join([repo_path, ".git", "refs", "heads", "test", "observe-corrupt"])
      File.mkdir_p!(Path.dirname(corrupt_ref))
      File.write!(corrupt_ref, "NOT-A-VALID-OID\n")

      assert {:error, _reason} = Git.observe_branch_ref(repo_path, "test/observe-corrupt")
      refute match?({:ok, :absent}, Git.observe_branch_ref(repo_path, "test/observe-corrupt"))
    end

    @tag :security_regression
    test "security regression: delete_branch_ref on a corrupt ref fails closed", %{
      repo_path: repo_path
    } do
      head = git_rev_parse(repo_path, "HEAD")
      corrupt_ref = Path.join([repo_path, ".git", "refs", "heads", "test", "delete-corrupt"])
      File.mkdir_p!(Path.dirname(corrupt_ref))
      File.write!(corrupt_ref, "NOT-A-VALID-OID\n")

      # Must NOT return :ok (which would mean "idempotent absence") for a ref
      # whose state git itself flagged as broken.
      assert {:error, _reason} =
               Git.delete_branch_ref(repo_path, "test/delete-corrupt", head)
    end

    @tag :security_regression
    test "security regression: similarly prefixed but non-exact ref is absent (not ambiguous)", %{
      repo_path: repo_path
    } do
      # When a branch "test/prefix-observe" exists, observing "test/prefix-observe-x"
      # must NOT match it. With strict for-each-ref exact matching, the non-existent
      # ref returns :absent — no ambiguity with the existing branch.
      branch = "test/prefix-observe"
      head = git_rev_parse(repo_path, "HEAD")
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)

      # The actual branch must be observable
      assert {:ok, {:present, ^head}} = Git.observe_branch_ref(repo_path, branch)

      # Non-existent refs that share a prefix return :absent (for-each-ref exact match)
      assert {:ok, :absent} = Git.observe_branch_ref(repo_path, "test/prefix-observe-x")
      assert {:ok, :absent} = Git.observe_branch_ref(repo_path, "test/prefix")
    end

    @tag :security_regression
    test "security regression: OID is returned lowercase regardless of git casing", %{
      repo_path: repo_path
    } do
      branch = "test/observe-case"
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)

      assert {:ok, {:present, oid}} = Git.observe_branch_ref(repo_path, branch)
      assert oid == String.downcase(oid)
      assert String.match?(oid, ~r/\A[0-9a-f]{40}\z/)
    end

    @tag :security_regression
    test "security regression: invalid arguments return typed error", %{repo_path: repo_path} do
      assert {:error, _} = Git.observe_branch_ref(repo_path, "")
      assert {:error, _} = Git.observe_branch_ref(repo_path, "HEAD")
      assert {:error, _} = Git.observe_branch_ref(nil, "branch")
    end

    @tag :security_regression
    test "security regression: checkout race between precheck and CAS delete restores the ref",
         %{repo_path: repo_path, tmp_dir: tmp_dir} do
      # The race window this boundary must close: a concurrent worktree checkout
      # lands AFTER `reject_checked_out_branch` passes but BEFORE `update-ref -d`
      # retires the ref. The precheck cannot see it, the CAS delete succeeds, and
      # the post-delete probe must detect the orphaned checkout and CAS-restore
      # the exact expected ref so it is not silently lost.
      branch = "test/delete-checkout-race"
      head = git_rev_parse(repo_path, "HEAD")
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)
      race_worktree = Path.join(tmp_dir, "race-worktree")

      # Deterministic injection: check out the branch inside the race window.
      Process.put(
        {Git, :pre_delete_branch_ref_hook},
        fn _repo, br ->
          {_, 0} = System.cmd("git", ["worktree", "add", race_worktree, br], cd: repo_path)
        end
      )

      assert {:error, :branch_checked_out_race} =
               Git.delete_branch_ref(repo_path, branch, head)

      # The exact expected ref is restored — never silently lost to the race.
      assert {:ok, {:present, ^head}} = Git.observe_branch_ref(repo_path, branch)
      assert git_rev_parse(repo_path, branch) == head

      # The racing checkout is still registered; cleanup the worktree and ref.
      assert File.dir?(race_worktree)
      _ = System.cmd("git", ["worktree", "remove", "--force", race_worktree], cd: repo_path)
      _ = System.cmd("git", ["branch", "-D", branch], cd: repo_path)
    end

    @tag :security_regression
    test "security regression: restored ref with no surviving checkout reports checkout-lost, not successful race confirmation",
         %{repo_path: repo_path, tmp_dir: tmp_dir} do
      # Race-within-a-race: a worktree checkout lands inside the precheck->CAS
      # delete window (triggering the CAS-restore path), then vanishes (e.g. a
      # concurrent `worktree remove`) BEFORE confirm_race_restore re-probes the
      # inventory. The ref is restored to the exact expected OID, but no
      # worktree holds it. This MUST surface as :branch_ref_restore_checkout_lost
      # (honest residue), NOT :ok (which would masquerade as a successfully
      # confirmed race -> :branch_checked_out_race). Before the clause-order
      # fix, {:ok, _path} shadowed {:ok, nil} and nil was silently treated as a
      # surviving checkout, making the explicit checkout-lost branch dead.
      branch = "test/restore-checkout-lost"
      head = git_rev_parse(repo_path, "HEAD")
      {_, 0} = System.cmd("git", ["branch", branch], cd: repo_path)
      race_worktree = Path.join(tmp_dir, "restore-lost-worktree")

      # Hook 1 (precheck -> CAS delete window): check out the branch so the
      # post-delete probe sees ref-absent + worktree-present and enters the
      # CAS-restore path.
      Process.put(
        {Git, :pre_delete_branch_ref_hook},
        fn _repo, br ->
          {_, 0} = System.cmd("git", ["worktree", "add", race_worktree, br], cd: repo_path)
        end
      )

      # Hook 2 (CAS-restore -> confirm window): the racing checkout vanishes
      # before confirm_race_restore re-probes the inventory. The ref was already
      # restored to the exact OID, so confirm sees present-at-expected + nil
      # worktree -> :branch_ref_restore_checkout_lost.
      Process.put(
        {Git, :pre_confirm_restore_hook},
        fn _repo, _br ->
          {_, 0} =
            System.cmd("git", ["worktree", "remove", "--force", race_worktree], cd: repo_path)
        end
      )

      assert {:error, :branch_ref_restore_checkout_lost} =
               Git.delete_branch_ref(repo_path, branch, head)

      # The exact expected ref is still present — restored, never silently lost
      # when the checkout vanished. This is the honest-residue guarantee.
      assert {:ok, {:present, ^head}} = Git.observe_branch_ref(repo_path, branch)
      assert git_rev_parse(repo_path, branch) == head

      # The racing checkout was removed by the confirm-window hook.
      refute File.dir?(race_worktree)
      _ = System.cmd("git", ["branch", "-D", branch], cd: repo_path)
    end

    @tag :security_regression
    test "security regression: delete_branch_ref on a non-existent branch is idempotent",
         %{repo_path: repo_path} do
      head = git_rev_parse(repo_path, "HEAD")
      assert :ok = Git.delete_branch_ref(repo_path, "test/delete-idempotent", head)
    end

    @tag :security_regression
    test "security regression: SHA-256 repositories use 64-hex OIDs for observe, delete, and race-restore",
         %{tmp_dir: tmp_dir} do
      sha256_repo = Path.join(tmp_dir, "sha256-repo")

      # Skip gracefully on Git builds without SHA-256 object format support;
      # run the full regression where the local Git supports it.
      if create_sha256_git_repo(sha256_repo) == :ok do
        branch = "test/sha256-observe"
        head = git_rev_parse(sha256_repo, "HEAD")
        assert String.length(head) == 64
        {_, 0} = System.cmd("git", ["branch", branch], cd: sha256_repo)

        assert {:ok, {:present, ^head}} = Git.observe_branch_ref(sha256_repo, branch)
        assert String.length(head) == 64

        # Delete at the expected SHA-256 OID succeeds.
        assert :ok = Git.delete_branch_ref(sha256_repo, branch, head)
        assert {:ok, :absent} = Git.observe_branch_ref(sha256_repo, branch)

        # Race-restore must derive a 64-char zero old-OID (not hardcoded 40).
        {_, 0} = System.cmd("git", ["branch", branch], cd: sha256_repo)

        race_worktree = Path.join(tmp_dir, "sha256-race-wt")

        Process.put(
          {Git, :pre_delete_branch_ref_hook},
          fn _repo, br ->
            {_, 0} = System.cmd("git", ["worktree", "add", race_worktree, br], cd: sha256_repo)
          end
        )

        assert {:error, :branch_checked_out_race} =
                 Git.delete_branch_ref(sha256_repo, branch, head)

        # Ref restored to the exact SHA-256 OID — never silently lost.
        assert {:ok, {:present, ^head}} = Git.observe_branch_ref(sha256_repo, branch)
        assert git_rev_parse(sha256_repo, branch) == head

        _ = System.cmd("git", ["worktree", "remove", "--force", race_worktree], cd: sha256_repo)
        _ = System.cmd("git", ["branch", "-D", branch], cd: sha256_repo)
      end
    end
  end

  defp worktree_removal_identity(repo_path, worktree_path) do
    {:ok, registration} = Git.worktree_registration(repo_path, worktree_path)

    %{
      lstat_identity: worktree_lstat_identity(worktree_path),
      worktree_registration: registration
    }
  end

  describe "Status" do
    test "returns clean status for clean repo", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.path == repo_path
      assert result.is_clean == true
      assert result.staged == []
      assert result.modified == []
      assert result.untracked == []
    end

    test "detects untracked files", %{repo_path: repo_path} do
      create_file(repo_path, "new_file.txt", "content")

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.is_clean == false
      assert "new_file.txt" in result.untracked
    end

    test "detects modified files", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Modified content")

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.is_clean == false
      assert "README.md" in result.modified
    end

    test "detects staged files", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Modified content")
      System.cmd("git", ["add", "README.md"], cd: repo_path)

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      assert result.is_clean == false
      assert "README.md" in result.staged
    end

    test "reports current branch", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})

      # Branch is either "master" or "main" depending on git config
      assert result.branch in ["master", "main"]
    end

    test "returns error for non-git directory" do
      assert {:error, message} = Git.Status.run(%{path: "/tmp"}, %{})
      assert message =~ "Failed to get git status" or message =~ "not a git repository"
    end

    test "validates action metadata" do
      assert Git.Status.name() == "git_status"
      assert Git.Status.category() == "git"
      assert "status" in Git.Status.tags()
    end

    test "detects deleted unstaged file", %{repo_path: repo_path} do
      File.rm!(Path.join(repo_path, "README.md"))

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})
      assert result.is_clean == false
      assert "README.md" in result.modified
    end

    test "detects staged deletion", %{repo_path: repo_path} do
      System.cmd("git", ["rm", "README.md"], cd: repo_path)

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})
      assert result.is_clean == false
      assert "README.md" in result.staged
    end

    test "detects renamed file", %{repo_path: repo_path} do
      # Create a new file and commit to get enough history
      create_file(repo_path, "original.txt", "some content")
      System.cmd("git", ["add", "original.txt"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "add original"], cd: repo_path)

      # Rename via git
      System.cmd("git", ["mv", "original.txt", "renamed.txt"], cd: repo_path)

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})
      assert result.is_clean == false
    end

    test "detects file that is both staged and modified", %{repo_path: repo_path} do
      # Create, stage, then modify again
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Staged content")
      System.cmd("git", ["add", "README.md"], cd: repo_path)
      File.write!(readme_path, "Modified after staging")

      assert {:ok, result} = Git.Status.run(%{path: repo_path}, %{})
      assert result.is_clean == false
      # File should appear in both staged and modified
      assert "README.md" in result.staged or "README.md" in result.modified
    end

    test "generates tool schema" do
      tool = Git.Status.to_tool()
      assert is_map(tool)
      assert tool[:name] == "git_status"
    end
  end

  describe "Diff" do
    test "shows empty diff for clean repo", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Diff.run(%{path: repo_path}, %{})

      assert result.path == repo_path
      assert result.diff == ""
    end

    test "shows diff for modified file", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Modified content\n")

      assert {:ok, result} = Git.Diff.run(%{path: repo_path}, %{})

      assert result.diff =~ "Modified content"
      assert result.diff =~ "diff --git"
    end

    test "shows staged diff", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Staged content\n")
      System.cmd("git", ["add", "README.md"], cd: repo_path)

      assert {:ok, result} = Git.Diff.run(%{path: repo_path, staged: true}, %{})

      assert result.diff =~ "Staged content"
    end

    test "shows stat only", %{repo_path: repo_path} do
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "New line 1\nNew line 2\n")

      assert {:ok, result} = Git.Diff.run(%{path: repo_path, stat_only: true}, %{})

      assert Map.has_key?(result, :files_changed)
      assert Map.has_key?(result, :insertions)
      assert Map.has_key?(result, :deletions)
    end

    test "diffs specific file", %{repo_path: repo_path} do
      # Create and modify two files
      readme_path = Path.join(repo_path, "README.md")
      other_path = Path.join(repo_path, "other.txt")
      File.write!(readme_path, "README modified\n")
      File.write!(other_path, "other content\n")

      # Diff only README
      assert {:ok, result} = Git.Diff.run(%{path: repo_path, file: "README.md"}, %{})

      assert result.diff =~ "README modified"
      refute result.diff =~ "other content"
    end

    test "diff with ref parameter", %{repo_path: repo_path} do
      # Get current HEAD hash
      {hash, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      hash = String.trim(hash)

      # Make a change
      readme_path = Path.join(repo_path, "README.md")
      File.write!(readme_path, "Changed content\n")
      System.cmd("git", ["add", "README.md"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "Change README"], cd: repo_path)

      # Diff against the previous commit
      assert {:ok, result} = Git.Diff.run(%{path: repo_path, ref: hash}, %{})
      assert result.diff =~ "Changed content"
    end

    test "stat_only with insertions only", %{repo_path: repo_path} do
      # Create a new file (only insertions, no deletions)
      create_file(repo_path, "newfile.txt", "line1\nline2\nline3\n")
      System.cmd("git", ["add", "newfile.txt"], cd: repo_path)

      assert {:ok, result} =
               Git.Diff.run(%{path: repo_path, stat_only: true, staged: true}, %{})

      assert result.files_changed >= 1
      assert result.insertions >= 1
    end

    test "returns error for non-git directory" do
      non_git = Path.join(System.tmp_dir!(), "non_git_diff_#{System.unique_integer([:positive])}")
      File.mkdir_p!(non_git)
      on_exit(fn -> File.rm_rf!(non_git) end)

      assert {:error, message} = Git.Diff.run(%{path: non_git}, %{})
      assert message =~ "Failed to get git diff"
    end

    test "security regression: ref options and configured external diff cannot execute helpers",
         %{
           repo_path: repo_path
         } do
      helper = Path.join(repo_path, "external-diff-helper")
      marker = Path.join(repo_path, "external-diff-marker")
      File.write!(helper, "#!/bin/sh\ntouch #{marker}\n")
      File.chmod!(helper, 0o755)
      {_output, 0} = System.cmd("git", ["-C", repo_path, "config", "diff.external", helper])

      assert {:error, injected_reason} =
               Git.Diff.run(%{path: repo_path, ref: "--ext-diff"}, %{})

      assert injected_reason =~ "invalid_git_ref"

      assert {:error, configured_reason} =
               Git.Diff.run(%{path: repo_path, ref: "HEAD"}, %{})

      assert configured_reason =~ "unsafe_git_configuration"
      Process.sleep(200)
      refute File.exists?(marker)
    end

    @tag :security_regression
    test "security regression: exact core.hooksPath=/dev/null is allowed; other helpers fail",
         %{repo_path: repo_path} do
      {_out, 0} =
        System.cmd("git", ["-C", repo_path, "config", "--local", "core.hooksPath", "/dev/null"])

      assert {:ok, _result} = Git.Status.run(%{path: repo_path}, %{})
      assert {:ok, _result} = Git.Diff.run(%{path: repo_path, ref: "HEAD"}, %{})

      {_out, 0} =
        System.cmd("git", ["-C", repo_path, "config", "--local", "core.hooksPath", "/tmp/hooks"])

      assert {:error, hooks_reason} = Git.Status.run(%{path: repo_path}, %{})
      assert hooks_reason =~ "unsafe_git_configuration"
      assert hooks_reason =~ "core.hookspath"

      {_out, 0} =
        System.cmd("git", ["-C", repo_path, "config", "--local", "core.hooksPath", "/dev/null"])

      helper = Path.join(repo_path, "credential-helper")
      File.write!(helper, "#!/bin/sh\nexit 0\n")
      File.chmod!(helper, 0o755)

      {_out, 0} =
        System.cmd("git", ["-C", repo_path, "config", "--local", "credential.helper", helper])

      assert {:error, credential_reason} = Git.Status.run(%{path: repo_path}, %{})
      assert credential_reason =~ "unsafe_git_configuration"
    end

    @tag :security_regression
    test "security regression: duplicate core.hooksPath entries fail closed even for /dev/null",
         %{repo_path: repo_path} do
      {_out, 0} =
        System.cmd("git", ["-C", repo_path, "config", "--local", "core.hooksPath", "/dev/null"])

      {_out, 0} =
        System.cmd("git", [
          "-C",
          repo_path,
          "config",
          "--local",
          "--add",
          "core.hooksPath",
          "/dev/null"
        ])

      assert {:error, reason} = Git.Status.run(%{path: repo_path}, %{})
      assert reason =~ "unsafe_git_configuration"
    end

    @tag :security_regression
    test "security regression: core.hooksPath allowlist compares exact value bytes", %{
      repo_path: repo_path
    } do
      {_out, 0} =
        System.cmd("git", ["-C", repo_path, "config", "--local", "core.hooksPath", "/dev/null\r"])

      assert {:error, reason} = Git.Status.run(%{path: repo_path}, %{})
      assert reason =~ "unsafe_git_configuration"
      assert reason =~ "core.hookspath"
    end

    test "validates action metadata" do
      assert Git.Diff.name() == "git_diff"
      assert "diff" in Git.Diff.tags()
    end
  end

  describe "Commit" do
    test "creates commit with staged files", %{repo_path: repo_path} do
      # Create and stage a new file
      create_file(repo_path, "new_file.txt", "content")
      System.cmd("git", ["add", "new_file.txt"], cd: repo_path)

      assert {:ok, result} = Git.Commit.run(%{path: repo_path, message: "Add new file"}, %{})

      assert result.path == repo_path
      assert String.length(result.commit_hash) >= 7
      assert result.message == "Add new file"
    end

    test "rejects empty commit message before invoking git", %{repo_path: repo_path} do
      create_file(repo_path, "new_file.txt", "content")
      System.cmd("git", ["add", "new_file.txt"], cd: repo_path)

      assert {:error, message} = Git.Commit.run(%{path: repo_path, message: ""}, %{})
      assert message =~ "commit message is required"
    end

    test "security regression: preserves shell metacharacters as inert commit argv", %{
      repo_path: repo_path
    } do
      create_file(repo_path, "new_file.txt", "content")
      System.cmd("git", ["add", "new_file.txt"], cd: repo_path)
      marker = Path.join(repo_path, "commit-message-must-not-execute")
      message = "  Use `touch #{marker}` and $(touch #{marker}) safely  "

      assert {:ok, result} =
               Git.Commit.run(%{path: repo_path, message: message}, %{})

      assert result.message == message
      refute File.exists?(marker)

      {stored, 0} = System.cmd("git", ["-C", repo_path, "log", "-1", "--format=%B"])
      assert stored == message <> "\n\n"
      assert String.length(result.commit_hash) >= 7
    end

    test "stages and commits specified files", %{repo_path: repo_path} do
      create_file(repo_path, "file1.txt", "content1")
      create_file(repo_path, "file2.txt", "content2")

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Add files", files: ["file1.txt", "file2.txt"]},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "stages all with -A flag", %{repo_path: repo_path} do
      create_file(repo_path, "file1.txt", "content1")
      create_file(repo_path, "file2.txt", "content2")

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Add all files", all: true},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "stages all when a DOT static boolean arrives as a string", %{repo_path: repo_path} do
      create_file(repo_path, "dot_file.txt", "content")

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Add DOT file", all: "true"},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "handles commit with no changes", %{repo_path: repo_path} do
      assert {:error, message} = Git.Commit.run(%{path: repo_path, message: "Empty"}, %{})
      assert message =~ "nothing to commit" or message =~ "Failed to create commit"
    end

    test "allows empty commit when specified", %{repo_path: repo_path} do
      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Empty commit", allow_empty: true},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "allows an empty commit when a DOT static boolean arrives as a string", %{
      repo_path: repo_path
    } do
      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: "Empty DOT commit", allow_empty: "true"},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "handles special characters in commit message", %{repo_path: repo_path} do
      create_file(repo_path, "file.txt", "content")

      message = "Fix bug: \"quoted\" and 'apostrophe' and $special"

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: message, files: ["file.txt"]},
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
    end

    test "security regression: structured commit argv keeps inert ampersand and parentheses", %{
      repo_path: repo_path
    } do
      create_file(repo_path, "structured.txt", "content")
      message = "Fix A & B (safe)"

      assert {:ok, result} =
               Git.Commit.run(
                 %{path: repo_path, message: message, files: ["structured.txt"]},
                 %{}
               )

      assert result.message == message
      assert {subject, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: repo_path)
      assert String.trim(subject) == message
    end

    test "security regression: commit action never launches repository hooks", %{
      repo_path: repo_path
    } do
      marker = Path.join(repo_path, "hook-must-not-run")
      hook = Path.join([repo_path, ".git", "hooks", "pre-commit"])
      create_file(repo_path, "hook-safe.txt", "content")
      System.cmd("git", ["add", "--", "hook-safe.txt"], cd: repo_path)
      File.write!(hook, "#!/bin/sh\ntouch '#{marker}'\nexit 1\n")
      File.chmod!(hook, 0o755)

      assert {:ok, result} =
               Git.Commit.run(%{path: repo_path, message: "Hook-free commit"}, %{})

      refute File.exists?(marker)
      assert String.length(result.commit_hash) >= 7
    end

    test "validates action metadata" do
      assert Git.Commit.name() == "git_commit"
      assert "commit" in Git.Commit.tags()
    end

    @tag :security_regression
    test "write-risk metadata security regression: commit is local_write via Egress" do
      # Undeclared actions default to :read; git.commit mutates the repo.
      assert Egress.effect_class_for(Git.Commit) == :local_write
    end

    test "security regression: matching expected_head and expected_tree bindings succeed", %{
      repo_path: repo_path
    } do
      create_file(repo_path, "bound.txt", "bound content")
      {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      head = String.trim(head)

      assert {:ok, binding} = Arbor.Actions.Mix.committable_tree_binding(repo_path)

      assert {:ok, result} =
               Git.Commit.run(
                 %{
                   path: repo_path,
                   message: "bound commit",
                   all: true,
                   expected_head_commit: head,
                   expected_tree_oid: binding.tree_oid
                 },
                 %{}
               )

      assert String.length(result.commit_hash) >= 7
      assert result.commit_hash != head

      assert {:ok, tree} =
               Arbor.Actions.Mix.commit_tree_oid(repo_path, result.commit_hash)

      assert tree == binding.tree_oid
    end

    test "security regression: expected_head mismatch fails before mutation", %{
      repo_path: repo_path
    } do
      create_file(repo_path, "head-mismatch.txt", "content")
      snapshot = git_pre_mutation_snapshot!(repo_path)
      fake_head = String.duplicate("a", 40)

      assert {:ok, binding} = Arbor.Actions.Mix.committable_tree_binding(repo_path)

      assert {:error, message} =
               Git.Commit.run(
                 %{
                   path: repo_path,
                   message: "must not commit",
                   all: true,
                   expected_head_commit: fake_head,
                   expected_tree_oid: binding.tree_oid
                 },
                 %{}
               )

      assert message =~ "head mismatch"
      assert_git_unmutated!(repo_path, snapshot)
    end

    test "security regression: expected_tree mismatch fails before mutation", %{
      repo_path: repo_path
    } do
      create_file(repo_path, "tree-mismatch.txt", "content")
      snapshot = git_pre_mutation_snapshot!(repo_path)
      fake_tree = String.duplicate("b", 40)

      assert {:error, message} =
               Git.Commit.run(
                 %{
                   path: repo_path,
                   message: "must not commit",
                   all: true,
                   expected_head_commit: snapshot.head,
                   expected_tree_oid: fake_tree
                 },
                 %{}
               )

      assert message =~ "tree mismatch"
      assert_git_unmutated!(repo_path, snapshot)
    end

    test "security regression: empty expected bindings are invalid not absent", %{
      repo_path: repo_path
    } do
      create_file(repo_path, "empty-bind.txt", "content")
      snapshot = git_pre_mutation_snapshot!(repo_path)

      assert {:error, message} =
               Git.Commit.run(
                 %{
                   path: repo_path,
                   message: "must not commit",
                   all: true,
                   expected_head_commit: ""
                 },
                 %{}
               )

      assert message =~ "expected_head_commit is invalid"
      assert_git_unmutated!(repo_path, snapshot)

      assert {:error, tree_message} =
               Git.Commit.run(
                 %{
                   path: repo_path,
                   message: "must not commit",
                   all: true,
                   expected_tree_oid: "not-an-oid"
                 },
                 %{}
               )

      assert tree_message =~ "expected_tree_oid is invalid"
      assert_git_unmutated!(repo_path, snapshot)
    end

    test "security regression: absent expected bindings keep ordinary commit behavior", %{
      repo_path: repo_path
    } do
      create_file(repo_path, "ordinary.txt", "content")

      assert {:ok, result} =
               Git.Commit.run(%{path: repo_path, message: "ordinary", all: true}, %{})

      assert String.length(result.commit_hash) >= 7
    end
  end

  describe "Log" do
    test "shows commit history", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Log.run(%{path: repo_path}, %{})

      assert result.path == repo_path
      assert result.commits != []
      assert result.count >= 1

      first_commit = hd(result.commits)
      assert Map.has_key?(first_commit, :hash)
      assert Map.has_key?(first_commit, :author)
      assert Map.has_key?(first_commit, :subject)
    end

    test "limits number of commits", %{repo_path: repo_path} do
      # Create some commits
      for i <- 1..5 do
        create_file(repo_path, "file#{i}.txt", "content")
        System.cmd("git", ["add", "file#{i}.txt"], cd: repo_path)
        System.cmd("git", ["commit", "-m", "Commit #{i}"], cd: repo_path)
      end

      assert {:ok, result} = Git.Log.run(%{path: repo_path, limit: 3}, %{})

      assert result.count == 3
    end

    test "shows oneline format", %{repo_path: repo_path} do
      assert {:ok, result} = Git.Log.run(%{path: repo_path, oneline: true}, %{})

      first_commit = hd(result.commits)
      assert Map.has_key?(first_commit, :hash)
      assert Map.has_key?(first_commit, :message)
      # Oneline format has fewer fields
      refute Map.has_key?(first_commit, :email)
    end

    test "filters by file", %{repo_path: repo_path} do
      # Create commits affecting different files
      create_file(repo_path, "file1.txt", "content")
      System.cmd("git", ["add", "file1.txt"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "Add file1"], cd: repo_path)

      create_file(repo_path, "file2.txt", "content")
      System.cmd("git", ["add", "file2.txt"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "Add file2"], cd: repo_path)

      # Filter to only file1
      assert {:ok, result} = Git.Log.run(%{path: repo_path, file: "file1.txt"}, %{})

      # Should only show commits affecting file1
      assert result.count == 1
      first_commit = hd(result.commits)
      assert first_commit.subject =~ "file1"
    end

    test "handles non-git directory" do
      # /tmp might have git history on some systems, use a definitely non-git path
      non_git_path = Path.join(System.tmp_dir!(), "non_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(non_git_path)

      on_exit(fn -> File.rm_rf!(non_git_path) end)

      result = Git.Log.run(%{path: non_git_path}, %{})

      case result do
        {:error, message} ->
          assert message =~ "Failed to get git log" or message =~ "not a git repository"

        {:ok, %{commits: commits}} ->
          # If it succeeds, it should return empty commits
          assert commits == []
      end
    end

    test "validates action metadata" do
      assert Git.Log.name() == "git_log"
      assert "history" in Git.Log.tags()
    end

    test "log with ref parameter", %{repo_path: repo_path} do
      # Create a second commit
      create_file(repo_path, "file1.txt", "content")
      System.cmd("git", ["add", "file1.txt"], cd: repo_path)
      System.cmd("git", ["commit", "-m", "Second commit"], cd: repo_path)

      # Get HEAD hash
      {hash, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
      hash = String.trim(hash)

      # Log with specific ref
      assert {:ok, result} = Git.Log.run(%{path: repo_path, ref: hash, limit: 1}, %{})
      assert result.count == 1
    end

    test "log with multiline commit body", %{repo_path: repo_path} do
      create_file(repo_path, "file1.txt", "content")
      System.cmd("git", ["add", "file1.txt"], cd: repo_path)

      # Create commit with multiline body
      System.cmd(
        "git",
        ["commit", "-m", "Subject line\n\nBody line 1\nBody line 2\nBody line 3"],
        cd: repo_path
      )

      assert {:ok, result} = Git.Log.run(%{path: repo_path, limit: 1}, %{})
      assert result.count == 1

      commit = hd(result.commits)
      assert commit.subject == "Subject line"
      assert commit.body =~ "Body line"
    end

    test "generates tool schema" do
      tool = Git.Log.to_tool()
      assert is_map(tool)
      assert tool[:name] == "git_log"
    end
  end

  defp create_linked_worktree(repo_path, worktree_path, branch) do
    # Try checking out an existing branch first; if it doesn't exist, create it.
    {_output, exit_code} =
      System.cmd(
        "git",
        ["worktree", "add", worktree_path, branch],
        cd: repo_path,
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      assert {_output, 0} =
               System.cmd(
                 "git",
                 ["worktree", "add", "-b", branch, worktree_path],
                 cd: repo_path,
                 stderr_to_stdout: true
               )
    end
  end

  defp worktree_lstat_identity(path) do
    path
    |> File.lstat!()
    |> Map.from_struct()
    |> Map.take([:type, :major_device, :minor_device, :inode])
  end

  # Create a SHA-256 repository for regression coverage. Returns :unsupported
  # (after cleanup) when the local Git is not compiled with sha256 support so
  # the caller can skip gracefully.
  defp create_sha256_git_repo(path) do
    File.mkdir_p!(path)

    case System.cmd("git", ["init", "--object-format=sha256"], cd: path, stderr_to_stdout: true) do
      {_output, 0} ->
        {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
        {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: path)
        readme = Path.join(path, "README.md")
        File.write!(readme, "# SHA-256 Test\n")
        {_, 0} = System.cmd("git", ["add", "README.md"], cd: path)
        {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit"], cd: path)
        :ok

      {_output, _exit} ->
        File.rm_rf!(path)
        :unsupported
    end
  end

  # Boundary promised by expected_* bindings is before staging, not only before
  # commit. Snapshot HEAD, staged index, and porcelain status (incl. untracked).
  defp git_pre_mutation_snapshot!(repo_path) do
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo_path)
    {index, 0} = System.cmd("git", ["ls-files", "--stage", "-z"], cd: repo_path)

    {status, 0} =
      System.cmd("git", ["status", "--porcelain", "--untracked-files=all", "-z"], cd: repo_path)

    %{
      head: String.trim(head),
      index: index,
      status: status
    }
  end

  defp assert_git_unmutated!(repo_path, snapshot) do
    after_snap = git_pre_mutation_snapshot!(repo_path)
    assert after_snap.head == snapshot.head
    assert after_snap.index == snapshot.index
    assert after_snap.status == snapshot.status
  end

  defp git_rev_parse(path, ref) do
    {output, 0} = System.cmd("git", ["rev-parse", ref], cd: path, stderr_to_stdout: true)
    String.trim(output)
  end

  defp branch_exists?(repo_path, branch) do
    case System.cmd(
           "git",
           ["show-ref", "--verify", "--quiet", "refs/heads/#{branch}"],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end
end
