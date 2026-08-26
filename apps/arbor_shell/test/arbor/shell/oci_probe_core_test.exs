defmodule Arbor.Shell.OciProbeCoreTest do
  @moduledoc """
  Pure projection tests for OCI/Podman inspect evidence.
  """

  use ExUnit.Case, async: true

  alias Arbor.Shell.OciProbeCore, as: Core

  @moduletag :fast

  @digest "sha256:" <> String.duplicate("a", 64)
  @id "sha256:" <> String.duplicate("b", 64)

  @labels %{
    "org.arbor.validation.schema" => "1",
    "org.arbor.validation.role" => "spawn-containment",
    "org.arbor.validation.platform" => "linux/amd64"
  }

  defp inspect_json(overrides \\ %{}) do
    resource =
      Map.merge(
        %{
          "Digest" => @digest,
          "Id" => @id,
          "Architecture" => "amd64",
          "Os" => "linux",
          "Labels" => @labels
        },
        overrides
      )

    Jason.encode!([resource])
  end

  defp valid_input(overrides \\ %{}) do
    Map.merge(
      %{
        system_architecture: "x86_64-pc-linux-gnu",
        image_inspect_json: inspect_json()
      },
      overrides
    )
  end

  describe "host architecture" do
    test "maps x86_64 and amd64 linux hosts to linux/amd64" do
      for arch <- ["x86_64-pc-linux-gnu", "amd64-linux-gnu", "x86_64"] do
        assert {:ok, projection} = Core.project(valid_input(%{system_architecture: arch}))
        assert projection.host_platform == %{os: "linux", architecture: "x86_64"}
        assert projection.guest_platform == "linux/amd64"
      end
    end

    test "maps aarch64 and arm64 linux hosts to linux/arm64" do
      for arch <- ["aarch64-unknown-linux-gnu", "arm64-linux-gnu", "aarch64"] do
        assert {:ok, projection} = Core.project(valid_input(%{system_architecture: arch}))
        assert projection.host_platform == %{os: "linux", architecture: "arm64"}
        assert projection.guest_platform == "linux/arm64"
      end
    end

    @tag :security_regression
    test "security regression: non-linux hosts are rejected" do
      for arch <- ["aarch64-apple-darwin24.0.0", "x86_64-apple-darwin", "x86_64-unknown-freebsd"] do
        assert {:error, :unsupported_host_os} =
                 Core.project(valid_input(%{system_architecture: arch}))
      end
    end
  end

  describe "inspect projection" do
    test "projects Digest, Id, Labels, Architecture, and Os" do
      assert {:ok, projection} = Core.project(valid_input())
      assert projection.inspect["Digest"] == @digest
      assert projection.inspect["Id"] == @id
      assert projection.inspect["Labels"] == @labels
      assert projection.inspect["Architecture"] == "amd64"
      assert projection.inspect["Os"] == "linux"
      assert Jason.encode!(Core.show(projection))
    end

    test "normalizes Podman's bare-hex inspect Id to sha256: prefix" do
      bare = String.duplicate("b", 64)
      json = inspect_json(%{"Id" => bare})

      assert {:ok, projection} = Core.project(valid_input(%{image_inspect_json: json}))
      assert projection.inspect["Id"] == "sha256:" <> bare
      assert projection.inspect["Digest"] == @digest
    end

    test "projects a captured podman image inspect document" do
      json =
        Path.expand("../../fixtures/podman_image_inspect.json", __DIR__)
        |> File.read!()

      assert {:ok, projection} =
               Core.project(%{
                 system_architecture: "x86_64-pc-linux-gnu",
                 image_inspect_json: json
               })

      assert projection.inspect["Id"] ==
               "sha256:14433cef00000000000000000000000000000000000000000000000000002e9b"

      assert projection.inspect["Digest"] ==
               "sha256:c591dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"

      assert projection.inspect["Architecture"] == "amd64"
      assert projection.inspect["Os"] == "linux"
      assert projection.inspect["Labels"]["org.arbor.validation.schema"] == "1"
    end

    test "falls back to Id when Digest is missing" do
      json = inspect_json() |> Jason.decode!() |> hd() |> Map.delete("Digest") |> List.wrap()

      assert {:ok, projection} =
               Core.project(valid_input(%{image_inspect_json: Jason.encode!(json)}))

      assert projection.inspect["Digest"] == @id
    end

    test "accepts a single inspect object without an array wrapper" do
      json = inspect_json() |> Jason.decode!() |> hd() |> Jason.encode!()
      assert {:ok, projection} = Core.project(valid_input(%{image_inspect_json: json}))
      assert projection.inspect["Digest"] == @digest
    end

    @tag :security_regression
    test "security regression: non-sha256 inspect digest is rejected" do
      assert {:error, :inspect_digest_not_sha256} =
               Core.project(
                 valid_input(%{image_inspect_json: inspect_json(%{"Digest" => "latest"})})
               )
    end

    test "rejects non-linux inspect Os" do
      assert {:error, :inspect_os_not_linux} =
               Core.project(valid_input(%{image_inspect_json: inspect_json(%{"Os" => "darwin"})}))
    end

    test "rejects oversized inspect JSON" do
      too_large = String.duplicate("x", 262_144 + 1)

      assert {:error, :image_inspect_json_too_long} =
               Core.project(valid_input(%{image_inspect_json: too_large}))
    end

    test "rejects invalid JSON" do
      assert {:error, :invalid_image_inspect_json} =
               Core.project(valid_input(%{image_inspect_json: "not-json"}))
    end
  end
end
