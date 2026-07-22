defmodule Arbor.Actions.Coding.ToolchainIdentityTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.ToolchainIdentityCore, as: Core

  test "public observation has a deterministic bounded JSON-clean shape" do
    assert {:ok, first} = Arbor.Actions.coding_toolchain_identity()
    assert {:ok, second} = Arbor.Actions.coding_toolchain_identity()
    assert first == second

    assert Map.keys(first) |> Enum.sort() ==
             ~w(architecture elixir_version identity_digest mix_wrapper_path otp_release platform runtime_roots schema_version)

    assert first["schema_version"] == 1
    assert is_binary(first["platform"])
    assert is_binary(first["architecture"])
    assert is_binary(first["otp_release"])
    assert is_binary(first["elixir_version"])
    assert Path.type(first["mix_wrapper_path"]) == :absolute
    assert Map.keys(first["runtime_roots"]) |> Enum.sort() == ~w(elixir_root erlang_root)
    assert Enum.all?(Map.values(first["runtime_roots"]), &(Path.type(&1) == :absolute))
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, first["identity_digest"])
    assert {:ok, _json} = Jason.encode(first)
  end

  test "digest is stable across observation map insertion order" do
    first = observation()

    second =
      Enum.into(
        [
          {"runtime_roots", first["runtime_roots"]},
          {"mix_wrapper_path", first["mix_wrapper_path"]},
          {"elixir_version", first["elixir_version"]},
          {"otp_release", first["otp_release"]},
          {"architecture", first["architecture"]},
          {"platform", first["platform"]},
          {"schema_version", first["schema_version"]}
        ],
        %{}
      )

    assert {:ok, first_identity} = Core.new(first)
    assert {:ok, second_identity} = Core.new(second)
    assert first_identity == second_identity

    expected_digest =
      first
      |> Core.canonical_json()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert first_identity["identity_digest"] == expected_digest
  end

  test "malformed observations fail closed without projecting nested details" do
    assert {:error, :invalid_toolchain_identity} =
             Core.new(Map.put(observation(), "mix_wrapper_path", "relative/bin/mix"))

    assert {:error, :invalid_toolchain_identity} =
             Core.new(Map.put(observation(), "runtime_roots", {:error, "do not leak this"}))

    assert {:error, :invalid_toolchain_identity} =
             Core.new(Map.put(observation(), "unexpected", "field"))
  end

  defp observation do
    %{
      "schema_version" => 1,
      "platform" => "unix:darwin",
      "architecture" => "aarch64",
      "otp_release" => "28",
      "elixir_version" => "1.19.5",
      "mix_wrapper_path" => "/reviewed/bin/mix",
      "runtime_roots" => %{
        "erlang_root" => "/runtime/erlang",
        "elixir_root" => "/runtime/elixir"
      }
    }
  end
end
