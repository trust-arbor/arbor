defmodule Arbor.Commands.BaselineCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.Baseline.{ActivateCore, BuildCore, StatusCore}

  @moduletag :fast

  @digest String.duplicate("ab", 32)

  test "layout refuses relative arbor home and projects owner-only dests" do
    assert {:error, :invalid_arbor_home} = BuildCore.layout("relative", @digest)

    assert {:ok, layout} = BuildCore.layout("/home/operator/.arbor", @digest)
    assert layout.tree_dir == "/home/operator/.arbor/baseline/#{@digest}/tree"
    assert layout.default_config_path == "/home/operator/.arbor/validation-runtime.json"

    assert :ok =
             BuildCore.refuse_active_config_mutation(layout, layout.default_config_path)

    assert {:error, :must_not_mutate_active_config} =
             BuildCore.refuse_active_config_mutation(layout, layout.baseline_json_path)
  end

  test "activate paths stay local and reject apple-only documents" do
    assert {:ok, source} = ActivateCore.source_path("/home/operator/.arbor", @digest)
    assert String.ends_with?(source, "/baseline/#{@digest}/baseline.json")

    assert {:ok, dest} = ActivateCore.destination_path("/home/operator/.arbor", nil)
    assert dest == "/home/operator/.arbor/validation-runtime.json"

    assert {:ok, override} =
             ActivateCore.destination_path(
               "/home/operator/.arbor",
               "/tmp/validation-runtime.json"
             )

    assert override == "/tmp/validation-runtime.json"

    image_id = "sha256:" <> String.duplicate("12", 32)

    assert :ok =
             ActivateCore.require_oci_document(%{
               "runtime" => "oci",
               "image_policy" => %{"image_id" => image_id}
             })

    assert {:error, :missing_image_id} =
             ActivateCore.require_oci_document(%{"runtime" => "oci"})

    assert {:error, :apple_only_policy_key} =
             ActivateCore.require_oci_document(%{
               "runtime" => "oci",
               "apple_container" => %{},
               "image_policy" => %{"image_id" => image_id}
             })
  end

  test "image_policy records an optional local image id" do
    image = "docker.io/arbor/validation@sha256:#{@digest}"
    image_id = "sha256:" <> String.duplicate("12", 32)
    labels = %{"org.arbor.validation.schema" => "1"}

    fields = %{
      image: image,
      manifest_digest: "sha256:#{@digest}",
      mix_lock_digest: @digest,
      baseline_tree_digest: @digest,
      erlang: "28.4.1",
      elixir: "1.19.5-otp-28",
      platform: "linux/amd64",
      env: [],
      labels: labels
    }

    assert {:ok, policy} = BuildCore.image_policy(fields)
    refute Map.has_key?(policy, "image_id")

    assert {:ok, with_id} = BuildCore.image_policy(Map.put(fields, :image_id, image_id))
    assert with_id["image_id"] == image_id

    assert {:error, :invalid_image_id} =
             BuildCore.image_policy(Map.put(fields, :image_id, "arbor/validation:latest"))
  end

  test "status projection is JSON-clean and redacts failed digests" do
    report =
      StatusCore.project(%{
        runtime: %{"state" => "pinned", "driver" => "podman", "reason" => nil},
        baseline: %{"state" => "unavailable", "reason" => "missing_config"},
        mix_lock_digest: {:error, :linux_dependency_baseline_unavailable},
        head_mix_lock_digest: @digest,
        probe: {:error, :image_policy_unavailable},
        host_platform: "x86_64-pc-linux-gnu",
        guest_platform: "linux/amd64"
      })

    assert report["driver"] == "podman"
    assert report["mix_lock_digest"] == nil
    assert report["mix_lock_matches_head"] == false
    assert report["image_reachable"] == false
    assert report["guest_platform"] == "linux/amd64"
  end

  # ── B2a: image backend selection + Apple Container identity ─────────────

  @index "sha256:" <> String.duplicate("f0", 32)
  @manifest_arm "sha256:" <> String.duplicate("1d", 32)
  @manifest_amd "sha256:" <> String.duplicate("2e", 32)
  @config "sha256:" <> String.duplicate("ca", 32)

  defp apple_inspect(variants) do
    Jason.encode!([
      %{
        "id" => String.duplicate("f0", 32),
        "configuration" => %{"descriptor" => %{"digest" => @index}},
        "variants" => variants
      }
    ])
  end

  test "image_backend follows the runtime status driver, then the probe, and names unknowns" do
    assert {:ok, "podman"} = BuildCore.image_backend(%{"driver" => "podman"}, nil)

    assert {:ok, "apple_container"} =
             BuildCore.image_backend(
               %{"state" => "unpinned"},
               {:ok, %{"driver" => "apple_container"}}
             )

    assert {:error, {:image_backend_unsupported, "docker"}} =
             BuildCore.image_backend(%{"driver" => "docker"}, nil)

    # Fresh host: nothing activated yet, status and probe say "unavailable" —
    # the host OS decides (first macOS build failed here before this clause).
    assert {:ok, "apple_container"} =
             BuildCore.image_backend(
               %{"driver" => "unavailable"},
               {:error, :validation_runtime_unavailable},
               {:unix, :darwin}
             )

    assert {:ok, "podman"} =
             BuildCore.image_backend(%{"driver" => "unavailable"}, nil, {:unix, :linux})

    assert {:error, {:image_backend_unsupported, nil}} =
             BuildCore.image_backend(%{}, {:error, :probe_skipped}, {:win32, :nt})

    # A pinned driver always wins over the host default.
    assert {:ok, "podman"} =
             BuildCore.image_backend(%{"driver" => "podman"}, nil, {:unix, :darwin})
  end

  test "image_executable prefers reviewed host config and requires absolute paths" do
    assert {:ok, "/usr/bin/podman"} = BuildCore.image_executable("podman", %{})
    assert {:ok, "/usr/local/bin/container"} = BuildCore.image_executable("apple_container", nil)

    assert {:ok, "/opt/podman/bin/podman"} =
             BuildCore.image_executable("podman", %{"podman" => "/opt/podman/bin/podman"})

    assert {:error, :image_executable_invalid} =
             BuildCore.image_executable("podman", %{"podman" => "podman"})

    assert {:error, :image_executable_invalid} = BuildCore.image_executable("docker", %{})
  end

  test "apple_container_tags derive the build tag and the admitted local workload alias" do
    tree = "81704a6b" <> String.duplicate("0", 56)

    assert {:ok,
            %{
              build: "arbor/validation:baseline-81704a6b",
              alias: "127.0.0.1:0/arbor/workload:baseline-81704a6b"
            }} =
             BuildCore.apple_container_tags(tree)

    assert {:error, :invalid_tree_digest} = BuildCore.apple_container_tags("81704a6b")

    assert {:error, :invalid_tree_digest} =
             BuildCore.apple_container_tags(String.duplicate("G", 64))
  end

  test "apple_container_image reads index from inspect, manifest by platform, image id from the manifest config" do
    inspect_json =
      apple_inspect([
        %{"digest" => @manifest_amd, "platform" => %{"architecture" => "amd64", "os" => "linux"}},
        %{"digest" => @manifest_arm, "platform" => %{"architecture" => "arm64", "os" => "linux"}}
      ])

    manifest_json = Jason.encode!(%{"config" => %{"digest" => @config, "size" => 1}})

    assert {:ok, %{index_digest: @index, manifest_digest: @manifest_arm, image_id: @config}} =
             BuildCore.apple_container_image(inspect_json, manifest_json, "linux/arm64")

    assert {:ok, %{manifest_digest: @manifest_amd}} =
             BuildCore.apple_container_image(inspect_json, manifest_json, "linux/amd64")

    # A single variant needs no platform match (what `container build` produces).
    single = apple_inspect([%{"digest" => @manifest_arm}])

    assert {:ok, %{manifest_digest: @manifest_arm}} =
             BuildCore.apple_container_image(single, manifest_json, "linux/arm64")

    assert {:error, :image_inspect_failed} =
             BuildCore.apple_container_image(inspect_json, manifest_json, "linux/riscv64")

    assert {:error, :image_inspect_failed} =
             BuildCore.apple_container_image(
               inspect_json,
               Jason.encode!(%{"config" => %{}}),
               "linux/arm64"
             )

    assert {:error, :image_inspect_failed} =
             BuildCore.apple_container_image("not json", manifest_json, "linux/arm64")
  end

  @pinned_from "debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171"

  # Fixture tails from podman/buildah `--pull=never` and sibling failures.
  @missing_image_not_known """
  STEP 1/8: FROM #{@pinned_from}
  Error: creating build container: initializing source docker://#{@pinned_from}: image not known
  """

  @missing_no_such_image """
  Error: short-name resolution enforced but cannot prompt without a TTY
  Error: debian:bookworm-slim: no such image
  """

  @missing_creating_container """
  Error: creating build container: #{@pinned_from}
  """

  @platform_manifest """
  Error: no image found in manifest list for architecture linux/riscv64
  """

  @platform_host """
  Error: requested image's platform (linux/amd64) does not match the detected host platform (linux/arm64)
  """

  @disk_full """
  committing container: writing blob: no space left on device
  """

  @unknown_parse """
  Error: dockerfile parse error line 3: unknown instruction: BANANA
  """

  test "failure_diagnostic classifies fixture outputs and bounds the tail" do
    known =
      BuildCore.failure_diagnostic("/usr/bin/podman", 125, @missing_image_not_known)

    assert known.reason == :base_image_missing
    assert known.executable == "/usr/bin/podman"
    assert known.exit_status == 125
    assert known.tail =~ "image not known"
    assert BuildCore.image_build_failed?({:image_build_failed, known})
    assert BuildCore.image_build_failed?(:image_build_failed)
    refute BuildCore.image_build_failed?(:image_inspect_failed)

    assert BuildCore.failure_diagnostic("/usr/bin/podman", 125, @missing_no_such_image).reason ==
             :base_image_missing

    assert BuildCore.failure_diagnostic("/usr/bin/podman", 125, @missing_creating_container).reason ==
             :base_image_missing

    assert BuildCore.failure_diagnostic("/usr/bin/podman", 1, @platform_manifest).reason ==
             :platform_unsupported

    assert BuildCore.failure_diagnostic("/usr/local/bin/container", 1, @platform_host).reason ==
             :platform_unsupported

    assert BuildCore.failure_diagnostic("/usr/bin/podman", 1, @disk_full).reason == :disk_full

    unknown = BuildCore.failure_diagnostic("/usr/bin/podman", 1, @unknown_parse)
    assert unknown.reason == :unknown
    assert unknown.tail =~ "unknown instruction"
  end

  test "failure_diagnostic strips controls, stays UTF-8, and caps lines and bytes" do
    lines = Enum.map_join(1..50, "\n", fn n -> "line #{n}" end)
    diag = BuildCore.failure_diagnostic("/usr/bin/podman", 1, lines)
    tail_lines = String.split(diag.tail, "\n")
    assert length(tail_lines) == 40
    assert hd(tail_lines) == "line 11"
    assert List.last(tail_lines) == "line 50"

    oversized = String.duplicate("x", 5000)
    bounded = BuildCore.failure_diagnostic("/usr/bin/podman", 1, oversized)
    assert byte_size(bounded.tail) <= 4096
    assert String.valid?(bounded.tail)

    dirty = "ok\r\n\x1b[31merror\x1b[0m\nimage not known"
    cleaned = BuildCore.failure_diagnostic("/usr/bin/podman", 125, dirty)
    refute String.contains?(cleaned.tail, <<0x1B>>)
    refute String.contains?(cleaned.tail, "\r")
    assert String.contains?(cleaned.tail, "\n")
    assert cleaned.reason == :base_image_missing

    invalid = "image not known " <> <<0xFF, 0xFE>>
    safe = BuildCore.failure_diagnostic("/usr/bin/podman", 125, invalid)
    assert String.valid?(safe.tail)
    assert safe.reason == :base_image_missing
  end

  test "pinned_from_reference reads digest-form FROM and names the pull remedy" do
    text = """
    # comment mentioning debian:bookworm-slim@sha256:#{String.duplicate("ab", 32)}
    FROM #{@pinned_from}
    ARG ERLANG_VERSION=28.4.1
    """

    assert {:ok, @pinned_from} = BuildCore.pinned_from_reference(text)
    assert {:error, :missing_from_reference} = BuildCore.pinned_from_reference("FROM debian\n")
    assert {:error, :missing_from_reference} = BuildCore.pinned_from_reference(nil)

    assert {:ok, ["image", "exists", @pinned_from]} =
             BuildCore.image_exists_args("podman", @pinned_from)

    assert {:ok, ["image", "inspect", @pinned_from]} =
             BuildCore.image_exists_args("apple_container", @pinned_from)

    assert BuildCore.pull_remedy(@pinned_from) == "podman pull #{@pinned_from}"

    formatted = BuildCore.format_failure({:base_image_missing, @pinned_from})
    assert formatted =~ "base_image_missing"
    assert formatted =~ "podman pull #{@pinned_from}"

    diag = BuildCore.failure_diagnostic("/usr/bin/podman", 125, @missing_image_not_known)
    shown = BuildCore.format_failure({:image_build_failed, diag})
    assert shown =~ "image_build_failed"
    assert shown =~ "base_image_missing"
    assert shown =~ "image not known"
    assert BuildCore.format_failure(:image_build_failed) == "image_build_failed"
  end

  test "functional cores contain no impurity" do
    src =
      File.read!(Path.expand("../../../lib/arbor/commands/baseline/build_core.ex", __DIR__))

    forbidden = [
      ~r/DateTime\.utc_now/,
      ~r/System\.(monotonic|os|system)_time/,
      ~r/:rand\./,
      ~r/:erlang\.unique_integer/,
      ~r/\bmake_ref\s*\(/,
      ~r/Application\.get_env/,
      ~r/GenServer\./,
      ~r/\bRepo\./,
      ~r/:ets\./,
      ~r/\bLogger\./
    ]

    Enum.each(forbidden, fn re ->
      refute Regex.match?(re, src), "impure pattern #{inspect(re.source)} in BuildCore"
    end)
  end
end
