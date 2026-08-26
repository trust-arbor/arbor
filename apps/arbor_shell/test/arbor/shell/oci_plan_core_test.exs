defmodule Arbor.Shell.OciPlanCoreTest do
  @moduledoc """
  Host-independent security regressions for the OCI/Podman plan core.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.OciPlanCore

  @moduletag :fast
  @moduletag :security_regression

  @digest String.duplicate("a", 64)
  @image "sha256:#{@digest}"
  @name "arbor-oci-unit01"

  @projections %{
    worktree: "/tmp/arbor-oci/worktree",
    home: "/tmp/arbor-oci/home",
    build: "/tmp/arbor-oci/build",
    deps: "/tmp/arbor-oci/deps",
    validation_runner: "/tmp/arbor-oci/runner",
    validation_result: "/tmp/arbor-oci/result",
    mix_wrapper_dir: "/tmp/arbor-oci/bin"
  }

  @valid_request %{
    image: @image,
    name: @name,
    projections: @projections,
    mix_env: "test",
    command_args: ["test", "--", "apps/arbor_shell/test/example_test.exs"],
    resource_profile: :standard,
    driver: :podman,
    platform: "linux/amd64"
  }

  describe "positive create plan" do
    test "emits digest-only image after --pull never and --network none" do
      assert {:ok, plan} = OciPlanCore.new(@valid_request)

      assert plan.runtime_executable == "/usr/bin/podman"
      assert plan.image == @image
      assert plan.platform == "linux/amd64"
      assert plan.guest_mix_wrapper == "/arbor/bin/mix"
      assert plan.resource_profile == :standard

      create = plan.argv.create
      assert hd(create) == "/usr/bin/podman"
      assert "create" in create
      assert pull_never?(create)
      assert network_none?(create)
      assert "--read-only" in create
      assert cap_drop_all?(create)
      refute "docker.io" in create
      refute Enum.any?(create, &String.contains?(&1, ":latest"))
      assert Enum.at(create, Enum.find_index(create, &(&1 == "--entrypoint")) + 2) == @image
      assert List.last(create) == "apps/arbor_shell/test/example_test.exs"

      assert plan.argv.verify_absent == [
               "/usr/bin/podman",
               "ps",
               "-a",
               "--format",
               "json"
             ]

      refute "exists" in plan.argv.verify_absent
    end

    test "does not bind host tmp into the guest" do
      assert {:ok, plan} = OciPlanCore.new(@valid_request)
      refute Enum.any?(plan.mounts, &(&1.purpose == :tmp))
      refute Enum.any?(plan.mounts, &String.contains?(&1.host_path, "/tmp/arbor-oci/tmp"))
      assert plan.guest_tmpfs.guest_path == "/tmp"
    end
  end

  describe "security regression: image identity" do
    test "rejects a mutable tag" do
      assert {:error, :mutable_image_tag} =
               OciPlanCore.new(Map.put(@valid_request, :image, "validation:latest"))
    end

    test "rejects a provisioning registry reference" do
      assert {:error, :external_provisioning_reference} =
               OciPlanCore.new(
                 Map.put(
                   @valid_request,
                   :image,
                   "docker.io/arbor/validation@sha256:#{@digest}"
                 )
               )
    end

    test "rejects a malformed digest" do
      assert {:error, :malformed_image_digest} =
               OciPlanCore.new(Map.put(@valid_request, :image, "sha256:not-a-digest"))
    end
  end

  describe "security regression: containment argv" do
    test "rejects caller network or pull overrides as unknown keys" do
      assert {:error, {:unsupported_request_keys, keys}} =
               OciPlanCore.new(Map.put(@valid_request, :network, "bridge"))

      assert "network" in keys

      assert {:error, {:unsupported_request_keys, pull_keys}} =
               OciPlanCore.new(Map.put(@valid_request, :pull, "always"))

      assert "pull" in pull_keys
    end

    test "rejects raw cpus/memory overrides" do
      assert {:error, {:unsupported_request_keys, keys}} =
               OciPlanCore.new(Map.put(@valid_request, :cpus, "8"))

      assert "cpus" in keys
    end

    test "rejects docker driver until its projector exists" do
      assert {:error, :docker_driver_unimplemented} =
               OciPlanCore.new(Map.put(@valid_request, :driver, :docker))
    end
  end

  describe "security regression: host paths" do
    test "rejects a relative projection" do
      projections = Map.put(@projections, :worktree, "relative/worktree")

      assert {:error, {:invalid_projection, :worktree, :relative_path}} =
               OciPlanCore.new(Map.put(@valid_request, :projections, projections))
    end

    test "rejects a dot-segment escape" do
      projections = Map.put(@projections, :worktree, "/tmp/arbor-oci/../secret")

      assert {:error, {:invalid_projection, :worktree, :dot_segment}} =
               OciPlanCore.new(Map.put(@valid_request, :projections, projections))
    end

    test "rejects a mount-language delimiter in a host path" do
      projections = Map.put(@projections, :worktree, "/tmp/arbor-oci/work,tree")

      assert {:error, {:invalid_projection, :worktree, :mount_field_delimiter}} =
               OciPlanCore.new(Map.put(@valid_request, :projections, projections))
    end

    test "rejects extra tmp projection keys" do
      projections = Map.put(@projections, :tmp, "/tmp/arbor-oci/tmp")

      assert {:error, :unsupported_projection_keys} =
               OciPlanCore.new(Map.put(@valid_request, :projections, projections))
    end
  end

  describe "closed platform" do
    test "admits linux/arm64 as well as linux/amd64" do
      assert {:ok, plan} = OciPlanCore.new(Map.put(@valid_request, :platform, "linux/arm64"))
      assert plan.platform == "linux/arm64"
    end

    test "rejects an open platform string" do
      assert {:error, :unsupported_platform} =
               OciPlanCore.new(Map.put(@valid_request, :platform, "linux/riscv64"))
    end
  end

  defp pull_never?(create) do
    index = Enum.find_index(create, &(&1 == "--pull"))
    is_integer(index) and Enum.at(create, index + 1) == "never"
  end

  defp network_none?(create) do
    index = Enum.find_index(create, &(&1 == "--network"))
    is_integer(index) and Enum.at(create, index + 1) == "none"
  end

  defp cap_drop_all?(create) do
    index = Enum.find_index(create, &(&1 == "--cap-drop"))
    is_integer(index) and Enum.at(create, index + 1) == "ALL"
  end
end
