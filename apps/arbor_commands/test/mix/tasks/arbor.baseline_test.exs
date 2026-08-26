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

    image_build = fn request ->
      send(self(), {:image_build, request})

      {:ok,
       %{
         index_digest: @index,
         manifest_digest: @manifest,
         image: "docker.io/arbor/validation@" <> @index
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
end
