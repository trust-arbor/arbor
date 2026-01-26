defmodule Arbor.Sandbox.VirtualTest do
  use ExUnit.Case, async: true

  alias Arbor.Sandbox.Virtual

  describe "create/1" do
    test "creates a virtual filesystem" do
      assert {:ok, vfs} = Virtual.create()
      assert is_map(vfs)
      assert Map.has_key?(vfs, :vfs)
    end
  end

  describe "write/3 and read/2" do
    test "writes and reads content" do
      {:ok, vfs} = Virtual.create()
      {:ok, vfs} = Virtual.write(vfs, "/test.txt", "hello world")

      assert {:ok, "hello world"} = Virtual.read(vfs, "/test.txt")
    end

    test "returns error for nonexistent file" do
      {:ok, vfs} = Virtual.create()
      assert {:error, _} = Virtual.read(vfs, "/nonexistent.txt")
    end
  end

  describe "delete/2" do
    test "deletes a file" do
      {:ok, vfs} = Virtual.create()
      {:ok, vfs} = Virtual.write(vfs, "/to_delete.txt", "content")
      {:ok, vfs} = Virtual.delete(vfs, "/to_delete.txt")

      assert {:error, _} = Virtual.read(vfs, "/to_delete.txt")
    end
  end

  describe "list/2" do
    test "lists files in directory" do
      {:ok, vfs} = Virtual.create()
      {:ok, vfs} = Virtual.write(vfs, "/file1.txt", "a")
      {:ok, vfs} = Virtual.write(vfs, "/file2.txt", "b")

      assert {:ok, files} = Virtual.list(vfs, "/")
      assert "file1.txt" in files
      assert "file2.txt" in files
    end
  end

  describe "exists?/2" do
    test "returns true for existing file" do
      {:ok, vfs} = Virtual.create()
      {:ok, vfs} = Virtual.write(vfs, "/exists.txt", "content")

      assert Virtual.exists?(vfs, "/exists.txt")
    end

    test "returns false for nonexistent file" do
      {:ok, vfs} = Virtual.create()
      refute Virtual.exists?(vfs, "/nope.txt")
    end
  end

  describe "snapshot/1 and restore/2" do
    test "creates and restores snapshots" do
      {:ok, vfs} = Virtual.create()
      {:ok, vfs} = Virtual.write(vfs, "/original.txt", "original")

      # Take snapshot
      {:ok, snapshot_id, vfs} = Virtual.snapshot(vfs)

      # Modify the vfs
      {:ok, vfs} = Virtual.write(vfs, "/original.txt", "modified")
      assert {:ok, "modified"} = Virtual.read(vfs, "/original.txt")

      # Restore snapshot
      {:ok, vfs} = Virtual.restore(vfs, snapshot_id)
      assert {:ok, "original"} = Virtual.read(vfs, "/original.txt")
    end
  end

  describe "eval_lua/2" do
    test "evaluates simple Lua code" do
      {:ok, vfs} = Virtual.create()
      {:ok, result, _vfs} = Virtual.eval_lua(vfs, "return 1 + 2")

      # Lua returns numbers as floats
      assert result == 3 or result == 3.0
    end

    test "lua can interact with vfs" do
      {:ok, vfs} = Virtual.create()
      {:ok, _result, vfs} = Virtual.eval_lua(vfs, ~s|vfs.write("/lua.txt", "from lua")|)

      assert {:ok, "from lua"} = Virtual.read(vfs, "/lua.txt")
    end
  end
end
