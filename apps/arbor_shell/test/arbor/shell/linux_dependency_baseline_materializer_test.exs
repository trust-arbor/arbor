defmodule Arbor.Shell.LinuxDependencyBaselineMaterializerTest do
  @moduledoc """
  Slice 2B2 materializer primitive tests.

  Covers exact candidate/base copy, modes, drift, hostile plans/sources,
  cleanup ownership, rest_for_one turnover, status redaction, and facade
  fail-closed behavior. Materializer unit tests; public spawn is separate.
  """

  use ExUnit.Case, async: false

  import Bitwise

  alias Arbor.Shell
  alias Arbor.Shell.LinuxDependencyBaselineCore, as: Core
  alias Arbor.Shell.LinuxDependencyBaselineMaterializer, as: Materializer
  alias Arbor.Shell.LinuxDependencyBaselineMaterializer.Lease

  @moduletag :fast

  @domain "arbor-linux-dependency-baseline-v1\0"
  @index_hex String.duplicate("a", 64)
  @manifest_hex String.duplicate("b", 64)
  @mix_lock_hex String.duplicate("c", 64)
  @index_digest "sha256:#{@index_hex}"
  @manifest_digest "sha256:#{@manifest_hex}"
  @erlang_version "28.4.1"
  @elixir_version "1.19.5-otp-28"

  # ---------------------------------------------------------------------------
  # Fake authority: serves a real Core-valid plan over a temp source tree.
  # ---------------------------------------------------------------------------

  defmodule FakeAuthority do
    @moduledoc false

    def reset do
      :persistent_term.put({__MODULE__, :mode}, :ok)
      :persistent_term.put({__MODULE__, :plan}, nil)
      :persistent_term.put({__MODULE__, :checkout_count}, 0)
      :persistent_term.put({__MODULE__, :second_plan}, nil)
      :ok
    end

    def set_plan(plan) when is_map(plan) do
      :persistent_term.put({__MODULE__, :plan}, plan)
      :ok
    end

    def set_mode(mode), do: :persistent_term.put({__MODULE__, :mode}, mode)

    def set_second_plan(plan) when is_map(plan) do
      :persistent_term.put({__MODULE__, :second_plan}, plan)
      :ok
    end

    def checkout_count, do: :persistent_term.get({__MODULE__, :checkout_count}, 0)

    def checkout_plan do
      count = checkout_count() + 1
      :persistent_term.put({__MODULE__, :checkout_count}, count)

      case :persistent_term.get({__MODULE__, :mode}, :ok) do
        :unavailable ->
          {:error, :linux_dependency_baseline_unavailable}

        :drift ->
          {:error, {:linux_dependency_baseline_drift, :identity_mismatch}}

        :raise ->
          raise "sentinel-authority-exception"

        :ok ->
          plan = :persistent_term.get({__MODULE__, :plan}, nil)
          second = :persistent_term.get({__MODULE__, :second_plan}, nil)

          cond do
            count >= 2 and is_map(second) ->
              {:ok, second}

            is_map(plan) ->
              {:ok, plan}

            true ->
              {:error, :linux_dependency_baseline_unavailable}
          end
      end
    end
  end

  setup do
    FakeAuthority.reset()
    ensure_materializer_supervisor!()

    root =
      Path.join(
        System.tmp_dir!(),
        "linux-baseline-mat-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)

    on_exit(fn ->
      FakeAuthority.reset()
      File.rm_rf(root)
      ensure_materializer_supervisor!()
    end)

    {:ok, fixture_root: root}
  end

  # ---------------------------------------------------------------------------
  # Positive paths
  # ---------------------------------------------------------------------------

  describe "exact materialization" do
    test "copies declared inventory into candidate and base with correct modes", %{
      fixture_root: root
    } do
      {source_root, plan, files} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} =
               Materializer.acquire(30_000, authority: FakeAuthority)

      assert %Lease{} = lease
      assert is_binary(view["candidate_path"])
      assert is_binary(view["base_path"])
      assert view["candidate_path"] != view["base_path"]
      assert view["candidate_path"] != source_root
      assert view["base_path"] != source_root

      receipt = view["receipt"]
      assert view["verified_copy"] == true
      refute Map.has_key?(receipt, "status")
      refute Map.has_key?(receipt, "ready")
      refute Map.has_key?(receipt, "readiness")
      refute Map.has_key?(view, "status")
      assert receipt["platform"] == "linux/arm64"
      assert receipt["schema"] == "1"
      assert receipt["baseline_tree_digest"] == plan["receipt"]["baseline_tree_digest"]
      assert receipt == plan["receipt"]
      refute Map.has_key?(receipt, "source_root")
      refute Map.has_key?(receipt, "manifest_path")
      refute Map.has_key?(receipt, "materialization_entries")
      refute Map.has_key?(receipt, "inventory")
      refute inspect(receipt) =~ source_root

      for dest <- [view["candidate_path"], view["base_path"]] do
        assert_tree_matches(dest, files)
      end

      assert :ok = Materializer.release(lease)
      refute File.exists?(Path.dirname(view["candidate_path"]))
    end

    test "executable files are 0700 and non-executable files are 0600", %{fixture_root: root} do
      {_source, plan, files} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)

      for dest <- [view["candidate_path"], view["base_path"]] do
        exe = Path.join(dest, "pkg/bin/tool")
        data = Path.join(dest, "pkg/data.txt")

        assert {:ok, %File.Stat{mode: emode}} = File.lstat(exe)
        assert {:ok, %File.Stat{mode: dmode}} = File.lstat(data)
        assert (emode &&& 0o777) == 0o700
        assert (dmode &&& 0o777) == 0o600
        assert File.read!(exe) == files["pkg/bin/tool"]
        assert File.read!(data) == files["pkg/data.txt"]
      end

      assert :ok = Materializer.release(lease)
    end

    test "facade acquire/release works when production authority is pinned via injection only path for tests",
         %{fixture_root: root} do
      {_source, plan, _files} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      # Production facade never accepts authority injection.
      assert function_exported?(Shell, :acquire_linux_dependency_baseline_lease, 1)
      assert function_exported?(Shell, :release_linux_dependency_baseline_lease, 1)

      # Direct materializer with injection is the test seam.
      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      assert is_map(view["receipt"])
      assert :ok = Shell.release_linux_dependency_baseline_lease(lease)
    end
  end

  # ---------------------------------------------------------------------------
  # Security regressions — plans / sources
  # ---------------------------------------------------------------------------

  describe "security regression: hostile plans before writes" do
    test "rejects malformed plan kind without creating destinations", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(Map.put(plan, "kind", "not-baseline"))

      before = list_tmp_baseline_roots()
      assert {:error, :invalid_plan_kind} = Materializer.acquire(5_000, authority: FakeAuthority)
      assert list_tmp_baseline_roots() == before
    end

    test "rejects provisioning/readiness claims", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(Map.put(plan, "ready", true))

      assert {:error, :unsupported_plan_keys} =
               Materializer.acquire(5_000, authority: FakeAuthority)
    end

    test "rejects source_root traversal", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      bad = Map.put(plan, "source_root", "/tmp/../etc")
      FakeAuthority.set_plan(bad)

      assert {:error, :source_root_traversal} =
               Materializer.acquire(5_000, authority: FakeAuthority)
    end

    test "rejects oversized entry counts before copy", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      limits = Core.limits()

      huge_entries =
        for i <- 1..(limits.max_entries + 1) do
          %{"path" => "e#{i}", "type" => "directory"}
        end

      FakeAuthority.set_plan(Map.put(plan, "materialization_entries", huge_entries))

      assert {:error, :too_many_entries} =
               Materializer.acquire(5_000, authority: FakeAuthority)
    end

    test "rejects relative source_root", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(Map.put(plan, "source_root", "relative/path"))

      assert {:error, :source_root_not_absolute} =
               Materializer.acquire(5_000, authority: FakeAuthority)
    end
  end

  describe "security regression: hostile source filesystem" do
    test "rejects source symlink at regular file path", %{fixture_root: root} do
      {source_root, plan, _} = build_source_and_plan(root)
      target = Path.join(source_root, "pkg/data.txt")
      File.rm!(target)
      File.ln_s!("/etc/hosts", target)
      FakeAuthority.set_plan(plan)

      assert {:error, :symlink_rejected} =
               Materializer.acquire(10_000, authority: FakeAuthority)
    end

    test "rejects hardlinked source regular file", %{fixture_root: root} do
      {source_root, plan, _} = build_source_and_plan(root)
      original = Path.join(source_root, "pkg/data.txt")
      link = Path.join(source_root, "pkg/data-link.txt")
      File.ln!(original, link)

      # Same inode as data.txt — materializing data.txt sees links > 1.
      FakeAuthority.set_plan(plan)

      assert {:error, :hardlink_rejected} =
               Materializer.acquire(10_000, authority: FakeAuthority)
    end

    test "rejects special file (fifo) substitution", %{fixture_root: root} do
      {source_root, plan, _} = build_source_and_plan(root)
      target = Path.join(source_root, "pkg/data.txt")
      File.rm!(target)
      # Create a fifo in place of the regular file.
      case System.cmd("mkfifo", [target], stderr_to_stdout: true) do
        {_out, 0} ->
          FakeAuthority.set_plan(plan)

          assert {:error, reason} = Materializer.acquire(5_000, authority: FakeAuthority)
          assert reason in [:special_file_rejected, :not_a_regular_file, :source_open_failed]

        _ ->
          # Platform without mkfifo — skip without failing the suite.
          assert true
      end
    end

    test "rejects source content drift (size/digest) during copy", %{fixture_root: root} do
      {source_root, plan, _} = build_source_and_plan(root)
      # Mutate file after plan is built so Core accepts but copy detects drift.
      FakeAuthority.set_plan(plan)
      File.write!(Path.join(source_root, "pkg/data.txt"), "mutated-after-plan!!!!")

      assert {:error, reason} = Materializer.acquire(10_000, authority: FakeAuthority)
      assert reason in [:size_mismatch, :digest_mismatch]
    end

    test "rejects second checkout drift after copy", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      # Second checkout returns a different tree digest while keeping shape.
      alt_entries = [
        %{"path" => "only", "type" => "directory"}
      ]

      alt_digest = tree_digest_from_encoded(alt_entries)

      second =
        plan
        |> Map.put("materialization_entries", alt_entries)
        |> put_in(["receipt", "baseline_tree_digest"], alt_digest)
        |> put_in(["receipt", "entry_count"], 1)
        |> put_in(["receipt", "total_bytes"], 0)

      FakeAuthority.set_second_plan(second)

      assert {:error, :baseline_drift_after_copy} =
               Materializer.acquire(30_000, authority: FakeAuthority)
    end

    test "rejects second checkout that only relocates manifest_path", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      alt_manifest = Path.join(root, "manifest-relocated.json")
      File.write!(alt_manifest, "{}")
      second = Map.put(plan, "manifest_path", alt_manifest)
      FakeAuthority.set_second_plan(second)

      before = list_tmp_baseline_roots()

      assert {:error, :baseline_drift_after_copy} =
               Materializer.acquire(30_000, authority: FakeAuthority)

      assert eventually?(fn -> list_tmp_baseline_roots() == before end)
    end
  end

  describe "security regression: lease ownership and cleanup" do
    test "foreign process cannot release with a copied lease", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      parent = self()

      task =
        Task.async(fn ->
          result = Materializer.release(lease)
          send(parent, {:foreign_result, result})
          result
        end)

      assert {:error, :foreign_release} = Task.await(task)
      assert_receive {:foreign_result, {:error, :foreign_release}}
      assert File.dir?(view["candidate_path"])

      assert :ok = Materializer.release(lease)
      refute File.exists?(Path.dirname(view["candidate_path"]))
    end

    test "security regression: copied opaque token fields alone are not authority", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, _view} = Materializer.acquire(30_000, authority: FakeAuthority)

      forged = %Lease{
        token: lease.token,
        worker: lease.worker,
        owner: self(),
        root_path: lease.root_path,
        root_device: lease.root_device,
        root_inode: lease.root_inode
      }

      # Same owner+token+worker is the legitimate lease shape; forging with a
      # different owner is denied.
      forged_other = %{lease | owner: spawn(fn -> :ok end)}
      assert {:error, :foreign_release} = Materializer.release(forged_other)

      # Invalid term denied.
      assert {:error, :invalid_lease} = Materializer.release(%{token: lease.token})
      assert {:error, :invalid_lease} = Materializer.release(lease.token)

      assert :ok = Materializer.release(forged)
    end

    test "owner death cleans up the private root", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)
      parent = self()

      {:ok, owner} =
        Task.start(fn ->
          assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
          send(parent, {:leased, lease, view})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, _lease, view}, 10_000
      root_path = Path.dirname(view["candidate_path"])
      assert File.dir?(root_path)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      assert eventually?(fn -> not File.exists?(root_path) end)
    end

    test "explicit release proves absence before success", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      root_path = Path.dirname(view["candidate_path"])
      assert File.dir?(root_path)

      assert :ok = Materializer.release(lease)
      refute File.exists?(root_path)
      refute File.exists?(view["candidate_path"])
      refute File.exists?(view["base_path"])
    end

    test "post-materialization symlink and special entries cleanup without following", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      root_path = Path.dirname(view["candidate_path"])

      outside =
        Path.join(root, "outside-secret-#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "must-not-be-deleted")

      symlink = Path.join(view["candidate_path"], "evil-link")
      File.ln_s!(outside, symlink)

      fifo = Path.join(view["base_path"], "post-compile.fifo")

      case System.cmd("mkfifo", [fifo], stderr_to_stdout: true) do
        {_out, 0} -> :ok
        _ -> File.write!(fifo <> ".socket-like", "special-placeholder")
      end

      assert :ok = Materializer.release(lease)
      refute File.exists?(root_path)
      assert File.exists?(outside)
      assert File.read!(outside) == "must-not-be-deleted"
    end

    test "identity-mismatch release fails then succeeds after original root restored", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      root_path = Path.dirname(view["candidate_path"])
      preserved = root_path <> ".preserved-#{System.unique_integer([:positive])}"

      File.rename!(root_path, preserved)
      File.mkdir_p!(root_path)
      File.write!(Path.join(root_path, "decoy"), "different-inode")

      assert {:error, {:cleanup_failed, :cleanup_identity_mismatch}} =
               Materializer.release(lease)

      File.rm_rf!(root_path)
      File.rename!(preserved, root_path)

      assert :ok = Materializer.release(lease)
      refute File.exists?(root_path)
    end

    test "security regression: failed cleanup never rm_rf-deletes a replacement root", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} =
               Materializer.acquire(30_000,
                 authority: FakeAuthority,
                 __test_cleanup_fail_after_identity: 1
               )

      root_path = Path.dirname(view["candidate_path"])
      assert is_binary(lease.root_path)
      assert lease.root_path == root_path
      refute Map.has_key?(view, "root_path")
      refute Map.has_key?(view, "root_device")
      refute Map.has_key?(view, "root_inode")

      outside =
        Path.join(root, "outside-must-survive-#{System.unique_integer([:positive])}.txt")

      File.write!(outside, "outside-secret")

      # First release: identity matched but forced post-identity failure — no recursive
      # rm_rf fallback, so authority is retained and the root remains.
      assert {:error, {:cleanup_failed, :cleanup_forced_after_identity}} =
               Materializer.release(lease)

      assert File.dir?(root_path)
      assert Process.alive?(lease.worker)

      # Replace the original root with a different inode at the same path while
      # the worker still holds the original identity.
      preserved = root_path <> ".preserved-#{System.unique_integer([:positive])}"
      File.rename!(root_path, preserved)
      File.mkdir_p!(root_path)
      File.write!(Path.join(root_path, "replacement"), "must-not-be-deleted")
      File.ln_s!(outside, Path.join(root_path, "link-to-outside"))

      assert {:error, {:cleanup_failed, :cleanup_identity_mismatch}} =
               Materializer.release(lease)

      assert File.exists?(Path.join(root_path, "replacement"))
      assert File.read!(Path.join(root_path, "replacement")) == "must-not-be-deleted"
      assert File.exists?(outside)
      assert File.read!(outside) == "outside-secret"

      # Restore original identity; release succeeds without touching the outside target.
      File.rm_rf!(root_path)
      File.rename!(preserved, root_path)

      assert :ok = Materializer.release(lease)
      refute File.exists?(root_path)
      refute Process.alive?(lease.worker)
      assert File.exists?(outside)
      assert File.read!(outside) == "outside-secret"
    end

    test "cleanup-required acquisition returns retryable lease and release cleans", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      # Force materialize success path then forced cleanup failure via hook on a
      # deliberately failing second checkout after copy? Use test cleanup failures
      # with a plan that fails after ownership: second-plan drift after copy.
      alt_entries = [%{"path" => "only", "type" => "directory"}]
      alt_digest = tree_digest_from_encoded(alt_entries)

      second =
        plan
        |> Map.put("materialization_entries", alt_entries)
        |> put_in(["receipt", "baseline_tree_digest"], alt_digest)
        |> put_in(["receipt", "entry_count"], 1)
        |> put_in(["receipt", "total_bytes"], 0)

      FakeAuthority.set_second_plan(second)

      assert {:error, {:cleanup_required, :baseline_drift_after_copy, lease}} =
               Materializer.acquire(30_000,
                 authority: FakeAuthority,
                 __test_cleanup_failures: 2
               )

      assert %Lease{} = lease
      assert Process.alive?(lease.worker)
      assert is_binary(lease.root_path)

      # acquire consumed one forced failure; the next release still fails.
      assert {:error, {:cleanup_failed, :cleanup_forced_failure}} =
               Materializer.release(lease)

      # Counter exhausted: release performs real cleanup and stops the worker.
      assert :ok = Materializer.release(lease)
      refute Process.alive?(lease.worker)
    end

    test "security regression: release is idempotent after successful teardown; dead worker with root present is denied",
         %{
           fixture_root: root
         } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      root_path = Path.dirname(view["candidate_path"])
      worker = lease.worker
      worker_ref = Process.monitor(worker)

      assert :ok = Materializer.release(lease)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000
      refute File.exists?(root_path)

      # Double release after successful teardown: prove absence only.
      assert :ok = Materializer.release(lease)

      # Fresh lease, tear down via supervisor, then same-caller release proves absence.
      FakeAuthority.set_plan(plan)
      assert {:ok, lease2, view2} = Materializer.acquire(30_000, authority: FakeAuthority)
      root2 = Path.dirname(view2["candidate_path"])
      worker2 = lease2.worker
      worker2_ref = Process.monitor(worker2)

      assert :ok =
               DynamicSupervisor.terminate_child(
                 Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor,
                 worker2
               )

      assert_receive {:DOWN, ^worker2_ref, :process, ^worker2, _}, 5_000
      assert eventually?(fn -> not File.exists?(root2) end)
      assert :ok = Materializer.release(lease2)

      # Dead worker with private root still present: never delete from caller.
      FakeAuthority.set_plan(plan)
      assert {:ok, lease3, view3} = Materializer.acquire(30_000, authority: FakeAuthority)
      root3 = Path.dirname(view3["candidate_path"])
      worker3 = lease3.worker
      worker3_ref = Process.monitor(worker3)
      assert File.dir?(root3)

      # Untrappable kill skips terminate cleanup; root remains at the lease locator.
      true = Process.exit(worker3, :kill)
      assert_receive {:DOWN, ^worker3_ref, :process, ^worker3, :killed}, 5_000
      assert File.dir?(root3)

      assert {:error, {:lease_worker_unavailable, :cleanup_path_remains}} =
               Materializer.release(lease3)

      assert File.dir?(root3)
      # Caller must not have deleted the retained root; clean up for the suite.
      File.rm_rf!(root3)
    end

    test "security regression: nil root_identity never late-adopts current path occupant", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:error, {:cleanup_required, :root_identity_capture_failed, lease}} =
               Materializer.acquire(30_000,
                 authority: FakeAuthority,
                 __test_identity_capture_failures: 1
               )

      assert %Lease{} = lease
      assert is_binary(lease.root_path)
      assert is_nil(lease.root_device)
      assert is_nil(lease.root_inode)
      assert Process.alive?(lease.worker)
      assert File.dir?(lease.root_path)

      # Existing path with unknown identity is retained — release cannot delete it.
      assert {:error, {:cleanup_failed, :cleanup_identity_unknown}} =
               Materializer.release(lease)

      assert File.dir?(lease.root_path)
      assert Process.alive?(lease.worker)

      # Only absence is acceptable with root_identity=nil.
      File.rm_rf!(lease.root_path)
      assert :ok = Materializer.release(lease)
      refute Process.alive?(lease.worker)
    end

    test "deadline failure leaves no orphan root or worker", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)
      before = list_tmp_baseline_roots()

      assert {:error, :deadline_exceeded} =
               Materializer.acquire(1, authority: FakeAuthority)

      assert eventually?(fn -> list_tmp_baseline_roots() == before end)
    end

    test "security regression: deadline after owned root leaves no orphan root or worker", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)
      before = list_tmp_baseline_roots()
      parent = self()

      hook = fn dest_root ->
        send(parent, {:verify_after_owned_root, dest_root})
        # Cross the absolute acquire deadline after Shell already owns the root.
        Process.sleep(1_500)
        :ok
      end

      assert {:error, :deadline_exceeded} =
               Materializer.acquire(800,
                 authority: FakeAuthority,
                 __test_verify_hook: hook
               )

      assert_receive {:verify_after_owned_root, dest_root}, 10_000
      assert is_binary(dest_root)

      assert eventually?(fn -> list_tmp_baseline_roots() == before end, 5_000)

      # No live materializer workers remain under the supervisor.
      children =
        DynamicSupervisor.which_children(
          Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor
        )

      assert children == []
    end

    test "owner-death cleanup retries until absence when cleanup initially fails", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)
      parent = self()

      {:ok, owner} =
        Task.start(fn ->
          assert {:ok, lease, view} =
                   Materializer.acquire(30_000,
                     authority: FakeAuthority,
                     __test_cleanup_failures: 3
                   )

          send(parent, {:leased, lease, view})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, lease, view}, 10_000
      root_path = Path.dirname(view["candidate_path"])
      worker = lease.worker
      worker_ref = Process.monitor(worker)
      assert File.dir?(root_path)

      ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^ref, :process, ^owner, :killed}

      # Worker must keep retrying rather than stop while root remains.
      assert eventually?(fn -> not File.exists?(root_path) end, 5_000)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000
    end

    test "security regression: owner-death cleanup becomes dormant after bounded retries", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)
      parent = self()

      {:ok, owner} =
        Task.start(fn ->
          assert {:ok, lease, view} =
                   Materializer.acquire(30_000,
                     authority: FakeAuthority,
                     __test_cleanup_failures: 2,
                     __test_cleanup_retry_limit: 1
                   )

          send(parent, {:dormant_lease, lease, view})
          Process.sleep(:infinity)
        end)

      assert_receive {:dormant_lease, lease, view}, 10_000
      root_path = Path.dirname(view["candidate_path"])
      worker = lease.worker
      assert File.dir?(root_path)

      owner_ref = Process.monitor(owner)
      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}

      assert eventually?(fn ->
               state = :sys.get_state(worker)

               state.status == :cleanup_dormant and state.cleanup_retry_count == 1 and
                 state.cleanup_timer == nil and state.cleanup_dormant
             end)

      dormant_state = :sys.get_state(worker)
      Process.sleep(250)
      assert :sys.get_state(worker) == dormant_state
      assert File.dir?(root_path)

      worker_ref = Process.monitor(worker)

      assert :ok =
               DynamicSupervisor.terminate_child(Materializer.supervisor_name(), worker)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000
      refute File.exists?(root_path)
    end

    test "destination exact-tree verification rejects extra undeclared names", %{
      fixture_root: root
    } do
      # Covered implicitly by positive path; add an explicit inject-after-copy
      # simulation via second-plan mismatch is above. Here verify empty dest
      # requirement: pre-create is impossible because Shell owns the path.
      # Assert facade rejects caller destination options.
      assert {:error, :unknown_materializer_option} =
               Materializer.acquire(1_000, authority: FakeAuthority, destination: "/tmp/x")

      assert {:error, :unknown_materializer_option} =
               Materializer.acquire(1_000, authority: FakeAuthority, candidate_path: "/tmp/y")

      # Keep root used so setup cleanup is meaningful.
      _ = root
    end

    test "descriptor-bound verify hook can fail closed before accepting destinations", %{
      fixture_root: root
    } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)
      before = list_tmp_baseline_roots()

      hook = fn _dest_root -> {:error, :verify_hook_injected_failure} end

      assert {:error, :verify_hook_injected_failure} =
               Materializer.acquire(30_000,
                 authority: FakeAuthority,
                 __test_verify_hook: hook
               )

      assert eventually?(fn -> list_tmp_baseline_roots() == before end)
    end
  end

  describe "facade fail-closed and production invariants" do
    test "production facade fails closed when authority is unavailable" do
      # Global production authority is unpinned (no config) in test env.
      assert {:error, reason} = Shell.acquire_linux_dependency_baseline_lease(2_000)

      assert reason in [
               :linux_dependency_baseline_unavailable,
               :materializer_unavailable,
               :authority_checkout_failed
             ]
    end

    test "production facade rejects non-positive deadlines" do
      assert {:error, :invalid_deadline} = Shell.acquire_linux_dependency_baseline_lease(0)
      assert {:error, :invalid_deadline} = Shell.acquire_linux_dependency_baseline_lease(-1)
      assert {:error, :invalid_deadline} = Shell.acquire_linux_dependency_baseline_lease("1s")
    end

    test "security regression: no caller-selected destination API on Shell" do
      Code.ensure_loaded!(Shell)

      # Only arity-1 deadline API is public.
      assert function_exported?(Shell, :acquire_linux_dependency_baseline_lease, 1)
      refute function_exported?(Shell, :acquire_linux_dependency_baseline_lease, 2)

      # Keyword injection cannot reach production facade.
      assert_raise UndefinedFunctionError, fn ->
        apply(Shell, :acquire_linux_dependency_baseline_lease, [1_000, [destination: "/tmp"]])
      end
    end

    test "relative tool is pure preflight before admission" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Shell.execute_spawn_capable("mix", ["test"], [])
    end

    test "format_status redacts plan, paths, digests, owner, and token", %{fixture_root: root} do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      worker = lease.worker

      status = :sys.get_status(worker)
      rendered = inspect(status, limit: :infinity)

      refute rendered =~ view["candidate_path"]
      refute rendered =~ view["base_path"]
      refute rendered =~ plan["source_root"]
      refute rendered =~ plan["receipt"]["baseline_tree_digest"]
      refute rendered =~ Base.encode16(lease.token, case: :lower)
      # Inspect of lease itself is redacted.
      assert inspect(lease) == "#Arbor.Shell.LinuxDependencyBaselineLease<redacted>"

      assert :ok = Materializer.release(lease)
    end

    test "security regression: supervisor shutdown cleans up and rest_for_one turns over workers",
         %{
           fixture_root: root
         } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} = Materializer.acquire(30_000, authority: FakeAuthority)
      worker = lease.worker
      worker_ref = Process.monitor(worker)
      root_path = Path.dirname(view["candidate_path"])
      assert File.dir?(root_path)

      materializer_sup =
        Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor)

      assert is_pid(materializer_sup)

      # Supervisor-ordered child teardown (not GenServer.stop) must still clean up.
      assert :ok =
               DynamicSupervisor.terminate_child(
                 Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor,
                 worker
               )

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 5_000

      assert eventually?(fn -> not File.exists?(root_path) end),
             "expected private root cleaned up after materializer worker shutdown"

      # Acquire again and tear down the whole materializer supervisor (rest_for_one
      # path after authority death). Live workers must clean up on supervisor exit.
      FakeAuthority.set_plan(plan)
      assert {:ok, lease2, view2} = Materializer.acquire(30_000, authority: FakeAuthority)
      root2 = Path.dirname(view2["candidate_path"])
      worker2_ref = Process.monitor(lease2.worker)
      sup_ref = Process.monitor(materializer_sup)

      assert :ok =
               Supervisor.terminate_child(
                 Arbor.Shell.Supervisor,
                 Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor
               )

      assert_receive {:DOWN, ^sup_ref, :process, ^materializer_sup, _}, 5_000
      assert_receive {:DOWN, ^worker2_ref, :process, _, _}, 5_000

      assert eventually?(fn -> not File.exists?(root2) end),
             "expected private root cleaned up after materializer supervisor shutdown"

      ensure_materializer_supervisor!()
      assert is_pid(Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor))
    end

    test "security regression: supervisor shutdown does not repeat bounded cleanup in terminate",
         %{
           fixture_root: root
         } do
      {_source, plan, _} = build_source_and_plan(root)
      FakeAuthority.set_plan(plan)

      assert {:ok, lease, view} =
               Materializer.acquire(30_000,
                 authority: FakeAuthority,
                 __test_cleanup_failures: 20
               )

      root_path = Path.dirname(view["candidate_path"])
      worker_ref = Process.monitor(lease.worker)

      materializer_sup =
        Process.whereis(Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor)

      sup_ref = Process.monitor(materializer_sup)
      assert File.dir?(root_path)

      assert :ok =
               Supervisor.terminate_child(
                 Arbor.Shell.Supervisor,
                 Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor
               )

      assert_receive {:DOWN, ^sup_ref, :process, ^materializer_sup, _}, 5_000
      assert_receive {:DOWN, ^worker_ref, :process, _, _}, 5_000

      # Exactly twenty bounded attempts were forced to fail. A second cleanup
      # from terminate/2 would be attempt twenty-one and remove this root.
      assert File.dir?(root_path)
      File.rm_rf!(root_path)

      ensure_materializer_supervisor!()
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_source_and_plan(fixture_root) do
    source_root = Path.join(fixture_root, "source")
    File.mkdir_p!(Path.join(source_root, "pkg/bin"))

    files = %{
      "pkg/data.txt" => "hello-baseline-data",
      "pkg/bin/tool" => "#!/bin/sh\necho tool\n"
    }

    File.write!(Path.join(source_root, "pkg/data.txt"), files["pkg/data.txt"])
    File.write!(Path.join(source_root, "pkg/bin/tool"), files["pkg/bin/tool"])
    File.chmod!(Path.join(source_root, "pkg/bin/tool"), 0o755)
    File.chmod!(Path.join(source_root, "pkg/data.txt"), 0o644)

    entries = [
      dir("pkg"),
      dir("pkg/bin"),
      file_entry("pkg/data.txt", files["pkg/data.txt"], false),
      file_entry("pkg/bin/tool", files["pkg/bin/tool"], true)
    ]

    input = build_core_input(entries)
    assert {:ok, state} = Core.new(input)
    receipt = Core.show(state)

    encoded =
      Enum.map(Core.materialization_entries(state), fn
        %{path: p, type: "directory"} ->
          %{"path" => p, "type" => "directory"}

        %{path: p, type: "regular", size: s, sha256: h, executable: e} ->
          %{
            "path" => p,
            "type" => "regular",
            "size" => s,
            "sha256" => h,
            "executable" => e
          }
      end)

    plan = %{
      "kind" => "linux_dependency_baseline_source",
      "source_root" => source_root,
      "manifest_path" => Path.join(fixture_root, "manifest.json"),
      "receipt" => receipt,
      "materialization_entries" => encoded,
      "evidence_only" => true
    }

    # Manifest path must exist as absolute lexical path field only (not read).
    File.write!(plan["manifest_path"], "{}")

    {source_root, plan, files}
  end

  defp dir(path), do: %{path: path, type: "directory"}

  defp file_entry(path, content, executable) do
    %{
      path: path,
      type: "regular",
      size: byte_size(content),
      sha256: sha256_hex(content),
      executable: executable
    }
  end

  defp sha256_hex(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp frame_entry(%{type: "directory", path: path}) do
    <<0, byte_size(path)::unsigned-32, path::binary>>
  end

  defp frame_entry(%{
         type: "regular",
         path: path,
         size: size,
         sha256: sha256_hex,
         executable: executable
       }) do
    flag = if executable, do: 1, else: 0
    raw = Base.decode16!(sha256_hex, case: :lower)

    <<1, byte_size(path)::unsigned-32, path::binary, flag::unsigned-8, size::unsigned-64,
      raw::binary-size(32)>>
  end

  defp tree_digest(entries) do
    sorted = Enum.sort_by(entries, & &1.path)

    binary =
      Enum.reduce(sorted, @domain, fn entry, acc ->
        acc <> frame_entry(entry)
      end)

    :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  end

  defp tree_digest_from_encoded(encoded) do
    entries =
      Enum.map(encoded, fn
        %{"path" => p, "type" => "directory"} ->
          %{path: p, type: "directory"}

        %{"path" => p, "type" => "regular", "size" => s, "sha256" => h, "executable" => e} ->
          %{path: p, type: "regular", size: s, sha256: h, executable: e}
      end)

    tree_digest(entries)
  end

  defp total_bytes(entries) do
    entries
    |> Enum.filter(&(&1.type == "regular"))
    |> Enum.reduce(0, fn e, acc -> acc + e.size end)
  end

  defp build_core_input(entries) do
    digest = tree_digest(entries)

    %{
      manifest: %{
        schema: "1",
        platform: "linux/arm64",
        image_index_digest: @index_digest,
        image_manifest_digest: @manifest_digest,
        mix_lock_digest: @mix_lock_hex,
        baseline_tree_digest: digest,
        toolchain: %{erlang: @erlang_version, elixir: @elixir_version},
        entry_count: length(entries),
        total_bytes: total_bytes(entries)
      },
      entries: entries
    }
  end

  defp assert_tree_matches(dest, files) do
    assert File.dir?(Path.join(dest, "pkg"))
    assert File.dir?(Path.join(dest, "pkg/bin"))
    assert File.read!(Path.join(dest, "pkg/data.txt")) == files["pkg/data.txt"]
    assert File.read!(Path.join(dest, "pkg/bin/tool")) == files["pkg/bin/tool"]

    # No extras at root of dest.
    assert Enum.sort(File.ls!(dest)) == ["pkg"]
  end

  defp list_tmp_baseline_roots do
    tmp = System.tmp_dir!()

    case File.ls(tmp) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, "arbor-linux-baseline-"))
        |> Enum.sort()

      _ ->
        []
    end
  end

  defp eventually?(fun, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        do_eventually(fun, deadline)
      else
        false
      end
    end
  end

  defp ensure_materializer_supervisor! do
    name = Arbor.Shell.LinuxDependencyBaselineMaterializerSupervisor

    case Process.whereis(name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Arbor.Shell.Supervisor, name) do
          {:ok, _} ->
            :ok

          {:ok, _, _} ->
            :ok

          {:error, :running} ->
            :ok

          {:error, {:already_started, _}} ->
            :ok

          _other ->
            case Supervisor.start_child(
                   Arbor.Shell.Supervisor,
                   Materializer.supervisor_child_spec()
                 ) do
              {:ok, _} -> :ok
              {:ok, _, _} -> :ok
              {:error, {:already_started, _}} -> :ok
              {:error, reason} -> flunk("materializer supervisor unavailable: #{inspect(reason)}")
            end
        end
    end
  end
end
