defmodule Arbor.Shell.ValidationRuntimeToolchainTest do
  use ExUnit.Case, async: true

  alias Arbor.Shell.ValidationRuntimeToolchainCore, as: Core

  @moduletag :fast

  @repo_root Path.expand("../../../../..", __DIR__)
  @tool_versions_path Path.join(@repo_root, ".tool-versions")
  @containerfile_path Path.join(@repo_root, "images/validation-runtime/Containerfile")

  test "parses .tool-versions and Containerfile ARG defaults without a third copy" do
    tool_versions = File.read!(@tool_versions_path)
    containerfile = File.read!(@containerfile_path)

    assert {:ok, from_tool_versions} = Core.parse_tool_versions(tool_versions)
    assert {:ok, from_containerfile} = Core.parse_containerfile_arg_defaults(containerfile)
    assert Core.compare(from_tool_versions, from_containerfile) == :ok
    assert :ok = Core.require_attestation_labels(containerfile)

    assert String.contains?(containerfile, "org.arbor.validation.erlang=\"${ERLANG_VERSION}\"")
    assert String.contains?(containerfile, "org.arbor.validation.elixir=\"${ELIXIR_VERSION}\"")
    refute Regex.match?(~r/^\s*COPY\s+/m, containerfile)
  end

  test "fails when either parsed source drifts" do
    assert {:error, :toolchain_drift} =
             Core.compare(%{erlang: "28.4.1", elixir: "1.19.5-otp-28"}, %{
               erlang: "27.0",
               elixir: "1.19.5-otp-28"
             })
  end
end
