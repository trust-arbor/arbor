defmodule Arbor.SandboxTest do
  use ExUnit.Case, async: false

  alias Arbor.Sandbox

  setup do
    base_path =
      Path.join(
        System.tmp_dir!(),
        "arbor_sandbox_facade_test_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(base_path)
    File.mkdir_p!(base_path)

    # Start the registry if not running
    case Process.whereis(Arbor.Sandbox.Registry) do
      nil -> {:ok, _pid} = Arbor.Sandbox.Registry.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      File.rm_rf(base_path)
    end)

    {:ok, base_path: base_path}
  end

  describe "create/2" do
    test "creates a sandbox with default level", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_1", base_path: base_path)
      assert sandbox.level == :limited
      assert sandbox.agent_id == "agent_facade_1"
      assert String.starts_with?(sandbox.id, "sbx_")
    end

    test "creates sandbox with specified level", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_2", level: :pure, base_path: base_path)
      assert sandbox.level == :pure
    end

    test "derives level from trust tier", %{base_path: base_path} do
      {:ok, sandbox} =
        Sandbox.create("agent_facade_3", trust_tier: :veteran, base_path: base_path)

      assert sandbox.level == :full
    end
  end

  describe "get/1" do
    test "retrieves sandbox by id", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_4", base_path: base_path)
      assert {:ok, ^sandbox} = Sandbox.get(sandbox.id)
    end

    test "retrieves sandbox by agent_id", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_5", base_path: base_path)
      assert {:ok, ^sandbox} = Sandbox.get("agent_facade_5")
    end
  end

  describe "destroy/1" do
    test "destroys a sandbox", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_6", base_path: base_path)
      assert :ok = Sandbox.destroy(sandbox.id)
      assert {:error, :not_found} = Sandbox.get(sandbox.id)
    end
  end

  describe "check_path/3" do
    test "validates path operations", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_7", level: :limited, base_path: base_path)
      assert :ok = Sandbox.check_path(sandbox, "/file.txt", :read)
      assert :ok = Sandbox.check_path(sandbox, "/file.txt", :write)
    end

    test "blocks writes in pure mode", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_8", level: :pure, base_path: base_path)
      assert :ok = Sandbox.check_path(sandbox, "/file.txt", :read)

      assert {:error, :write_not_allowed_in_pure_mode} =
               Sandbox.check_path(sandbox, "/file.txt", :write)
    end
  end

  describe "sandboxed_path/2" do
    test "resolves paths within sandbox", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_9", base_path: base_path)
      assert {:ok, path} = Sandbox.sandboxed_path(sandbox, "/subdir/file.txt")
      assert String.contains?(path, "agent_facade_9")
    end
  end

  describe "check_code/2" do
    test "validates safe code", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_10", level: :pure, base_path: base_path)
      ast = quote do: Enum.map([1, 2, 3], &(&1 * 2))
      assert :ok = Sandbox.check_code(sandbox, ast)
    end

    test "blocks dangerous code", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_11", level: :full, base_path: base_path)
      ast = quote do: System.cmd("ls", [])
      assert {:error, {:code_violations, _}} = Sandbox.check_code(sandbox, ast)
    end
  end

  describe "check_module/2" do
    test "validates modules", %{base_path: base_path} do
      {:ok, sandbox} = Sandbox.create("agent_facade_12", level: :pure, base_path: base_path)
      assert :ok = Sandbox.check_module(sandbox, Enum)
      assert {:error, :module_not_allowed} = Sandbox.check_module(sandbox, File)
    end
  end

  describe "virtual filesystem" do
    test "create_virtual creates vfs" do
      assert {:ok, vfs} = Sandbox.create_virtual()
      assert is_map(vfs)
    end

    test "vfs_write and vfs_read work together" do
      {:ok, vfs} = Sandbox.create_virtual()
      {:ok, vfs} = Sandbox.vfs_write(vfs, "/test.txt", "hello")
      assert {:ok, "hello"} = Sandbox.vfs_read(vfs, "/test.txt")
    end

    test "vfs_snapshot and vfs_restore work" do
      {:ok, vfs} = Sandbox.create_virtual()
      {:ok, vfs} = Sandbox.vfs_write(vfs, "/file.txt", "original")
      {:ok, snap_id, vfs} = Sandbox.vfs_snapshot(vfs)
      {:ok, vfs} = Sandbox.vfs_write(vfs, "/file.txt", "changed")
      {:ok, vfs} = Sandbox.vfs_restore(vfs, snap_id)
      assert {:ok, "original"} = Sandbox.vfs_read(vfs, "/file.txt")
    end
  end

  describe "level_for_trust/1" do
    test "maps trust tiers to sandbox levels" do
      assert {:ok, :pure} = Sandbox.level_for_trust(:untrusted)
      assert {:ok, :limited} = Sandbox.level_for_trust(:probationary)
      assert {:ok, :limited} = Sandbox.level_for_trust(:trusted)
      assert {:ok, :full} = Sandbox.level_for_trust(:veteran)
      assert {:ok, :full} = Sandbox.level_for_trust(:autonomous)
    end

    test "returns error for unknown tier" do
      assert {:error, :unknown_tier} = Sandbox.level_for_trust(:superduper)
    end
  end

  describe "list/1" do
    test "lists sandboxes", %{base_path: base_path} do
      {:ok, _} = Sandbox.create("agent_facade_list_1", base_path: base_path)
      {:ok, _} = Sandbox.create("agent_facade_list_2", base_path: base_path)

      assert {:ok, sandboxes} = Sandbox.list()
      assert length(sandboxes) >= 2
    end
  end

  describe "healthy?/0" do
    test "returns true when registry is running" do
      assert Sandbox.healthy?()
    end
  end
end
