defmodule Arbor.Scheduler.CapsFileTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.{Capability, Identity}
  alias Arbor.Scheduler.CapsFile
  alias Arbor.Scheduler.CapsFile.Attestation
  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry, as: IdentityRegistry
  alias Arbor.Security.IssuerRegistry

  @envelope_uri "arbor://fs/write/reports/**"
  @dot_source "digraph Signed { start [shape=Mdiamond] }"

  setup do
    {:ok, identity} = Identity.generate()
    :ok = IdentityRegistry.register(identity)

    {:ok, envelope} =
      Capability.new(resource_uri: @envelope_uri, principal_id: identity.agent_id)

    :ok = IssuerRegistry.register(identity.agent_id, envelope, reason: "caps_file_test")

    tmp_dir =
      System.tmp_dir!() |> Path.join("caps_file_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn ->
      IssuerRegistry.revoke(identity.agent_id, "test cleanup")
      File.rm_rf!(tmp_dir)
    end)

    {:ok, identity: identity, tmp_dir: tmp_dir}
  end

  describe "version 2 verification" do
    test "returns the complete verified attestation", %{identity: identity, tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "review.caps.json")
      initial_args = %{"mode" => "review", "attempts" => [1, 2]}

      write_signed(path, identity, tmp_dir,
        initial_args: initial_args,
        capabilities: [
          %{
            resource_uri: "arbor://fs/write/reports/review/",
            constraints: %{"rate_limit" => 5}
          }
        ]
      )

      assert {:ok, %Attestation{} = attestation} = CapsFile.load(path)
      assert attestation.version == 2
      assert attestation.issuer_id == identity.agent_id
      assert attestation.pipeline_root == "test"
      assert attestation.pipeline_path == "jobs/review.dot"
      assert attestation.graph_hash == sha256(@dot_source)
      assert attestation.workdir == Path.expand(tmp_dir)
      assert attestation.initial_args == initial_args

      assert [descriptor] = attestation.capabilities
      assert descriptor.resource_uri == "arbor://fs/write/reports/review"
      assert descriptor.constraints == %{rate_limit: 5}
      assert descriptor.issuer_id == identity.agent_id
    end

    test "empty declared capability set is explicit and valid", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "empty.caps.json")
      write_signed(path, identity, tmp_dir, capabilities: [])

      assert {:ok, %Attestation{capabilities: []}} = CapsFile.load(path)
    end

    test "canonical payload ignores object and capability declaration order", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      caps_a = [
        %{resource_uri: "arbor://fs/write/reports/a", constraints: %{rate_limit: 1}},
        %{resource_uri: "arbor://fs/write/reports/b", constraints: %{}}
      ]

      caps_b = Enum.reverse(caps_a)
      args_a = Map.new([{"z", 1}, {"a", %{"y" => 2, "x" => 3}}])
      args_b = Map.new([{"a", %{"x" => 3, "y" => 2}}, {"z", 1}])

      {:ok, first} = CapsFile.build(identity.agent_id, caps_a, attrs(tmp_dir, args_a))
      {:ok, second} = CapsFile.build(identity.agent_id, caps_b, attrs(tmp_dir, args_b))

      assert CapsFile.signing_payload(first) == CapsFile.signing_payload(second)
    end

    test "exact JSON argument comparison distinguishes numeric encodings" do
      assert CapsFile.initial_args_match?(%{"n" => 1}, %{"n" => 1})
      refute CapsFile.initial_args_match?(%{"n" => 1}, %{"n" => 1.0})
      refute CapsFile.initial_args_match?(%{n: 1}, %{"n" => 1})
    end
  end

  describe "version and schema gates" do
    test "security regression: legacy version 1 fails closed before issuer lookup", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "legacy.caps.json")

      File.write!(
        path,
        Jason.encode!(%{
          "version" => 1,
          "issuer_id" => "agent_not_enrolled",
          "capabilities" => [],
          "signature" => Base.encode64(:crypto.strong_rand_bytes(64))
        })
      )

      assert {:error, {:legacy_version, 1}} = CapsFile.load(path)
    end

    test "unsupported future version is rejected", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "future.caps.json")
      File.write!(path, Jason.encode!(%{"version" => 99}))

      assert {:error, {:invalid_schema, {:unsupported_version, 99}}} = CapsFile.load(path)
    end

    test "missing and malformed files return specific errors", %{tmp_dir: tmp_dir} do
      missing = Path.join(tmp_dir, "missing.caps.json")
      malformed = Path.join(tmp_dir, "malformed.caps.json")
      File.write!(malformed, "not-json")

      assert {:error, {:read_failed, :enoent}} = CapsFile.load(missing)
      assert {:error, {:invalid_json, _}} = CapsFile.load(malformed)
    end

    test "build rejects non-JSON args and noncanonical execution paths", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      assert {:error, {:invalid_schema, {:non_string_initial_arg_key, []}}} =
               CapsFile.build(identity.agent_id, [], attrs(tmp_dir, %{unsafe: true}))

      assert {:error, {:invalid_schema, {:invalid_pipeline_path, "../escape.dot"}}} =
               CapsFile.build(
                 identity.agent_id,
                 [],
                 attrs(tmp_dir, %{}) |> Keyword.put(:pipeline_path, "../escape.dot")
               )

      assert {:error, {:invalid_schema, {:invalid_workdir, "relative"}}} =
               CapsFile.build(
                 identity.agent_id,
                 [],
                 attrs(tmp_dir, %{}) |> Keyword.put(:workdir, "relative")
               )
    end

    test "invalid and traversal capability URIs are rejected by build", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      assert {:error, {:invalid_schema, {:invalid_resource_uri, :invalid_scheme}}} =
               CapsFile.build(
                 identity.agent_id,
                 [%{resource_uri: "https://example.com", constraints: %{}}],
                 attrs(tmp_dir, %{})
               )

      assert {:error, {:invalid_schema, {:invalid_resource_uri, :traversal_segment}}} =
               CapsFile.build(
                 identity.agent_id,
                 [
                   %{
                     resource_uri: "arbor://fs/write/reports/../secret",
                     constraints: %{}
                   }
                 ],
                 attrs(tmp_dir, %{})
               )
    end
  end

  describe "signature binding" do
    for {field, replacement} <- [
          {"pipeline_root", "copied_root"},
          {"pipeline_path", "jobs/copied.dot"},
          {"graph_hash", String.duplicate("0", 64)},
          {"workdir", "/different/workdir"},
          {"initial_args", %{"mode" => "publish"}},
          {"capabilities",
           [%{"resource_uri" => "arbor://fs/write/reports/other", "constraints" => %{}}]}
        ] do
      test "security regression: tampering #{field} invalidates the signature", %{
        identity: identity,
        tmp_dir: tmp_dir
      } do
        path = Path.join(tmp_dir, "tampered_#{unquote(field)}.caps.json")
        raw = signed_manifest(identity, tmp_dir, initial_args: %{"mode" => "review"})

        File.write!(
          path,
          raw |> Map.put(unquote(field), unquote(Macro.escape(replacement))) |> Jason.encode!()
        )

        assert {:error, :invalid_signature} = CapsFile.load(path)
      end
    end

    test "security regression: invalid signature bytes are rejected", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "bad_signature.caps.json")

      raw =
        identity
        |> signed_manifest(tmp_dir)
        |> Map.put("signature", Base.encode64(:crypto.strong_rand_bytes(64)))

      File.write!(path, Jason.encode!(raw))
      assert {:error, :invalid_signature} = CapsFile.load(path)
    end
  end

  describe "issuer envelope" do
    test "security regression: a valid signature cannot exceed the issuer envelope", %{
      identity: identity,
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "envelope_escape.caps.json")

      write_signed(path, identity, tmp_dir,
        capabilities: [%{resource_uri: "arbor://shell/exec/rm", constraints: %{}}]
      )

      assert {:error, {:cap_exceeds_envelope, "arbor://shell/exec/rm"}} =
               CapsFile.load(path)
    end

    test "revoked and unenrolled issuers fail closed", %{identity: identity, tmp_dir: tmp_dir} do
      revoked_path = Path.join(tmp_dir, "revoked.caps.json")
      write_signed(revoked_path, identity, tmp_dir)
      :ok = IssuerRegistry.revoke(identity.agent_id, "compromised")
      assert {:error, :issuer_revoked} = CapsFile.load(revoked_path)

      {:ok, other} = Identity.generate()
      :ok = IdentityRegistry.register(other)
      unenrolled_path = Path.join(tmp_dir, "unenrolled.caps.json")
      write_signed(unenrolled_path, other, tmp_dir)
      assert {:error, :issuer_not_found} = CapsFile.load(unenrolled_path)
    end
  end

  defp write_signed(path, identity, tmp_dir, opts \\ []) do
    File.write!(path, signed_manifest(identity, tmp_dir, opts) |> Jason.encode!())
  end

  defp signed_manifest(identity, tmp_dir, opts \\ []) do
    capabilities =
      Keyword.get(opts, :capabilities, [
        %{resource_uri: "arbor://fs/write/reports/review", constraints: %{}}
      ])

    initial_args = Keyword.get(opts, :initial_args, %{})
    {:ok, payload} = CapsFile.build(identity.agent_id, capabilities, attrs(tmp_dir, initial_args))
    signature = Crypto.sign(CapsFile.signing_payload(payload), identity.private_key)
    CapsFile.manifest_map(payload, signature)
  end

  defp attrs(tmp_dir, initial_args) do
    [
      pipeline_root: "test",
      pipeline_path: "jobs/review.dot",
      graph_hash: sha256(@dot_source),
      workdir: Path.expand(tmp_dir),
      initial_args: initial_args
    ]
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
