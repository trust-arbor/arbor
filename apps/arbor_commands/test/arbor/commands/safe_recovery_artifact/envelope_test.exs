defmodule Arbor.Commands.SafeRecoveryArtifact.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryArtifact.{Encode, Envelope}

  @moduletag :fast

  @payload_bytes "not-the-real-payload-but-exact-bytes"

  test "schema, version, and payload path are closed constants" do
    assert Envelope.schema() == "arbor.packaging.safe_recovery_artifact.envelope.v1"
    assert Envelope.version() == 1

    assert Envelope.payload_path() ==
             "apps/arbor_commands/priv/packaging/safe_recovery_artifact.payload.v1.json"
  end

  test "build/1 produces the closed bounded descriptor with the payload digest" do
    {:ok, envelope} = Envelope.build(@payload_bytes)

    expected_digest =
      :crypto.hash(:sha256, @payload_bytes) |> Base.encode16(case: :lower)

    assert envelope == %{
             "schema" => "arbor.packaging.safe_recovery_artifact.envelope.v1",
             "version" => 1,
             "payload" => %{
               "schema" => Encode.schema(),
               "path" => Envelope.payload_path(),
               "byte_size" => byte_size(@payload_bytes),
               "sha256" => expected_digest
             }
           }

    assert :ok = Envelope.validate(envelope)
  end

  test "build/1 rejects non-binary and out-of-bound payloads" do
    assert {:error, :invalid_payload} = Envelope.build(:not_bytes)
    assert {:error, :invalid_payload_size} = Envelope.build("")
    assert {:error, :invalid_payload_size} = Envelope.build(:binary.copy("x", 16_777_217))
  end

  test "validate/1 rejects every shape, schema, path, size, and digest deviation" do
    {:ok, envelope} = Envelope.build(@payload_bytes)

    assert {:error, {:field_mismatch, _}} =
             Envelope.validate(Map.put(envelope, "extra", true))

    assert {:error, :invalid_schema} = Envelope.validate(%{envelope | "schema" => "other.v1"})
    assert {:error, :invalid_version} = Envelope.validate(%{envelope | "version" => 2})

    payload = envelope["payload"]

    assert {:error, {:field_mismatch, _}} =
             Envelope.validate(%{envelope | "payload" => Map.put(payload, "entries", [])})

    assert {:error, :invalid_schema} =
             Envelope.validate(%{envelope | "payload" => %{payload | "schema" => "other"}})

    assert {:error, :payload_path_mismatch} =
             Envelope.validate(%{
               envelope
               | "payload" => %{payload | "path" => "apps/arbor_commands/priv/other.json"}
             })

    assert {:error, :invalid_payload_size} =
             Envelope.validate(%{envelope | "payload" => %{payload | "byte_size" => 0}})

    assert {:error, :invalid_payload_size} =
             Envelope.validate(%{envelope | "payload" => %{payload | "byte_size" => -1}})

    assert {:error, :invalid_digest} =
             Envelope.validate(%{
               envelope
               | "payload" => %{payload | "sha256" => String.upcase(payload["sha256"])}
             })

    assert {:error, :invalid_digest} =
             Envelope.validate(%{envelope | "payload" => %{payload | "sha256" => "deadbeef"}})

    assert {:error, :invalid_payload} = Envelope.validate(%{envelope | "payload" => :not_a_map})
    assert {:error, :invalid_envelope} = Envelope.validate(:not_a_map)
  end

  test "encode/1 is deterministic canonical JSON and round-trips through validation" do
    {:ok, envelope} = Envelope.build(@payload_bytes)

    assert {:ok, first} = Envelope.encode(envelope)
    assert {:ok, second} = Envelope.encode(Jason.decode!(first))
    assert first == second
    refute String.contains?(first, "\n")

    assert {:ok, decoded} = Jason.decode(first)
    assert :ok = Envelope.validate(decoded)
  end

  test "encode/1 refuses to encode an invalid envelope" do
    {:ok, envelope} = Envelope.build(@payload_bytes)
    assert {:error, :invalid_version} = Envelope.encode(%{envelope | "version" => 3})
  end
end
