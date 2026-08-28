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
end
