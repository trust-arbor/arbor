defmodule Arbor.Shell.OciUnitArgvTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.OciPlanCore
  alias Arbor.Shell.OciUnitArgv
  alias Arbor.Shell.OciUnitRuntime

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

  test "admits the PlanCore create/start/kill/rm/ps argv shapes" do
    assert {:ok, plan} = OciPlanCore.new(@valid_request)

    assert :ok = OciUnitArgv.review(strip(plan.argv.create))
    assert :ok = OciUnitArgv.review(strip(plan.argv.start))
    assert :ok = OciUnitArgv.review(strip(plan.argv.force_stop))
    assert :ok = OciUnitArgv.review(strip(plan.argv.delete))
    assert :ok = OciUnitArgv.review(strip(plan.argv.verify_absent))
    assert :ok = OciUnitRuntime.authorize_unit_args(strip(plan.argv.create))
  end

  test "security regression: run/exec/pull/privileged argv is refused" do
    assert {:error, :unreviewed_oci_unit_command} =
             OciUnitArgv.review(["run", "--privileged", @image])

    assert {:error, :unreviewed_oci_unit_command} =
             OciUnitArgv.review(["exec", @name, "sh"])

    assert {:error, :unreviewed_oci_unit_command} =
             OciUnitArgv.review(["pull", @image])

    assert {:error, :unreviewed_oci_unit_command} =
             OciUnitArgv.review(["create", "--name", @name, "--network", "bridge"])
  end

  test "security regression: rw mount of a read-only guest destination is refused" do
    assert {:ok, plan} = OciPlanCore.new(@valid_request)
    create = strip(plan.argv.create)
    assert :ok = OciUnitArgv.review(create)

    rw_bin =
      "type=bind,source=/tmp/arbor-oci/bin,destination=/arbor/bin"

    rw_runner =
      "type=bind,source=/tmp/arbor-oci/runner,destination=/arbor/validation/runner"

    refused =
      create
      |> Enum.map(fn
        "type=bind,source=/tmp/arbor-oci/bin,destination=/arbor/bin,ro=true" -> rw_bin
        other -> other
      end)

    assert {:error, :unreviewed_oci_unit_command} = OciUnitArgv.review(refused)

    refused_runner =
      create
      |> Enum.map(fn
        "type=bind,source=/tmp/arbor-oci/runner,destination=/arbor/validation/runner,ro=true" ->
          rw_runner

        other ->
          other
      end)

    assert {:error, :unreviewed_oci_unit_command} = OciUnitArgv.review(refused_runner)
  end

  test "security regression: inspect-like unit argv cannot smuggle a tag" do
    assert {:error, :unreviewed_oci_unit_command} =
             OciUnitArgv.review(["image", "inspect", "validation:latest"])
  end

  test "security regression: production worker uses OciUnitRuntime not Apple unit runtime" do
    source = File.read!(Path.expand("../../../lib/arbor/shell/oci_unit_worker.ex", __DIR__))

    assert source =~ "OciUnitRuntime"
    refute source =~ "AppleContainerUnitRuntime"
  end

  test "security regression: launcher C reviews oci-unit argv and skips no-fork" do
    source = File.read!(Path.expand("../../../c_src/arbor_shell_launcher.c", __DIR__))

    assert source =~ "EXECUTION_OCI_UNIT"
    assert source =~ "reviewed_oci_unit"
    assert source =~ "unreviewed OCI unit command"
    assert source =~ "\"oci-unit\""
    assert source =~ "oci_read_only_destination"
  end

  defp strip(["/usr/bin/podman" | rest]), do: rest
  defp strip(_argv), do: flunk("expected argv to start with /usr/bin/podman")
end
