defmodule Arbor.Actions.Coding.CandidateMaterializationCompositionTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.CandidateMaterialization.Materialize
  alias Arbor.Actions.Coding.CrossApp.Shell, as: CrossAppShell
  alias Arbor.Actions.Coding.CrossApp.Validate, as: CrossAppValidate
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Actions.TestLinuxBaselineMaterializer
  alias Arbor.Contracts.Coding.CandidateMaterialization

  @moduletag :fast

  defmodule ReceiptStore do
    def archive(store, digest, receipt) do
      Agent.update(store, &Map.put(&1, digest, receipt))
      {:ok, %{"digest" => digest, "schema_version" => 1}}
    end

    def read(store, digest) do
      Agent.get(store, fn receipts ->
        case Map.fetch(receipts, digest) do
          {:ok, receipt} -> {:ok, receipt}
          :error -> {:error, :cross_app_static_receipt_unavailable}
        end
      end)
    end
  end

  setup_all do
    case Process.whereis(Arbor.Shell.ExecutionRegistry) do
      nil -> {:ok, _} = Application.ensure_all_started(:arbor_shell)
      _pid -> :ok
    end

    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    server = :"g5d_compose_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: {WorkspaceLeaseRegistry, server},
      start:
        {WorkspaceLeaseRegistry, :start_link,
         [
           [
             name: server,
             retention_journal: :disabled,
             linux_dependency_baseline_materializer: TestLinuxBaselineMaterializer
           ]
         ]}
    })

    repo = create_git_repo(Path.join(tmp_dir, "repo"))
    task_id = "task_g5d_#{System.unique_integer([:positive])}"
    principal_id = "agent_g5d_#{System.unique_integer([:positive])}"

    assert {:ok, lease} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: "test/g5d-compose",
                 worktree_base_dir: Path.join(tmp_dir, "worktrees"),
                 task_id: task_id,
                 principal_id: principal_id
               },
               server: server
             )

    on_exit(fn ->
      _ = WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{server: server})
    end)

    %{
      server: server,
      repo: lease.repo_path,
      lease: lease,
      task_id: task_id,
      principal_id: principal_id,
      worktree: lease.worktree_path
    }
  end

  test "Mix rebinds the same object-backed resource across windows and reauthorizes each child",
       %{
         server: server,
         lease: lease,
         task_id: task_id,
         principal_id: principal_id,
         worktree: worktree
       } do
    {source, descriptor, _before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    git!(worktree, ["reset", "--hard", lease.base_commit])
    {:ok, digest} = CandidateMaterialization.digest(descriptor)

    assert {:ok, first} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    binding_caller = %{
      server: server,
      task_id: task_id,
      principal_id: principal_id,
      workspace_id: lease.workspace_id,
      source_commit_oid: source,
      expected_tree_oid: descriptor["expected_tree_oid"],
      candidate_materialization_digest: digest,
      acquired_base_commit: lease.base_commit,
      evidence_ref: first["hidden_ref"]
    }

    for key <- ~w(
          task_id
          principal_id
          workspace_id
          source_commit_oid
          expected_tree_oid
          candidate_materialization_digest
          acquired_base_commit
        )a do
      assert {:error, :incomplete_immutable_review_binding} =
               WorkspaceLeaseRegistry.bind_existing_object_backed_validation_resource(
                 first["resource_id"],
                 Map.delete(binding_caller, key)
               )
    end

    assert {:ok, :kept} =
             MixAction.with_existing_object_backed_validation_resource(
               first["resource_id"],
               context(task_id, principal_id, server),
               fn resource ->
                 assert resource["resource_id"] == first["resource_id"]
                 assert resource["candidate_path"] != worktree

                 assert {:ok,
                         %{
                           validation_resource_id: resource_id,
                           workspace_id: workspace_id,
                           task_id: ^task_id,
                           principal_id: ^principal_id
                         }} = MixAction.unit_owner_from_validation_resource(resource)

                 assert resource_id == first["resource_id"]
                 assert workspace_id == lease.workspace_id
                 assert resource["source_projection"] == :read_only
                 assert is_binary(resource["candidate_runtime_path"])
                 assert is_binary(resource["candidate_deps_path"])
                 assert is_binary(resource["candidate_runner_dir_path"])
                 assert is_binary(resource["candidate_result_dir_path"])
                 assert :ok = MixAction.recapture_committable_snapshot(resource)

                 assert {:error, :incomplete_immutable_review_binding} =
                          resource
                          |> Map.delete("source_commit_oid")
                          |> MixAction.recapture_committable_snapshot()

                 assert {:error, :compiler_descriptor_mismatch} =
                          resource
                          |> Map.put("source_commit_oid", lease.base_commit)
                          |> MixAction.recapture_committable_snapshot()

                 {:ok, :kept}
               end,
               workspace_id: lease.workspace_id,
               source_commit_oid: source,
               expected_tree_oid: descriptor["expected_tree_oid"],
               candidate_materialization_digest: digest,
               acquired_base_commit: lease.base_commit,
               evidence_ref: first["hidden_ref"],
               worktree_path: worktree,
               server: server
             )

    assert {:ok, :same_window_resource} =
             MixAction.with_existing_object_backed_validation_resource(
               first["resource_id"],
               context(task_id, principal_id, server),
               fn resource ->
                 assert resource["resource_id"] == first["resource_id"]
                 assert :ok = MixAction.recapture_committable_snapshot(resource)
                 {:ok, :same_window_resource}
               end,
               workspace_id: lease.workspace_id,
               source_commit_oid: source,
               expected_tree_oid: descriptor["expected_tree_oid"],
               candidate_materialization_digest: digest,
               acquired_base_commit: lease.base_commit,
               evidence_ref: first["hidden_ref"],
               worktree_path: worktree,
               server: server
             )

    assert {:ok, reused} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    assert reused["resource_id"] == first["resource_id"]
  end

  test "security regression: exact-lineage successor reuses the same immutable resource after owner death",
       %{server: server, repo: repo, tmp_dir: tmp_dir} do
    task_id = "task_g5d_resume_#{System.unique_integer([:positive])}"
    principal_id = "agent_g5d_resume_#{System.unique_integer([:positive])}"

    owner =
      start_materialized_owner(
        self(),
        server,
        repo,
        Path.join(tmp_dir, "resume-worktrees"),
        task_id,
        principal_id
      )

    assert_receive {:materialized_owner_ready, ^owner, {:ok, owned}}, 60_000

    on_exit(fn ->
      _ =
        WorkspaceLeaseRegistry.release(owned.lease.workspace_id, :remove, %{
          server: server,
          task_id: task_id,
          principal_id: principal_id
        })
    end)

    assert {:error, :workspace_owner_active} =
             WorkspaceLeaseRegistry.ensure_active_by_lineage(
               owned.lease.workspace_id,
               task_id,
               principal_id,
               server: server
             )

    assert {:error, :not_authorized} =
             WorkspaceLeaseRegistry.ensure_active_by_lineage(
               owned.lease.workspace_id,
               task_id,
               principal_id <> "_wrong",
               server: server
             )

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

    review_opts = %{
      server: server,
      task_id: task_id,
      principal_id: principal_id,
      candidate_source: "immutable_object",
      evidence_ref: owned.materialized["hidden_ref"],
      acquired_base_commit: owned.lease.base_commit,
      expected_tree_oid: owned.descriptor["expected_tree_oid"],
      candidate_materialization_digest: owned.digest,
      validation_resource_id: owned.materialized["resource_id"]
    }

    # Review is a checkpoint-resumable consumer. It must reclaim the retained
    # lineage itself; the completed materialization/committed-change nodes will
    # not replay merely to restore process ownership.
    assert {:ok, snapshot} =
             WorkspaceLeaseRegistry.open_review_snapshot(
               owned.lease.workspace_id,
               owned.source,
               review_opts
             )

    assert {:ok, _closed} =
             WorkspaceLeaseRegistry.close_review_snapshot(
               snapshot.review_snapshot_id,
               review_opts
             )

    assert {:ok, proof} =
             Workspace.EnsureActive.run(
               %{workspace_id: owned.lease.workspace_id},
               context(task_id, principal_id, server)
             )

    assert proof.exists == true
    assert proof.dirty == false
    assert proof.head_commit == owned.lease.base_commit

    assert {:ok, [resource]} =
             WorkspaceLeaseRegistry.validation_resources(owned.lease.workspace_id, %{
               server: server,
               task_id: task_id,
               principal_id: principal_id
             })

    assert resource.resource_id == owned.materialized["resource_id"]

    assert {:ok, reused} =
             Materialize.run(
               params(owned.lease, owned.descriptor, owned.digest),
               context(task_id, principal_id, server)
             )

    assert reused["resource_id"] == owned.materialized["resource_id"]
    assert reused["hidden_ref"] == owned.materialized["hidden_ref"]
  end

  test "security regression: owner death cleans a partial object-backed resource instead of adopting it",
       %{server: server, repo: repo, tmp_dir: tmp_dir} do
    task_id = "task_g5d_partial_#{System.unique_integer([:positive])}"
    principal_id = "agent_g5d_partial_#{System.unique_integer([:positive])}"
    parent = self()

    owner =
      spawn(fn ->
        result =
          with {:ok, lease} <-
                 WorkspaceLeaseRegistry.acquire(
                   %{
                     repo_path: repo,
                     branch: "test/g5d-partial-#{System.unique_integer([:positive])}",
                     worktree_base_dir: Path.join(tmp_dir, "partial-worktrees"),
                     task_id: task_id,
                     principal_id: principal_id
                   },
                   server: server
                 ),
               {:ok, resource} <-
                 WorkspaceLeaseRegistry.acquire_validation_resource(lease.workspace_id, %{
                   server: server,
                   task_id: task_id,
                   principal_id: principal_id,
                   object_backed_snapshot: true
                 }) do
            {:ok, %{lease: lease, resource: resource}}
          end

        send(parent, {:partial_owner_ready, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:partial_owner_ready, ^owner, {:ok, owned}}, 60_000

    on_exit(fn ->
      _ =
        WorkspaceLeaseRegistry.release(owned.lease.workspace_id, :remove, %{
          server: server,
          task_id: task_id,
          principal_id: principal_id
        })
    end)

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

    assert {:ok, _lease} =
             WorkspaceLeaseRegistry.ensure_active_by_lineage(
               owned.lease.workspace_id,
               task_id,
               principal_id,
               server: server
             )

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(owned.lease.workspace_id, %{
               server: server,
               task_id: task_id,
               principal_id: principal_id
             })
  end

  test "security regression: descriptor materialization rejects a reused workspace before allocation",
       %{server: server, repo: repo, tmp_dir: tmp_dir} do
    task_id = "task_g5d_reused_#{System.unique_integer([:positive])}"
    principal_id = "agent_g5d_reused_#{System.unique_integer([:positive])}"
    branch = "test/g5d-reused-#{System.unique_integer([:positive])}"
    worktree_base = Path.join(tmp_dir, "reused-worktrees")
    worktree = Path.join(worktree_base, Workspace.worktree_dir_name(branch))
    File.mkdir_p!(worktree_base)
    git!(repo, ["branch", branch])
    git!(repo, ["worktree", "add", worktree, branch])
    parent = self()

    owner =
      spawn(fn ->
        result =
          with {:ok, lease} <-
                 WorkspaceLeaseRegistry.acquire(
                   %{
                     repo_path: repo,
                     branch: branch,
                     worktree_base_dir: worktree_base,
                     task_id: task_id,
                     principal_id: principal_id
                   },
                   server: server
                 ) do
            {source, descriptor, _before} =
              commit_regular_add(lease.worktree_path, lease.repo_path, lease.base_commit)

            git!(lease.worktree_path, ["reset", "--hard", lease.base_commit])
            {:ok, digest} = CandidateMaterialization.digest(descriptor)

            {:ok,
             %{
               lease: lease,
               source: source,
               materialize_result:
                 Materialize.run(
                   params(lease, descriptor, digest),
                   context(task_id, principal_id, server)
                 )
             }}
          end

        send(parent, {:reused_materialized_owner_ready, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:reused_materialized_owner_ready, ^owner, {:ok, owned}}, 60_000
    assert owned.lease.ownership == "reused"
    assert owned.materialize_result == {:error, :descriptor_workspace_not_owned}

    assert {:ok, []} =
             WorkspaceLeaseRegistry.validation_resources(owned.lease.workspace_id, %{
               server: server,
               task_id: task_id,
               principal_id: principal_id
             })

    refute match?(
             {:ok, _},
             Git.verify_archived_evidence_ref(
               owned.lease.repo_path,
               task_id,
               owned.lease.workspace_id,
               owned.source
             )
           )

    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000

    assert_eventually(fn ->
      state = :sys.get_state(server)

      not Map.has_key?(state.leases, owned.lease.workspace_id) and
        not Map.has_key?(state.validation_by_workspace, owned.lease.workspace_id)
    end)

    assert File.dir?(owned.lease.worktree_path)
  end

  test "security regression: review rebinds checkpointed identities and rejects lease/base fallback",
       %{
         server: server,
         lease: lease,
         task_id: task_id,
         principal_id: principal_id,
         worktree: worktree
       } do
    {source, descriptor, _before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    git!(worktree, ["reset", "--hard", lease.base_commit])
    {:ok, digest} = CandidateMaterialization.digest(descriptor)

    assert {:ok, materialized} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    identities = %{
      workspace_id: lease.workspace_id,
      commit: source,
      candidate_source: "immutable_object",
      acquired_base_commit: lease.base_commit,
      expected_tree_oid: descriptor["expected_tree_oid"],
      candidate_materialization_digest: digest,
      candidate_materialization: descriptor,
      validation_resource_id: materialized["resource_id"],
      evidence_ref: materialized["hidden_ref"]
    }

    assert {:ok, change} =
             Workspace.CommittedChange.run(identities, context(task_id, principal_id, server))

    assert change["commit_hash"] == source
    assert change["base_ref"] == lease.base_commit
    assert change["resource_id"] == materialized["resource_id"]
    assert Enum.all?(Map.keys(change), &is_binary/1)

    assert {:error, :incomplete_immutable_review_binding} =
             Workspace.CommittedChange.run(
               %{
                 workspace_id: lease.workspace_id,
                 commit: source,
                 candidate_source: "immutable_object"
               },
               context(task_id, principal_id, server)
             )

    assert {:error, :incomplete_immutable_review_binding} =
             Workspace.CommittedChange.run(
               Map.delete(identities, :candidate_materialization),
               context(task_id, principal_id, server)
             )

    assert {:error, :acquired_base_mismatch} =
             Workspace.CommittedChange.run(
               Map.put(identities, :acquired_base_commit, source),
               context(task_id, principal_id, server)
             )

    assert {:error, :evidence_ref_mismatch} =
             Workspace.CommittedChange.run(
               Map.put(identities, :evidence_ref, "refs/arbor/evidence/moved"),
               context(task_id, principal_id, server)
             )

    git!(worktree, ["reset", "--hard", source])

    assert {:error, :head_commit_mismatch} =
             Workspace.CommittedChange.run(
               identities,
               context(task_id, principal_id, server)
             )
  end

  test "security regression: immutable CrossApp windows require every checkpointed identity" do
    input = %{workspace_id: "ws_missing_identity", stage_timeout: 10_000}

    context = %{
      "candidate_source" => "immutable_object",
      "validation_resource_id" => "validation_" <> String.duplicate("a", 32),
      "source_commit_oid" => String.duplicate("b", 40),
      "expected_tree_oid" => String.duplicate("c", 40),
      "candidate_materialization_digest" => String.duplicate("d", 64),
      "acquired_base_commit" => String.duplicate("e", 40),
      "evidence_ref" => "refs/arbor/evidence/task/workspace",
      "candidate_materialization" => %{
        "source_commit_oid" => String.duplicate("b", 40),
        "expected_tree_oid" => String.duplicate("c", 40),
        "entries" => [
          %{
            "path" => "lib/a.ex",
            "blob_oid" => String.duplicate("f", 40),
            "mode" => 100_644
          }
        ]
      }
    }

    for key <- ~w(
          validation_resource_id
          source_commit_oid
          expected_tree_oid
          candidate_materialization_digest
          acquired_base_commit
          evidence_ref
          candidate_materialization
        ) do
      assert {:error, :incomplete_immutable_review_binding} =
               CrossAppShell.run(input, Map.delete(context, key))
    end
  end

  test "security regression: immutable CrossApp continuation admits state before execution",
       %{
         server: server,
         lease: lease,
         task_id: task_id,
         principal_id: principal_id,
         worktree: worktree
       } do
    {source, descriptor, _before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    git!(worktree, ["reset", "--hard", lease.base_commit])
    {:ok, digest} = CandidateMaterialization.digest(descriptor)

    assert {:ok, materialized} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    {:ok, receipt_store} = Agent.start_link(fn -> %{} end)

    frozen = %{
      "work_packet_digest" => "sha256:" <> String.duplicate("1", 64),
      "toolchain_digest" => String.duplicate("2", 64),
      "dependency_baseline_digest" => String.duplicate("3", 64),
      "wrapper_digest" => String.duplicate("4", 64)
    }

    previous_observer =
      Application.get_env(:arbor_actions, :cross_app_frozen_binding_observer)

    previous_runner = Application.get_env(:arbor_actions, :cross_app_mix_runner)

    Application.put_env(:arbor_actions, :cross_app_frozen_binding_observer, fn _context ->
      {:ok, frozen}
    end)

    Application.put_env(:arbor_actions, :cross_app_mix_runner, fn _path, _args, _opts ->
      {:ok, %{exit_code: 0, stdout: "ok", stderr: "", timed_out: false}}
    end)

    on_exit(fn ->
      restore_application_env(:cross_app_frozen_binding_observer, previous_observer)
      restore_application_env(:cross_app_mix_runner, previous_runner)

      if Process.alive?(receipt_store), do: Agent.stop(receipt_store)
    end)

    immutable_context =
      context(task_id, principal_id, server)
      |> Map.merge(%{
        "candidate_source" => "immutable_object",
        "validation_resource_id" => materialized["resource_id"],
        "source_commit_oid" => source,
        "expected_tree_oid" => descriptor["expected_tree_oid"],
        "candidate_materialization_digest" => digest,
        "candidate_materialization" => descriptor,
        "acquired_base_commit" => lease.base_commit,
        "evidence_ref" => materialized["hidden_ref"],
        "worktree_path" => worktree,
        "coding_plan_work_packet_digest" => frozen["work_packet_digest"],
        "cross_app_progress" => %{},
        "cross_app_progress_binding" => %{},
        :cross_app_static_receipt_sink => {ReceiptStore, :archive, [receipt_store]},
        :cross_app_static_receipt_source => {ReceiptStore, :read, [receipt_store]}
      })

    validation_params = %{
      workspace_id: lease.workspace_id,
      timeout: 300_000,
      stage_timeout: 1_200_000,
      test_stage_timeout: 600_000
    }

    seed_context =
      Map.drop(immutable_context, ["cross_app_progress", "cross_app_progress_binding"])

    assert {:ok, seeded} = CrossAppValidate.run(validation_params, seed_context)
    assert seeded["disposition_type"] == "completed"
    assert seeded["progress_status"] == "completed"

    resumed_context =
      seed_context
      |> Map.put("cross_app_progress", seeded["progress"])
      |> Map.put("cross_app_progress_binding", seeded["progress_binding"])

    assert {:ok, resumed} = CrossAppValidate.run(validation_params, resumed_context)
    assert resumed["disposition_type"] == "completed"
    assert resumed["progress"] == seeded["progress"]

    assert {:error, :malformed_state} =
             CrossAppValidate.run(validation_params, immutable_context)
  end

  test "security regression: resumed immutable validation verifies the snapshot before its first child",
       %{
         server: server,
         lease: lease,
         task_id: task_id,
         principal_id: principal_id,
         worktree: worktree
       } do
    {source, descriptor, _before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    git!(worktree, ["reset", "--hard", lease.base_commit])
    {:ok, digest} = CandidateMaterialization.digest(descriptor)

    assert {:ok, materialized} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    candidate_file = Path.join(materialized["candidate_path"], "lib/a.ex")
    File.chmod!(candidate_file, 0o600)
    File.write!(candidate_file, "defmodule Substituted do\nend\n")
    parent = self()

    assert {:error, _reason} =
             MixAction.with_existing_object_backed_validation_resource(
               materialized["resource_id"],
               context(task_id, principal_id, server),
               fn _resource ->
                 send(parent, :validation_child_launched)
                 {:ok, :launched}
               end,
               workspace_id: lease.workspace_id,
               source_commit_oid: source,
               expected_tree_oid: descriptor["expected_tree_oid"],
               candidate_materialization_digest: digest,
               acquired_base_commit: lease.base_commit,
               evidence_ref: materialized["hidden_ref"],
               worktree_path: worktree,
               server: server
             )

    refute_received :validation_child_launched
  end

  test "security regression: descriptor publication rebinds the complete immutable candidate",
       %{
         server: server,
         lease: lease,
         task_id: task_id,
         principal_id: principal_id,
         worktree: worktree
       } do
    {source, descriptor, _before} =
      commit_regular_add(worktree, lease.repo_path, lease.base_commit)

    git!(worktree, ["reset", "--hard", lease.base_commit])
    {:ok, digest} = CandidateMaterialization.digest(descriptor)

    assert {:ok, materialized} =
             Materialize.run(
               params(lease, descriptor, digest),
               context(task_id, principal_id, server)
             )

    assert {:ok, published} =
             Workspace.Release.run(
               %{
                 workspace_id: lease.workspace_id,
                 mode: "publish",
                 commit_hash: source,
                 repo_path: lease.repo_path,
                 candidate_source: "immutable_object",
                 acquired_base_commit: lease.base_commit,
                 expected_tree_oid: descriptor["expected_tree_oid"],
                 candidate_materialization_digest: digest,
                 validation_resource_id: materialized["resource_id"],
                 evidence_ref: materialized["hidden_ref"],
                 candidate_materialization: descriptor,
                 require_candidate_binding: true
               },
               context(task_id, principal_id, server)
             )

    assert published.status == "removed"
    assert published.published_commit == source
    assert git!(lease.repo_path, ["rev-parse", published.evidence_ref]) == source
    assert git!(lease.repo_path, ["rev-parse", lease.branch]) == lease.base_commit
  end

  test "security regression: descriptor publication cannot fall back without its binding" do
    base_params = %{
      workspace_id: "ws_descriptor_publication",
      mode: "publish",
      commit_hash: String.duplicate("a", 40),
      require_candidate_binding: true
    }

    assert {:error, :incomplete_immutable_review_binding} =
             Workspace.Release.run(
               Map.put(base_params, :candidate_source, "immutable_object"),
               %{}
             )

    assert {:error, :incomplete_immutable_review_binding} =
             Workspace.Release.run(base_params, %{})
  end

  defp params(lease, descriptor, digest) do
    %{
      workspace_id: lease.workspace_id,
      candidate_materialization: descriptor,
      pinned_descriptor_digest: digest,
      candidate_materialization_digest: digest,
      source_commit_oid: descriptor["source_commit_oid"],
      expected_tree_oid: descriptor["expected_tree_oid"],
      acquired_base_commit: lease.base_commit,
      materialize_window: 0
    }
  end

  defp start_materialized_owner(
         parent,
         server,
         repo,
         worktree_base_dir,
         task_id,
         principal_id
       ) do
    spawn(fn ->
      result =
        with {:ok, lease} <-
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: "test/g5d-resume-#{System.unique_integer([:positive])}",
                   worktree_base_dir: worktree_base_dir,
                   task_id: task_id,
                   principal_id: principal_id
                 },
                 server: server
               ) do
          {source, descriptor, _before} =
            commit_regular_add(lease.worktree_path, lease.repo_path, lease.base_commit)

          git!(lease.worktree_path, ["reset", "--hard", lease.base_commit])
          {:ok, digest} = CandidateMaterialization.digest(descriptor)

          with {:ok, materialized} <-
                 Materialize.run(
                   params(lease, descriptor, digest),
                   context(task_id, principal_id, server)
                 ) do
            {:ok,
             %{
               lease: lease,
               source: source,
               descriptor: descriptor,
               digest: digest,
               materialized: materialized
             }}
          end
        end

      send(parent, {:materialized_owner_ready, self(), result})
      receive do: (:stop -> :ok)
    end)
  end

  defp context(task_id, principal_id, server) do
    %{
      "session.task_id" => task_id,
      :agent_id => principal_id,
      :workspace_registry => server,
      :server => server
    }
  end

  defp commit_regular_add(worktree, repo, base) do
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, "lib/a.ex"), "defmodule A do\nend\n")
    git!(worktree, ["add", "lib/a.ex"])
    git!(worktree, ["commit", "-m", "add a"])
    source = git!(worktree, ["rev-parse", "HEAD"])
    descriptor = descriptor_between(repo, base, source)
    {source, descriptor, worktree_snapshot(worktree)}
  end

  defp descriptor_between(repo, base, source) do
    {:ok, base_listing} = Git.ls_tree_z(repo, base)
    {:ok, source_listing} = Git.ls_tree_z(repo, source)
    {:ok, base_manifest} = BlobManifest.parse_ls_tree_z(base_listing)
    {:ok, source_manifest} = BlobManifest.parse_ls_tree_z(source_listing)
    {:ok, changed} = BlobManifest.diff_blob_manifests(base_manifest, source_manifest)
    {:ok, tree} = Git.commit_tree_oid(repo, source)
    by_path = Map.new(source_manifest, &{&1.path, &1})

    entries =
      Enum.map(changed, fn path ->
        entry = Map.fetch!(by_path, path)
        %{"path" => entry.path, "blob_oid" => entry.oid, "mode" => mode_int(entry.mode)}
      end)

    %{
      "source_commit_oid" => source,
      "expected_tree_oid" => tree,
      "entries" => entries
    }
  end

  defp mode_int("100644"), do: 100_644
  defp mode_int("100755"), do: 100_755

  defp worktree_snapshot(worktree) do
    %{
      head: git!(worktree, ["rev-parse", "HEAD"]),
      status: git!(worktree, ["status", "--porcelain", "-z"]),
      index: git!(worktree, ["write-tree"])
    }
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:arbor_actions, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:arbor_actions, key, value)

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 1 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 1), do: assert(fun.())
end
