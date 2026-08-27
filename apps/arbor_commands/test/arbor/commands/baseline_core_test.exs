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
end
