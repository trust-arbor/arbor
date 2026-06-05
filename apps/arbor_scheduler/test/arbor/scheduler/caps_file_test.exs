defmodule Arbor.Scheduler.CapsFileTest do
  @moduledoc """
  Tests for `Arbor.Scheduler.CapsFile` — Phase 3 of the scheduler-privesc
  redesign.

  Setup mints a fresh identity, registers it, enrolls it as an issuer with
  a known envelope, then synthesizes signed/unsigned/tampered `.caps.json`
  files and exercises the loader's verification chain.

  Each failure mode in `CapsFile.load/1` has at least one test asserting the
  specific error tuple, since callers (PipelineRunner) need to distinguish
  "issuer not enrolled" from "signature mismatch" from "cap outside envelope"
  to log meaningful errors.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  import Bitwise, only: [bxor: 2]

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.CapsFile
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  @envelope_uri "arbor://fs/write/reports/**"

  setup do
    {:ok, identity} = Identity.generate()
    :ok = IdentityRegistry.register(identity)

    {:ok, envelope} =
      Capability.new(
        resource_uri: @envelope_uri,
        principal_id: "agent_envelope_holder"
      )

    :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "caps_file_test")

    tmp_dir =
      System.tmp_dir!() |> Path.join("caps_file_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      IssuerRegistry.revoke(identity.agent_id, "test cleanup")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, identity: identity, envelope: envelope, tmp_dir: tmp_dir}
  end

  describe "load/1 happy path" do
    test "loads, verifies signature, returns descriptors", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      caps = [
        %{
          resource_uri: "arbor://fs/write/reports/upstream-deps-summary/**",
          constraints: %{}
        },
        %{
          resource_uri: "arbor://fs/write/reports/morning-digest-synthesis/**",
          constraints: %{}
        }
      ]

      path = Path.join(tmp_dir, "ok.caps.json")
      write_signed_caps_file(path, identity, caps)

      assert {:ok, descriptors} = CapsFile.load(path)
      assert length(descriptors) == 2
      assert Enum.all?(descriptors, &Map.has_key?(&1, :resource_uri))
      assert Enum.all?(descriptors, &Map.has_key?(&1, :constraints))
    end

    test "atomizes known constraint keys (string→atom)", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      caps = [
        %{
          resource_uri: "arbor://fs/write/reports/x/**",
          constraints: %{"rate_limit" => 50}
        }
      ]

      path = Path.join(tmp_dir, "atomize.caps.json")
      write_signed_caps_file(path, identity, caps)

      assert {:ok, [%{constraints: %{rate_limit: 50}}]} = CapsFile.load(path)
    end
  end

  describe "load/1 file/JSON errors" do
    test "missing file returns {:read_failed, :enoent}", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "does_not_exist.caps.json")
      assert {:error, {:read_failed, :enoent}} = CapsFile.load(path)
    end

    test "malformed JSON returns {:invalid_json, _}", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "broken.caps.json")
      File.write!(path, "not really json {{{")
      assert {:error, {:invalid_json, _}} = CapsFile.load(path)
    end
  end

  describe "load/1 schema errors" do
    test "missing version field returns invalid_schema", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_version.caps.json")

      File.write!(
        path,
        Jason.encode!(%{"issuer_id" => "x", "capabilities" => [], "signature" => "x"})
      )

      assert {:error, {:invalid_schema, {:missing_or_invalid, "version"}}} = CapsFile.load(path)
    end

    test "wrong version returns unsupported_version", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "v99.caps.json")

      write_raw_caps_file(path, %{
        "version" => 99,
        "issuer_id" => identity.agent_id,
        "capabilities" => [%{"resource_uri" => "arbor://fs/write/reports/x"}],
        "signature" => "AAAA"
      })

      assert {:error, {:invalid_schema, {:unsupported_version, 99}}} = CapsFile.load(path)
    end

    test "capability missing resource_uri returns indexed error", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "missing_uri.caps.json")

      write_raw_caps_file(path, %{
        "version" => 1,
        "issuer_id" => identity.agent_id,
        "capabilities" => [
          %{"resource_uri" => "arbor://fs/write/reports/x"},
          %{"constraints" => %{}}
        ],
        "signature" => "AAAA"
      })

      assert {:error, {:invalid_schema, {:capability_missing_resource_uri, 1}}} =
               CapsFile.load(path)
    end

    test "empty capabilities array rejected", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "empty_caps.caps.json")

      write_raw_caps_file(path, %{
        "version" => 1,
        "issuer_id" => identity.agent_id,
        "capabilities" => [],
        "signature" => "AAAA"
      })

      assert {:error, {:invalid_schema, :empty_capabilities}} = CapsFile.load(path)
    end
  end

  describe "load/1 trust errors" do
    test "unenrolled issuer returns :issuer_not_found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_issuer.caps.json")

      write_raw_caps_file(path, %{
        "version" => 1,
        "issuer_id" => "agent_4444444444444444444444444444444444444444444444444444444444444444",
        "capabilities" => [%{"resource_uri" => "arbor://fs/write/reports/x"}],
        "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
      })

      assert {:error, :issuer_not_found} = CapsFile.load(path)
    end

    test "revoked issuer returns :issuer_revoked", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      caps = [%{resource_uri: "arbor://fs/write/reports/x", constraints: %{}}]

      path = Path.join(tmp_dir, "revoked.caps.json")
      write_signed_caps_file(path, identity, caps)

      # Revoke AFTER signing — simulates a key compromise. Pre-existing signed
      # files must stop being honored.
      :ok = IssuerRegistry.revoke(identity.agent_id, "compromise")

      assert {:error, :issuer_revoked} = CapsFile.load(path)
    end

    test "regression: tampered signature returns :invalid_signature", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      # Sign a real payload, then flip a byte in the signature. The crypto
      # check is what closes the gate — without this guard the loader would
      # accept anything the issuer technically COULD have signed.
      caps = [%{resource_uri: "arbor://fs/write/reports/x", constraints: %{}}]

      payload = CapsFile.build(identity.agent_id, caps) |> CapsFile.signing_payload()
      sig = Crypto.sign(payload, identity.private_key)
      tampered_sig = flip_first_byte(sig)

      path = Path.join(tmp_dir, "tampered_sig.caps.json")

      write_raw_caps_file(path, %{
        "version" => 1,
        "issuer_id" => identity.agent_id,
        "capabilities" =>
          Enum.map(caps, fn c ->
            %{"resource_uri" => c.resource_uri, "constraints" => c.constraints}
          end),
        "signature" => Base.encode64(tampered_sig)
      })

      assert {:error, :invalid_signature} = CapsFile.load(path)
    end

    test "regression: tampered capability payload returns :invalid_signature", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      # Issuer signs caps A; attacker swaps in caps B. Without signature-
      # over-payload binding, attacker's substitution would slip through.
      original_caps = [%{resource_uri: "arbor://fs/write/reports/x", constraints: %{}}]

      payload =
        CapsFile.build(identity.agent_id, original_caps) |> CapsFile.signing_payload()

      sig = Crypto.sign(payload, identity.private_key)

      # Build file with DIFFERENT capabilities, same signature
      escalated_caps = [%{resource_uri: "arbor://shell/exec/rm", constraints: %{}}]

      path = Path.join(tmp_dir, "tampered_payload.caps.json")

      write_raw_caps_file(path, %{
        "version" => 1,
        "issuer_id" => identity.agent_id,
        "capabilities" =>
          Enum.map(escalated_caps, fn c ->
            %{"resource_uri" => c.resource_uri, "constraints" => c.constraints}
          end),
        "signature" => Base.encode64(sig)
      })

      assert {:error, :invalid_signature} = CapsFile.load(path)
    end
  end

  describe "load/1 envelope enforcement" do
    test "regression: cap outside envelope returns :cap_exceeds_envelope with URI",
         %{identity: identity, tmp_dir: tmp_dir} do
      # The whole point of the issuer registry: an issuer authorized to sign
      # for `arbor://fs/write/reports/**` cannot declare `arbor://shell/exec/rm`
      # even though they can validly sign anything (cryptographically). The
      # envelope check is the trust boundary.
      caps = [
        %{resource_uri: "arbor://fs/write/reports/x", constraints: %{}},
        %{resource_uri: "arbor://shell/exec/rm", constraints: %{}}
      ]

      path = Path.join(tmp_dir, "escape.caps.json")
      write_signed_caps_file(path, identity, caps)

      assert {:error, {:cap_exceeds_envelope, "arbor://shell/exec/rm"}} =
               CapsFile.load(path)
    end

    test "wider URI than envelope rejected", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      # Envelope is arbor://fs/write/reports/** — a cap for arbor://fs/write/**
      # is wider, must be rejected.
      caps = [%{resource_uri: "arbor://fs/write/**", constraints: %{}}]

      path = Path.join(tmp_dir, "wider.caps.json")
      write_signed_caps_file(path, identity, caps)

      assert {:error, {:cap_exceeds_envelope, "arbor://fs/write/**"}} = CapsFile.load(path)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_signed_caps_file(path, identity, caps) do
    parsed = CapsFile.build(identity.agent_id, caps)
    payload = CapsFile.signing_payload(parsed)
    sig = Crypto.sign(payload, identity.private_key)

    json_data = %{
      "version" => parsed.version,
      "issuer_id" => parsed.issuer_id,
      "capabilities" =>
        Enum.map(parsed.capabilities, fn c ->
          %{
            "resource_uri" => c.resource_uri,
            "constraints" => stringify_keys(c.constraints)
          }
        end),
      "signature" => Base.encode64(sig)
    }

    File.write!(path, Jason.encode!(json_data))
  end

  defp write_raw_caps_file(path, raw_map) do
    File.write!(path, Jason.encode!(raw_map))
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp flip_first_byte(<<first, rest::binary>>), do: <<bxor(first, 0xFF)::8, rest::binary>>
end
