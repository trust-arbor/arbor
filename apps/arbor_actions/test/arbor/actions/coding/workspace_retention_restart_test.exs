defmodule Arbor.Actions.Coding.ControllableRetentionStore do
  @moduledoc false
  # Deterministic Persistence.Store double for journal write/delete failure tests.
  # Modes: :ok | :fail_put | :fail_delete | :fail_list | :fail_get |
  #        {:fail_active_put_after, (() -> term())}
  use GenServer

  def child_spec(opts) do
    name = Keyword.fetch!(opts, :name)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5_000
    }
  end

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
  def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
  def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})
  def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
  def exists?(key, opts), do: match?({:ok, _}, get(key, opts))
  def durability_class(_opts), do: :node_restart

  def set_mode(name, mode), do: GenServer.call(name, {:set_mode, mode})
  def release_put(name), do: GenServer.call(name, :release_put)
  def release_list(name), do: GenServer.call(name, :release_list)
  def seed(name, key, value), do: GenServer.call(name, {:seed, key, value})
  def entries(name), do: GenServer.call(name, :entries)

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       mode: Keyword.get(opts, :mode, :ok),
       pending_put: nil,
       pending_list: nil
     }}
  end

  @impl true
  def handle_call({:set_mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}

  def handle_call({:seed, key, value}, _from, state) do
    {:reply, :ok, %{state | entries: Map.put(state.entries, key, value)}}
  end

  def handle_call(:entries, _from, state), do: {:reply, state.entries, state}

  def handle_call({:put, _key, _value}, _from, %{mode: :fail_put} = state) do
    {:reply, {:error, :injected_put_failure}, state}
  end

  def handle_call(
        {:put, key, value},
        _from,
        %{mode: {:fail_active_put_after, callback}} = state
      )
      when is_function(callback, 0) do
    lifecycle = Map.get(value, "lifecycle") || Map.get(value, :lifecycle)

    if lifecycle == "active" do
      callback.()
      {:reply, {:error, :injected_active_put_failure}, state}
    else
      {:reply, :ok, %{state | entries: Map.put(state.entries, key, value)}}
    end
  end

  def handle_call({:put, key, value}, from, %{mode: {:hold_put, observer}} = state)
      when is_pid(observer) do
    send(observer, {:retention_put_held, key, value})

    {:noreply,
     %{state | entries: Map.put(state.entries, key, value), pending_put: from, mode: :ok}}
  end

  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | entries: Map.put(state.entries, key, value)}}
  end

  def handle_call(:release_put, _from, %{pending_put: pending} = state)
      when not is_nil(pending) do
    GenServer.reply(pending, :ok)
    {:reply, :ok, %{state | pending_put: nil}}
  end

  def handle_call(:release_put, _from, state), do: {:reply, :ok, state}

  def handle_call(:release_list, _from, %{pending_list: pending} = state)
      when not is_nil(pending) do
    GenServer.reply(pending, {:ok, Map.keys(state.entries) |> Enum.sort()})
    {:reply, :ok, %{state | pending_list: nil}}
  end

  def handle_call(:release_list, _from, state), do: {:reply, :ok, state}

  def handle_call({:get, _key}, _from, %{mode: :fail_get} = state) do
    {:reply, {:error, :injected_get_failure}, state}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.entries, key) do
      {:ok, value} -> {:reply, {:ok, value}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, _key}, _from, %{mode: :fail_delete} = state) do
    {:reply, {:error, :injected_delete_failure}, state}
  end

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | entries: Map.delete(state.entries, key)}}
  end

  def handle_call(:list, _from, %{mode: :fail_list} = state) do
    {:reply, {:error, :injected_list_failure}, state}
  end

  def handle_call(:list, from, %{mode: {:hold_list, observer}} = state)
      when is_pid(observer) do
    send(observer, :retention_list_held)
    {:noreply, %{state | pending_list: from, mode: :ok}}
  end

  def handle_call(:list, _from, state) do
    {:reply, {:ok, Map.keys(state.entries) |> Enum.sort()}, state}
  end
end

defmodule Arbor.Actions.Coding.WorkspaceRetentionRestartTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Coding.ControllableRetentionStore
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Coding.WorkspaceRetentionDurableStore
  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: Core
  alias Arbor.Actions.Config
  alias Arbor.Persistence
  alias Arbor.Persistence.Store.ETS, as: StoreETS

  @moduletag :slow
  @moduletag :integration

  describe "security regression: retained workspace restart durability" do
    test "dirty, untracked, and committed state survives registry restart with exact task+principal",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-reactivate"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-restart-#{System.unique_integer([:positive])}"
      principal_id = "agent-restart-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "untracked.txt"), "preserve\n")
      File.write!(Path.join(lease.worktree_path, "committed.txt"), "commit\n")
      git!(lease.worktree_path, ["add", "committed.txt"])
      git!(lease.worktree_path, ["commit", "-m", "retained commit"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, backend, lease.workspace_id)

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      assert retained_count(server2) == 1

      assert {:ok, reactivated} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert reactivated.workspace_id == lease.workspace_id
      assert reactivated.active
      assert reactivated.ownership == "owned"
      assert File.read!(Path.join(reactivated.worktree_path, "untracked.txt")) == "preserve\n"
      assert git!(reactivated.worktree_path, ["rev-parse", "HEAD"]) == head
      assert git!(reactivated.worktree_path, ["show", "HEAD:committed.txt"]) == "commit"
      # Crash consistency: durable marker remains throughout active ownership.
      assert durable_marker?(store_name, backend, lease.workspace_id)

      assert {:ok, _} = release(server2, reactivated.workspace_id, :remove)
      refute durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "wrong task or principal remains denied after restart", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-authz"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-owner-#{System.unique_integer([:positive])}"
      principal_id = "agent-owner-#{System.unique_integer([:positive])}"
      parent = self()

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "secret.txt"), "must stay\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      spawn(fn ->
        result =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: branch,
              worktree_base_dir: base,
              task_id: "task-other",
              principal_id: principal_id,
              workspace_id: lease.workspace_id,
              create_worktree: fn _, _, _ ->
                send(parent, :create_must_not_run)
                {:error, :unexpected_create}
              end
            },
            server: server2
          )

        send(parent, {:wrong_task, result})
      end)

      assert_receive {:wrong_task, {:error, :retained_workspace_not_authorized}}, 2_000

      spawn(fn ->
        result =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: branch,
              worktree_base_dir: base,
              task_id: task_id,
              principal_id: "agent-other",
              workspace_id: lease.workspace_id,
              create_worktree: fn _, _, _ ->
                send(parent, :create_must_not_run)
                {:error, :unexpected_create}
              end
            },
            server: server2
          )

        send(parent, {:wrong_principal, result})
      end)

      assert_receive {:wrong_principal, {:error, :retained_workspace_not_authorized}}, 2_000
      refute_receive :create_must_not_run, 100
      assert File.read!(Path.join(lease.worktree_path, "secret.txt")) == "must stay\n"
      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert retained_count(server2) == 1
    end

    test "expired valid record cleans only after identity revalidation", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-ttl-clean"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-ttl-#{System.unique_integer([:positive])}"
      principal_id = "agent-ttl-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(1_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      path = lease.worktree_path
      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, backend, lease.workspace_id)

      stop_registry(server)
      # Hydrate with already-past absolute expiry so cleanup runs immediately.
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, record} = Persistence.get(store_name, backend, key)

      past =
        record
        |> stringify_keys()
        |> Map.put(
          "expires_at",
          DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))
        )

      assert :ok = Persistence.put(store_name, backend, key, ensure_closed_record(past, lease))

      _server2 = start_registry(1_000, retention_journal: {store_name, backend})

      assert_eventually(
        fn ->
          refute File.dir?(path)
          refute durable_marker?(store_name, backend, lease.workspace_id)
        end,
        200
      )
    end

    test "replaced path/inode or changed Git registration is not deleted or reactivated", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-identity-mismatch"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-id-#{System.unique_integer([:positive])}"
      principal_id = "agent-id-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      path = lease.worktree_path
      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, backend, lease.workspace_id)

      # Replace directory inode while keeping the path string.
      File.rm_rf!(path)
      File.mkdir_p!(path)
      File.write!(Path.join(path, "imposter.txt"), "not original\n")

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})
      assert retained_count(server2) == 1

      assert {:error, :retained_identity_mismatch} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert File.dir?(path)
      assert File.exists?(Path.join(path, "imposter.txt"))
      assert durable_marker?(store_name, backend, lease.workspace_id)

      # Force expiry generation while identity is mismatched — must not delete.
      force_retained_expired(server2)
      {target, generation} = retained_target_and_generation(server2)
      send(server_pid(server2), {:retained_expire, target, generation})
      Process.sleep(50)
      assert File.dir?(path)
      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert retained_count(server2) == 1
    end

    test "security regression: path replacement between validation and cleanup survives", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/cleanup-identity-race"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-race-#{System.unique_integer([:positive])}"
      principal_id = "agent-race-#{System.unique_integer([:positive])}"

      # Cleanup boundary: replace the path after outer validation would have
      # passed, then invoke the production identity-bound destroyer. The
      # destroyer must refuse and the replacement must survive.
      cleanup = fn retained ->
        path = retained.worktree_path
        File.rm_rf!(path)
        File.mkdir_p!(path)
        File.write!(Path.join(path, "survivor.txt"), "must-live\n")
        WorkspaceLeaseRegistry.remove_owned_retained_worktree(retained)
      end

      {store_name, backend} = start_journal_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup: cleanup
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      path = lease.worktree_path
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(server_pid(server), {:retained_expire, target, generation})

      survivor = Path.join(path, "survivor.txt")

      # Wait for the injected cleanup to materialize the survivor before reading.
      assert_eventually(
        fn ->
          assert File.dir?(path)
          assert File.exists?(survivor)
        end,
        100
      )

      assert File.read!(survivor) == "must-live\n"
      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert retained_count(server) == 1

      retained = retained_from_state(server)
      assert retained.retry_count >= 1 or retained.dormant == true
      assert File.read!(survivor) == "must-live\n"
    end

    test "reactivation crash evidence: marker refresh failure denies and leaves retained", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/reactivate-write-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-react-fail-#{System.unique_integer([:positive])}"
      principal_id = "agent-react-fail-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_controllable_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "wip.txt"), "wip\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, backend, lease.workspace_id)

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})
      assert retained_count(server2) == 1

      # Deterministic put failure for marker refresh — no process-kill races.
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_put)

      assert {:error, {:retention_journal_write_failed, :injected_put_failure}} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert retained_count(server2) == 1
      assert File.read!(Path.join(lease.worktree_path, "wip.txt")) == "wip\n"
      assert durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "marker delete failure schedules retries before dormancy", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/marker-delete-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-mdel-#{System.unique_integer([:positive])}"
      principal_id = "agent-mdel-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 2
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      path = lease.worktree_path
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      # Path settled; marker delete fails via injected store mode.
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_delete)
      _ = WorkspaceLeaseRegistry.remove_owned_retained_worktree(retained_from_state(server))
      refute File.dir?(path)

      # Force the absolute deadline into the past so the expire message settles
      # rather than rescheduling a still-future TTL.
      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(server_pid(server), {:retained_expire, target, generation})

      assert_eventually(
        fn ->
          assert retained_count(server) == 1
          refute File.dir?(path)
          retained = retained_from_state(server)
          # Pre-reserved attempt count; not yet exhausted (limit 2).
          assert retained.retry_count == 1
          assert retained.dormant == false
          assert match?({:marker_delete_failed, _}, retained.cleanup_failure)
        end,
        50
      )

      # Second reserved attempt still fails delete → count 2, still schedulable or dormant
      # depending on post-attempt limit check (count >= limit → dormant).
      force_retained_expired(server)
      {target2, generation2} = retained_target_and_generation(server)
      send(server_pid(server), {:retained_expire, target2, generation2})

      assert_eventually(
        fn ->
          retained = retained_from_state(server)
          assert retained.retry_count == 2
          assert retained.dormant == true
          assert durable_marker?(store_name, backend, lease.workspace_id)
        end,
        50
      )
    end

    test "corrupt journal poisons registry and blocks fresh allocation", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-corrupt"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-corrupt-#{System.unique_integer([:positive])}"
      principal_id = "agent-corrupt-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "keep.txt"), "keep\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert :ok = Persistence.put(store_name, backend, key, %{"not" => "a valid record"})

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      assert retained_count(server2) == 0
      assert journal_poisoned?(server2)
      assert File.read!(Path.join(lease.worktree_path, "keep.txt")) == "keep\n"

      parent = self()

      spawn(fn ->
        result =
          WorkspaceLeaseRegistry.acquire(
            %{
              repo_path: repo,
              branch: branch,
              worktree_base_dir: base,
              task_id: task_id,
              principal_id: principal_id,
              workspace_id: lease.workspace_id,
              create_worktree: fn _, _, _ ->
                send(parent, :create_must_not_run)
                {:error, :unexpected_create}
              end
            },
            server: server2
          )

        send(parent, {:after_corrupt, result})
      end)

      assert_receive {:after_corrupt, {:error, :retention_journal_unavailable}}, 2_000
      refute_receive :create_must_not_run, 100
      assert File.read!(Path.join(lease.worktree_path, "keep.txt")) == "keep\n"

      huge = String.duplicate("x", 5_000)

      assert {:error, :invalid_retention_string} =
               Core.encode_record(%{
                 workspace_id: "ws_oversized",
                 repo_path: huge,
                 worktree_path: "/tmp/x",
                 branch: "b",
                 base_commit: "abc",
                 ownership: "owned",
                 lifecycle: "retained",
                 runtime_id: "rt_test",
                 lstat_identity: %{
                   type: "directory",
                   major_device: 0,
                   minor_device: 0,
                   inode: 1
                 },
                 worktree_registration: %{path: "/tmp/x", head: "abc", branch: "b"},
                 expires_at: DateTime.utc_now()
               })
    end

    test "journal write and load failures fail closed", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-write-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-write-#{System.unique_integer([:positive])}"
      principal_id = "agent-write-#{System.unique_integer([:positive])}"

      # Deterministic put failure after a healthy hydrate (not a missing process).
      {store_name, backend} = start_controllable_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      :ok = ControllableRetentionStore.set_mode(store_name, :fail_put)

      assert {:error, {:retention_journal_write_failed, :injected_put_failure}} =
               release(server, lease.workspace_id, :retain)

      # Live authority preserved; worktree still present.
      assert active_count(server) == 1
      assert File.dir?(lease.worktree_path)
      assert retained_count(server) == 0

      # Unreadable/missing journal inventory poisons and blocks fresh allocate.
      server_poisoned =
        start_registry(60_000,
          retention_journal: {:missing_retention_store, StoreETS}
        )

      assert {:error, :retention_journal_unavailable} =
               acquire(server_poisoned, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:error, :retention_journal_unavailable} =
               WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id,
                 server: server_poisoned
               )
    end

    test "security regression: a journal that becomes unreadable blocks fresh allocation", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_controllable_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})
      parent = self()

      :ok = ControllableRetentionStore.set_mode(store_name, :fail_list)

      assert {:error, :retention_journal_unavailable} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: "test/runtime-journal-failure",
                   worktree_base_dir: base,
                   task_id: "task-runtime-journal",
                   principal_id: "agent-runtime-journal",
                   create_worktree: fn _, _, _ ->
                     send(parent, :create_must_not_run)
                     {:error, :unexpected_create}
                   end
                 },
                 server: server
               )

      refute_receive :create_must_not_run, 100
      assert active_count(server) == 0
      assert retained_count(server) == 0
    end

    test "crash window around retain leaves recoverable durable marker", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-crash-retain"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-crash-#{System.unique_integer([:positive])}"
      principal_id = "agent-crash-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "wip.txt"), "wip\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, backend, lease.workspace_id)

      # Simulate crash after durable write by killing the registry process.
      stop_registry(server)
      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert File.read!(Path.join(lease.worktree_path, "wip.txt")) == "wip\n"

      server2 = start_registry(60_000, retention_journal: {store_name, backend})
      assert retained_count(server2) == 1

      assert {:ok, reactivated} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert File.read!(Path.join(reactivated.worktree_path, "wip.txt")) == "wip\n"
      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert {:ok, _} = release(server2, reactivated.workspace_id, :remove)
    end

    test "owner-death journaling persists durable marker", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/owner-death-journal"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-od-#{System.unique_integer([:positive])}"
      principal_id = "agent-od-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})
      parent = self()

      owner_pid =
        spawn(fn ->
          result =
            WorkspaceLeaseRegistry.acquire(
              %{
                repo_path: repo,
                branch: branch,
                worktree_base_dir: base,
                task_id: task_id,
                principal_id: principal_id
              },
              server: server
            )

          send(parent, {:acquired, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:acquired, {:ok, lease}}, 3_000
      File.write!(Path.join(lease.worktree_path, "od.txt"), "owner-death\n")
      {:ok, marker_key} = Core.record_key(lease.workspace_id)
      assert {:ok, initial_marker} = Persistence.get(store_name, backend, marker_key)

      assert (Map.get(initial_marker, "lifecycle") || Map.get(initial_marker, :lifecycle)) ==
               "active"

      ref = Process.monitor(owner_pid)
      Process.exit(owner_pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^owner_pid, _} -> :ok
      after
        2_000 -> flunk("owner did not die")
      end

      assert_eventually(
        fn ->
          assert durable_marker?(store_name, backend, lease.workspace_id)
          assert retained_count(server) == 1
          assert {:ok, [^marker_key]} = Persistence.list(store_name, backend)
          assert {:ok, retained_marker} = Persistence.get(store_name, backend, marker_key)

          assert (Map.get(retained_marker, "lifecycle") ||
                    Map.get(retained_marker, :lifecycle)) == "retained"
        end,
        100
      )

      assert File.read!(Path.join(lease.worktree_path, "od.txt")) == "owner-death\n"

      assert {:ok, reactivated} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert reactivated.ownership == "owned"
      assert File.read!(Path.join(reactivated.worktree_path, "od.txt")) == "owner-death\n"
    end

    test "reused workspace behavior is unchanged with journal enabled", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/restart-reused"
      base = Path.join(tmp_dir, "worktrees")
      path = expected_worktree_path(base, branch)
      git!(repo, ["branch", branch])
      git!(repo, ["worktree", "add", path, branch])

      {store_name, backend} = start_journal_store()
      server = start_registry(50, retention_journal: {store_name, backend})

      assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
      assert lease.ownership == "reused"
      File.write!(Path.join(path, "keep.txt"), "keep\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert retained_state(server) == {[], []}
      refute durable_marker?(store_name, backend, lease.workspace_id)

      Process.sleep(100)
      assert File.dir?(path)
      assert File.exists?(Path.join(path, "keep.txt"))

      # Restart must not invent a retained journal record for reused paths.
      stop_registry(server)
      server2 = start_registry(50, retention_journal: {store_name, backend})
      assert retained_state(server2) == {[], []}
      assert File.dir?(path)
    end

    test "security regression: initial active marker is durable before owned acquire succeeds", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/initial-active-marker"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-initial-active"
      principal_id = "agent-initial-active"
      runtime_id = "rt_initial_active"
      {store_name, backend} = start_controllable_store()
      parent = self()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      :ok = ControllableRetentionStore.set_mode(store_name, {:hold_put, self()})

      owner =
        spawn(fn ->
          result =
            acquire(server, repo, branch, tmp_dir, base,
              task_id: task_id,
              principal_id: principal_id
            )

          send(parent, {:initial_active_acquire_reply, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:retention_put_held, key, held_marker}, 3_000
      refute_receive {:initial_active_acquire_reply, _}, 100

      assert (Map.get(held_marker, "lifecycle") || Map.get(held_marker, :lifecycle)) ==
               "creating"

      assert Map.has_key?(ControllableRetentionStore.entries(store_name), key)
      :ok = ControllableRetentionStore.release_put(store_name)
      assert_receive {:initial_active_acquire_reply, {:ok, lease}}, 3_000

      assert {:ok, ^key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker} = Persistence.get(store_name, backend, key)
      assert (Map.get(marker, "lifecycle") || Map.get(marker, :lifecycle)) == "active"
      assert (Map.get(marker, "runtime_id") || Map.get(marker, :runtime_id)) == runtime_id
      assert (Map.get(marker, "task_id") || Map.get(marker, :task_id)) == task_id

      assert (Map.get(marker, "principal_id") || Map.get(marker, :principal_id)) ==
               principal_id

      assert active_count(server) == 1
      assert retained_count(server) == 0

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert Map.keys(ControllableRetentionStore.entries(store_name)) == [key]
      assert {:ok, retained_marker} = Persistence.get(store_name, backend, key)

      assert (Map.get(retained_marker, "lifecycle") || Map.get(retained_marker, :lifecycle)) ==
               "retained"

      assert {:ok, rebound} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(rebound.workspace_id, :remove, %{
                 server: server,
                 task_id: task_id,
                 principal_id: principal_id
               })

      refute Map.has_key?(ControllableRetentionStore.entries(store_name), key)
      send(owner, :stop)
    end

    test "security regression: failed active put preserves creating blocker across restart", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/creating-blocker-restart"
      base = Path.join(tmp_dir, "worktrees")
      path = expected_worktree_path(base, branch)
      workspace_id = "ws_creating_blocker_#{System.unique_integer([:positive])}"
      task_id = "task-creating-blocker"
      principal_id = "agent-creating-blocker"
      {store_name, backend} = start_controllable_store()
      parent = self()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_creating_blocker"
        )

      :ok =
        ControllableRetentionStore.set_mode(store_name, {
          :fail_active_put_after,
          fn ->
            File.rm_rf!(path)
            File.mkdir_p!(path)
            File.write!(Path.join(path, "survivor.txt"), "must-live\n")
            send(parent, :active_marker_replaced)
          end
        })

      assert {:error, {:retention_journal_write_failed, :injected_active_put_failure}} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert_receive :active_marker_replaced, 2_000
      assert File.read!(Path.join(path, "survivor.txt")) == "must-live\n"
      assert active_count(server) == 0
      assert retained_count(server) == 0
      assert map_size(:sys.get_state(server_pid(server)).retention_blockers) == 1

      {:ok, key} = Core.record_key(workspace_id)
      assert {:ok, creating_marker} = Persistence.get(store_name, backend, key)

      assert (Map.get(creating_marker, "lifecycle") || Map.get(creating_marker, :lifecycle)) ==
               "creating"

      :ok = ControllableRetentionStore.set_mode(store_name, :ok)
      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      state2 = :sys.get_state(server_pid(server2))
      assert map_size(state2.leases) == 0
      assert map_size(state2.retained_by_id) == 0
      assert map_size(state2.retention_blockers) == 1
      assert is_nil(Map.get(hd(Map.values(state2.retention_blockers)), :expiry_ref))
      assert durable_marker?(store_name, backend, workspace_id)
      assert File.exists?(Path.join(path, "survivor.txt"))

      assert {:ok, %{lifecycle: "creating", dormant: true}} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.inspect_lease(workspace_id, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: "agent-creating-blocker-alternate"
               })

      assert {:error, :retention_creation_blocked} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:error, :retention_creation_blocked} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: "ws_creating_alternate",
                 task_id: "task-creating-alternate",
                 principal_id: "agent-creating-alternate"
               )

      assert {:error, :retention_creation_blocked} =
               WorkspaceLeaseRegistry.release(workspace_id, :remove, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert durable_marker?(store_name, backend, workspace_id)
      assert File.exists?(Path.join(path, "survivor.txt"))
    end

    test "create error settles pre-create intent after proving absence", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/create-error-settles-intent"
      base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_controllable_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:error, :injected_create_failure} =
               acquire(server, repo, branch, tmp_dir, base,
                 create_worktree: fn _repo, _branch, _params ->
                   {:error, :injected_create_failure}
                 end
               )

      assert ControllableRetentionStore.entries(store_name) == %{}
      assert map_size(:sys.get_state(server_pid(server)).retention_blockers) == 0
    end

    test "security regression: create error preserves intent when path or registration remains",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      real_base = Path.join(tmp_dir, "worktrees-real")
      aliased_base = Path.join(tmp_dir, "worktrees-alias")
      File.mkdir_p!(real_base)
      File.ln_s!(real_base, aliased_base)
      commit = git!(repo, ["rev-parse", "HEAD"])

      for {suffix, remaining} <- [{"path", :path}, {"registration", :registration}] do
        branch = "test/create-error-remains-#{suffix}"
        base = if remaining == :registration, do: aliased_base, else: real_base
        path = expected_worktree_path(base, branch)
        workspace_id = "ws_create_error_#{suffix}_#{System.unique_integer([:positive])}"
        {store_name, backend} = start_controllable_store()
        server = start_registry(60_000, retention_journal: {store_name, backend})

        assert {:error, :injected_create_failure} =
                 acquire(server, repo, branch, tmp_dir, base,
                   workspace_id: workspace_id,
                   create_worktree: fn _repo, _branch, _params ->
                     assert {:ok, ^path} =
                              Workspace.create_detached_worktree(repo, path, commit)

                     if remaining == :registration, do: File.rm_rf!(path)
                     {:error, :injected_create_failure}
                   end
                 )

        assert worktree_registered?(repo, path)

        if remaining == :registration do
          registered_paths =
            git!(repo, ["worktree", "list", "--porcelain"])
            |> String.split("\n", trim: true)
            |> Enum.filter(&String.starts_with?(&1, "worktree "))
            |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))

          assert Enum.any?(registered_paths, fn registered_path ->
                   registered_path != path and
                     Workspace.canonical_path_or_expanded(registered_path) ==
                       Workspace.canonical_path_or_expanded(path)
                 end)

          assert {:error, :detached_snapshot_cleanup_identity_required} =
                   Workspace.remove_detached_worktree(repo, path)
        end

        assert map_size(:sys.get_state(server_pid(server)).retention_blockers) == 1

        case remaining do
          :path ->
            assert File.dir?(path)

          :registration ->
            assert {:error, :enoent} = File.lstat(path)
        end

        assert durable_marker?(store_name, backend, workspace_id)

        _ =
          System.cmd("git", ["-C", repo, "worktree", "remove", "--force", path],
            stderr_to_stdout: true
          )

        _ = System.cmd("git", ["-C", repo, "worktree", "prune"], stderr_to_stdout: true)
      end
    end

    test "security regression: hydrated creation blocker matches canonical aliased target",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/hydrated-creation-alias"
      base = Path.join(tmp_dir, "worktrees")
      candidate_path = expected_worktree_path(base, branch)
      File.mkdir_p!(candidate_path)

      aliases = Path.join(tmp_dir, "creation-aliases")
      File.mkdir_p!(aliases)
      repo_alias = Path.join(aliases, "repo")
      worktree_alias = Path.join(aliases, "worktree")
      File.ln_s!(repo, repo_alias)
      File.ln_s!(candidate_path, worktree_alias)

      workspace_id = "ws_hydrated_creation_alias"
      {:ok, key} = Core.record_key(workspace_id)

      record = %{
        "schema_version" => 1,
        "workspace_id" => workspace_id,
        "task_id" => nil,
        "principal_id" => nil,
        "repo_path" => repo_alias,
        "worktree_path" => worktree_alias,
        "display_worktree_path" => worktree_alias,
        "branch" => branch,
        "base_commit" => nil,
        "ownership" => "pending",
        "lifecycle" => "creating",
        "runtime_id" => "rt_hydrated_creation_alias",
        "lstat_identity" => nil,
        "worktree_registration" => nil,
        "expires_at" => DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
        "retry_count" => 0
      }

      {store_name, backend} = start_controllable_store()
      :ok = ControllableRetentionStore.seed(store_name, key, record)
      server = start_registry(60_000, retention_journal: {store_name, backend})
      assert map_size(:sys.get_state(server_pid(server)).retention_blockers) == 1

      parent = self()

      assert {:error, :retention_creation_blocked} =
               acquire(server, repo, branch, tmp_dir, base,
                 create_worktree: fn _repo, _branch, _params ->
                   send(parent, :aliased_creation_blocker_create_ran)
                   {:error, :unexpected_create}
                 end
               )

      refute_receive :aliased_creation_blocker_create_ran
      assert durable_marker?(store_name, backend, workspace_id)
    end

    test "create intent delete failure remains a dormant blocker", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/create-intent-delete-failure"
      base = Path.join(tmp_dir, "worktrees")
      workspace_id = "ws_create_delete_failure"
      {store_name, backend} = start_controllable_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_delete)

      assert {:error, {:retention_journal_delete_failed, :injected_delete_failure}} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: workspace_id,
                 task_id: "task-create-delete-failure",
                 principal_id: "agent-create-delete-failure",
                 create_worktree: fn _repo, _branch, _params ->
                   {:error, :injected_create_failure}
                 end
               )

      assert durable_marker?(store_name, backend, workspace_id)
      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      assert map_size(:sys.get_state(server_pid(server2)).retention_blockers) == 1
      assert durable_marker?(store_name, backend, workspace_id)

      assert {:error, :retention_creation_blocked} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: workspace_id,
                 task_id: "task-create-delete-failure",
                 principal_id: "agent-create-delete-failure"
               )

      :ok = ControllableRetentionStore.set_mode(store_name, :ok)
    end

    test "security regression: fresh active full-incarnation recovery preserves dirty data and authority",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/initial-active-incarnation"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-initial-incarnation"
      principal_id = "agent-initial-incarnation"
      {store_name, backend} = start_journal_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_initial_old"
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "dirty.txt"), "preserve exact owner\n")
      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_initial_new"
        )

      assert retained_from_state(server2).lifecycle == :retained

      assert {:error, :retained_workspace_not_authorized} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: "agent-wrong"
               )

      assert File.read!(Path.join(lease.worktree_path, "dirty.txt")) ==
               "preserve exact owner\n"

      assert {:ok, rebound} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert File.read!(Path.join(rebound.worktree_path, "dirty.txt")) ==
               "preserve exact owner\n"

      assert {:ok, _} = release(server2, rebound.workspace_id, :remove)
    end

    test "security regression: one-sided task authority is rejected before create", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})
      parent = self()

      for {suffix, task_id, principal_id} <- [
            {"task-only", "task-only", nil},
            {"principal-only", nil, "agent-only"},
            {"task-with-blank-principal", "task-only", " \t\n"},
            {"blank-task-with-principal", " \t\n", "agent-only"}
          ] do
        assert {:error, :incomplete_task_principal} =
                 WorkspaceLeaseRegistry.acquire(
                   %{
                     repo_path: repo,
                     branch: "test/one-sided-#{suffix}",
                     worktree_base_dir: base,
                     task_id: task_id,
                     principal_id: principal_id,
                     create_worktree: fn _, _, _ ->
                       send(parent, :one_sided_create_ran)
                       {:error, :unexpected_create}
                     end
                   },
                   server: server
                 )
      end

      refute_receive :one_sided_create_ran, 100
      assert active_count(server) == 0
    end

    test "whitespace-only task and principal IDs normalize to absent", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/blank-authority-pair"
      base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: " \t",
                 principal_id: "\n "
               )

      stored = :sys.get_state(server_pid(server)).leases[lease.workspace_id]
      assert is_nil(stored.task_id)
      assert is_nil(stored.principal_id)
      assert {:ok, _} = release(server, lease.workspace_id, :remove)
    end

    test "explicit invalid workspace IDs are rejected before create", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})
      parent = self()

      for {suffix, workspace_id} <- [
            {"uppercase", "WS_UPPERCASE"},
            {"path", "ws/invalid"}
          ] do
        assert {:error, :invalid_workspace_id} =
                 WorkspaceLeaseRegistry.acquire(
                   %{
                     repo_path: repo,
                     branch: "test/invalid-workspace-id-#{suffix}",
                     workspace_id: workspace_id,
                     worktree_base_dir: base,
                     create_worktree: fn _, _, _ ->
                       send(parent, :invalid_workspace_create_ran)
                       {:error, :unexpected_create}
                     end
                   },
                   server: server
                 )
      end

      refute_receive :invalid_workspace_create_ran, 100
      assert active_count(server) == 0
    end

    test "full journal admits a known production reused worktree without a marker", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/full-production-reused"
      base = Path.join(tmp_dir, "worktrees")
      path = expected_worktree_path(base, branch)
      git!(repo, ["branch", branch])
      git!(repo, ["worktree", "add", path, branch])
      {store_name, backend} = start_controllable_store()

      for i <- 1..Core.max_records() do
        workspace_id = "ws_full_reused_#{i}"
        {:ok, key} = Core.record_key(workspace_id)

        :ok =
          ControllableRetentionStore.seed(
            store_name,
            key,
            full_fixture_record(i, workspace_id, repo)
          )
      end

      server = start_registry(120_000, retention_journal: {store_name, backend})

      assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
      assert lease.ownership == "reused"
      assert lease.worktree_path == path_alias(path)
      assert map_size(ControllableRetentionStore.entries(store_name)) == Core.max_records()

      assert {:ok, _} = release(server, lease.workspace_id, :remove)
      assert File.dir?(path)
      git!(repo, ["worktree", "remove", "--force", path])
    end

    test "security regression: full journal denies create before Git side effects", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base = Path.join(tmp_dir, "worktrees")
      {store_name, backend} = start_controllable_store()

      for i <- 1..Core.max_records() do
        workspace_id = "ws_full_#{i}"
        {:ok, key} = Core.record_key(workspace_id)

        :ok =
          ControllableRetentionStore.seed(store_name, key, full_fixture_record(i, nil, repo))
      end

      server = start_registry(120_000, retention_journal: {store_name, backend})
      parent = self()

      assert {:error, :retention_record_limit_exceeded} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: "test/full-owned-denied",
                   worktree_base_dir: base,
                   task_id: "task-full",
                   principal_id: "agent-full",
                   create_worktree: fn _, _, _ ->
                     send(parent, :full_store_create_ran)
                     {:error, :unexpected_create}
                   end
                 },
                 server: server
               )

      refute_receive :full_store_create_ran, 100
      refute File.dir?(expected_worktree_path(base, "test/full-owned-denied"))
      assert map_size(ControllableRetentionStore.entries(store_name)) == Core.max_records()
    end

    test "full journal refuses create when production reuse preflight races away", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/full-reuse-races-owned"
      base = Path.join(tmp_dir, "worktrees")
      path = expected_worktree_path(base, branch)
      git!(repo, ["branch", branch])
      git!(repo, ["worktree", "add", path, branch])
      {store_name, backend} = start_controllable_store()

      for i <- 1..Core.max_records() do
        workspace_id = "ws_full_race_#{i}"
        {:ok, key} = Core.record_key(workspace_id)

        :ok =
          ControllableRetentionStore.seed(
            store_name,
            key,
            full_fixture_record(i, workspace_id, repo)
          )
      end

      server = start_registry(120_000, retention_journal: {store_name, backend})
      :ok = ControllableRetentionStore.set_mode(store_name, {:hold_list, self()})
      parent = self()

      spawn(fn ->
        send(parent, {:full_race_result, acquire(server, repo, branch, tmp_dir, base)})
      end)

      assert_receive :retention_list_held, 3_000
      git!(repo, ["worktree", "remove", "--force", path])
      refute File.dir?(path)
      :ok = ControllableRetentionStore.release_list(store_name)

      assert_receive {:full_race_result, {:error, :reused_worktree_vanished}}, 5_000
      refute File.dir?(path)
      refute String.contains?(git!(repo, ["worktree", "list", "--porcelain"]), path)
      assert active_count(server) == 0
      assert map_size(ControllableRetentionStore.entries(store_name)) == Core.max_records()
    end

    test "security regression: post-start journal extra missing and get divergence deny create",
         %{
           tmp_dir: tmp_dir
         } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base = Path.join(tmp_dir, "worktrees")
      parent = self()

      {extra_store, extra_backend} = start_controllable_store()
      extra_server = start_registry(60_000, retention_journal: {extra_store, extra_backend})
      {:ok, extra_key} = Core.record_key("ws_post_start_extra")

      :ok =
        ControllableRetentionStore.seed(
          extra_store,
          extra_key,
          full_fixture_record(900, "ws_post_start_extra")
        )

      assert {:error, :retention_journal_unavailable} =
               WorkspaceLeaseRegistry.settle_task_workspaces("task-extra", "agent-extra",
                 server: extra_server
               )

      assert_allocation_denied_before_create(
        extra_server,
        repo,
        "test/post-start-extra",
        base,
        parent
      )

      {missing_store, missing_backend} = start_controllable_store()

      missing_server =
        start_registry(60_000, retention_journal: {missing_store, missing_backend})

      assert {:ok, active} =
               acquire(missing_server, repo, "test/post-start-missing-owner", tmp_dir, base,
                 task_id: "task-missing-owner",
                 principal_id: "agent-missing-owner"
               )

      {:ok, missing_key} = Core.record_key(active.workspace_id)
      :ok = Persistence.delete(missing_store, missing_backend, missing_key)

      assert {:error, :retention_journal_unavailable} =
               WorkspaceLeaseRegistry.settle_task_workspaces(
                 "task-missing-owner",
                 "agent-missing-owner",
                 server: missing_server
               )

      assert active_count(missing_server) == 1

      assert_allocation_denied_before_create(
        missing_server,
        repo,
        "test/post-start-missing",
        base,
        parent
      )

      {get_store, get_backend} = start_controllable_store()
      get_server = start_registry(60_000, retention_journal: {get_store, get_backend})

      assert {:ok, get_active} =
               acquire(get_server, repo, "test/post-start-get-owner", tmp_dir, base,
                 task_id: "task-get-owner",
                 principal_id: "agent-get-owner"
               )

      :ok = ControllableRetentionStore.set_mode(get_store, :fail_get)

      assert {:error, :retention_journal_unavailable} =
               WorkspaceLeaseRegistry.settle_task_workspaces(
                 "task-get-owner",
                 "agent-get-owner",
                 server: get_server
               )

      assert active_count(get_server) == 1

      assert_allocation_denied_before_create(
        get_server,
        repo,
        "test/post-start-get",
        base,
        parent
      )

      refute_receive :divergent_store_create_ran, 100

      :ok = ControllableRetentionStore.set_mode(get_store, :ok)

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(get_active.workspace_id, :remove, %{
                 server: get_server,
                 task_id: "task-get-owner",
                 principal_id: "agent-get-owner"
               })
    end
  end

  describe "production durable store backend" do
    test "persist, stop/restart store+registry, exact task+principal reactivation", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/prod-store-restart"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-prod-#{System.unique_integer([:positive])}"
      principal_id = "agent-prod-#{System.unique_integer([:positive])}"
      journal_path = Path.join(tmp_dir, "retention-journal")

      store_name = String.to_atom("prod_retention_#{System.unique_integer([:positive])}")

      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: journal_path},
        id: store_name
      )

      server =
        start_registry(60_000,
          retention_journal: {store_name, WorkspaceRetentionDurableStore}
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "untracked.txt"), "u\n")
      File.write!(Path.join(lease.worktree_path, "committed.txt"), "c\n")
      git!(lease.worktree_path, ["add", "committed.txt"])
      git!(lease.worktree_path, ["commit", "-m", "prod store commit"])
      head = git!(lease.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, WorkspaceRetentionDurableStore, lease.workspace_id)

      # Value representation is consistent after put (string-key JSON map).
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, value} = Persistence.get(store_name, WorkspaceRetentionDurableStore, key)
      assert is_map(value)
      assert Map.get(value, "ownership") == "owned" or Map.get(value, :ownership) == "owned"

      stop_registry(server)
      _ = stop_supervised(store_name)

      # Restart store + registry from the same durable root.
      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: journal_path},
        id: store_name
      )

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, WorkspaceRetentionDurableStore}
        )

      assert retained_count(server2) == 1

      assert {:ok, reactivated} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert reactivated.workspace_id == lease.workspace_id
      assert File.read!(Path.join(reactivated.worktree_path, "untracked.txt")) == "u\n"
      assert git!(reactivated.worktree_path, ["rev-parse", "HEAD"]) == head
      assert durable_marker?(store_name, WorkspaceRetentionDurableStore, lease.workspace_id)
    end

    test "owner death through durable restart preserves exact authority and removes cleanly", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/owner-death-durable-sequence"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-owner-death-durable"
      principal_id = "agent-owner-death-durable"
      journal_path = Path.join(tmp_dir, "owner-death-retention-journal")
      store_name = String.to_atom("owner_death_store_#{System.unique_integer([:positive])}")
      parent = self()

      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: journal_path},
        id: store_name
      )

      server =
        start_registry(60_000,
          retention_journal: {store_name, WorkspaceRetentionDurableStore},
          retention_runtime_id: "rt_owner_death_before_restart"
        )

      owner =
        spawn(fn ->
          result =
            acquire(server, repo, branch, tmp_dir, base,
              task_id: task_id,
              principal_id: principal_id
            )

          send(parent, {:durable_sequence_acquired, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:durable_sequence_acquired, {:ok, lease}}, 3_000
      File.write!(Path.join(lease.worktree_path, "dirty-sequence.txt"), "preserve me\n")

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}, 2_000

      assert_eventually(
        fn ->
          assert retained_count(server) == 1
          {:ok, key} = Core.record_key(lease.workspace_id)

          assert {:ok, marker} =
                   Persistence.get(store_name, WorkspaceRetentionDurableStore, key)

          assert (Map.get(marker, "lifecycle") || Map.get(marker, :lifecycle)) == "retained"
        end,
        100
      )

      stop_registry(server)
      _ = stop_supervised(store_name)

      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: journal_path},
        id: store_name
      )

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, WorkspaceRetentionDurableStore},
          retention_runtime_id: "rt_owner_death_after_restart"
        )

      before = retained_from_state(server2)
      {:ok, key} = Core.record_key(lease.workspace_id)

      assert {:ok, marker_before} =
               Persistence.get(store_name, WorkspaceRetentionDurableStore, key)

      assert {:error, :retained_workspace_not_authorized} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: "agent-wrong"
               )

      assert retained_from_state(server2) == before

      assert {:ok, ^marker_before} =
               Persistence.get(store_name, WorkspaceRetentionDurableStore, key)

      assert File.read!(Path.join(lease.worktree_path, "dirty-sequence.txt")) ==
               "preserve me\n"

      assert {:ok, reactivated} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert File.read!(Path.join(reactivated.worktree_path, "dirty-sequence.txt")) ==
               "preserve me\n"

      assert {:ok, _} = release(server2, reactivated.workspace_id, :remove)
      assert {:error, :enoent} = File.lstat(lease.worktree_path)
      refute durable_marker?(store_name, WorkspaceRetentionDurableStore, lease.workspace_id)

      refute String.contains?(
               git!(repo, ["worktree", "list", "--porcelain"]),
               lease.worktree_path
             )
    end

    test "duplicate JSON keys fail closed with exact poison", %{tmp_dir: tmp_dir} do
      journal_path = Path.join(tmp_dir, "dup-journal")
      store_name = String.to_atom("dup_store_#{System.unique_integer([:positive])}")

      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: journal_path},
        id: store_name
      )

      key = "retained:ws_dupkeys01"
      path = Path.join(journal_path, key <> ".json")
      File.chmod!(journal_path, 0o700)

      File.write!(
        path,
        ~s({"schema_version":1,"schema_version":2,"workspace_id":"ws_dupkeys01"})
      )

      File.chmod!(path, 0o600)

      _ = stop_supervised(store_name)

      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: journal_path},
        id: store_name
      )

      assert {:error, {:retention_store_poisoned, _}} =
               Persistence.list(store_name, WorkspaceRetentionDurableStore)

      assert {:error, {:retention_store_poisoned, _}} =
               Persistence.get(store_name, WorkspaceRetentionDurableStore, key)

      assert {:error, :unexpected_retention_keys} =
               Core.decode_record(%{
                 "schema_version" => 1,
                 "workspace_id" => "ws_nested",
                 "task_id" => nil,
                 "principal_id" => nil,
                 "repo_path" => "/tmp/r",
                 "worktree_path" => "/tmp/w",
                 "display_worktree_path" => "/tmp/w",
                 "branch" => "main",
                 "base_commit" => "abc",
                 "ownership" => "owned",
                 "lifecycle" => "retained",
                 "runtime_id" => "rt_test",
                 "lstat_identity" => %{
                   "type" => "directory",
                   "major_device" => 0,
                   "minor_device" => 0,
                   "inode" => 1,
                   "extra" => "nope"
                 },
                 "worktree_registration" => %{
                   "path" => "/tmp/w",
                   "head" => "abc",
                   "branch" => "main"
                 },
                 "expires_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "retry_count" => 0
               })

      assert {:error, :duplicate_key_alias} =
               Core.decode_record(%{
                 :schema_version => 1,
                 "schema_version" => 1,
                 "workspace_id" => "ws_alias",
                 "task_id" => nil,
                 "principal_id" => nil,
                 "repo_path" => "/tmp/r",
                 "worktree_path" => "/tmp/w",
                 "display_worktree_path" => "/tmp/w",
                 "branch" => "main",
                 "base_commit" => "abc",
                 "ownership" => "owned",
                 "lifecycle" => "retained",
                 "runtime_id" => "rt_test",
                 "lstat_identity" => %{
                   "type" => "directory",
                   "major_device" => 0,
                   "minor_device" => 0,
                   "inode" => 1
                 },
                 "worktree_registration" => %{
                   "path" => "/tmp/w",
                   "head" => "abc",
                   "branch" => "main"
                 },
                 "expires_at" => DateTime.to_iso8601(DateTime.utc_now()),
                 "retry_count" => 0
               })

      assert {:error, :duplicate_json_member} =
               Core.decode_json_bytes(~s({"a":1,"a":2}))
    end

    test "security regression: excessive file count poisons store before an empty inventory can be admitted",
         %{
           tmp_dir: tmp_dir
         } do
      journal_path = Path.join(tmp_dir, "overflow-journal")
      File.mkdir_p!(journal_path)
      File.chmod!(journal_path, 0o700)

      max = Core.max_records() * 4 + 5

      for i <- 1..max do
        File.write!(Path.join(journal_path, "noise-#{i}.json"), "{}")
      end

      store_name = String.to_atom("overflow_store_#{System.unique_integer([:positive])}")

      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: journal_path},
        id: store_name
      )

      assert {:error, {:retention_store_poisoned, :retention_inventory_oversized}} =
               Persistence.list(store_name, WorkspaceRetentionDurableStore)

      assert {:error, {:retention_store_poisoned, :retention_inventory_oversized}} =
               Persistence.put(store_name, WorkspaceRetentionDurableStore, "retained:ws_x", %{})
    end

    test "future expiry is clamped and persisted so second restart cannot regain far future",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/future-expiry"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-future-#{System.unique_integer([:positive])}"
      principal_id = "agent-future-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(1_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, record} = Persistence.get(store_name, backend, key)

      far = DateTime.add(DateTime.utc_now(), 365 * 24 * 60 * 60, :second)

      mutated =
        record
        |> stringify_keys()
        |> Map.put("expires_at", DateTime.to_iso8601(far))
        |> Map.put("ownership", "owned")

      assert :ok = Persistence.put(store_name, backend, key, ensure_closed_record(mutated, lease))

      stop_registry(server)
      server2 = start_registry(1_000, retention_journal: {store_name, backend})
      assert retained_count(server2) == 1

      retained = hd(Map.values(:sys.get_state(server_pid(server2)).retained_by_id))
      remaining = DateTime.diff(retained.expires_at, DateTime.utc_now(), :millisecond)
      assert remaining <= 1_000 + 50
      assert remaining <= Config.workspace_retention_max_ttl_ms()

      # Bounded absolute expiry must be durable before hot admission.
      assert {:ok, rewritten} = Persistence.get(store_name, backend, key)
      rewritten_iso = Map.get(rewritten, "expires_at") || Map.get(rewritten, :expires_at)
      {:ok, rewritten_dt, _} = DateTime.from_iso8601(rewritten_iso)
      assert DateTime.diff(rewritten_dt, DateTime.utc_now(), :millisecond) <= 1_000 + 100
      refute DateTime.diff(rewritten_dt, DateTime.utc_now(), :second) > 86_400

      stop_registry(server2)
      server3 = start_registry(1_000, retention_journal: {store_name, backend})
      assert retained_count(server3) == 1

      retained3 = hd(Map.values(:sys.get_state(server_pid(server3)).retained_by_id))
      remaining3 = DateTime.diff(retained3.expires_at, DateTime.utc_now(), :millisecond)
      assert remaining3 <= 1_000 + 50

      assert {:ok, again} = Persistence.get(store_name, backend, key)
      again_iso = Map.get(again, "expires_at") || Map.get(again, :expires_at)
      {:ok, again_dt, _} = DateTime.from_iso8601(again_iso)
      # Second restart must not regain the original year-scale expiry.
      assert DateTime.diff(again_dt, DateTime.utc_now(), :second) < 86_400
    end

    test "security regression: hydration canonicalizes aliased operational paths before admission",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/hydrate-path-alias"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-path-alias-#{System.unique_integer([:positive])}"
      principal_id = "agent-path-alias-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, record} = Persistence.get(store_name, backend, key)

      aliases = Path.join(tmp_dir, "retention-aliases")
      File.mkdir_p!(aliases)
      repo_alias = Path.join(aliases, "repo")
      worktree_alias = Path.join(aliases, "worktree")
      File.ln_s!(lease.repo_path, repo_alias)
      File.ln_s!(lease.worktree_path, worktree_alias)

      aliased = retention_record_with_paths(record, lease, repo_alias, worktree_alias)
      assert :ok = Persistence.put(store_name, backend, key, aliased)

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      retained = retained_from_state(server2)
      assert retained.repo_path == lease.repo_path
      assert retained.worktree_path == lease.worktree_path
      assert retained.worktree_registration.path == lease.worktree_path

      # Canonical durable evidence is committed before the hot entry is admitted.
      assert {:ok, rewritten} = Persistence.get(store_name, backend, key)

      rewritten_registration =
        Map.get(rewritten, "worktree_registration") ||
          Map.get(rewritten, :worktree_registration)

      assert (Map.get(rewritten, "repo_path") || Map.get(rewritten, :repo_path)) ==
               lease.repo_path

      assert (Map.get(rewritten, "worktree_path") || Map.get(rewritten, :worktree_path)) ==
               lease.worktree_path

      assert (Map.get(rewritten_registration, "path") ||
                Map.get(rewritten_registration, :path)) == lease.worktree_path

      assert (Map.get(rewritten, "lifecycle") || Map.get(rewritten, :lifecycle)) == "retained"

      assert {:ok, reactivated} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert reactivated.worktree_path == lease.worktree_path
      assert {:ok, _} = release(server2, reactivated.workspace_id, :remove)
      refute File.dir?(lease.worktree_path)
      refute durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "security regression: path canonicalization rewrite failure admits no hot state", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/hydrate-path-alias-write-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-path-fail-#{System.unique_integer([:positive])}"
      principal_id = "agent-path-fail-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_controllable_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, record} = Persistence.get(store_name, backend, key)

      alias_root = Path.join(tmp_dir, "failed-rewrite-aliases")
      File.mkdir_p!(alias_root)
      repo_alias = Path.join(alias_root, "repo")
      worktree_alias = Path.join(alias_root, "worktree")
      File.ln_s!(lease.repo_path, repo_alias)
      File.ln_s!(lease.worktree_path, worktree_alias)

      aliased = retention_record_with_paths(record, lease, repo_alias, worktree_alias)
      assert :ok = Persistence.put(store_name, backend, key, aliased)
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_put)

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      assert retained_count(server2) == 0
      assert journal_poisoned?(server2)
      assert File.dir?(lease.worktree_path)
      assert {:ok, ^aliased} = Persistence.get(store_name, backend, key)

      assert {:error, :retention_journal_unavailable} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )
    end

    test "HEAD commit after reactivation is not ownership identity; restart still works", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/head-not-identity"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-head-#{System.unique_integer([:positive])}"
      principal_id = "agent-head-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "note.txt"), "v1\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, backend, lease.workspace_id)

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, reactivated} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      # Resumed worker commits — HEAD mutates while path/lstat/branch stay.
      File.write!(Path.join(reactivated.worktree_path, "note.txt"), "v2\n")
      git!(reactivated.worktree_path, ["add", "note.txt"])
      git!(reactivated.worktree_path, ["commit", "-m", "post-reactivation commit"])
      new_head = git!(reactivated.worktree_path, ["rev-parse", "HEAD"])

      assert {:ok, _} = release(server2, reactivated.workspace_id, :retain)

      stop_registry(server2)
      server3 = start_registry(60_000, retention_journal: {store_name, backend})
      assert retained_count(server3) == 1

      assert {:ok, again} =
               acquire(server3, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert git!(again.worktree_path, ["rev-parse", "HEAD"]) == new_head
      assert File.read!(Path.join(again.worktree_path, "note.txt")) == "v2\n"
      assert durable_marker?(store_name, backend, lease.workspace_id)

      assert {:ok, _} = release(server3, again.workspace_id, :remove)
      refute File.dir?(again.worktree_path)
      refute durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "duplicate workspace targets poison hydrate with no partial hot state", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/dup-target"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-dup-#{System.unique_integer([:positive])}"
      principal_id = "agent-dup-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, record} = Persistence.get(store_name, backend, key)

      # Second durable id at a path-string alias of the same canonical target
      # (/var vs /private/var on macOS) must still collide.
      other_id = "ws_dup_target_other"
      {:ok, other_key} = Core.record_key(other_id)
      alias_worktree = path_alias(lease.worktree_path)
      alias_repo = path_alias(lease.repo_path)

      dup =
        record
        |> stringify_keys()
        |> Map.put("workspace_id", other_id)
        |> Map.put("worktree_path", alias_worktree)
        |> Map.put("display_worktree_path", alias_worktree)
        |> Map.put("repo_path", alias_repo)
        |> ensure_closed_record(%{
          workspace_id: other_id,
          repo_path: alias_repo,
          worktree_path: alias_worktree,
          branch: lease.branch,
          base_commit: lease.base_commit
        })

      assert :ok = Persistence.put(store_name, backend, other_key, dup)

      stop_registry(server)
      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      assert retained_count(server2) == 0
      assert journal_poisoned?(server2)

      assert {:error, :retention_journal_unavailable} =
               acquire(server2, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )
    end

    test "disabled journal still allows allocation (test seam)", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/journal-disabled"
      base = Path.join(tmp_dir, "worktrees")

      server = start_registry(60_000, retention_journal: :disabled)

      assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
      assert lease.active
      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert retained_count(server) == 1
    end

    test "security regression: malformed journal configuration poisons admission", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/journal-malformed"
      base = Path.join(tmp_dir, "worktrees")

      server =
        start_registry(60_000,
          retention_journal: %{store_name: "not-an-atom", backend: StoreETS}
        )

      assert journal_poisoned?(server)

      assert {:error, :retention_journal_unavailable} =
               acquire(server, repo, branch, tmp_dir, base)

      refute File.exists?(expected_worktree_path(base, branch))
    end

    test "security regression: unsupported journal state cannot acknowledge marker effects", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      base = Path.join(tmp_dir, "worktrees")

      persist_server = start_registry(60_000, retention_journal: :disabled)

      assert {:ok, persist_lease} =
               acquire(persist_server, repo, "test/journal-persist-catchall", tmp_dir, base)

      replace_journal_state(persist_server, %{status: :unsupported})

      assert {:error, :retention_identity_unavailable} =
               release(persist_server, persist_lease.workspace_id, :retain)

      assert active_count(persist_server) == 1
      assert retained_count(persist_server) == 0
      assert File.dir?(persist_lease.worktree_path)

      remove_repo = create_git_repo(Path.join(tmp_dir, "remove-repo"))
      {store_name, backend} = start_journal_store()
      remove_server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, remove_lease} =
               acquire(
                 remove_server,
                 remove_repo,
                 "test/journal-delete-catchall",
                 tmp_dir,
                 Path.join(tmp_dir, "remove-worktrees")
               )

      assert {:ok, _} = release(remove_server, remove_lease.workspace_id, :retain)

      assert {:ok, reactivated} =
               acquire(
                 remove_server,
                 remove_repo,
                 "test/journal-delete-catchall",
                 tmp_dir,
                 Path.join(tmp_dir, "remove-worktrees"),
                 workspace_id: remove_lease.workspace_id
               )

      replace_journal_state(remove_server, %{status: :unsupported})

      assert {:ok, result} = release(remove_server, reactivated.workspace_id, :remove)
      assert result.status == "removed"
      refute File.dir?(reactivated.worktree_path)
      assert durable_marker?(store_name, backend, reactivated.workspace_id)
      assert journal_poisoned?(remove_server)
      assert retained_count(remove_server) == 1
    end

    test "security regression: test env never starts the application-owned retention store" do
      # config/test.exs must fail-closed: never open ~/.arbor under MIX_ENV=test.
      refute Config.workspace_retention_journal_enabled?()
      assert Config.application_retention_journal() == :disabled
      refute Process.whereis(WorkspaceRetentionDurableStore)

      children = Arbor.Actions.Application.supervision_children()
      modules = Enum.map(children, &child_module/1)

      refute WorkspaceRetentionDurableStore in modules
      assert WorkspaceLeaseRegistry in modules

      registry_opts =
        Enum.find_value(children, fn
          {WorkspaceLeaseRegistry, opts} when is_list(opts) -> opts
          _ -> nil
        end)

      assert Keyword.get(registry_opts, :retention_journal) == :disabled
    end
  end

  describe "journal core bounds" do
    test "decode rejects unexpected keys, wrong schema, and non-owned provenance" do
      base = closed_fixture_record()

      assert {:error, :unsupported_schema_version} =
               Core.decode_record(Map.put(base, "schema_version", 99))

      assert {:error, :unexpected_retention_keys} =
               Core.decode_record(Map.put(base, "extra", "nope"))

      assert {:error, :invalid_ownership_provenance} =
               Core.decode_record(Map.put(base, "ownership", "reused"))

      assert {:error, :primary_checkout_not_retainable} =
               Core.decode_record(
                 base
                 |> Map.put("worktree_path", "/tmp/r")
                 |> Map.put("display_worktree_path", "/tmp/r")
                 |> Map.put("worktree_registration", %{
                   "path" => "/tmp/r",
                   "head" => "abc",
                   "branch" => "main"
                 })
               )

      assert {:ok, decoded} = Core.decode_record(base)
      assert decoded.ownership == "owned"
      assert decoded.lifecycle == "retained"
      assert decoded.runtime_id == "rt_fixture"
    end

    test "security regression: encode and decode reject one-sided task authority" do
      decoded = closed_fixture_record()

      assert {:error, :incomplete_task_principal} =
               Core.decode_record(
                 decoded
                 |> Map.put("task_id", "task-only")
                 |> Map.put("principal_id", nil)
               )

      assert {:error, :incomplete_task_principal} =
               Core.decode_record(
                 decoded
                 |> Map.put("task_id", nil)
                 |> Map.put("principal_id", "agent-only")
               )

      encoded = %{
        workspace_id: "ws_pair_encode",
        task_id: "task-only",
        principal_id: nil,
        repo_path: "/tmp/pair-repo",
        worktree_path: "/tmp/pair-worktree",
        branch: "main",
        base_commit: "abc",
        ownership: "owned",
        lifecycle: "active",
        runtime_id: "rt_pair",
        lstat_identity: %{type: "directory", major_device: 0, minor_device: 0, inode: 1},
        worktree_registration: %{
          path: "/tmp/pair-worktree",
          head: "abc",
          branch: "main"
        },
        expires_at: DateTime.utc_now()
      }

      assert {:error, :incomplete_task_principal} = Core.encode_record(encoded)

      assert {:error, :incomplete_task_principal} =
               encoded
               |> Map.put(:task_id, nil)
               |> Map.put(:principal_id, "agent-only")
               |> Core.encode_record()
    end

    test "walk budget admits the exact node ceiling and rejects the next node" do
      exact = %{"payload" => List.duplicate(nil, Core.max_json_nodes() - 2)}
      over = %{"payload" => List.duplicate(nil, Core.max_json_nodes() - 1)}

      refute Core.decode_record(exact) == {:error, :retention_structure_oversized}
      assert {:error, :retention_structure_oversized} = Core.decode_record(over)
    end

    test "default journal path uses ARBOR_HOME not CWD" do
      previous_app = Application.get_env(:arbor_actions, :workspace_retention_journal_path)
      previous_home = System.get_env("ARBOR_HOME")
      Application.delete_env(:arbor_actions, :workspace_retention_journal_path)

      try do
        System.delete_env("ARBOR_HOME")
        path = Config.workspace_retention_journal_path()
        refute String.starts_with?(path, Path.expand("."))

        assert String.ends_with?(path, Path.join(".arbor", "workspace_retention")) or
                 String.ends_with?(path, "workspace_retention")

        custom = Path.join(System.tmp_dir!(), "arbor-home-#{System.unique_integer([:positive])}")
        System.put_env("ARBOR_HOME", custom)

        assert Config.workspace_retention_journal_path() ==
                 Path.join(Path.expand(custom), "workspace_retention")
      after
        if previous_home == nil,
          do: System.delete_env("ARBOR_HOME"),
          else: System.put_env("ARBOR_HOME", previous_home)

        if previous_app == nil,
          do: Application.delete_env(:arbor_actions, :workspace_retention_journal_path),
          else:
            Application.put_env(:arbor_actions, :workspace_retention_journal_path, previous_app)
      end
    end

    test "security regression: aggregate raw inventory bytes and JSON node bounds", %{
      tmp_dir: tmp_dir
    } do
      # Node count during ordered normalization (before full decode budgets).
      # Build a shallow object with more than max_json_nodes leaf members.
      max_nodes = Core.max_json_nodes()

      pairs =
        for i <- 1..(max_nodes + 5) do
          ~s("k#{i}":#{i})
        end

      oversized = "{" <> Enum.join(pairs, ",") <> "}"
      assert {:error, :retention_structure_oversized} = Core.decode_json_bytes(oversized)

      # Aggregate on-disk inventory bound: many large files under one journal root.
      # Use ActionCase tmp_dir (not System.tmp_dir!) so Linux guests with /tmp
      # parents pass durable-store parent-permission checks.
      tmp = Path.join(tmp_dir, "agg-inv-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.chmod!(tmp, 0o700)
      # Write enough large-ish files that lstat size sum exceeds aggregate ceiling
      # without each file exceeding max_snapshot_bytes.
      chunk = String.duplicate("x", 64_000)
      max_agg = Core.max_aggregate_inventory_bytes()
      n = div(max_agg, byte_size(chunk)) + 3

      for i <- 1..n do
        record_path = Path.join(tmp, "retained:ws_agg#{i}.json")

        File.write!(
          record_path,
          Jason.encode!(%{"n" => i, "p" => chunk})
        )

        File.chmod!(record_path, 0o600)
      end

      store_name = String.to_atom("agg_store_#{System.unique_integer([:positive])}")

      start_supervised!(
        {WorkspaceRetentionDurableStore, name: store_name, path: tmp},
        id: store_name
      )

      assert {:error, {:retention_store_poisoned, reason}} =
               Persistence.list(store_name, WorkspaceRetentionDurableStore)

      assert reason in [:retention_aggregate_bytes_exceeded, :retention_record_limit_exceeded] or
               match?({:corrupt_store_entry, _, _}, reason) or
               reason == :retention_inventory_oversized
    end
  end

  describe "security regression: primary checkout, display path, incarnation, reservation" do
    test "primary checkout marker cannot be encoded or cleaned via durable path", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))

      assert {:error, :primary_checkout_not_retainable} =
               Core.encode_record(%{
                 workspace_id: "ws_primary",
                 repo_path: repo,
                 worktree_path: repo,
                 branch: "main",
                 base_commit: "abc123",
                 ownership: "owned",
                 lifecycle: "retained",
                 runtime_id: "rt_test",
                 lstat_identity: %{
                   type: "directory",
                   major_device: 0,
                   minor_device: 0,
                   inode: 1
                 },
                 worktree_registration: %{path: repo, head: "abc123", branch: "main"},
                 expires_at: DateTime.utc_now()
               })

      # Direct destroyer refuses primary even if caller synthesizes a map.
      {:ok, stat} = File.lstat(repo)

      assert {:error, :primary_checkout_not_retainable} =
               WorkspaceLeaseRegistry.remove_owned_retained_worktree(%{
                 repo_path: repo,
                 worktree_path: repo,
                 lstat_identity:
                   Map.take(Map.from_struct(stat), [:type, :major_device, :minor_device, :inode]),
                 worktree_registration: %{path: repo, head: "x", branch: "main"}
               })

      assert File.dir?(repo)
    end

    test "Git cleanup failure retains evidence without File.rm_rf fallback", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/git-cleanup-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-gcf-#{System.unique_integer([:positive])}"
      principal_id = "agent-gcf-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()

      # Inject cleanup that simulates git remove failure while path remains.
      cleanup = fn _retained ->
        {:error, {:worktree_remove_failed, :injected}}
      end

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup: cleanup,
          retention_runtime_id: "rt_gcf"
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      path = lease.worktree_path
      File.write!(Path.join(path, "keep-me.txt"), "evidence\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(server_pid(server), {:retained_expire, target, generation})

      assert_eventually(
        fn ->
          assert File.dir?(path)
          assert File.read!(Path.join(path, "keep-me.txt")) == "evidence\n"
          assert durable_marker?(store_name, backend, lease.workspace_id)
          retained = retained_from_state(server)
          assert retained.retry_count >= 1 or retained.dormant == true
        end,
        100
      )
    end

    test "same-BEAM registry restart with live owner does not arm TTL; exact reacquire rebinds",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/same-beam-active"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-sba-#{System.unique_integer([:positive])}"
      principal_id = "agent-sba-#{System.unique_integer([:positive])}"
      runtime_id = "rt_same_beam_#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()

      server =
        start_registry(200,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "live.txt"), "owner-holds\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      # Reactivate so durable marker is lifecycle=active for this runtime.
      assert {:ok, live} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert live.active
      assert durable_marker?(store_name, backend, lease.workspace_id)

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker} = Persistence.get(store_name, backend, key)
      lifecycle = Map.get(marker, "lifecycle") || Map.get(marker, :lifecycle)
      assert lifecycle == "active"
      assert (Map.get(marker, "runtime_id") || Map.get(marker, :runtime_id)) == runtime_id

      # Registry-only restart, same runtime id, owner process still alive conceptually
      # (we reacquire after). Must not arm TTL deletion of the live worktree.
      stop_registry(server)

      server2 =
        start_registry(50,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      retained = retained_from_state(server2)
      assert retained.lifecycle == :active_orphaned
      assert is_nil(retained.expiry_ref)

      # Wait longer than the short TTL would have been — path must survive.
      Process.sleep(120)
      assert File.dir?(lease.worktree_path)
      assert File.read!(Path.join(lease.worktree_path, "live.txt")) == "owner-holds\n"

      # Exact task+principal reacquire rebinds the orphaned active marker.
      assert {:ok, rebound} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert rebound.active
      assert rebound.workspace_id == lease.workspace_id
      assert rebound.worktree_path == lease.worktree_path
      assert File.read!(Path.join(rebound.worktree_path, "live.txt")) == "owner-holds\n"
    end

    test "same-runtime active marker settles when path and Git registration are absent", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/same-runtime-settled-active"
      base = Path.join(tmp_dir, "worktrees")
      runtime_id = "rt_settled_active_#{System.unique_integer([:positive])}"
      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
      assert durable_marker?(store_name, backend, lease.workspace_id)
      stop_registry(server)

      git!(repo, ["worktree", "remove", "--force", lease.worktree_path])
      assert {:error, :enoent} = File.lstat(lease.worktree_path)

      refute String.contains?(
               git!(repo, ["worktree", "list", "--porcelain"]),
               lease.worktree_path
             )

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert retained_count(server2) == 0
      refute journal_poisoned?(server2)
      refute durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "retained marker settles on hydration when both repo and worktree paths are absent", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/both-absent-hydration"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task_both_absent_hydration"
      principal_id = "agent_both_absent_hydration"
      runtime_id = "rt_both_absent_#{System.unique_integer([:positive])}"
      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      # Live owner process may retain without task/principal opts.
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      assert durable_marker?(store_name, backend, lease.workspace_id)
      stop_registry(server)

      # Benchmark-style parent deletion: both recorded parents are gone.
      File.rm_rf!(lease.worktree_path)
      File.rm_rf!(repo)
      assert {:error, :enoent} = File.lstat(lease.worktree_path)
      assert {:error, :enoent} = File.lstat(repo)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert retained_count(server2) == 0
      refute journal_poisoned?(server2)
      refute durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "security regression: retained marker delete failure preserves expiry cleanup",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/settle-marker-delete-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task_settle_marker_delete_fail"
      principal_id = "agent_settle_marker_delete_fail"
      runtime_id = "rt_settle_marker_fail_#{System.unique_integer([:positive])}"
      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert retained_count(server) == 1

      File.rm_rf!(lease.worktree_path)
      File.rm_rf!(repo)
      assert {:error, :enoent} = File.lstat(lease.worktree_path)
      assert {:error, :enoent} = File.lstat(repo)

      # Marker-delete failure is not settlement: residue remains fail-closed.
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_delete)

      assert {:error, {:workspace_settlement_unconfirmed, failures}} =
               WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id,
                 server: server
               )

      assert Enum.any?(failures, fn {id, reason} ->
               id == lease.workspace_id and
                 (reason == :settlement_residue or
                    match?({:marker_delete_failed, _}, reason))
             end)

      assert retained_count(server) == 1 or active_count(server) == 1
      assert durable_marker?(store_name, backend, lease.workspace_id)

      retained = retained_from_state(server)
      assert is_reference(retained.expiry_ref)
      assert is_integer(Process.read_timer(retained.expiry_ref))

      # Recover for test hygiene: allow marker delete and settle both-absent.
      :ok = ControllableRetentionStore.set_mode(store_name, :ok)

      assert {:ok, cleaned} =
               WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id,
                 server: server
               )

      assert cleaned["settled_count"] >= 1
      assert retained_count(server) == 0
      assert active_count(server) == 0
      refute durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "security regression: active marker delete failure preserves owner monitor", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/active-marker-delete-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task_active_marker_delete_fail"
      principal_id = "agent_active_marker_delete_fail"
      runtime_id = "rt_active_marker_fail_#{System.unique_integer([:positive])}"
      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      owner_pid = self()

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert active_count(server) == 1

      File.rm_rf!(lease.worktree_path)
      File.rm_rf!(repo)
      assert {:error, :enoent} = File.lstat(lease.worktree_path)
      assert {:error, :enoent} = File.lstat(repo)

      :ok = ControllableRetentionStore.set_mode(store_name, :fail_delete)

      assert {:error, {:workspace_settlement_unconfirmed, _failures}} =
               WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id,
                 server: server
               )

      assert active_count(server) == 1
      assert durable_marker?(store_name, backend, lease.workspace_id)
      assert {:monitors, monitors} = Process.info(server_pid(server), :monitors)
      assert Enum.any?(monitors, &match?({:process, ^owner_pid}, &1))

      # Recover for test hygiene and confirm monitor removal follows marker deletion.
      :ok = ControllableRetentionStore.set_mode(store_name, :ok)

      assert {:ok, %{"settled_count" => 1}} =
               WorkspaceLeaseRegistry.settle_task_workspaces(task_id, principal_id,
                 server: server
               )

      assert active_count(server) == 0
      refute durable_marker?(store_name, backend, lease.workspace_id)
      assert {:monitors, monitors_after} = Process.info(server_pid(server), :monitors)
      refute Enum.any?(monitors_after, &match?({:process, ^owner_pid}, &1))
    end

    test "security regression: detached Git registration prevents retained absence proof", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/detached-registration-retained"
      base = Path.join(tmp_dir, "worktrees")
      parent = self()
      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup: fn retained ->
            git!(retained.worktree_path, ["checkout", "--detach", "HEAD"])
            File.rm_rf!(retained.worktree_path)
            send(parent, :detached_cleanup_performed)
            :ok
          end
        )

      assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(server_pid(server), {:retained_expire, target, generation})

      assert_receive :detached_cleanup_performed, 2_000

      assert_eventually(
        fn ->
          assert retained_count(server) == 1
          assert durable_marker?(store_name, backend, lease.workspace_id)
          assert {:error, :enoent} = File.lstat(lease.worktree_path)
          assert worktree_registered?(repo, lease.worktree_path)
        end,
        100
      )

      _ = System.cmd("git", ["-C", repo, "worktree", "prune"], stderr_to_stdout: true)
    end

    test "same-runtime settled active marker delete failure poisons hydration", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/same-runtime-settled-delete-failure"
      base = Path.join(tmp_dir, "worktrees")
      runtime_id = "rt_settled_delete_fail_#{System.unique_integer([:positive])}"
      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} = acquire(server, repo, branch, tmp_dir, base)
      stop_registry(server)
      git!(repo, ["worktree", "remove", "--force", lease.worktree_path])
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_delete)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert retained_count(server2) == 0
      assert journal_poisoned?(server2)
      assert durable_marker?(store_name, backend, lease.workspace_id)
    end

    test "security regression: owner death after same-BEAM registry restart never arms deletion",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/same-beam-owner-dies-after-restart"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-owner-dies-after-restart"
      principal_id = "agent-owner-dies-after-restart"
      runtime_id = "rt_owner_dies_after_restart"
      {store_name, backend} = start_journal_store()
      parent = self()

      server =
        start_registry(50,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      owner =
        spawn(fn ->
          result =
            acquire(server, repo, branch, tmp_dir, base,
              task_id: task_id,
              principal_id: principal_id
            )

          send(parent, {:restart_owner_acquired, result})

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:restart_owner_acquired, {:ok, lease}}, 3_000
      File.write!(Path.join(lease.worktree_path, "late-owner.txt"), "must survive\n")
      stop_registry(server)

      server2 =
        start_registry(50,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      retained = retained_from_state(server2)
      assert retained.lifecycle == :active_orphaned
      assert is_nil(retained.expiry_ref)

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, _}, 2_000

      Process.sleep(120)
      assert File.read!(Path.join(lease.worktree_path, "late-owner.txt")) == "must survive\n"
      assert retained_from_state(server2).lifecycle == :active_orphaned
      assert durable_marker?(store_name, backend, lease.workspace_id)

      assert {:ok, _} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })
    end

    test "same-runtime active orphan exact release retain refreshes durable expiry", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/orphan-release-retain"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-orphan-retain-#{System.unique_integer([:positive])}"
      principal_id = "agent-orphan-retain-#{System.unique_integer([:positive])}"
      runtime_id = "rt_orphan_retain_#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      assert {:ok, _} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      orphan = retained_from_state(server2)
      assert orphan.lifecycle == :active_orphaned
      assert is_nil(orphan.expiry_ref)

      assert {:ok, result} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert result.status == "retained"
      retained = retained_from_state(server2)
      assert retained.lifecycle == :retained
      assert is_reference(retained.expiry_ref)
      assert DateTime.compare(retained.expires_at, DateTime.utc_now()) == :gt

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker} = Persistence.get(store_name, backend, key)
      assert (Map.get(marker, "lifecycle") || Map.get(marker, :lifecycle)) == "retained"
      assert (Map.get(marker, "runtime_id") || Map.get(marker, :runtime_id)) == runtime_id
      assert File.dir?(lease.worktree_path)
    end

    test "same-runtime active orphan exact release remove settles Git worktree and marker", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/orphan-release-remove"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-orphan-remove-#{System.unique_integer([:positive])}"
      principal_id = "agent-orphan-remove-#{System.unique_integer([:positive])}"
      runtime_id = "rt_orphan_remove_#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "evidence.txt"), "keep until remove\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      assert {:ok, _} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, result} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert result.status == "removed"
      refute File.dir?(lease.worktree_path)
      refute durable_marker?(store_name, backend, lease.workspace_id)
      assert retained_count(server2) == 0

      refute String.contains?(
               git!(repo, ["worktree", "list", "--porcelain"]),
               lease.worktree_path
             )
    end

    test "same-runtime orphan marker delete failure reserves one cleanup attempt", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/orphan-remove-delete-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-orphan-delete-#{System.unique_integer([:positive])}"
      principal_id = "agent-orphan-delete-#{System.unique_integer([:positive])}"
      runtime_id = "rt_orphan_delete_#{System.unique_integer([:positive])}"

      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      assert {:ok, _} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      :ok = ControllableRetentionStore.set_mode(store_name, :fail_delete)

      assert {:ok, result} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert result.status == "removed"
      refute File.dir?(lease.worktree_path)

      retained = retained_from_state(server2)
      assert retained.retry_count == 1
      assert match?({:marker_delete_failed, _}, retained.cleanup_failure)

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker} = Persistence.get(store_name, backend, key)
      assert (Map.get(marker, "retry_count") || Map.get(marker, :retry_count)) == 1
    end

    test "same-runtime active orphan wrong or missing authority does not mutate state", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/orphan-release-authz"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-orphan-authz-#{System.unique_integer([:positive])}"
      principal_id = "agent-orphan-authz-#{System.unique_integer([:positive])}"
      runtime_id = "rt_orphan_authz_#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      File.write!(Path.join(lease.worktree_path, "secret.txt"), "must remain\n")
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      assert {:ok, _} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      before = retained_from_state(server2)
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker_before} = Persistence.get(store_name, backend, key)

      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server2,
                 task_id: "wrong-task",
                 principal_id: principal_id
               })

      assert {:error, :not_authorized} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :remove, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: nil
               })

      after_attempts = retained_from_state(server2)
      assert after_attempts.lifecycle == :active_orphaned
      assert is_nil(after_attempts.expiry_ref)
      assert after_attempts == before
      assert {:ok, ^marker_before} = Persistence.get(store_name, backend, key)
      assert File.read!(Path.join(lease.worktree_path, "secret.txt")) == "must remain\n"
    end

    test "same-runtime active orphan retain write failure leaves orphan unchanged", %{
      tmp_dir: tmp_dir
    } do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/orphan-release-write-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-orphan-write-#{System.unique_integer([:positive])}"
      principal_id = "agent-orphan-write-#{System.unique_integer([:positive])}"
      runtime_id = "rt_orphan_write_#{System.unique_integer([:positive])}"

      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      assert {:ok, _} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      before = retained_from_state(server2)
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker_before} = Persistence.get(store_name, backend, key)
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_put)

      assert {:error, {:retention_journal_write_failed, :injected_put_failure}} =
               WorkspaceLeaseRegistry.release(lease.workspace_id, :retain, %{
                 server: server2,
                 task_id: task_id,
                 principal_id: principal_id
               })

      assert retained_from_state(server2) == before
      assert {:ok, ^marker_before} = Persistence.get(store_name, backend, key)
      assert File.dir?(lease.worktree_path)
    end

    test "active remove retry marker uses injected retention runtime id", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/runtime-id-active-remove"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-runtime-id-#{System.unique_integer([:positive])}"
      principal_id = "agent-runtime-id-#{System.unique_integer([:positive])}"
      runtime_id = "rt_injected_active_remove_#{System.unique_integer([:positive])}"

      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: runtime_id
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      :ok = ControllableRetentionStore.set_mode(store_name, :fail_delete)
      assert {:ok, _} = release(server, lease.workspace_id, :remove)
      refute File.dir?(lease.worktree_path)

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker} = Persistence.get(store_name, backend, key)
      assert (Map.get(marker, "runtime_id") || Map.get(marker, :runtime_id)) == runtime_id
      assert (Map.get(marker, "lifecycle") || Map.get(marker, :lifecycle)) == "retained"
    end

    test "old-incarnation active markers may become retained with TTL", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/old-incarnation"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-oi-#{System.unique_integer([:positive])}"
      principal_id = "agent-oi-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_journal_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_old_inc"
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      assert {:ok, _} =
               acquire(server, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      stop_registry(server)

      # New BEAM incarnation simulated by a different runtime id.
      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_new_inc"
        )

      retained = retained_from_state(server2)
      assert retained.lifecycle == :retained
      assert is_reference(retained.expiry_ref)

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker} = Persistence.get(store_name, backend, key)
      assert (Map.get(marker, "lifecycle") || Map.get(marker, :lifecycle)) == "retained"
    end

    test "expired prior-runtime active marker receives one fresh TTL and later restarts consume it",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/expired-old-active"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-expired-old-active"
      principal_id = "agent-expired-old-active"
      {store_name, backend} = start_journal_store()

      server =
        start_registry(5_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_expired_old"
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, marker} = Persistence.get(store_name, backend, key)

      expired_active =
        marker
        |> stringify_keys()
        |> Map.put(
          "expires_at",
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
        )
        |> ensure_closed_record(lease)

      assert :ok = Persistence.put(store_name, backend, key, expired_active)
      stop_registry(server)

      server2 =
        start_registry(5_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_expired_new"
        )

      retained2 = retained_from_state(server2)
      assert retained2.lifecycle == :retained
      assert is_reference(retained2.expiry_ref)
      assert File.dir?(lease.worktree_path)

      fresh_remaining = DateTime.diff(retained2.expires_at, DateTime.utc_now(), :millisecond)
      assert fresh_remaining > 3_000
      assert fresh_remaining <= 5_000

      assert {:ok, converted_marker} = Persistence.get(store_name, backend, key)

      converted_expiry =
        Map.get(converted_marker, "expires_at") || Map.get(converted_marker, :expires_at)

      assert (Map.get(converted_marker, "lifecycle") ||
                Map.get(converted_marker, :lifecycle)) == "retained"

      stop_registry(server2)
      Process.sleep(100)

      server3 =
        start_registry(5_000,
          retention_journal: {store_name, backend},
          retention_runtime_id: "rt_expired_newer"
        )

      retained3 = retained_from_state(server3)
      assert DateTime.compare(retained3.expires_at, retained2.expires_at) == :eq

      assert DateTime.diff(retained3.expires_at, DateTime.utc_now(), :millisecond) <
               fresh_remaining

      assert {:ok, restarted_marker} = Persistence.get(store_name, backend, key)

      assert (Map.get(restarted_marker, "expires_at") ||
                Map.get(restarted_marker, :expires_at)) == converted_expiry

      assert File.dir?(lease.worktree_path)

      assert {:ok, rebound} =
               acquire(server3, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server3, rebound.workspace_id, :remove)
    end

    test "malicious display_worktree_path is never operational", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/malicious-display"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-md-#{System.unique_integer([:positive])}"
      principal_id = "agent-md-#{System.unique_integer([:positive])}"
      evil = Path.join(tmp_dir, "evil-outside")
      File.mkdir_p!(evil)
      File.write!(Path.join(evil, "do-not-touch.txt"), "safe\n")

      {store_name, backend} = start_journal_store()
      server = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)
      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, record} = Persistence.get(store_name, backend, key)

      poisoned =
        record
        |> stringify_keys()
        |> Map.put("display_worktree_path", evil)
        |> ensure_closed_record(lease)

      assert :ok = Persistence.put(store_name, backend, key, poisoned)
      stop_registry(server)

      server2 = start_registry(60_000, retention_journal: {store_name, backend})

      assert {:ok, reactivated} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      # Operational path is the real worktree, not the malicious display path.
      assert reactivated.worktree_path == lease.worktree_path
      refute reactivated.worktree_path == evil
      assert File.exists?(Path.join(evil, "do-not-touch.txt"))
      assert File.read!(Path.join(evil, "do-not-touch.txt")) == "safe\n"
    end

    test "failed retry reservation poisons current admission without cleanup; restart may retry",
         %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/reserve-fail"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-rf-#{System.unique_integer([:positive])}"
      principal_id = "agent-rf-#{System.unique_integer([:positive])}"

      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 3
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      path = lease.worktree_path
      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      # Next automatic cleanup attempt cannot pre-reserve (put fails).
      :ok = ControllableRetentionStore.set_mode(store_name, :fail_put)
      force_retained_expired(server)
      {target, generation} = retained_target_and_generation(server)
      send(server_pid(server), {:retained_expire, target, generation})

      assert_eventually(
        fn ->
          assert journal_poisoned?(server)
          retained = retained_from_state(server)
          assert retained.dormant == true
          assert match?({:retry_reservation_failed, _}, retained.cleanup_failure)
          # No cleanup attempt — path still present.
          assert File.dir?(path)
        end,
        100
      )

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, unchanged_marker} = Persistence.get(store_name, backend, key)

      assert (Map.get(unchanged_marker, "retry_count") ||
                Map.get(unchanged_marker, :retry_count)) == 0

      parent = self()

      assert {:error, :retention_journal_unavailable} =
               WorkspaceLeaseRegistry.acquire(
                 %{
                   repo_path: repo,
                   branch: "test/reserve-fail-poisoned-admission",
                   worktree_base_dir: base,
                   create_worktree: fn _, _, _ ->
                     send(parent, :poisoned_reservation_create_ran)
                     {:error, :unexpected_create}
                   end
                 },
                 server: server
               )

      refute_receive :poisoned_reservation_create_ran, 100

      # The failed reservation did not persist or perform an attempt. A healthy
      # restart therefore restores count zero and may safely make that attempt.
      :ok = ControllableRetentionStore.set_mode(store_name, :ok)
      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 3
        )

      retained2 = retained_from_state(server2)
      assert retained2.dormant == false
      assert retained2.retry_count == 0
      assert File.dir?(path)

      force_retained_expired(server2)
      {target2, generation2} = retained_target_and_generation(server2)
      send(server_pid(server2), {:retained_expire, target2, generation2})

      assert_eventually(
        fn ->
          refute File.dir?(path)
          refute durable_marker?(store_name, backend, lease.workspace_id)
        end,
        100
      )
    end

    test "genuinely persisted exhausted retry count hydrates dormant", %{tmp_dir: tmp_dir} do
      repo = create_git_repo(Path.join(tmp_dir, "repo"))
      branch = "test/persisted-exhausted-retries"
      base = Path.join(tmp_dir, "worktrees")
      task_id = "task-persisted-exhausted"
      principal_id = "agent-persisted-exhausted"
      {store_name, backend} = start_controllable_store()

      server =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 3,
          retained_cleanup: fn _retained -> {:error, :injected_cleanup_failure} end
        )

      assert {:ok, lease} =
               acquire(server, repo, branch, tmp_dir, base,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server, lease.workspace_id, :retain)

      for expected_count <- 1..3 do
        force_retained_expired(server)
        {target, generation} = retained_target_and_generation(server)
        send(server_pid(server), {:retained_expire, target, generation})

        assert_eventually(
          fn ->
            retained = retained_from_state(server)
            assert retained.retry_count == expected_count

            if expected_count == 3 do
              assert retained.dormant == true
            end
          end,
          100
        )
      end

      {:ok, key} = Core.record_key(lease.workspace_id)
      assert {:ok, exhausted_marker} = Persistence.get(store_name, backend, key)

      assert (Map.get(exhausted_marker, "retry_count") ||
                Map.get(exhausted_marker, :retry_count)) == 3

      stop_registry(server)

      server2 =
        start_registry(60_000,
          retention_journal: {store_name, backend},
          retained_cleanup_retry_limit: 3
        )

      hydrated = retained_from_state(server2)
      assert hydrated.dormant == true
      assert hydrated.retry_count == 3
      assert is_nil(hydrated.expiry_ref)
      assert File.dir?(lease.worktree_path)

      assert {:ok, rebound} =
               acquire(server2, repo, branch, tmp_dir, base,
                 workspace_id: lease.workspace_id,
                 task_id: task_id,
                 principal_id: principal_id
               )

      assert {:ok, _} = release(server2, rebound.workspace_id, :remove)
    end
  end

  defp assert_allocation_denied_before_create(server, repo, branch, base, parent) do
    assert {:error, :retention_journal_unavailable} =
             WorkspaceLeaseRegistry.acquire(
               %{
                 repo_path: repo,
                 branch: branch,
                 worktree_base_dir: base,
                 task_id: "task-#{branch}",
                 principal_id: "agent-#{branch}",
                 create_worktree: fn _, _, _ ->
                   send(parent, :divergent_store_create_ran)
                   {:error, :unexpected_create}
                 end
               },
               server: server
             )
  end

  defp full_fixture_record(index, workspace_id), do: full_fixture_record(index, workspace_id, nil)

  defp full_fixture_record(index, workspace_id, live_repo_path) do
    workspace_id = workspace_id || "ws_full_#{index}"
    repo_path = live_repo_path || "/tmp/arbor-retention-full/repo-#{index}"
    worktree_path = "/tmp/arbor-retention-full/worktree-#{index}"
    branch = "full-#{index}"

    %{
      "schema_version" => 1,
      "workspace_id" => workspace_id,
      "task_id" => nil,
      "principal_id" => nil,
      "repo_path" => repo_path,
      "worktree_path" => worktree_path,
      "display_worktree_path" => worktree_path,
      "branch" => branch,
      "base_commit" => "abc#{index}",
      "ownership" => "owned",
      "lifecycle" => "retained",
      "runtime_id" => "rt_full_fixture",
      "lstat_identity" => %{
        "type" => "directory",
        "major_device" => 0,
        "minor_device" => 0,
        "inode" => index + 1
      },
      "worktree_registration" => %{
        "path" => worktree_path,
        "head" => "abc#{index}",
        "branch" => branch
      },
      "expires_at" => DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.to_iso8601(),
      "retry_count" => 0
    }
  end

  defp closed_fixture_record do
    %{
      "schema_version" => 1,
      "workspace_id" => "ws_abc",
      "task_id" => nil,
      "principal_id" => nil,
      "repo_path" => "/tmp/r",
      "worktree_path" => "/tmp/w",
      "display_worktree_path" => "/tmp/w",
      "branch" => "main",
      "base_commit" => "abc",
      "ownership" => "owned",
      "lifecycle" => "retained",
      "runtime_id" => "rt_fixture",
      "lstat_identity" => %{
        "type" => "directory",
        "major_device" => 0,
        "minor_device" => 0,
        "inode" => 1
      },
      "worktree_registration" => %{
        "path" => "/tmp/w",
        "head" => "abc",
        "branch" => "main"
      },
      "expires_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "retry_count" => 0
    }
  end

  defp start_journal_store do
    name = String.to_atom("retention_journal_#{System.unique_integer([:positive])}")
    start_supervised!({StoreETS, name: name, max_entries: 1_000}, id: name)
    {name, StoreETS}
  end

  defp start_controllable_store do
    name = String.to_atom("ctrl_retention_#{System.unique_integer([:positive])}")
    start_supervised!({ControllableRetentionStore, name: name}, id: name)
    {name, ControllableRetentionStore}
  end

  defp journal_poisoned?(server) do
    case :sys.get_state(server_pid(server)).retention_journal do
      %{status: :poisoned} -> true
      _ -> false
    end
  end

  # BEAM monotonic clocks may be negative; force absolute deadline into the past
  # so an injected {:retained_expire, ...} settles instead of rescheduling.
  defp force_retained_expired(server) do
    pid = server_pid(server)
    now = System.monotonic_time(:millisecond)

    :sys.replace_state(pid, fn state ->
      retained_by_id =
        Map.new(state.retained_by_id, fn {id, retained} ->
          {id, %{retained | expires_at_ms: now - 1}}
        end)

      retained_by_target =
        Map.new(state.retained_by_target, fn {target, retained} ->
          {target, %{retained | expires_at_ms: now - 1}}
        end)

      %{state | retained_by_id: retained_by_id, retained_by_target: retained_by_target}
    end)
  end

  # macOS path alias for duplicate-target hydration coverage.
  defp path_alias("/private" <> rest), do: rest
  defp path_alias(<<"/var", _::binary>> = path), do: "/private" <> path
  defp path_alias(path) when is_binary(path), do: path

  defp child_module({mod, _opts}) when is_atom(mod), do: mod
  defp child_module(%{start: {mod, _, _}}) when is_atom(mod), do: mod
  defp child_module(mod) when is_atom(mod), do: mod
  defp child_module(_), do: nil

  defp start_registry(ttl_ms, opts) do
    name = String.to_atom("workspace_retention_restart_#{System.unique_integer([:positive])}")

    start_supervised!(
      {WorkspaceLeaseRegistry, Keyword.merge([name: name, retention_ttl_ms: ttl_ms], opts)},
      id: name
    )

    name
  end

  defp stop_registry(server) do
    pid = server_pid(server)

    if is_pid(pid) and Process.alive?(pid) do
      ref = Process.monitor(pid)
      _ = stop_supervised(server)

      if Process.alive?(pid) do
        GenServer.stop(pid, :shutdown, 2_000)
      end

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> :ok
      end
    else
      _ = stop_supervised(server)
      :ok
    end
  end

  defp server_pid(server), do: Process.whereis(server)

  defp replace_journal_state(server, journal) do
    :sys.replace_state(server_pid(server), fn state ->
      %{state | retention_journal: journal}
    end)
  end

  defp acquire(server, repo, branch, tmp_dir, base),
    do: acquire(server, repo, branch, tmp_dir, base, [])

  defp acquire(server, repo, branch, tmp_dir, base, opts) do
    attrs =
      %{
        repo_path: repo,
        branch: branch,
        worktree_base_dir: base || Path.join(tmp_dir, "worktrees")
      }
      |> Map.merge(Map.new(opts))

    WorkspaceLeaseRegistry.acquire(attrs, server: server)
  end

  defp release(server, workspace_id, mode),
    do: WorkspaceLeaseRegistry.release(workspace_id, mode, %{server: server})

  defp retained_state(server) do
    state = :sys.get_state(server_pid(server))
    {Map.keys(state.retained_by_id), Map.keys(state.retained_by_target)}
  end

  defp retained_count(server), do: map_size(:sys.get_state(server_pid(server)).retained_by_id)
  defp active_count(server), do: map_size(:sys.get_state(server_pid(server)).leases)

  defp retained_target_and_generation(server) do
    [{target, retained}] = Map.to_list(:sys.get_state(server_pid(server)).retained_by_target)
    {target, retained.expiry_generation}
  end

  defp retained_from_state(server) do
    [{_target, retained}] = Map.to_list(:sys.get_state(server_pid(server)).retained_by_target)
    retained
  end

  defp durable_marker?(store_name, backend, workspace_id) do
    case Core.record_key(workspace_id) do
      {:ok, key} ->
        match?({:ok, _}, Persistence.get(store_name, backend, key))

      _ ->
        false
    end
  end

  defp expected_worktree_path(base_dir, branch),
    do: Path.join(base_dir, Workspace.worktree_dir_name(branch))

  defp worktree_registered?(repo_root, worktree_path) do
    registered_paths =
      git!(repo_root, ["worktree", "list", "--porcelain"])
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.starts_with?(&1, "worktree "))
      |> Enum.map(&String.replace_prefix(&1, "worktree ", ""))

    Enum.any?(registered_paths, fn registered_path ->
      Workspace.canonical_path_or_expanded(registered_path) ==
        Workspace.canonical_path_or_expanded(worktree_path)
    end)
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", ["-C", path | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(other), do: other

  defp retention_record_with_paths(record, lease, repo_path, worktree_path) do
    registration =
      record
      |> then(&(Map.get(&1, "worktree_registration") || Map.get(&1, :worktree_registration)))
      |> stringify_keys()
      |> Map.put("path", worktree_path)

    record
    |> stringify_keys()
    |> Map.put("repo_path", repo_path)
    |> Map.put("worktree_path", worktree_path)
    |> Map.put("display_worktree_path", worktree_path)
    |> Map.put("worktree_registration", registration)
    |> ensure_closed_record(lease)
  end

  defp ensure_closed_record(map, lease) when is_map(lease) do
    workspace_id =
      Map.get(lease, :workspace_id) || Map.get(lease, "workspace_id") ||
        Map.get(map, "workspace_id")

    repo_path = Map.get(lease, :repo_path) || Map.get(lease, "repo_path")
    worktree_path = Map.get(lease, :worktree_path) || Map.get(lease, "worktree_path")
    branch = Map.get(lease, :branch) || Map.get(lease, "branch")
    base_commit = Map.get(lease, :base_commit) || Map.get(lease, "base_commit")

    %{
      "schema_version" => 1,
      "workspace_id" => workspace_id,
      "task_id" => Map.get(map, "task_id"),
      "principal_id" => Map.get(map, "principal_id"),
      "repo_path" => Map.get(map, "repo_path") || repo_path,
      "worktree_path" => Map.get(map, "worktree_path") || worktree_path,
      "display_worktree_path" =>
        Map.get(map, "display_worktree_path") || Map.get(map, "worktree_path") || worktree_path,
      "branch" => Map.get(map, "branch") || branch,
      "base_commit" => Map.get(map, "base_commit") || base_commit,
      "ownership" => "owned",
      "lifecycle" => Map.get(map, "lifecycle") || Map.get(map, :lifecycle) || "retained",
      "runtime_id" =>
        Map.get(map, "runtime_id") || Map.get(map, :runtime_id) || "rt_test_fixture",
      "lstat_identity" =>
        stringify_keys(Map.get(map, "lstat_identity") || Map.get(map, :lstat_identity)),
      "worktree_registration" =>
        stringify_keys(
          Map.get(map, "worktree_registration") || Map.get(map, :worktree_registration)
        ),
      "expires_at" => Map.get(map, "expires_at") || DateTime.to_iso8601(DateTime.utc_now()),
      "retry_count" => Map.get(map, "retry_count") || 0
    }
  end

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error in [ExUnit.AssertionError] ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
      end
  end
end
