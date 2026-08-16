defmodule Arbor.Commands.SafeRecoveryArtifact.SourceStagingTest do
  use ExUnit.Case, async: false

  alias Arbor.Commands.ImmutableGitSource.Git
  alias Arbor.Commands.SafeRecoveryArtifact
  alias Arbor.Commands.SafeRecoveryArtifact.{Overlay, SourceLease, SourcePolicy}

  @moduletag timeout: 90_000

  @overlay_source_path "deps/sqlite_vec/priv/0.1.5/vec0.dylib"
  @overlay_size 126_600
  @overlay_sha256 "45d67c7868152c1b9b4b86cd1cea1d8834136e13f8e0348648b89f8aa90e7b5b"

  @apps [
    "arbor_kernel",
    "arbor_kernel_runtime",
    "arbor_security",
    "arbor_persistence",
    "arbor_trust"
  ]

  setup_all do
    template = tmp_dir!("e0b2c-template")
    build_umbrella!(template)
    on_exit(fn -> File.rm_rf(template) end)
    {:ok, template: template}
  end

  setup %{template: template} do
    root =
      Path.join(
        System.tmp_dir!(),
        "e0b2c-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      )

    File.cp_r!(template, root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  @tag :fast
  test "selects required files, app test blobs, and excludes the output manifest" do
    oid = String.duplicate("a", 40)

    triples =
      required_triples(oid) ++
        [
          %{path: "apps/arbor_kernel/test/kernel_test.exs", mode: "100644", oid: oid},
          %{
            path: "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json",
            mode: "100644",
            oid: oid
          },
          %{path: "apps/arbor_dashboard/lib/x.ex", mode: "100644", oid: oid}
        ]

    assert {:ok, paths} = SourcePolicy.select(triples)
    assert "apps/arbor_kernel/mix.exs" in paths
    assert "apps/arbor_kernel/test/kernel_test.exs" in paths
    assert "mix.lock" in paths
    refute "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json" in paths
    refute "apps/arbor_dashboard/lib/x.ex" in paths
    assert paths == Enum.sort(paths)
  end

  @tag :fast
  test "enforces the 4999 source-row bound before later work" do
    oid = String.duplicate("c", 40)

    extras =
      Enum.map(1..5_000, fn index ->
        %{
          path: "apps/arbor_kernel/lib/f#{index}.ex",
          mode: "100644",
          oid: oid
        }
      end)

    assert {:error, :file_limit} = SourcePolicy.select(required_triples(oid) ++ extras)
  end

  @tag :fast
  test "ignores tree records and rejects symlink or unsupported blob modes" do
    oid = String.duplicate("b", 40)
    required = required_triples(oid)

    assert {:ok, _} = SourcePolicy.select(required)

    assert {:error, :symlink_input} =
             SourcePolicy.select([
               %{path: "apps/arbor_kernel/lib/x.ex", mode: "120000", oid: oid} | required
             ])

    assert {:error, :unsupported_mode} =
             SourcePolicy.select([
               %{path: "apps/arbor_kernel/lib/x.ex", mode: "100666", oid: oid} | required
             ])

    assert {:error, :missing_required_input} =
             SourcePolicy.select(Enum.reject(required, &(&1.path == "mix.lock")))
  end

  @tag :slow
  @tag :integration
  test "two staging runs are identical and ignore unrelated dirty paths", %{root: root} do
    File.write!(Path.join(root, "apps/arbor_commands/mix.exs"), "dirty\n")
    File.write!(Path.join(root, "unrelated.txt"), "nope\n")
    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)

    assert {:ok, first} = stage!(root, overlay, digest)
    assert {:ok, second} = stage!(root, overlay, digest)

    on_exit(fn ->
      _ = SafeRecoveryArtifact.release_source_for_test(first)
      _ = SafeRecoveryArtifact.release_source_for_test(second)
    end)

    assert Overlay.logical_path() == @overlay_source_path
    assert Overlay.source_path() == @overlay_source_path
    assert Overlay.size() == @overlay_size
    assert Overlay.sha256() == @overlay_sha256
    assert first["build_inputs"] == second["build_inputs"]
    assert first["reconstructed_tree"] == second["reconstructed_tree"]
    assert first["tree"] == first["reconstructed_tree"]
    assert first["source_root"] != second["source_root"]
    assert first["source_root"] == SourceLease.expected_source_root(first["identity"]["path"])
    assert first["overlay_path"] == SourceLease.expected_overlay_path(first["identity"]["path"])
    assert File.regular?(first["overlay_path"])
    assert sha256_hex(File.read!(first["overlay_path"])) == digest
    refute String.starts_with?(first["overlay_path"], first["source_root"] <> "/")
    assert Enum.sort_by(first["build_inputs"], & &1["path"]) == first["build_inputs"]
    assert @overlay_source_path in Enum.map(first["build_inputs"], & &1["path"])

    assert "apps/arbor_kernel/test/kernel_test.exs" in Enum.map(
             first["build_inputs"],
             & &1["path"]
           )

    refute "unrelated.txt" in Enum.map(first["build_inputs"], & &1["path"])

    File.write!(Path.join(root, "apps/arbor_kernel/lib/a.ex"), "dirty-not-read\n")

    assert {:error, :selected_worktree_drift} = stage!(root, overlay, digest)
  end

  @tag :slow
  @tag :integration
  test "selected staged, unstaged, and untracked dirt fail closed", %{root: root} do
    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)

    File.write!(Path.join(root, "apps/arbor_trust/lib/a.ex"), "staged\n")
    git!(root, ["add", "--", "apps/arbor_trust/lib/a.ex"])

    assert {:error, :selected_index_drift} = stage!(root, overlay, digest)

    git!(root, ["reset", "HEAD", "--", "apps/arbor_trust/lib/a.ex"])
    git!(root, ["checkout", "--", "apps/arbor_trust/lib/a.ex"])
    File.write!(Path.join(root, "apps/arbor_trust/lib/a.ex"), "unstaged\n")

    assert {:error, :selected_worktree_drift} = stage!(root, overlay, digest)

    File.write!(Path.join(root, "apps/arbor_trust/lib/a.ex"), "trust\n")
    File.write!(Path.join(root, "apps/arbor_trust/lib/new.ex"), "untracked\n")

    assert {:error, reason} = stage!(root, overlay, digest)
    assert reason in [:selected_untracked, :selected_index_drift]
  end

  @tag :slow
  @tag :integration
  test "unrelated rename remains admissible and selected rename fails", %{root: root} do
    File.write!(Path.join(root, "notes.txt"), "notes\n")
    git!(root, ["add", "--", "notes.txt"])
    git!(root, ["commit", "--quiet", "--no-verify", "--no-gpg-sign", "-m", "notes"])
    git!(root, ["mv", "notes.txt", "other-notes.txt"])

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)
    assert {:ok, lease} = stage!(root, overlay, digest)
    on_exit(fn -> SafeRecoveryArtifact.release_source_for_test(lease) end)

    git!(root, ["mv", "apps/arbor_trust/lib/a.ex", "apps/arbor_trust/lib/moved.ex"])
    assert {:error, reason} = stage!(root, overlay, digest)
    assert reason in [:selected_index_drift, :selected_worktree_drift]
  end

  @tag :slow
  @tag :integration
  test "selected symlink fails closed", %{root: root} do
    File.rm!(Path.join(root, "apps/arbor_kernel/lib/a.ex"))
    File.ln_s!("missing", Path.join(root, "apps/arbor_kernel/lib/a.ex"))
    git!(root, ["add", "--", "apps/arbor_kernel/lib/a.ex"])
    git!(root, ["commit", "--quiet", "--no-verify", "--no-gpg-sign", "-m", "link"])

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)

    assert {:error, :symlink_input} = stage!(root, overlay, digest)
  end

  @tag :slow
  @tag :integration
  test "production overlay missing and changed digest fail closed", %{root: root} do
    assert Overlay.logical_path() == @overlay_source_path
    assert Overlay.size() == @overlay_size
    assert Overlay.sha256() == @overlay_sha256
    assert {:error, :overlay_missing} = Overlay.bind(root)

    dead =
      Path.join(
        root,
        "apps/arbor_commands/priv/packaging/native_overlays/v1/aarch64-apple-darwin/sqlite_vec/0.1.5/vec0.dylib"
      )

    File.mkdir_p!(Path.dirname(dead))
    File.write!(dead, :binary.copy(<<0>>, @overlay_size))
    assert {:error, :overlay_missing} = Overlay.bind(root)

    overlay = "overlay-bytes"

    assert {:error, :invalid_opts} =
             SafeRecoveryArtifact.stage_source(
               root: root,
               overlay_bytes: overlay,
               overlay_sha256: sha256_hex(overlay)
             )

    assert {:error, :overlay_missing} =
             SafeRecoveryArtifact.stage_source(root: root, timeout_ms: 15_000)

    real = Path.join(root, @overlay_source_path)
    File.mkdir_p!(Path.dirname(real))
    File.write!(real, :binary.copy(<<0>>, @overlay_size))
    assert {:error, :overlay_digest_mismatch} = Overlay.bind(root)

    assert {:error, :overlay_digest_mismatch} =
             stage!(root, overlay, sha256_hex("other"))
  end

  @tag :fast
  test "rejects lease path tampering, digest tampering, extras, and 4999+overlay bounds" do
    assert Overlay.logical_path() == @overlay_source_path
    assert Overlay.size() == @overlay_size
    assert Overlay.sha256() == @overlay_sha256

    lease = lease_fixture(frozen_inputs())
    assert {:ok, _} = SourceLease.admit(lease)

    assert {:error, :invalid_opts} =
             SourceLease.admit(%{lease | "source_root" => "/tmp/other/source"})

    assert {:error, :invalid_opts} =
             SourceLease.admit(%{lease | "overlay_path" => "/tmp/other/vec0.dylib"})

    assert {:error, :invalid_opts} =
             SourceLease.admit(put_in(lease, ["identity", "path"], "/tmp/other"))

    wrong_path_inputs =
      frozen_inputs()
      |> Enum.map(fn
        %{"path" => @overlay_source_path} = fact ->
          %{fact | "path" => "apps/arbor_commands/priv/packaging/native_overlays/vec0.dylib"}

        fact ->
          fact
      end)
      |> Enum.sort_by(& &1["path"])

    assert {:error, :missing_required_input} =
             SourceLease.admit(%{lease | "build_inputs" => wrong_path_inputs})

    wrong_digest_inputs =
      Enum.map(frozen_inputs(), fn
        %{"path" => @overlay_source_path} = fact ->
          %{fact | "sha256" => String.duplicate("c", 64)}

        fact ->
          fact
      end)

    assert {:error, :overlay_digest_mismatch} =
             SourceLease.admit(%{lease | "build_inputs" => wrong_digest_inputs})

    dashboard =
      %{"path" => "apps/arbor_dashboard/lib/x.ex", "sha256" => String.duplicate("b", 64)}

    assert {:error, :extra_required_input} =
             SourceLease.admit(%{
               lease
               | "build_inputs" => Enum.sort_by([dashboard | frozen_inputs()], & &1["path"])
             })

    excluded = %{
      "path" => "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json",
      "sha256" => String.duplicate("b", 64)
    }

    assert {:error, :extra_required_input} =
             SourceLease.admit(%{
               lease
               | "build_inputs" => Enum.sort_by([excluded | frozen_inputs()], & &1["path"])
             })

    bounded = padded_source_inputs(4_999)
    assert {:ok, _} = SourceLease.admit(%{lease | "build_inputs" => bounded})

    overflow = padded_source_inputs(5_000)
    assert {:error, :file_limit} = SourceLease.admit(%{lease | "build_inputs" => overflow})
  end

  @tag :fast
  test "overlay ancestor symlink and leaf hardlink are rejected", %{root: root} do
    dest = Path.join(root, @overlay_source_path)
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, "overlay-bytes")
    alt = dest <> ".alt"
    File.ln!(dest, alt)

    assert {:error, :overlay_not_regular} =
             Overlay.bind_expected(root, 13, sha256_hex("overlay-bytes"))

    File.rm!(alt)
    File.rm!(dest)
    File.rm_rf!(Path.dirname(dest))
    File.ln_s!(root, Path.dirname(dest))

    assert {:error, :overlay_not_regular} =
             Overlay.bind_expected(root, 13, sha256_hex("overlay-bytes"))
  end

  @tag :slow
  @tag :integration
  test "cleanup failure never reports success", %{root: root} do
    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)

    assert {:error, {:cleanup_retained, _reason, identity}} =
             SafeRecoveryArtifact.stage_source_for_test(
               root: root,
               overlay_bytes: overlay,
               overlay_sha256: digest,
               cleanup_fault: :fail_release_after_error,
               timeout_ms: 15_000
             )

    assert is_map(identity)
    assert is_binary(identity.path)
    File.rm_rf(identity.path)
    File.rm_rf(identity.path <> ".kept")

    assert {:ok, lease} = stage!(root, overlay, digest)

    assert {:error, {:cleanup_retained, :cleanup_identity_mismatch, _identity}} =
             SafeRecoveryArtifact.release_source_for_test(lease, :force_cleanup_failure)

    File.rm_rf(lease["identity"]["path"])
    File.rm_rf(lease["identity"]["path"] <> ".kept")
  end

  @tag :slow
  @tag :integration
  test "ignored extras outside selected roots remain admissible", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git/info"))
    File.write!(Path.join(root, ".git/info/exclude"), "ignored-secret\n")
    File.write!(Path.join(root, "ignored-secret"), "outside\n")
    File.write!(Path.join(root, "apps/arbor_commands/ignored-secret"), "commands\n")

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)
    assert {:ok, lease} = stage!(root, overlay, digest)
    on_exit(fn -> SafeRecoveryArtifact.release_source_for_test(lease) end)

    refute "ignored-secret" in Enum.map(lease["build_inputs"], & &1["path"])
    refute "apps/arbor_commands/ignored-secret" in Enum.map(lease["build_inputs"], & &1["path"])
  end

  @tag :slow
  @tag :integration
  test "ignored selected-root extras fail closed", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git/info"))
    File.write!(Path.join(root, ".git/info/exclude"), "ignored-secret\n")
    File.write!(Path.join(root, "ignored-secret"), "outside\n")
    File.write!(Path.join(root, "apps/arbor_kernel/ignored-secret"), "secret\n")

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)
    assert {:error, :selected_untracked} = stage!(root, overlay, digest)
  end

  @tag :slow
  @tag :integration
  test "core.fileMode=false chmod drift fails closed", %{root: root} do
    git!(root, ["config", "core.fileMode", "false"])
    path = Path.join(root, "apps/arbor_kernel/lib/a.ex")
    File.chmod!(path, 0o755)

    assert {:ok, output} =
             Git.run(root, ["status", "--porcelain=v1", "--untracked-files=all"], 15_000)

    assert String.trim(output) == ""

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)
    assert {:error, :selected_worktree_drift} = stage!(root, overlay, digest)
  end

  @tag :slow
  @tag :integration
  test "source object alternates fail closed before staging", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git/objects/info"))
    File.write!(Path.join(root, ".git/objects/info/alternates"), "/tmp/other.git/objects\n")

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)
    assert {:error, :source_object_alternates} = stage!(root, overlay, digest)
  end

  defp stage!(root, overlay, digest) do
    SafeRecoveryArtifact.stage_source_for_test(
      root: root,
      overlay_bytes: overlay,
      overlay_sha256: digest,
      timeout_ms: 15_000
    )
  end

  defp required_triples(oid) do
    Enum.map(SourcePolicy.required_files(), fn path ->
      %{path: path, mode: "100644", oid: oid}
    end)
  end

  defp frozen_inputs(extra \\ []) do
    required =
      Enum.map(SourcePolicy.required_files(), fn path ->
        %{"path" => path, "sha256" => String.duplicate("b", 64)}
      end)

    overlay = %{"path" => @overlay_source_path, "sha256" => @overlay_sha256}
    Enum.sort_by(required ++ [overlay] ++ extra, & &1["path"])
  end

  defp padded_source_inputs(source_count) do
    required = SourcePolicy.required_files()
    padding_count = source_count - length(required)

    padding =
      Enum.map(1..padding_count, fn index ->
        %{
          "path" => "apps/arbor_kernel/lib/f#{index}.ex",
          "sha256" => String.duplicate("b", 64)
        }
      end)

    frozen_inputs(padding)
  end

  defp lease_fixture(inputs) do
    oid = String.duplicate("a", 40)

    identity = %{
      "path" => "/tmp/arbor-e0b2c-source-test",
      "type" => "directory",
      "device" => 1,
      "minor_device" => 0,
      "inode" => 2
    }

    %{
      "schema" => SourceLease.schema(),
      "commit" => oid,
      "tree" => oid,
      "object_format" => "sha1",
      "reconstructed_tree" => oid,
      "build_inputs" => inputs,
      "source_root" => "/tmp/arbor-e0b2c-source-test/source",
      "overlay_path" => SourceLease.expected_overlay_path("/tmp/arbor-e0b2c-source-test"),
      "identity" => identity
    }
  end

  defp build_umbrella!(root) do
    File.mkdir_p!(root)
    files = write_umbrella_files!(root)

    git_ok!(root, ["init", "--quiet", "--initial-branch=main"])
    git_ok!(root, ["config", "user.email", "e0b2c@example.com"])
    git_ok!(root, ["config", "user.name", "E0B2C"])
    git_ok!(root, ["config", "core.hooksPath", "/dev/null"])
    git_ok!(root, ["add", "--"] ++ files)
    git_ok!(root, ["commit", "--quiet", "--no-verify", "--no-gpg-sign", "-m", "base"])
  end

  defp write_umbrella_files!(root) do
    pairs = [
      {"mix.exs", "umbrella\n"},
      {"apps/arbor_commands/mix.exs", "commands\n"},
      {"mix.lock", "lock\n"},
      {".tool-versions", "erlang 28.4.1\n"},
      {"bin/mix", "#!/bin/sh\n"},
      {"build_support/mix_project_paths.exs", "paths\n"},
      {"config/config.exs", "config\n"},
      {"config/prod.exs", "prod\n"},
      {"config/provider_route_profile.exs", "routes\n"},
      {"config/runtime.exs", "runtime\n"},
      {"apps/arbor_kernel/test/kernel_test.exs", "test\n"}
    ]

    app_pairs =
      Enum.flat_map(@apps, fn app ->
        [
          {"apps/#{app}/mix.exs", app <> "\n"},
          {"apps/#{app}/lib/a.ex", if(app == "arbor_trust", do: "trust\n", else: app <> "\n")}
        ]
      end)

    Enum.map(pairs ++ app_pairs, fn {rel, contents} ->
      path = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      rel
    end)
  end

  defp git!(workdir, args), do: git_ok!(workdir, args)

  defp git_ok!(workdir, args) do
    case Git.run(workdir, args, 15_000) do
      {:ok, _output} -> :ok
      {:error, reason} -> flunk("git failed: #{reason}")
    end
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
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
end
