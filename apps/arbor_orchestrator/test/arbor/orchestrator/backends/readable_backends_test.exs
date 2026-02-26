defmodule Arbor.Orchestrator.Backends.ReadableBackendsTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Handler.ScopedContext
  alias Arbor.Orchestrator.Backends.{ContextReadable, FileReadable}

  describe "FileReadable" do
    test "reads file content" do
      path = Path.join(System.tmp_dir!(), "readable_test_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "hello from file")

      ctx = %ScopedContext{values: %{"path" => path}}
      assert {:ok, "hello from file"} = FileReadable.read(ctx, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "readable_test_*.txt"))
    end

    test "reads file via source_key" do
      path = Path.join(System.tmp_dir!(), "readable_sk_#{:rand.uniform(100_000)}.txt")
      File.write!(path, "via source_key")

      ctx = %ScopedContext{values: %{"source_key" => path}}
      assert {:ok, "via source_key"} = FileReadable.read(ctx, [])
    after
      File.rm(Path.join(System.tmp_dir!(), "readable_sk_*.txt"))
    end

    test "resolves relative paths against workdir" do
      dir = Path.join(System.tmp_dir!(), "readable_workdir_test")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "test.txt"), "relative read")

      ctx = %ScopedContext{values: %{"path" => "test.txt", "workdir" => dir}}
      assert {:ok, "relative read"} = FileReadable.read(ctx, [])
    after
      File.rm_rf(Path.join(System.tmp_dir!(), "readable_workdir_test"))
    end

    test "returns error for missing path" do
      ctx = %ScopedContext{values: %{}}
      assert {:error, :missing_path} = FileReadable.read(ctx, [])
    end

    test "returns error for nonexistent file" do
      ctx = %ScopedContext{values: %{"path" => "/nonexistent/file.txt"}}
      assert {:error, {:file_error, :enoent, _}} = FileReadable.read(ctx, [])
    end

    test "lists files in directory" do
      dir = Path.join(System.tmp_dir!(), "readable_list_test")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.txt"), "a")
      File.write!(Path.join(dir, "b.txt"), "b")

      ctx = %ScopedContext{values: %{"path" => dir}}
      assert {:ok, files} = FileReadable.list(ctx, [])
      assert "a.txt" in files
      assert "b.txt" in files
    after
      File.rm_rf(Path.join(System.tmp_dir!(), "readable_list_test"))
    end

    test "reports capability required" do
      assert "arbor://handler/read/file" =
               FileReadable.capability_required(:read, %ScopedContext{})
    end
  end

  describe "ContextReadable" do
    test "reads from scoped context values" do
      ctx = %ScopedContext{values: %{"source_key" => "my_key", "my_key" => "stored_value"}}
      assert {:ok, "stored_value"} = ContextReadable.read(ctx, [])
    end

    test "defaults to last_response" do
      ctx = %ScopedContext{values: %{"last_response" => "previous output"}}
      assert {:ok, "previous output"} = ContextReadable.read(ctx, [])
    end

    test "returns nil for missing context key" do
      ctx = %ScopedContext{values: %{"source_key" => "nonexistent"}}
      assert {:ok, nil} = ContextReadable.read(ctx, [])
    end

    test "reports capability required" do
      assert "arbor://handler/read/context" =
               ContextReadable.capability_required(:read, %ScopedContext{})
    end
  end
end
