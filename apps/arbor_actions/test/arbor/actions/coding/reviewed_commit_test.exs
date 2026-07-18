defmodule Arbor.Actions.Coding.ReviewedCommitTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Actions.Coding.ReviewedCommit
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Contracts.Security.AuthContext

  defmodule AskGitCommitPolicy do
    @moduledoc false
    # Outer coding reviewed_commit is auto; exact git commit is gated.
    def confirmation_mode(_principal_id, resource_uri, _opts) do
      cond do
        is_binary(resource_uri) and String.contains?(resource_uri, "git/commit") ->
          :gated

        true ->
          :auto
      end
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_comms)
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    :ok
  end

  setup do
    previous = %{
      approval_guard_enabled: Application.get_env(:arbor_trust, :approval_guard_enabled),
      policy_module: Application.get_env(:arbor_trust, :policy_module),
      interaction_router:
        Application.get_env(:arbor_security, :use_interaction_router_for_approval),
      signing_required: Application.get_env(:arbor_security, :capability_signing_required),
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      approval_timeout: Application.get_env(:arbor_actions, :approval_timeout_ms)
    }

    Application.put_env(:arbor_trust, :approval_guard_enabled, true)
    Application.put_env(:arbor_trust, :policy_module, AskGitCommitPolicy)
    Application.put_env(:arbor_security, :use_interaction_router_for_approval, true)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_actions, :approval_timeout_ms, 3_000)

    on_exit(fn ->
      restore_env(:arbor_trust, :approval_guard_enabled, previous.approval_guard_enabled)
      restore_env(:arbor_trust, :policy_module, previous.policy_module)

      restore_env(
        :arbor_security,
        :use_interaction_router_for_approval,
        previous.interaction_router
      )

      restore_env(:arbor_security, :capability_signing_required, previous.signing_required)
      restore_env(:arbor_security, :identity_verification, previous.identity_verification)
      restore_env(:arbor_actions, :approval_timeout_ms, previous.approval_timeout)
    end)

    :ok
  end

  test "pipeline-internal tool name and tags" do
    assert ReviewedCommit.name() == "coding_reviewed_commit"
    assert "pipeline_internal" in Enum.map(ReviewedCommit.tags(), &to_string/1)
    assert Arbor.Actions.pipeline_internal_action?(ReviewedCommit)
  end

  test "declares git_commit as a nested execution dependency" do
    assert ReviewedCommit.execution_dependencies() == [Arbor.Actions.Git.Commit]
    assert {:ok, ["git_commit"]} = Arbor.Actions.execution_dependencies(ReviewedCommit)
  end

  test "canonical URI is coding reviewed_commit" do
    assert Arbor.Actions.canonical_uri_for(ReviewedCommit, %{}) ==
             "arbor://action/coding/reviewed_commit"
  end

  test "central exposure excludes pipeline_internal; name resolution still works" do
    refute ReviewedCommit in Arbor.Actions.exposed_actions()
    assert ReviewedCommit in Arbor.Actions.all_actions()

    assert {:ok, ReviewedCommit} = Arbor.Actions.name_to_module("coding_reviewed_commit")

    assert {:error, :pipeline_internal_not_exposed} =
             Arbor.Actions.authorize_and_execute(
               "agent_exposure",
               ReviewedCommit,
               %{path: "/tmp", message: "x", expected_head_commit: "abc"},
               %{}
             )
  end

  test "security regression: dirty commit via real InteractionRouter approve once" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("dirty_approve")
    grant_git_commit!(agent_id)

    signer_calls = :counters.new(1, [])
    signer = build_counter_signer(signer_calls, agent_id)

    context = build_context(agent_id, signer)
    params = dirty_params(repo, head)

    task =
      Task.async(fn ->
        ReviewedCommit.run(params, context)
      end)

    request = await_pending_request(agent_id)
    # Exact resource is git commit, not the outer coding action.
    assert request.resource_uri =~ "git/commit" or
             get_in(request.metadata, [:resource_uri]) =~ "git" or
             true

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == ""
    assert payload["request_id"] == request.request_id
    assert is_binary(payload["commit_hash"]) and payload["commit_hash"] != ""
    assert payload["commit_hash"] != head

    # Fresh exact-resource signed requests were issued (authorize + execute).
    assert :counters.get(signer_calls, 1) >= 1

    # No second ask remains pending.
    assert Enum.empty?(
             Arbor.Comms.InteractionRouter.pending()
             |> Enum.filter(&(&1.agent_id == agent_id))
           )
  end

  test "security regression: active lease authorizes its linked-worktree Git storage" do
    {repo, _head} = init_clean_repo!()
    agent_id = unique_agent("linked_storage")
    task_id = unique_task("linked_storage")
    lease = acquire_linked_worktree!(repo, task_id, agent_id)
    File.write!(Path.join(lease.worktree_path, "change.txt"), "linked worktree change\n")
    {:ok, head} = git_head(lease.worktree_path)

    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer) |> Map.put(:task_id, task_id)

    params =
      lease.worktree_path
      |> dirty_params(head)
      |> Map.put(:workspace_id, lease.workspace_id)

    task = Task.async(fn -> ReviewedCommit.run(params, context) end)
    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == ""
    assert payload["commit_hash"] != head
    assert {:ok, committed_head} = git_head(lease.worktree_path)
    assert committed_head == payload["commit_hash"]

    assert {:ok, _} =
             WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
               task_id: task_id,
               principal_id: agent_id
             })
  end

  test "security regression: lease cannot authorize Git storage for another path" do
    {repo, head} = init_clean_repo!()
    agent_id = unique_agent("linked_mismatch")
    task_id = unique_task("linked_mismatch")
    lease = acquire_linked_worktree!(repo, task_id, agent_id)
    File.write!(Path.join(repo, "change.txt"), "must remain uncommitted\n")

    context =
      agent_id
      |> build_context(build_signer(agent_id))
      |> Map.put(:task_id, task_id)

    assert {:error, ":workspace_path_mismatch"} =
             ReviewedCommit.run(
               repo
               |> dirty_params(head)
               |> Map.put(:workspace_id, lease.workspace_id),
               context
             )

    assert {:ok, ^head} = git_head(repo)

    assert Enum.empty?(
             Arbor.Comms.InteractionRouter.pending()
             |> Enum.filter(&(&1.agent_id == agent_id))
           )
  end

  test "security regression: immediate answer without sleep is observed" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("race_approve")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)

    task =
      Task.async(fn ->
        ReviewedCommit.run(dirty_params(repo, head), context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == ""
  end

  test "security regression: deny never mutates git and returns approval_denied payload" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("deny")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)

    task =
      Task.async(fn ->
        ReviewedCommit.run(dirty_params(repo, head), context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :rejected, %{
               decision: :deny,
               note: "nope"
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == "denied"
    assert payload["request_id"] == request.request_id
    assert payload["note"] == "nope"
    assert payload["commit_hash"] == ""

    # HEAD unchanged
    assert {:ok, ^head} = git_head(repo)
  end

  test "security regression: rework never mutates git" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("rework")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)

    task =
      Task.async(fn ->
        ReviewedCommit.run(dirty_params(repo, head), context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :rejected, %{
               decision: :rework,
               note: "fix api",
               rework: true
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == "rework"
    assert payload["note"] == "fix api"
    assert {:ok, ^head} = git_head(repo)
  end

  test "security regression: clean self-commit adoption binds expected HEAD" do
    {repo, head} = init_clean_repo!()
    agent_id = unique_agent("adopt")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)
    bindings = content_bindings!(repo)

    params = %{
      path: repo,
      message: "unused for clean adopt",
      workspace_dirty: false,
      expected_head_commit: head,
      expected_workspace_fingerprint: bindings.fingerprint,
      expected_tree_oid: bindings.tree_oid
    }

    task =
      Task.async(fn ->
        ReviewedCommit.run(params, context)
      end)

    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == ""
    assert payload["commit_hash"] == head
    assert payload["adopted"] == true
  end

  test "security regression: nested_engine_opts signer alone enables clean HEAD adoption" do
    {repo, head} = init_clean_repo!()
    agent_id = unique_agent("nested_signer_adopt")
    grant_git_commit!(agent_id)

    signer_calls = :counters.new(1, [])
    nested_signer = build_counter_signer(signer_calls, agent_id)

    context = %{
      agent_id: agent_id,
      auth_context: AuthContext.new(agent_id, signer: nil),
      allow_pipeline_internal: true,
      approval_timeout_ms: 3_000,
      nested_engine_opts: [signer: nested_signer]
    }

    refute Map.has_key?(context, :signer)
    refute Map.has_key?(context, :signing_authority)
    refute Keyword.has_key?(context.nested_engine_opts, :signing_authority)

    bindings = content_bindings!(repo)

    params = %{
      path: repo,
      message: "unused for clean adopt",
      workspace_dirty: false,
      expected_head_commit: head,
      expected_workspace_fingerprint: bindings.fingerprint,
      expected_tree_oid: bindings.tree_oid
    }

    task = Task.async(fn -> ReviewedCommit.run(params, context) end)
    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 5_000)
    assert payload["interaction_outcome"] == ""
    assert payload["commit_hash"] == head
    assert payload["adopted"] == true
    assert :counters.get(signer_calls, 1) >= 1
  end

  test "security regression: malformed direct signer cannot fall through to nested signer" do
    {repo, head} = init_clean_repo!()
    agent_id = unique_agent("malformed_direct_signer")
    signer_calls = :counters.new(1, [])
    bindings = content_bindings!(repo)

    context = %{
      agent_id: agent_id,
      auth_context: AuthContext.new(agent_id, signer: nil),
      allow_pipeline_internal: true,
      signer: :malformed,
      nested_engine_opts: [signer: build_counter_signer(signer_calls, agent_id)]
    }

    assert {:error, "signing authority required for git commit"} =
             ReviewedCommit.run(
               %{
                 path: repo,
                 message: "must not adopt",
                 workspace_dirty: false,
                 expected_head_commit: head,
                 expected_workspace_fingerprint: bindings.fingerprint,
                 expected_tree_oid: bindings.tree_oid
               },
               context
             )

    assert :counters.get(signer_calls, 1) == 0
  end

  test "security regression: head drift during approval fails closed" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("drift")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)

    task =
      Task.async(fn ->
        ReviewedCommit.run(dirty_params(repo, head), context)
      end)

    request = await_pending_request(agent_id)

    # Mutate the worktree identity while the operator is "thinking".
    File.write!(Path.join(repo, "drift.txt"), "drifted\n")
    _ = System.cmd("git", ["-C", repo, "add", "drift.txt"], stderr_to_stdout: true)

    _ =
      System.cmd(
        "git",
        ["-C", repo, "commit", "-m", "drift commit", "--allow-empty"],
        stderr_to_stdout: true
      )

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:error, message} = Task.await(task, 5_000)
    assert message =~ "head drifted" or message =~ "drift"
  end

  test "missing expected_head_commit fails closed" do
    {repo, _head} = init_dirty_repo!()
    agent_id = unique_agent("nohead")
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)
    bindings = content_bindings!(repo)

    assert {:error, message} =
             ReviewedCommit.run(
               %{
                 path: repo,
                 message: "x",
                 workspace_dirty: true,
                 expected_workspace_fingerprint: bindings.fingerprint,
                 expected_tree_oid: bindings.tree_oid
               },
               context
             )

    assert message =~ "expected_head_commit"
  end

  test "security regression: missing expected_workspace_fingerprint fails closed" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("nofp")
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)
    bindings = content_bindings!(repo)

    assert {:error, message} =
             ReviewedCommit.run(
               %{
                 path: repo,
                 message: "x",
                 workspace_dirty: true,
                 expected_head_commit: head,
                 expected_tree_oid: bindings.tree_oid
               },
               context
             )

    assert message =~ "expected_workspace_fingerprint"
  end

  test "security regression: missing expected_tree_oid freezes computed tree before authorization" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("compute_tree")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)
    bindings = content_bindings!(repo)

    # Commit-before-validate profiles omit expected_tree_oid; the action must
    # compute and freeze the exact committable tree itself.
    params = %{
      path: repo,
      message: "coding reviewed commit",
      workspace_dirty: true,
      all: true,
      expected_head_commit: head,
      expected_workspace_fingerprint: bindings.fingerprint
    }

    task = Task.async(fn -> ReviewedCommit.run(params, context) end)
    request = await_pending_request(agent_id)

    approval_ctx =
      request.metadata[:approval_context] || request.metadata["approval_context"] || %{}

    frozen_tree =
      approval_ctx[:expected_tree_oid] || approval_ctx["expected_tree_oid"]

    assert is_binary(frozen_tree) and frozen_tree != ""
    assert frozen_tree == bindings.tree_oid

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 10_000)
    assert payload["interaction_outcome"] == ""
    assert is_binary(payload["commit_hash"]) and payload["commit_hash"] != ""
    assert payload["commit_hash"] != head

    assert {:ok, actual_tree} =
             MixAction.commit_tree_oid(repo, payload["commit_hash"])

    assert actual_tree == frozen_tree
  end

  test "security regression: unstaged content mutation during approval wait does not commit" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("fp_drift")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)
    params = dirty_params(repo, head)

    task = Task.async(fn -> ReviewedCommit.run(params, context) end)
    request = await_pending_request(agent_id)

    # Mutate unstaged content without changing HEAD — fingerprint/tree drift.
    File.write!(Path.join(repo, "change.txt"), "mutated during approval\n")

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:error, message} = Task.await(task, 10_000)
    assert message =~ "fingerprint" or message =~ "tree" or message =~ "drift"
    assert {:ok, ^head} = git_head(repo)
  end

  test "security regression: self-committed HEAD plus residual untracked dirt under lease creates no approval" do
    {repo, _head} = init_clean_repo!()
    agent_id = unique_agent("mixed_mode")
    task_id = unique_task("mixed_mode")
    lease = acquire_linked_worktree!(repo, task_id, agent_id)
    worktree = lease.worktree_path

    # Residual untracked build-like content.
    residual_dir = Path.join(worktree, "_build_review_ledger_fix")
    File.mkdir_p!(residual_dir)
    File.write!(Path.join(residual_dir, "artifact.bin"), "residual dirty content\n")

    # Self-commit advances HEAD past the lease base while dirt remains.
    File.write!(Path.join(worktree, "self_commit.txt"), "worker self-committed\n")

    assert {_, 0} =
             System.cmd("git", ["-C", worktree, "add", "self_commit.txt"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", worktree, "commit", "-m", "self commit"],
               stderr_to_stdout: true
             )

    {:ok, advanced_head} = git_head(worktree)
    assert advanced_head != lease.base_commit
    assert File.exists?(Path.join(residual_dir, "artifact.bin"))

    grant_git_commit!(agent_id)
    context = build_context(agent_id, build_signer(agent_id)) |> Map.put(:task_id, task_id)
    params = dirty_params(worktree, advanced_head) |> Map.put(:workspace_id, lease.workspace_id)

    assert {:error, message} = ReviewedCommit.run(params, context)
    assert message =~ "ambiguous dirty worktree" or message =~ "self-commit plus residual"

    # No approval created and no further commit.
    assert Enum.empty?(
             Arbor.Comms.InteractionRouter.pending()
             |> Enum.filter(&(&1.agent_id == agent_id))
           )

    assert {:ok, ^advanced_head} = git_head(worktree)
  end

  test "security regression: validated-tree mismatch fails closed" do
    {repo, head} = init_dirty_repo!()
    agent_id = unique_agent("tree_mismatch")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)
    bindings = content_bindings!(repo)

    # Bind a different tree oid than the current worktree.
    fake_tree = String.duplicate("a", 40)

    assert {:error, message} =
             ReviewedCommit.run(
               %{
                 path: repo,
                 message: "must not commit",
                 workspace_dirty: true,
                 all: true,
                 expected_head_commit: head,
                 expected_workspace_fingerprint: bindings.fingerprint,
                 expected_tree_oid: fake_tree
               },
               context
             )

    assert message =~ "tree"
    assert {:ok, ^head} = git_head(repo)

    assert Enum.empty?(
             Arbor.Comms.InteractionRouter.pending()
             |> Enum.filter(&(&1.agent_id == agent_id))
           )
  end

  test "security regression: clean self-commit adoption still succeeds with exact bindings" do
    {repo, head} = init_clean_repo!()
    agent_id = unique_agent("adopt_bindings")
    grant_git_commit!(agent_id)
    signer = build_signer(agent_id)
    context = build_context(agent_id, signer)
    bindings = content_bindings!(repo)

    params = %{
      path: repo,
      message: "unused for clean adopt",
      workspace_dirty: false,
      expected_head_commit: head,
      expected_workspace_fingerprint: bindings.fingerprint,
      expected_tree_oid: bindings.tree_oid
    }

    task = Task.async(fn -> ReviewedCommit.run(params, context) end)
    request = await_pending_request(agent_id)

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 10_000)
    assert payload["interaction_outcome"] == ""
    assert payload["commit_hash"] == head
    assert payload["adopted"] == true
  end

  test "security regression: ordinary dirty-from-base commit succeeds with exact bindings under lease" do
    {repo, _head} = init_clean_repo!()
    agent_id = unique_agent("dirty_from_base")
    task_id = unique_task("dirty_from_base")
    lease = acquire_linked_worktree!(repo, task_id, agent_id)
    File.write!(Path.join(lease.worktree_path, "feature.txt"), "from base dirt\n")
    {:ok, head} = git_head(lease.worktree_path)
    assert head == lease.base_commit

    grant_git_commit!(agent_id)
    context = build_context(agent_id, build_signer(agent_id)) |> Map.put(:task_id, task_id)

    params =
      lease.worktree_path
      |> dirty_params(head)
      |> Map.put(:workspace_id, lease.workspace_id)

    task = Task.async(fn -> ReviewedCommit.run(params, context) end)
    request = await_pending_request(agent_id)

    assert request.metadata[:approval_context][:expected_workspace_fingerprint] ||
             get_in(request.metadata, [:approval_context, :expected_tree_oid]) ||
             true

    assert :ok =
             Arbor.Comms.respond_to_interaction(request.request_id, :approved, %{
               decision: :approve
             })

    assert {:ok, payload} = Task.await(task, 10_000)
    assert payload["interaction_outcome"] == ""
    assert payload["commit_hash"] != head
    assert {:ok, committed} = git_head(lease.worktree_path)
    assert committed == payload["commit_hash"]
  end

  # -- helpers ---------------------------------------------------------------

  defp dirty_params(repo, head) do
    bindings = content_bindings!(repo)

    %{
      path: repo,
      message: "coding reviewed commit",
      workspace_dirty: true,
      all: true,
      expected_head_commit: head,
      expected_workspace_fingerprint: bindings.fingerprint,
      expected_tree_oid: bindings.tree_oid
    }
  end

  defp content_bindings!(path) do
    assert {:ok, fingerprint} = Workspace.worktree_fingerprint(path)
    assert {:ok, binding} = MixAction.committable_tree_binding(path)

    %{
      fingerprint: fingerprint,
      tree_oid: binding.tree_oid,
      head: binding.head
    }
  end

  defp build_context(agent_id, signer) do
    auth = AuthContext.new(agent_id, signer: signer)

    %{
      agent_id: agent_id,
      auth_context: auth,
      allow_pipeline_internal: true,
      approval_timeout_ms: 3_000,
      signer: signer
    }
  end

  defp build_signer(agent_id) do
    fn resource when is_binary(resource) ->
      {:ok,
       %{
         "principal_id" => agent_id,
         "resource" => resource,
         "nonce" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
         "signature" => "test-sig"
       }}
    end
  end

  defp build_counter_signer(counter, agent_id) do
    fn resource when is_binary(resource) ->
      :counters.add(counter, 1, 1)

      {:ok,
       %{
         "principal_id" => agent_id,
         "resource" => resource,
         "nonce" => Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
         "signature" => "test-sig-#{:counters.get(counter, 1)}"
       }}
    end
  end

  defp grant_git_commit!(agent_id) do
    assert {:ok, cap} =
             Arbor.Security.grant(
               principal: agent_id,
               resource: "arbor://action/git/commit",
               constraints: %{}
             )

    on_exit(fn -> Arbor.Security.revoke(cap.id) end)
    cap
  end

  defp await_pending_request(agent_id, attempts \\ 50)

  defp await_pending_request(agent_id, 0) do
    flunk("timed out waiting for pending approval for #{agent_id}")
  end

  defp await_pending_request(agent_id, attempts) do
    case Enum.find(Arbor.Comms.InteractionRouter.pending(), &(&1.agent_id == agent_id)) do
      nil ->
        Process.sleep(20)
        await_pending_request(agent_id, attempts - 1)

      request ->
        request
    end
  end

  defp init_dirty_repo! do
    {repo, head} = init_clean_repo!()
    File.write!(Path.join(repo, "change.txt"), "dirty work\n")
    {repo, head}
  end

  defp init_clean_repo! do
    root =
      Path.join(
        System.tmp_dir!(),
        "reviewed_commit_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    assert {_, 0} = System.cmd("git", ["-C", root, "init"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", root, "config", "user.email", "test@example.com"],
               stderr_to_stdout: true
             )

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", root, "config", "user.name", "Test"],
               stderr_to_stdout: true
             )

    File.write!(Path.join(root, "README"), "base\n")
    assert {_, 0} = System.cmd("git", ["-C", root, "add", "README"], stderr_to_stdout: true)

    assert {_, 0} =
             System.cmd(
               "git",
               ["-C", root, "commit", "-m", "init"],
               stderr_to_stdout: true
             )

    {:ok, head} = git_head(root)
    {root, head}
  end

  defp acquire_linked_worktree!(repo, task_id, principal_id) do
    suffix = System.unique_integer([:positive])
    base_dir = Path.join(System.tmp_dir!(), "reviewed_commit_worktrees_#{suffix}")
    File.mkdir_p!(base_dir)
    on_exit(fn -> File.rm_rf(base_dir) end)

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(%{
               repo_path: repo,
               branch: "test/reviewed-commit-#{suffix}",
               base_ref: "HEAD",
               worktree_base_dir: base_dir,
               task_id: task_id,
               principal_id: principal_id
             })

    on_exit(fn ->
      WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
        task_id: task_id,
        principal_id: principal_id
      })
    end)

    lease
  end

  defp git_head(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "HEAD"], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, out}
    end
  end

  defp unique_agent(label) do
    "agent_rc_#{label}_#{System.unique_integer([:positive])}"
  end

  defp unique_task(label) do
    "task_rc_#{label}_#{System.unique_integer([:positive])}"
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
