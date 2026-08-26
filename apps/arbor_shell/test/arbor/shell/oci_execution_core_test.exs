defmodule Arbor.Shell.OciExecutionCoreTest do
  @moduledoc """
  Pure tests for the OCI/Podman execution-request core.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.OciExecutionCore, as: Core
  alias Arbor.Shell.SpawnCapableTimeout

  @moduletag :fast

  @digest String.duplicate("a", 64)
  @image "sha256:#{@digest}"
  @unit "arbor-v1-unit01"
  @mix_wrapper "/private/tmp/arbor-oci/bin/mix"
  @worktree "/private/tmp/arbor-oci/worktree"
  @validation_runner_dir "/private/tmp/arbor-oci/runner"
  @validation_result_dir "/private/tmp/arbor-oci/result"
  @validation_runner_script Path.join(@validation_runner_dir, "runner.exs")
  @validation_result_file Path.join(@validation_result_dir, "result.etf")
  @guest_validation_runner_script "/arbor/validation/runner/runner.exs"
  @guest_validation_result_file "/arbor/validation/result/result.etf"

  @valid_admission %{
    "admitted" => true,
    "platform" => %{"os" => "linux", "architecture" => "x86_64"},
    "runtime" => %{"path" => "/usr/bin/podman"},
    "image" => %{
      "execution_reference" => @image,
      "platform" => "linux/amd64"
    }
  }

  defp actions_entry(path, mode, purpose) do
    %{
      "path" => path,
      "mode" => Atom.to_string(mode),
      "purpose" => Atom.to_string(purpose)
    }
  end

  defp base_projections(revision \\ "candidate") do
    %{
      read_only: [
        actions_entry("/opt/erlang", :read_only, :runtime_erlang),
        actions_entry("/opt/elixir", :read_only, :runtime_elixir),
        actions_entry(@mix_wrapper, :read_only, :mix_wrapper),
        actions_entry(@validation_runner_dir, :read_only, :validation_runner)
      ],
      read_write: [
        actions_entry(@worktree, :read_write, :worktree),
        actions_entry("/private/tmp/arbor-oci/home", :read_write, :home),
        actions_entry("/private/tmp/arbor-oci/tmp", :read_write, :tmp),
        actions_entry("/private/tmp/arbor-oci/build", :read_write, :build),
        actions_entry("/private/tmp/arbor-oci/deps", :read_write, :deps),
        actions_entry(@validation_result_dir, :read_write, :validation_result)
      ],
      revision: revision
    }
  end

  defp valid_opts(overrides \\ []) do
    base = [
      cwd: @worktree,
      timeout: 60_000,
      sandbox: :basic,
      env: %{},
      clear_env: true,
      filesystem_projections: base_projections()
    ]

    Keyword.merge(base, overrides)
  end

  defp valid_request(overrides \\ %{}) do
    Map.merge(
      %{
        tool_name: @mix_wrapper,
        args: ["compile"],
        opts: valid_opts(),
        admission: @valid_admission,
        unit_name: @unit
      },
      overrides
    )
  end

  describe "mix wrapper contract" do
    test "compile plans digest-only create argv without vminit or kernel" do
      assert {:ok, spec} = Core.new(valid_request())
      assert spec.plan.command_args == ["compile"]
      assert spec.plan.image == @image
      assert spec.plan.platform == "linux/amd64"
      assert spec.plan.runtime_executable == "/usr/bin/podman"
      assert spec.plan.guest_mix_wrapper == "/arbor/bin/mix"
      refute Map.has_key?(spec.plan, :init_image)
      refute Map.has_key?(spec.plan, :kernel_path)
      create = spec.plan.argv.create
      assert hd(create) == "/usr/bin/podman"
      assert "--pull" in create
      assert Enum.at(create, Enum.find_index(create, &(&1 == "--pull")) + 1) == "never"
      refute Enum.any?(create, &String.contains?(&1, "vminit"))
    end

    test "tool_name must equal the mix wrapper path" do
      assert {:error, :tool_name_mix_wrapper_mismatch} =
               Core.new(valid_request(%{tool_name: "/private/tmp/arbor-oci/other/mix"}))
    end

    test "validate_request rejects a relative mix wrapper" do
      assert {:error, {:invalid_tool_name, :relative_path}} =
               Core.validate_request("mix", ["compile"], valid_opts())
    end

    @tag :security_regression
    test "security regression: exact mix run --no-start harness rewrites host paths to guest" do
      args = [
        "run",
        "--no-start",
        @validation_runner_script,
        "--",
        @validation_result_file,
        "apps/arbor_actions/test/example_test.exs"
      ]

      assert {:ok, spec} = Core.new(valid_request(%{args: args}))

      assert spec.plan.command_args == [
               "run",
               "--no-start",
               @guest_validation_runner_script,
               "--",
               @guest_validation_result_file,
               "apps/arbor_actions/test/example_test.exs"
             ]
    end
  end

  describe "platforms" do
    test "admits linux/amd64 against x86_64 host without vminit" do
      assert {:ok, spec} = Core.new(valid_request())
      assert spec.plan.platform == "linux/amd64"
      shown = Core.show(spec)
      refute Map.has_key?(shown["plan"], "init_image")
      refute Map.has_key?(shown["plan"], "kernel_path")
    end

    test "admits linux/arm64 against arm64 host" do
      admission = %{
        "admitted" => true,
        "platform" => %{"os" => "linux", "architecture" => "arm64"},
        "runtime" => %{"path" => "/usr/bin/podman"},
        "image" => %{"execution_reference" => @image, "platform" => "linux/arm64"}
      }

      assert {:ok, spec} = Core.new(valid_request(%{admission: admission}))
      assert spec.plan.platform == "linux/arm64"
    end

    test "rejects cross-arch guest platforms" do
      admission =
        put_in(@valid_admission, ["image", "platform"], "linux/arm64")

      assert {:error, :guest_platform_host_mismatch} =
               Core.new(valid_request(%{admission: admission}))
    end

    test "rejects non-linux hosts" do
      admission = put_in(@valid_admission, ["platform", "os"], "macos")
      assert {:error, :host_os_not_supported} = Core.new(valid_request(%{admission: admission}))
    end
  end

  describe "resource profile ceilings" do
    test "defaults to standard 1 CPU / 2g / 512 pids" do
      assert {:ok, spec} = Core.new(valid_request())
      assert spec.plan.resource_profile == :standard
      assert spec.plan.resource_limits.cpus == "1"
      assert spec.plan.resource_limits.memory == "2g"
      assert spec.plan.resource_limits.pids == "512"
    end

    test "intensive profile produces 4 CPU / 4g create argv" do
      assert {:ok, spec} =
               Core.new(valid_request(%{opts: valid_opts(resource_profile: :intensive)}))

      assert spec.plan.resource_profile == :intensive
      create = spec.plan.argv.create
      assert Enum.at(create, Enum.find_index(create, &(&1 == "--cpus")) + 1) == "4"
      assert Enum.at(create, Enum.find_index(create, &(&1 == "--memory")) + 1) == "4g"
    end

    test "intensive timeout is rejected under standard" do
      assert {:ok, intensive_ceiling_ms} = SpawnCapableTimeout.max_timeout_ms(:intensive)

      assert {:error, :timeout_too_large} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts(timeout: intensive_ceiling_ms, resource_profile: :standard)
                 })
               )

      assert {:ok, spec} =
               Core.new(
                 valid_request(%{
                   opts: valid_opts(timeout: intensive_ceiling_ms, resource_profile: :intensive)
                 })
               )

      assert spec.plan.resource_profile == :intensive
    end
  end

  describe "authority" do
    @tag :security_regression
    test "security regression: caller authority injection is rejected" do
      for key <- [:image, :init_image, :kernel_path, :plan, :argv, :policy, :receipt, "runtime"] do
        assert {:error, :caller_authority_injection} =
                 Core.new(Map.put(valid_request(), key, "evil"))
      end
    end

    test "missing vminit and kernel on the admission is required, not an error" do
      refute Map.has_key?(@valid_admission, "vminit")
      refute Map.has_key?(@valid_admission, "control_plane")
      assert {:ok, _spec} = Core.new(valid_request())
    end

    test "non-digest execution image is rejected" do
      admission =
        put_in(@valid_admission, ["image", "execution_reference"], "validation:latest")

      assert {:error, :not_digest_execution_image} =
               Core.new(valid_request(%{admission: admission}))
    end

    test "runtime path must be /usr/bin/podman" do
      admission = put_in(@valid_admission, ["runtime", "path"], "/usr/local/bin/podman")
      assert {:error, :runtime_path_mismatch} = Core.new(valid_request(%{admission: admission}))
    end
  end
end
