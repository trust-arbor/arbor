defmodule Arbor.Shell.TrustedBuildRequestTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Shell
  alias Arbor.Shell.TrustedBuild.Plan
  alias Arbor.Shell.TrustedBuild.Request

  test "admits the closed source projection" do
    identity = valid_identity()

    assert {:ok, %{identity: admitted}} =
             Request.admit(%{
               "schema" => "arbor.shell.trusted_build.request.v1",
               "source" => %{
                 "schema" => "arbor.shell.trusted_build.source.v1",
                 "identity" => identity
               }
             })

    assert admitted.path == identity["path"]
    assert admitted.device == 1
  end

  test "rejects atom keys, extras, aliases, and invented source_root" do
    identity = valid_identity()

    assert {:error, :invalid_trusted_build_request} = Request.admit(:not_a_map)
    assert {:error, :invalid_trusted_build_request} = Request.admit(%{})

    assert {:error, :invalid_trusted_build_request} =
             Request.admit(%{
               schema: "arbor.shell.trusted_build.request.v1",
               source: %{}
             })

    assert {:error, :invalid_trusted_build_request} =
             Request.admit(%{
               "schema" => "arbor.shell.trusted_build.request.v1",
               "source" => %{
                 "schema" => "arbor.shell.trusted_build.source.v1",
                 "identity" => identity,
                 "source_root" => identity["path"] <> "/source"
               }
             })

    assert {:error, :invalid_trusted_build_request} =
             Request.admit(%{
               "schema" => "arbor.shell.trusted_build.request.v1",
               "source" => %{
                 "schema" => "arbor.shell.trusted_build.source.v1",
                 "identity" => identity
               },
               "timeout" => 1
             })

    assert {:error, :invalid_trusted_build_request} =
             Shell.acquire_trusted_build_lease(%{
               "schema" => "arbor.shell.trusted_build.request.v1",
               "source" => %{
                 "schema" => "arbor.shell.trusted_build.source.v1",
                 "identity" => Map.put(identity, "path", "/tmp/../evil")
               }
             })
  end

  test "rejects invented identities that were never registered" do
    request = %{
      "schema" => "arbor.shell.trusted_build.request.v1",
      "source" => %{
        "schema" => "arbor.shell.trusted_build.source.v1",
        "identity" => valid_identity()
      }
    }

    assert {:error, reason} = Shell.acquire_trusted_build_lease(request)

    case :os.type() do
      {:unix, :darwin} -> assert reason == :owned_tree_not_registered
      _other -> assert reason == :trusted_build_unavailable
    end
  end

  test "plan admits only the three phases in order" do
    assert {:ok, :deps_get} = Plan.admit_phase("deps_get")
    assert {:ok, :compile} = Plan.admit_phase("compile")
    assert {:ok, :release} = Plan.admit_phase("release")
    assert {:error, :trusted_build_phase_rejected} = Plan.admit_phase("deps.get")
    assert {:error, :trusted_build_phase_rejected} = Plan.admit_phase(:test)
    assert {:ok, :deps_get} = Plan.next_phase([])
    assert {:ok, :compile} = Plan.next_phase([:deps_get])
    assert {:error, :trusted_build_phase_rejected} = Plan.admit_order(:compile, [])
    assert {:error, :trusted_build_phase_rejected} = Plan.admit_order(:deps_get, [:deps_get])
    assert Plan.argv(:deps_get) == ["deps.get", "--only", "prod"]
    assert Plan.argv(:compile) == ["compile", "--warnings-as-errors"]
    assert Plan.argv(:release) == ["release", "--overwrite"]
  end

  test "public execute rejects a non-lease and unknown phase" do
    assert {:error, :invalid_lease} = Shell.execute_trusted_build(%{}, "compile")

    assert {:error, :trusted_build_phase_rejected} =
             Shell.execute_trusted_build(:not_a_lease, "deps.get")

    refute function_exported?(Shell, :acquire_trusted_build_lease_for_test, 2)
    assert function_exported?(Shell, :acquire_trusted_build_lease, 1)
    assert function_exported?(Shell, :execute_trusted_build, 2)
    assert function_exported?(Shell, :inventory_trusted_build, 1)
    assert function_exported?(Shell, :release_trusted_build_lease, 1)
  end

  defp valid_identity do
    %{
      "path" => "/tmp/arbor-e0b2c-source-test",
      "type" => "directory",
      "device" => 1,
      "minor_device" => 0,
      "inode" => 2
    }
  end
end
