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
    "arbor_kernel_runtime",
    "arbor_security",
    "arbor_persistence_host",
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
          %{path: "packages/arbor_kernel/test/kernel_test.exs", mode: "100644", oid: oid},
          %{path: "packages/arbor_signals/lib/arbor/signals.ex", mode: "100644", oid: oid},
          %{
            path: "packages/arbor_persistence/lib/arbor/persistence/core.ex",
            mode: "100644",
            oid: oid
          },
          %{
            path: "packages/arbor_persistence_sql/lib/arbor/persistence/sql/repo.ex",
            mode: "100644",
            oid: oid
          },
          %{
            path: "apps/arbor_persistence_host/lib/arbor/persistence.ex",
            mode: "100644",
            oid: oid
          },
          %{path: "apps/arbor_persistence/lib/arbor/persistence.ex", mode: "100644", oid: oid},
          %{
            path: "packages/arbor_persistence_eventstore/lib/arbor/persistence/ecto.ex",
            mode: "100644",
            oid: oid
          },
          %{
            path: "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json",
            mode: "100644",
            oid: oid
          },
          %{path: "apps/arbor_dashboard/lib/x.ex", mode: "100644", oid: oid}
        ]

    assert {:ok, paths} = SourcePolicy.select(triples)
    assert "packages/arbor_kernel/mix.exs" in paths
    assert "packages/arbor_kernel/test/kernel_test.exs" in paths
    assert "packages/arbor_signals/mix.exs" in paths
    assert "packages/arbor_signals/lib/arbor/signals.ex" in paths
    assert "packages/arbor_persistence/lib/arbor/persistence/core.ex" in paths
    assert "packages/arbor_persistence_sql/lib/arbor/persistence/sql/repo.ex" in paths
    assert "apps/arbor_persistence_host/lib/arbor/persistence.ex" in paths
    refute "apps/arbor_persistence/lib/arbor/persistence.ex" in paths
    refute "packages/arbor_persistence_eventstore/lib/arbor/persistence/ecto.ex" in paths
    assert "mix.lock" in paths
    refute "apps/arbor_commands/priv/packaging/safe_recovery_artifact.v1.json" in paths
    refute "apps/arbor_dashboard/lib/x.ex" in paths
    assert paths == Enum.sort(paths)
  end

  @tag :fast
  test "Custody is a required physical build input with an exact package root" do
    oid = String.duplicate("d", 40)
    required = required_triples(oid)
    custody_project = "packages/arbor_custody/mix.exs"
    custody_source = "packages/arbor_custody/lib/arbor/custody.ex"
    custody_test = "packages/arbor_custody/test/custody_test.exs"
    embedded = "apps/arbor_custody/lib/arbor/custody.ex"
    other_package = "packages/arbor_custody_other/lib/arbor/custody.ex"

    extras =
      Enum.map([custody_source, custody_test, embedded, other_package], fn path ->
        %{path: path, mode: "100644", oid: oid}
      end)

    assert custody_project in SourcePolicy.required_files()
    assert {:ok, paths} = SourcePolicy.select(required ++ extras)
    assert custody_project in paths
    assert custody_source in paths
    assert custody_test in paths
    refute embedded in paths
    refute other_package in paths

    assert {:error, :missing_required_input} =
             SourcePolicy.select(Enum.reject(required, &(&1.path == custody_project)) ++ extras)
  end

  @tag :fast
  test "Custody generated tooling exceptions retain exact directory and owner boundaries" do
    for path <- [
          "packages/arbor_custody/.elixir_ls/build/cache",
          "packages/arbor_custody/cover/report.html",
          "packages/arbor_custody/erl_crash.dump"
        ] do
      assert SourcePolicy.ignored_generated_extra?(path)
    end

    refute SourcePolicy.ignored_generated_extra?("packages/arbor_custody/coverup/report.html")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_custody/.elixir_ls_evil/cache")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_custody/erl_crash.dump/x.ex")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_custody_other/cover/report.html")
    refute SourcePolicy.ignored_generated_extra?("apps/arbor_custody/cover/report.html")
  end

  @tag :fast
  test "OAuth is a required physical input without admitting adjacent package or app roots" do
    oid = String.duplicate("e", 40)
    required = required_triples(oid)
    project = "packages/arbor_oauth/mix.exs"
    source = "packages/arbor_oauth/lib/arbor/common/oauth.ex"
    test_source = "packages/arbor_oauth/test/oauth_test.exs"
    embedded = "apps/arbor_oauth/lib/arbor/common/oauth.ex"
    adjacent = "packages/arbor_oauth_other/lib/arbor/common/oauth.ex"

    extras =
      Enum.map([source, test_source, embedded, adjacent], fn path ->
        %{path: path, mode: "100644", oid: oid}
      end)

    assert project in SourcePolicy.required_files()
    assert {:ok, paths} = SourcePolicy.select(required ++ extras)
    assert source in paths
    assert test_source in paths
    refute embedded in paths
    refute adjacent in paths

    assert {:error, :missing_required_input} =
             SourcePolicy.select(Enum.reject(required, &(&1.path == project)) ++ extras)

    assert SourcePolicy.ignored_generated_extra?("packages/arbor_oauth/cover/report.html")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_oauth_other/cover/report.html")
    refute SourcePolicy.ignored_generated_extra?("apps/arbor_oauth/cover/report.html")
  end

  @tag :fast
  test "OIDC is a required physical input with exact package ownership" do
    oid = String.duplicate("f", 40)
    required = required_triples(oid)
    project = "packages/arbor_capabilities_oidc/mix.exs"
    source = "packages/arbor_capabilities_oidc/lib/arbor/capabilities/oidc.ex"
    test_source = "packages/arbor_capabilities_oidc/test/oidc_test.exs"
    embedded = "apps/arbor_capabilities_oidc/lib/arbor/capabilities/oidc.ex"
    adjacent = "packages/arbor_capabilities_oidc_other/lib/arbor/capabilities/oidc.ex"

    extras =
      Enum.map([source, test_source, embedded, adjacent], fn path ->
        %{path: path, mode: "100644", oid: oid}
      end)

    assert project in SourcePolicy.required_files()
    assert {:ok, paths} = SourcePolicy.select(required ++ extras)
    assert source in paths
    assert test_source in paths
    refute embedded in paths
    refute adjacent in paths

    assert {:error, :missing_required_input} =
             SourcePolicy.select(Enum.reject(required, &(&1.path == project)) ++ extras)

    assert SourcePolicy.ignored_generated_extra?(
             "packages/arbor_capabilities_oidc/cover/report.html"
           )

    refute SourcePolicy.ignored_generated_extra?(
             "packages/arbor_capabilities_oidc_other/cover/report.html"
           )

    refute SourcePolicy.ignored_generated_extra?("apps/arbor_capabilities_oidc/cover/report.html")
  end

  @tag :fast
  test "Capabilities Core and Signals adapter are required exact physical inputs" do
    oid = String.duplicate("b", 40)
    required = required_triples(oid)

    for package <- ~w(arbor_capabilities arbor_capabilities_signals) do
      project = "packages/#{package}/mix.exs"
      source = "packages/#{package}/lib/authority.ex"
      test_source = "packages/#{package}/test/authority_test.exs"
      adjacent = "packages/#{package}_other/lib/authority.ex"
      embedded = "apps/#{package}/lib/authority.ex"

      extras =
        Enum.map([source, test_source, adjacent, embedded], fn path ->
          %{path: path, mode: "100644", oid: oid}
        end)

      assert project in SourcePolicy.required_files()
      assert {:ok, paths} = SourcePolicy.select(required ++ extras)
      assert project in paths
      assert source in paths
      assert test_source in paths
      refute adjacent in paths
      refute embedded in paths

      assert {:error, :missing_required_input} =
               SourcePolicy.select(Enum.reject(required, &(&1.path == project)) ++ extras)

      assert SourcePolicy.ignored_generated_extra?("packages/#{package}/cover/report.html")
      refute SourcePolicy.ignored_generated_extra?("packages/#{package}_other/cover/report.html")
      refute SourcePolicy.ignored_generated_extra?("apps/#{package}/cover/report.html")
      refute SourcePolicy.ignored_generated_extra?("packages/#{package}/coverup/report.html")
    end
  end

  @tag :fast
  test "Support includes its native source without admitting adjacent roots" do
    oid = String.duplicate("a", 40)
    required = required_triples(oid)
    project = "packages/arbor_support/mix.exs"
    source = "packages/arbor_support/lib/arbor/common/safe_path.ex"
    native = "packages/arbor_support/c_src/arbor_safe_path_reader.c"
    adjacent = "packages/arbor_support_other/c_src/arbor_safe_path_reader.c"
    embedded = "apps/arbor_support/lib/arbor/common/safe_path.ex"

    extras =
      Enum.map([source, adjacent, embedded], fn path ->
        %{path: path, mode: "100644", oid: oid}
      end)

    assert project in SourcePolicy.required_files()
    assert native in SourcePolicy.required_files()
    assert {:ok, paths} = SourcePolicy.select(required ++ extras)
    assert source in paths
    assert native in paths
    refute adjacent in paths
    refute embedded in paths

    assert {:error, :missing_required_input} =
             SourcePolicy.select(Enum.reject(required, &(&1.path == project)) ++ extras)

    assert {:error, :missing_required_input} =
             SourcePolicy.select(Enum.reject(required, &(&1.path == native)) ++ extras)

    assert SourcePolicy.ignored_generated_extra?("packages/arbor_support/cover/report.html")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_support_other/cover/report.html")
  end

  @tag :fast
  test "enforces the 4999 source-row bound before later work" do
    oid = String.duplicate("c", 40)

    extras =
      Enum.map(1..5_000, fn index ->
        %{
          path: "packages/arbor_kernel/lib/f#{index}.ex",
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
               %{path: "packages/arbor_kernel/lib/x.ex", mode: "120000", oid: oid} | required
             ])

    assert {:error, :unsupported_mode} =
             SourcePolicy.select([
               %{path: "packages/arbor_kernel/lib/x.ex", mode: "100666", oid: oid} | required
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

    desc = Arbor.Shell.trusted_build_native_overlay_descriptor()
    assert Overlay.descriptor() == desc
    assert Overlay.logical_path() == desc["logical_path"]
    assert Overlay.source_path() == desc["logical_path"]
    assert Overlay.staging_rel() == desc["staging_rel"]
    assert Overlay.size() == desc["size"]
    assert Overlay.sha256() == desc["sha256"]
    assert Overlay.logical_path() == @overlay_source_path
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

    assert "packages/arbor_kernel/test/kernel_test.exs" in Enum.map(
             first["build_inputs"],
             & &1["path"]
           )

    refute "unrelated.txt" in Enum.map(first["build_inputs"], & &1["path"])
    refute "AGENTS.md" in Enum.map(first["build_inputs"], & &1["path"])
    assert {:error, :enoent} = File.lstat(Path.join(first["source_root"], "AGENTS.md"))
    assert {:error, :enoent} = File.lstat(Path.join(first["source_root"], ".agents/skills"))
    assert File.regular?(Path.join(first["source_root"], "packages/arbor_kernel/lib/a.ex"))
    assert {:ok, _inventory} = Arbor.Shell.inventory_regular_tree(first["identity"]["path"])

    File.write!(Path.join(root, "packages/arbor_kernel/lib/a.ex"), "dirty-not-read\n")

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
    File.rm!(Path.join(root, "packages/arbor_kernel/lib/a.ex"))
    File.ln_s!("missing", Path.join(root, "packages/arbor_kernel/lib/a.ex"))
    git!(root, ["add", "--", "packages/arbor_kernel/lib/a.ex"])
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
  test "ignored generated tooling state beneath selected roots remains admissible", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git/info"))
    File.write!(Path.join(root, ".git/info/exclude"), ".elixir_ls/\ncover/\nerl_crash.dump\n")

    generated = [
      "apps/arbor_persistence_host/.elixir_ls/build/cache",
      "apps/arbor_security/cover/report.html",
      "apps/arbor_trust/erl_crash.dump",
      "packages/arbor_custody/.elixir_ls/build/cache",
      "packages/arbor_custody/cover/report.html",
      "packages/arbor_custody/erl_crash.dump",
      "packages/arbor_signals/cover/report.html",
      "packages/arbor_persistence/.elixir_ls/build/cache",
      "packages/arbor_persistence_sql/erl_crash.dump"
    ]

    Enum.each(generated, fn relative ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "generated\n")
    end)

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)
    assert {:ok, lease} = stage!(root, overlay, digest)
    on_exit(fn -> SafeRecoveryArtifact.release_source_for_test(lease) end)

    paths = Enum.map(lease["build_inputs"], & &1["path"])
    assert Enum.all?(generated, &SourcePolicy.ignored_generated_extra?/1)
    assert Enum.all?(generated, &(&1 not in paths))
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_kernel/.elixir_ls_evil/x.ex")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_kernel/coverup/x.ex")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_kernel/erl_crash.dump/x.ex")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_signals/coverup/x.ex")
    refute SourcePolicy.ignored_generated_extra?("packages/arbor_signals_other/cover/report.html")
  end

  @tag :slow
  @tag :integration
  test "ignored selected-root extras fail closed", %{root: root} do
    File.mkdir_p!(Path.join(root, ".git/info"))
    File.write!(Path.join(root, ".git/info/exclude"), "ignored-secret\n")
    File.write!(Path.join(root, "ignored-secret"), "outside\n")
    File.write!(Path.join(root, "packages/arbor_kernel/ignored-secret"), "secret\n")

    overlay = "overlay-bytes"
    digest = sha256_hex(overlay)
    assert {:error, :selected_untracked} = stage!(root, overlay, digest)
  end

  @tag :slow
  @tag :integration
  test "core.fileMode=false chmod drift fails closed", %{root: root} do
    git!(root, ["config", "core.fileMode", "false"])
    path = Path.join(root, "packages/arbor_kernel/lib/a.ex")
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
          "path" => "packages/arbor_kernel/lib/f#{index}.ex",
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
    extra = write_unselected_factory_symlinks!(root)

    git_ok!(root, ["init", "--quiet", "--initial-branch=main"])
    git_ok!(root, ["config", "user.email", "e0b2c@example.com"])
    git_ok!(root, ["config", "user.name", "E0B2C"])
    git_ok!(root, ["config", "core.hooksPath", "/dev/null"])
    git_ok!(root, ["add", "--"] ++ files ++ extra)
    git_ok!(root, ["commit", "--quiet", "--no-verify", "--no-gpg-sign", "-m", "base"])
  end

  defp write_unselected_factory_symlinks!(root) do
    File.ln_s!("CLAUDE.md", Path.join(root, "AGENTS.md"))
    File.mkdir_p!(Path.join(root, ".agents"))
    File.ln_s!("../.claude/skills", Path.join(root, ".agents/skills"))
    ["AGENTS.md", ".agents/skills"]
  end

  defp write_umbrella_files!(root) do
    pairs = [
      {"mix.exs", "umbrella\n"},
      {"apps/arbor_commands/mix.exs", "commands\n"},
      {"packages/arbor_kernel/mix.exs", "arbor_kernel\n"},
      {"packages/arbor_kernel/lib/a.ex", "arbor_kernel\n"},
      {"packages/arbor_custody/mix.exs", "custody\n"},
      {"packages/arbor_custody/lib/custody.ex", "custody source\n"},
      {"packages/arbor_support/mix.exs", "support\n"},
      {"packages/arbor_support/lib/support.ex", "support source\n"},
      {"packages/arbor_support/c_src/arbor_safe_path_reader.c", "native source\n"},
      {"packages/arbor_oauth/mix.exs", "oauth\n"},
      {"packages/arbor_oauth/lib/oauth.ex", "oauth source\n"},
      {"packages/arbor_capabilities/mix.exs", "capabilities\n"},
      {"packages/arbor_capabilities/lib/authority.ex", "capabilities source\n"},
      {"packages/arbor_capabilities_signals/mix.exs", "capabilities signals\n"},
      {"packages/arbor_capabilities_signals/lib/adapter.ex", "adapter source\n"},
      {"packages/arbor_capabilities_oidc/mix.exs", "oidc\n"},
      {"packages/arbor_capabilities_oidc/lib/oidc.ex", "oidc source\n"},
      {"packages/arbor_signals/mix.exs", "signals\n"},
      {"packages/arbor_signals/lib/signals.ex", "signals source\n"},
      {"packages/arbor_persistence/mix.exs", "persistence\n"},
      {"packages/arbor_persistence/lib/core.ex", "core source\n"},
      {"packages/arbor_persistence_sql/mix.exs", "persistence sql\n"},
      {"packages/arbor_persistence_sql/lib/sql.ex", "sql source\n"},
      {"mix.lock", "lock\n"},
      {".tool-versions", "erlang 28.4.1\n"},
      {"bin/mix", "#!/bin/sh\n"},
      {"build_support/mix_project_paths.exs", "paths\n"},
      {"config/config.exs", "config\n"},
      {"config/prod.exs", "prod\n"},
      {"config/provider_route_profile.exs", "routes\n"},
      {"config/runtime.exs", "runtime\n"},
      {"packages/arbor_kernel/test/kernel_test.exs", "test\n"}
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
