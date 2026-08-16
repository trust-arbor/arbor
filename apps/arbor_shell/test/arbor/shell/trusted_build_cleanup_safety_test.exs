Code.require_file("trusted_build_test_helpers.exs", __DIR__)

defmodule Arbor.Shell.TrustedBuildCleanupSafetyTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Shell.TrustedBuildTestHelpers, as: Helpers

  test "cleanup rejects tmp, parents, ancestors, and rewritten roots" do
    tmp = System.tmp_dir!()
    path = Path.join(tmp, "arbor-tb-clean-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    handle = Helpers.capture_handle!(path)

    try do
      assert {:error, :unsafe_cleanup_root} =
               Helpers.authorize_fixture_cleanup(tmp, %{handle | root: tmp})

      assert {:error, :cleanup_target_mismatch} =
               Helpers.authorize_fixture_cleanup(tmp, handle)

      assert {:error, :cleanup_target_mismatch} =
               Helpers.authorize_fixture_cleanup(Path.dirname(handle.root), handle)

      rewritten = %{handle | root: tmp}

      assert {:error, :unsafe_cleanup_root} =
               Helpers.authorize_fixture_cleanup(rewritten.root, rewritten)

      parent = Path.dirname(handle.root)
      parent_rewrite = %{handle | root: parent}

      assert {:error, :unsafe_cleanup_root} =
               Helpers.authorize_fixture_cleanup(parent, parent_rewrite)

      assert :ok = Helpers.authorize_fixture_cleanup(handle.root, handle)
      assert :ok = Helpers.rm_fixture!(handle)
      refute File.exists?(path)
      assert File.dir?(tmp)
    after
      _ = Helpers.rm_fixture!(handle)
    end
  end

  test "retained worker teardown observes DOWN before fixture deletion" do
    path = Path.join(System.tmp_dir!(), "arbor-tb-stop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    handle = Helpers.capture_handle!(path)
    {:ok, pid} = GenServer.start(Arbor.Shell.TrustedBuildCleanupSafetyTest.TrapIgnore, :ok)

    try do
      started = System.monotonic_time(:millisecond)
      assert :ok = Helpers.stop_retained_worker(pid)
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 2_000
      refute Process.alive?(pid)
      assert File.dir?(path)
      assert :ok = Helpers.rm_fixture!(handle)
      refute File.exists?(path)
    after
      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end

      _ = Helpers.rm_fixture!(handle)
    end
  end

  test "nonempty hex fixture is removed at the exact captured root" do
    path = Path.join(System.tmp_dir!(), "arbor-hex-src-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, "hex-2.0.0"))
    File.write!(Path.join(path, "hex-2.0.0/hex"), "body\n")
    handle = Helpers.capture_handle!(path)

    assert :ok = Helpers.rm_fixture!(handle)
    refute File.exists?(path)
    assert File.dir?(System.tmp_dir!())
  end
end

defmodule Arbor.Shell.TrustedBuildCleanupSafetyTest.TrapIgnore do
  @moduledoc false
  use GenServer

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}
end
