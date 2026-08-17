defmodule Arbor.Commands.ImmutableGitSourceTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.ImmutableGitSource
  alias Arbor.Commands.ImmutableGitSource.Git
  alias Arbor.Shell

  @moduletag :slow
  @moduletag :integration
  @moduletag timeout: 60_000

  setup_all do
    root = tmp_dir!("igs-all")
    source = Path.join(root, "source")
    {commit, tree} = build_repo!(source, object_format: "sha1")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root, source: source, commit: commit, tree: tree}
  end

  test "reconstructs a SHA-1 commit into an owned parent with neutral metadata", context do
    parent = Path.join(context.root, "owned-sha1")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    assert :ok =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000
             )

    dest = Path.join(parent, "source")
    assert git!(dest, ["rev-parse", "HEAD^{commit}"]) == context.commit
    assert git!(dest, ["rev-parse", "HEAD^{tree}"]) == context.tree
    assert git!(dest, ["status", "--porcelain=v1", "--untracked-files=all"]) == ""
    assert git!(dest, ["symbolic-ref", "--short", "HEAD"]) == "source"
    assert git!(dest, ["config", "--local", "--get", "core.hooksPath"]) == "/dev/null"

    assert match?(
             {:error, "git_failed:" <> _},
             Git.run(dest, ["config", "--local", "--get-regexp", "^remote\\."], 15_000)
           )

    refute File.exists?(Path.join(dest, ".git/hooks/pre-commit"))
    refute File.exists?(Path.join(dest, ".git/objects/info/alternates"))
    assert File.read!(Path.join(dest, "README.md")) == "hello\n"
    assert File.read_link!(Path.join(dest, "README.link")) == "README.md"
  end

  test "materialize_paths writes only selected regular blobs and omits unselected symlinks",
       context do
    parent = Path.join(context.root, "owned-selected")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    assert :ok =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000,
               materialize_paths: ["README.md"]
             )

    dest = Path.join(parent, "source")
    assert git!(dest, ["rev-parse", "HEAD^{commit}"]) == context.commit
    assert git!(dest, ["rev-parse", "HEAD^{tree}"]) == context.tree
    assert File.read!(Path.join(dest, "README.md")) == "hello\n"
    assert {:error, :enoent} = File.lstat(Path.join(dest, "README.link"))
    assert {:error, :enoent} = File.lstat(Path.join(dest, "lib/a.ex"))
  end

  test "materialize_paths rejects a selected symlink and a missing path", context do
    parent = Path.join(context.root, "owned-selected-symlink")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    assert {:error, "materialize_symlink"} =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000,
               materialize_paths: ["README.md", "README.link"]
             )

    parent_missing = Path.join(context.root, "owned-selected-missing")
    {:ok, missing_identity} = Shell.create_private_owned_tree(parent_missing)

    assert {:error, "materialize_path_missing"} =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               missing_identity,
               timeout_ms: 15_000,
               materialize_paths: ["README.md", "nope.ex"]
             )
  end

  test "reconstructs a SHA-256 commit", %{root: root} do
    source = Path.join(root, "source256")

    case build_repo(source, object_format: "sha256") do
      {:ok, commit, tree} ->
        parent = Path.join(root, "owned256")
        {:ok, identity} = Shell.create_private_owned_tree(parent)

        assert :ok =
                 ImmutableGitSource.reconstruct(source, "source", commit, tree, identity,
                   timeout_ms: 15_000
                 )

        dest = Path.join(parent, "source")
        assert byte_size(commit) == 64
        assert git!(dest, ["rev-parse", "HEAD^{tree}"]) == tree

      {:error, :sha256_unsupported} ->
        assert true
    end
  end

  test "rejects absolute and nested destinations", context do
    dest = Path.join(context.root, "abs")

    assert {:error, :invalid_reconstruct_request} =
             ImmutableGitSource.reconstruct(
               context.source,
               dest,
               context.commit,
               context.tree,
               %{path: context.root, type: :directory, device: 0, minor_device: 0, inode: 0}
             )

    parent = Path.join(context.root, "owned-bad-filter")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    assert {:error, :invalid_reconstruct_request} =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000,
               materialize_paths: "README.md"
             )

    assert {:error, :invalid_reconstruct_request} =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000,
               materialize_paths: ["README.md", "README.md"]
             )

    parent = Path.join(context.root, "owned-nested")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    assert {:error, :invalid_reconstruct_request} =
             ImmutableGitSource.reconstruct(
               context.source,
               "nested/source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000
             )
  end

  test "rejects source object alternates before destination create", %{root: root} do
    source = Path.join(root, "alt-source")
    {commit, tree} = build_repo!(source, object_format: "sha1")
    File.mkdir_p!(Path.join(source, ".git/objects/info"))
    File.write!(Path.join(source, ".git/objects/info/alternates"), "/tmp/other.git/objects\n")

    parent = Path.join(root, "owned-alternates")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    dest = Path.join(parent, "source")
    refute File.exists?(dest)

    assert {:error, "source_object_alternates"} =
             ImmutableGitSource.reconstruct(source, "source", commit, tree, identity,
               timeout_ms: 15_000
             )

    refute File.exists?(dest)
  end

  test "rejects parent identity swap before dest create", context do
    parent = Path.join(context.root, "swap")
    {:ok, identity} = Shell.create_private_owned_tree(parent)
    File.rename!(parent, parent <> ".kept")
    File.mkdir!(parent)

    assert {:error, :parent_identity_mismatch} =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000
             )
  end

  test "rejects unsafe symlinks", %{root: root} do
    source = Path.join(root, "badlink")
    {commit, tree} = build_repo!(source, object_format: "sha1", symlink_target: "../../outside")
    parent = Path.join(root, "owned-bad")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    assert {:error, "unsafe_symlink"} =
             ImmutableGitSource.reconstruct(source, "source", commit, tree, identity,
               timeout_ms: 15_000
             )
  end

  test "reconstruct_for_test rejects oversized trees", context do
    parent = Path.join(context.root, "owned-big")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    assert {:error, "unsupported_or_oversized_tree"} =
             ImmutableGitSource.reconstruct_for_test(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000,
               max_entries: 1
             )
  end

  test "CodingBenchmark wrapper maps budget errors and emits compat telemetry", context do
    alias Arbor.Commands.CodingBenchmark.Git, as: CompatGit

    parent = self()
    handler = "cb-git-compat-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:arbor, :commands, :coding_benchmark, :git_object_batch],
      fn _event, measurements, _meta, _cfg -> send(parent, {:compat, measurements}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    commit = context.commit

    assert {:ok, objects} =
             CompatGit.read_objects(
               context.source,
               [%{oid: commit, type: "commit"}],
               15_000
             )

    assert Map.has_key?(objects, commit)
    assert_receive {:compat, %{object_count: 1}}, 1_000

    assert {:error, "fixture_object_attestation_failed"} =
             CompatGit.read_objects(
               context.source,
               [%{oid: commit, type: "commit"}],
               15_000,
               max_object_bytes: 1
             )
  end

  test "ignores ambient GIT_DIR and GIT_WORK_TREE", context do
    parent = Path.join(context.root, "owned-env")
    {:ok, identity} = Shell.create_private_owned_tree(parent)

    previous_dir = System.get_env("GIT_DIR")
    previous_wt = System.get_env("GIT_WORK_TREE")
    System.put_env("GIT_DIR", Path.join(context.root, "missing.git"))
    System.put_env("GIT_WORK_TREE", Path.join(context.root, "missing-wt"))

    on_exit(fn ->
      restore_env("GIT_DIR", previous_dir)
      restore_env("GIT_WORK_TREE", previous_wt)
    end)

    assert :ok =
             ImmutableGitSource.reconstruct(
               context.source,
               "source",
               context.commit,
               context.tree,
               identity,
               timeout_ms: 15_000
             )
  end

  defp build_repo!(repo, opts) do
    case build_repo(repo, opts) do
      {:ok, commit, tree} -> {commit, tree}
      {:error, reason} -> flunk("failed to build repo: #{inspect(reason)}")
    end
  end

  defp build_repo(repo, opts) do
    File.mkdir_p!(repo)
    format = Keyword.get(opts, :object_format, "sha1")
    symlink_target = Keyword.get(opts, :symlink_target, "README.md")

    init_args =
      if format == "sha256" do
        ["init", "--quiet", "--initial-branch=main", "--object-format=sha256"]
      else
        ["init", "--quiet", "--initial-branch=main"]
      end

    with :ok <- git_ok(repo, init_args),
         :ok <- git_ok(repo, ["config", "user.email", "igs@example.com"]),
         :ok <- git_ok(repo, ["config", "user.name", "IGS"]),
         :ok <- git_ok(repo, ["config", "core.hooksPath", "/dev/null"]) do
      File.write!(Path.join(repo, "README.md"), "hello\n")
      File.ln_s!(symlink_target, Path.join(repo, "README.link"))
      File.mkdir_p!(Path.join(repo, "lib"))
      File.write!(Path.join(repo, "lib/a.ex"), "a\n")

      with :ok <- git_ok(repo, ["add", "--", "README.md", "README.link", "lib/a.ex"]),
           :ok <-
             git_ok(repo, ["commit", "--quiet", "--no-verify", "--no-gpg-sign", "-m", "base"]) do
        commit = git!(repo, ["rev-parse", "HEAD"])
        tree = git!(repo, ["rev-parse", "HEAD^{tree}"])
        {:ok, commit, tree}
      end
    else
      {:error, reason} ->
        if format == "sha256" and String.contains?(to_string(reason), "git_failed") do
          {:error, :sha256_unsupported}
        else
          {:error, reason}
        end
    end
  end

  defp git!(workdir, args) do
    case Git.run(workdir, args, 15_000) do
      {:ok, output} -> String.trim(output)
      {:error, reason} -> flunk("git failed: #{reason}")
    end
  end

  defp git_ok(workdir, args) do
    case Git.run(workdir, args, 15_000) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp tmp_dir!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        prefix <> "-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.mkdir_p!(path)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
