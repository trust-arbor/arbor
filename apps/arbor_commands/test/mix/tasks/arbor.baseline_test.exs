defmodule Mix.Tasks.Arbor.BaselineTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Mix.Tasks.Arbor.Baseline.{Activate, Build, Status}

  @moduletag :fast

  @hex64 String.duplicate("a", 64)
  @index "sha256:" <> String.duplicate("b", 64)
  @manifest "sha256:" <> String.duplicate("c", 64)

  defmodule FakeShell do
    @moduledoc false

    def build_linux_dependency_baseline(source_root, metadata) do
      send(test_pid(), {:build_linux_dependency_baseline, source_root, metadata})

      document = %{
        manifest: Map.put(metadata, :baseline_tree_digest, metadata_tree(metadata)),
        entries: [
          %{
            path: "ok",
            type: "regular",
            size: 3,
            sha256: String.duplicate("d", 64),
            executable: false
          }
        ]
      }

      {:ok, document, %{"platform" => metadata.platform}}
    end

    def linux_dependency_baseline_tree_digest(_source_root, _platform) do
      {:ok, String.duplicate("a", 64)}
    end

    def linux_dependency_baseline_status, do: %{"state" => "pinned", "reason" => nil}

    def linux_dependency_baseline_mix_lock_digest, do: {:ok, String.duplicate("e", 64)}

    def validation_runtime_status,
      do: %{"state" => "pinned", "reason" => nil, "driver" => "podman"}

    def validation_runtime_probe, do: {:ok, %{"state" => "available", "driver" => "podman"}}

    defp metadata_tree(%{mix_lock_digest: _}), do: String.duplicate("a", 64)
    defp metadata_tree(_), do: String.duplicate("a", 64)

    defp test_pid, do: :persistent_term.get({__MODULE__, :test_pid})
  end

  setup do
    :persistent_term.put({FakeShell, :test_pid}, self())

    root =
      Path.join(System.tmp_dir!(), "arbor-baseline-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "fetch and compile share one staging Mix env that redirects the build path" do
    # Regression (ombp, 2026-08-27, F1): `deps.get` ran with only MIX_DEPS_PATH
    # redirected, so Mix's post-fetch cleanup deleted every fetched dep's
    # compiled build from the checkout's own _build/dev.
    env = Arbor.Commands.Baseline.staging_mix_env("/tmp/x/baseline-staging")

    assert {"MIX_DEPS_PATH", "/tmp/x/baseline-staging"} in env
    assert {"MIX_BUILD_PATH", "/tmp/x/baseline-staging-build"} in env
    assert {"MIX_ENV", "test"} in env

    assert Arbor.Commands.Baseline.staging_build_path("/tmp/x/baseline-staging") ==
             "/tmp/x/baseline-staging-build"
  end

  test "activate writes mode 0400 and does not fetch", %{root: root} do
    digest = @hex64
    baseline_dir = Path.join([root, "baseline", digest])
    File.mkdir_p!(baseline_dir)
    File.chmod!(baseline_dir, 0o700)

    document = valid_oci_document(root, baseline_dir)

    source = Path.join(baseline_dir, "baseline.json")
    File.write!(source, Jason.encode!(document))
    File.chmod!(source, 0o400)

    network = fn _ -> flunk("activate must not fetch") end

    dest = Path.join(root, "validation-runtime.json")

    assert {:ok, report} =
             Activate.execute([digest],
               arbor_home: root,
               config_path: dest,
               network: network
             )

    assert report["restart_required"] == true
    assert File.exists?(dest)
    assert {:ok, %File.Stat{type: :regular} = stat} = File.lstat(dest)
    assert (stat.mode &&& 0o777) == 0o400
    refute_received {:network, _}
  end

  test "activate refuses a group-writable ancestor with a pin remedy", %{root: root} do
    digest = @hex64
    baseline_dir = Path.join([root, "baseline", digest])
    File.mkdir_p!(baseline_dir)
    File.chmod!(baseline_dir, 0o700)
    source = Path.join(baseline_dir, "baseline.json")
    File.write!(source, Jason.encode!(valid_oci_document(root, baseline_dir)))
    File.chmod!(source, 0o400)

    dest_dir = Path.join(root, "config")
    dest = Path.join(dest_dir, "validation-runtime.json")
    File.chmod!(root, 0o775)

    assert {:error, {:validation_runtime_untrusted, :config_file_untrusted}} =
             Activate.execute([digest],
               arbor_home: root,
               config_path: dest,
               network: fn _ -> flunk("activate must not fetch") end
             )

    assert File.exists?(dest)
    File.chmod!(root, 0o700)
  end

  test "build does not overwrite active validation-runtime.json", %{root: root} do
    {repo, deps} = fixture_repo!(root)
    active = Path.join(root, "validation-runtime.json")
    File.write!(active, "do-not-touch")
    File.chmod!(active, 0o400)

    image_id = "sha256:" <> String.duplicate("1", 64)

    image_build = fn request ->
      send(self(), {:image_build, request})

      {:ok,
       %{
         index_digest: @index,
         manifest_digest: @manifest,
         image: "docker.io/arbor/validation@" <> @index,
         image_id: image_id
       }}
    end

    assert {:ok, report} =
             Build.execute([],
               arbor_home: root,
               repo_root: repo,
               deps_path: deps,
               platform: "linux/amd64",
               active_config_path: active,
               image_build: image_build,
               deps_fetch: fn _ctx -> :ok end,
               deps_compile: fn _ctx -> :ok end,
               smoke_test: fn copy, _platform ->
                 refute copy == deps
                 :ok
               end,
               shell: FakeShell
             )

    assert File.read!(active) == "do-not-touch"
    assert report["active_config_path"] == active
    assert File.exists?(report["baseline_root"])
    assert_received {:image_build, request}
    assert request.platform == "linux/amd64"

    baseline_json =
      report["baseline_root"]
      |> Path.join("baseline.json")
      |> File.read!()
      |> Jason.decode!()

    assert baseline_json["image_policy"]["image_id"] == image_id
    assert baseline_json["image_policy"]["manifest_digest"] == @manifest
    assert report["image_id"] == image_id
  end

  test "second build with an unchanged digest replaces 0400 tree and records the new image id",
       %{root: root} do
    {repo, deps} = fixture_repo!(root)
    artifact = Path.join(deps, "sqlite_vec/priv/0.1.5/vec0.so")

    first_id = "sha256:" <> String.duplicate("1", 64)
    second_id = "sha256:" <> String.duplicate("2", 64)
    {:ok, agent} = Agent.start_link(fn -> first_id end)

    image_build = fn _request ->
      id = Agent.get(agent, & &1)

      {:ok,
       %{
         index_digest: @index,
         manifest_digest: @manifest,
         image: "docker.io/arbor/validation@" <> @index,
         image_id: id
       }}
    end

    opts = [
      arbor_home: root,
      repo_root: repo,
      deps_path: deps,
      platform: "linux/amd64",
      active_config_path: Path.join(root, "validation-runtime.json"),
      image_build: image_build,
      deps_fetch: fn _ctx -> :ok end,
      deps_compile: fn ctx ->
        send(self(), {:deps_compile, ctx.deps_path})
        dest = Path.join(ctx.deps_path, "sqlite_vec/priv/0.1.5")
        File.mkdir_p!(dest)
        path = Path.join(dest, "vec0.so")
        unless File.exists?(path), do: File.write!(path, "native\n")
        compiled = ctx.deps_path <> "-build"
        File.mkdir_p!(Path.join(compiled, "lib/test"))
        File.write!(Path.join(compiled, "lib/test/Elixir.Payload.beam"), "beam\n")
        :ok
      end,
      smoke_test: fn _copy, _platform -> :ok end,
      shell: FakeShell
    ]

    assert {:ok, first} = Build.execute([], opts)
    tree_file = Path.join(first["baseline_root"], "tree/sqlite_vec/priv/0.1.5/vec0.so")
    assert File.read!(tree_file) == "native\n"
    assert {:ok, %File.Stat{type: :regular} = stat} = File.lstat(tree_file)
    assert (stat.mode &&& 0o777) == 0o400

    compiled_beam =
      Path.join(first["baseline_root"], "build/lib/test/Elixir.Payload.beam")

    assert File.read!(compiled_beam) == "beam\n"
    assert_received {:deps_compile, ^deps}

    Agent.update(agent, fn _ -> second_id end)
    File.write!(artifact, "native-rebuild\n")

    assert {:ok, second} = Build.execute([], opts)
    assert_received {:deps_compile, ^deps}
    assert second["baseline_root"] == first["baseline_root"]
    assert second["image_id"] == second_id

    assert File.read!(Path.join(second["baseline_root"], "tree/sqlite_vec/priv/0.1.5/vec0.so")) ==
             "native-rebuild\n"

    baseline_json =
      second["baseline_root"]
      |> Path.join("baseline.json")
      |> File.read!()
      |> Jason.decode!()

    assert baseline_json["image_policy"]["image_id"] == second_id
    assert {:ok, %File.Stat{type: :regular} = rebuilt} = File.lstat(tree_file)
    assert (rebuilt.mode &&& 0o777) == 0o400
  end

  test "compiled build copy recreates Mix priv links into the seeded tree", %{root: root} do
    {repo, deps} = mix_layout_fixture!(root)

    assert {:ok, report} =
             Build.execute([],
               arbor_home: root,
               repo_root: repo,
               deps_path: deps,
               platform: "linux/amd64",
               active_config_path: Path.join(root, "validation-runtime.json"),
               image_build: fn _request ->
                 {:ok,
                  %{
                    index_digest: @index,
                    manifest_digest: @manifest,
                    image: "docker.io/arbor/validation@" <> @index,
                    image_id: "sha256:" <> String.duplicate("1", 64)
                  }}
               end,
               deps_fetch: fn _ctx -> :ok end,
               deps_compile: fn ctx ->
                 priv = Path.join(ctx.deps_path, "x/priv")
                 File.mkdir_p!(priv)
                 File.write!(Path.join(priv, "keep"), "ok\n")

                 link_dir = Path.join(ctx.deps_path <> "-build", "test/lib/x")
                 File.mkdir_p!(link_dir)
                 File.ln_s!("../../../../deps/x/priv", Path.join(link_dir, "priv"))
                 :ok
               end,
               smoke_test: fn _copy, _platform -> :ok end,
               shell: FakeShell
             )

    link = Path.join(report["baseline_root"], "build/test/lib/x/priv")
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
    target = File.read_link!(link)
    assert Path.type(target) == :relative
    resolved = Path.expand(target, Path.dirname(link))
    tree_priv = Path.join(report["baseline_root"], "tree/x/priv")
    assert Path.expand(resolved) == Path.expand(tree_priv)
    assert File.read!(Path.join(resolved, "keep")) == "ok\n"
  end

  test "compiled build copy refuses absolute and outside Mix links", %{root: root} do
    {repo, deps} = mix_layout_fixture!(root)

    opts = fn link_target ->
      [
        arbor_home: root,
        repo_root: repo,
        deps_path: deps,
        platform: "linux/amd64",
        active_config_path: Path.join(root, "validation-runtime.json"),
        image_build: fn _request ->
          {:ok,
           %{
             index_digest: @index,
             manifest_digest: @manifest,
             image: "docker.io/arbor/validation@" <> @index,
             image_id: "sha256:" <> String.duplicate("1", 64)
           }}
        end,
        deps_fetch: fn _ctx -> :ok end,
        deps_compile: fn ctx ->
          File.mkdir_p!(Path.join(ctx.deps_path, "x/priv"))
          link_dir = Path.join(ctx.deps_path <> "-build", "test/lib/x")
          File.rm_rf!(link_dir)
          File.mkdir_p!(link_dir)
          File.ln_s!(link_target, Path.join(link_dir, "priv"))
          :ok
        end,
        smoke_test: fn _copy, _platform -> :ok end,
        shell: FakeShell
      ]
    end

    assert {:error, :symlink_rejected} = Build.execute([], opts.("/etc/passwd"))
    assert {:error, :symlink_rejected} = Build.execute([], opts.("../../../../../../tmp/outside"))
  end

  test "compiled build copy translates source-staging Mix links and omits rebar _build",
       %{root: root} do
    {repo, deps} = mix_layout_fixture!(root)

    assert {:ok, report} =
             Build.execute([],
               arbor_home: root,
               repo_root: repo,
               deps_path: deps,
               platform: "linux/amd64",
               active_config_path: Path.join(root, "validation-runtime.json"),
               image_build: fn _request ->
                 {:ok,
                  %{
                    index_digest: @index,
                    manifest_digest: @manifest,
                    image: "docker.io/arbor/validation@" <> @index,
                    image_id: "sha256:" <> String.duplicate("1", 64)
                  }}
               end,
               deps_fetch: fn _ctx -> :ok end,
               deps_compile: fn ctx ->
                 priv = Path.join(ctx.deps_path, "d/priv")
                 File.mkdir_p!(priv)
                 File.write!(Path.join(priv, "keep"), "ok\n")

                 default_plugin = Path.join(ctx.deps_path, "d/_build/default/plugins")
                 File.mkdir_p!(default_plugin)
                 File.write!(Path.join(default_plugin, "p"), "plugin\n")
                 prod_plugin = Path.join(ctx.deps_path, "d/_build/prod/plugins")
                 File.mkdir_p!(prod_plugin)

                 File.ln_s!(
                   Path.join(default_plugin, "p"),
                   Path.join(prod_plugin, "p")
                 )

                 link_dir = Path.join(ctx.deps_path <> "-build", "lib/d")
                 File.mkdir_p!(link_dir)

                 File.ln_s!(
                   "../../../" <> Path.basename(ctx.deps_path) <> "/d/priv",
                   Path.join(link_dir, "priv")
                 )

                 :ok
               end,
               smoke_test: fn copy, _platform ->
                 refute File.exists?(Path.join(copy, "d/_build"))
                 :ok
               end,
               shell: FakeShell
             )

    link = Path.join(report["baseline_root"], "build/lib/d/priv")
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
    target = File.read_link!(link)
    assert Path.type(target) == :relative
    resolved = Path.expand(target, Path.dirname(link))
    tree_priv = Path.join(report["baseline_root"], "tree/d/priv")
    assert Path.expand(resolved) == Path.expand(tree_priv)
    assert File.read!(Path.join(resolved, "keep")) == "ok\n"
    refute File.exists?(Path.join(report["baseline_root"], "tree/d/_build"))
  end

  test "compiled build copy skips in-umbrella app lib entries", %{root: root} do
    {repo, deps} = mix_layout_fixture!(root)
    File.mkdir_p!(Path.join(repo, "apps/foo/priv"))
    File.write!(Path.join(repo, "apps/foo/priv/keep"), "app\n")

    assert {:ok, report} =
             Build.execute([],
               arbor_home: root,
               repo_root: repo,
               deps_path: deps,
               platform: "linux/amd64",
               active_config_path: Path.join(root, "validation-runtime.json"),
               image_build: fn _request ->
                 {:ok,
                  %{
                    index_digest: @index,
                    manifest_digest: @manifest,
                    image: "docker.io/arbor/validation@" <> @index,
                    image_id: "sha256:" <> String.duplicate("1", 64)
                  }}
               end,
               deps_fetch: fn _ctx -> :ok end,
               deps_compile: fn ctx ->
                 priv = Path.join(ctx.deps_path, "dep/priv")
                 File.mkdir_p!(priv)
                 File.write!(Path.join(priv, "keep"), "dep\n")

                 dep_dir = Path.join(ctx.deps_path <> "-build", "lib/dep")
                 File.mkdir_p!(dep_dir)

                 File.ln_s!(
                   "../../../" <> Path.basename(ctx.deps_path) <> "/dep/priv",
                   Path.join(dep_dir, "priv")
                 )

                 foo_dir = Path.join(ctx.deps_path <> "-build", "lib/foo")
                 File.mkdir_p!(foo_dir)

                 File.ln_s!(
                   "../../../../repo/apps/foo/priv",
                   Path.join(foo_dir, "priv")
                 )

                 :ok
               end,
               smoke_test: fn _copy, _platform -> :ok end,
               shell: FakeShell
             )

    assert {:ok, %File.Stat{type: :symlink}} =
             File.lstat(Path.join(report["baseline_root"], "build/lib/dep/priv"))

    refute File.exists?(Path.join(report["baseline_root"], "build/lib/foo"))
  end

  test "status uses the Shell facade and never names Authority modules" do
    task_path =
      Path.expand("../../../lib/mix/tasks/arbor.baseline.status.ex", Path.dirname(__ENV__.file))

    commands_path =
      Path.expand("../../../lib/arbor/commands/baseline.ex", Path.dirname(__ENV__.file))

    task_source = File.read!(task_path)
    commands_source = File.read!(commands_path)

    refute task_source =~ "LinuxDependencyBaselineAuthority"
    refute task_source =~ "ValidationRuntime.Authority"
    refute task_source =~ "OciProbeRuntime"
    assert commands_source =~ "shell.validation_runtime_status"
    assert commands_source =~ "shell.linux_dependency_baseline_status"
    assert commands_source =~ "shell.validation_runtime_probe"

    assert {:ok, report, true} =
             Status.execute(["--json"],
               shell: FakeShell,
               architecture: "x86_64-pc-linux-gnu",
               platform: "linux/amd64",
               head_mix_lock_digest: String.duplicate("e", 64),
               probe: true
             )

    assert report["driver"] == "podman"
    assert report["image_reachable"] == true
    assert report["mix_lock_matches_head"] == true
    assert report["guest_platform"] == "linux/amd64"
  end

  defp valid_oci_document(root, baseline_dir) do
    %{
      "runtime" => "oci",
      "linux_dependency_baseline" => %{
        "source_root" => Path.join(baseline_dir, "tree"),
        "manifest_path" => Path.join(baseline_dir, "manifest.json")
      },
      "image_policy" => %{
        "image" => "docker.io/arbor/validation@" <> @index,
        "image_id" => "sha256:" <> String.duplicate("1", 64),
        "manifest_digest" => @manifest,
        "env" => ["MIX_HOME=/usr/local/.mix"],
        "labels" => %{"org.arbor.validation.schema" => "1"},
        "mix_lock_digest" => String.duplicate("e", 64),
        "baseline_tree_digest" => @hex64,
        "toolchain" => %{"erlang" => "28.4.1", "elixir" => "1.19.5-otp-28"},
        "platform" => "linux/amd64"
      },
      "unit_journal_path" => Path.join(root, "oci-unit-journal.json")
    }
  end

  defp fixture_repo!(root) do
    repo = Path.join(root, "repo")
    deps = Path.join(root, "deps-tree")
    File.mkdir_p!(repo)
    File.mkdir_p!(deps)
    File.write!(Path.join(repo, ".tool-versions"), "erlang 28.4.1\nelixir 1.19.5-otp-28\n")
    File.write!(Path.join(repo, "mix.lock"), "%{}\n")
    File.write!(Path.join(deps, "ok"), "ok\n")
    {repo, deps}
  end

  defp mix_layout_fixture!(root) do
    repo = Path.join(root, "repo")
    deps = Path.join(root, "deps")
    File.mkdir_p!(repo)
    File.mkdir_p!(deps)
    File.write!(Path.join(repo, ".tool-versions"), "erlang 28.4.1\nelixir 1.19.5-otp-28\n")
    File.write!(Path.join(repo, "mix.lock"), "%{}\n")
    File.write!(Path.join(deps, "ok"), "ok\n")
    {repo, deps}
  end
end
