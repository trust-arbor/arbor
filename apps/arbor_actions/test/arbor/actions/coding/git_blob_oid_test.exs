defmodule Arbor.Actions.Coding.GitBlobOidTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.GitBlobOid

  @moduletag :fast

  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_TERMINAL_PROMPT", "0"},
    {"GIT_ATTR_NOSYSTEM", "1"}
  ]

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "git-blob-oid-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "hash_bytes matches git hash-object --no-filters for sha1 content classes", %{tmp: tmp} do
    samples = [
      {"empty", <<>>},
      {"ordinary", "hello owner dest verify\n"},
      {"binary", <<0, 1, 255, 0, "bin", 10>>},
      {"symlink-target", "mix.exs"},
      {"executable-bytes", "#!/bin/sh\nexit 0\n"}
    ]

    Enum.each(samples, fn {name, bytes} ->
      assert {:ok, oid} = GitBlobOid.hash_bytes(bytes, :sha1)
      assert oid == git_hash_object(tmp, bytes, :sha1), "#{name} sha1 oid mismatch"
      assert byte_size(oid) == 40
    end)
  end

  test "same bytes produce the same oid regardless of 100644 vs 100755", %{tmp: tmp} do
    bytes = "same-blob-bytes\n"
    assert {:ok, oid} = GitBlobOid.hash_bytes(bytes, :sha1)
    assert {:ok, ^oid} = GitBlobOid.hash_bytes(bytes, :sha1)
    assert oid == git_hash_object(tmp, bytes, :sha1)
  end

  test "hash_bytes matches git hash-object --no-filters for sha256", %{tmp: tmp} do
    samples = [
      <<>>,
      "ordinary sha256\n",
      <<0, 255, 10, 0>>,
      "rel/target"
    ]

    Enum.each(samples, fn bytes ->
      assert {:ok, oid} = GitBlobOid.hash_bytes(bytes, :sha256)
      assert oid == git_hash_object(tmp, bytes, :sha256)
      assert byte_size(oid) == 64
    end)
  end

  test "unknown format atoms fail closed" do
    assert {:error, :committable_snapshot_failed} = GitBlobOid.hash_bytes("x", :md5)
    assert {:error, :committable_snapshot_failed} = GitBlobOid.hash_init("sha1", 1)
    assert {:error, :committable_snapshot_failed} = GitBlobOid.hash_bytes("x", "sha1")
  end

  test "infer_object_format uses unique oid width including the tree oid" do
    sha1 = String.duplicate("a", 40)
    sha256 = String.duplicate("b", 64)
    invalid_sha1 = String.duplicate("z", 40)
    invalid_sha256 = String.duplicate("g", 64)

    assert {:ok, :sha1} = BlobManifest.infer_object_format(sha1, [])
    assert {:ok, :sha256} = BlobManifest.infer_object_format(sha256, [])

    assert {:ok, :sha1} =
             BlobManifest.infer_object_format(sha1, [%{path: "a", mode: "100644", oid: sha1}])

    assert {:ok, :sha256} =
             BlobManifest.infer_object_format(sha256, [
               %{"path" => "a", "mode" => "100644", "oid" => sha256}
             ])

    assert {:error, :mixed_object_format} =
             BlobManifest.infer_object_format(sha1, [%{path: "a", mode: "100644", oid: sha256}])

    assert {:error, :mixed_object_format} = BlobManifest.infer_object_format("not-an-oid", [])
    assert {:error, :mixed_object_format} = BlobManifest.infer_object_format(invalid_sha1, [])

    assert {:error, :mixed_object_format} =
             BlobManifest.infer_object_format(sha256, [
               %{path: "a", mode: "100644", oid: invalid_sha256}
             ])

    assert {:error, :mixed_object_format} =
             BlobManifest.infer_object_format(sha1, [
               %{"path" => "a", "mode" => "100644", "oid" => invalid_sha1}
             ])

    assert {:error, :mixed_object_format} = BlobManifest.infer_object_format(sha1, :invalid)
  end

  defp git_hash_object(tmp, bytes, :sha1) do
    path = Path.join(tmp, "blob-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)

    {output, 0} =
      System.cmd(
        "git",
        ["--no-replace-objects", "hash-object", "--no-filters", "--", path],
        env: @git_env,
        stderr_to_stdout: true
      )

    String.trim(output)
  end

  defp git_hash_object(tmp, bytes, :sha256) do
    git_dir = Path.join(tmp, "sha256-#{System.unique_integer([:positive])}.git")
    path = Path.join(tmp, "blob-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)

    {_, 0} =
      System.cmd(
        "git",
        ["init", "--bare", "--object-format=sha256", git_dir],
        env: @git_env,
        stderr_to_stdout: true
      )

    {output, 0} =
      System.cmd(
        "git",
        [
          "--git-dir",
          git_dir,
          "--no-replace-objects",
          "hash-object",
          "--no-filters",
          "--",
          path
        ],
        env: @git_env,
        stderr_to_stdout: true
      )

    String.trim(output)
  end
end
