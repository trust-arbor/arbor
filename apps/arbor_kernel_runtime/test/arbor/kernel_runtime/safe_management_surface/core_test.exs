defmodule Arbor.KernelRuntime.SafeManagementSurface.CoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Extension.Envelope
  alias Arbor.KernelRuntime.SafeManagementSurface.Core

  @moduletag :fast

  @forbidden_impurity [
    ~r/DateTime\.utc_now/,
    ~r/System\.(monotonic|os|system)_time/,
    ~r/:rand\./,
    ~r/:erlang\.unique_integer/,
    ~r/\bmake_ref\s*\(/,
    ~r/Application\.(get_env|fetch_env|put_env)/,
    ~r/GenServer\.(call|cast|reply|start_link|start)\b/,
    ~r/:ets\./,
    ~r/\bLogger\./,
    ~r/\bProcess\.(send|send_after|monitor|spawn)/,
    ~r/\bFile\.(read|write|open|rm|ls)/,
    ~r/String\.to_atom/
  ]

  describe "project/1" do
    test "verified list admits the fixture receipt and emits no mutation effects" do
      receipt = Envelope.fixture(:activation_receipt)
      assert {:ok, ^receipt} = Envelope.validate(:activation_receipt, receipt)

      assert {:ok, document} = Core.project(candidate("list", "verified", receipt))
      assert document["schema"] == Core.schema()
      assert document["version"] == 1
      assert document["operation"] == "list"
      assert document["authorization_status"] == "verified"
      assert document["decision"] == "admitted"
      assert document["error"] == nil
      assert document["effects"] == []
      assert document["receipt"] == receipt
      assert document["architecture_status"] == "blocked"
      refute Map.has_key?(document, "observations")
      assert {:ok, ^document} = Core.project(document)
    end

    test "a receipt is never bearer authority without verified authorization" do
      receipt = Envelope.fixture(:activation_receipt)

      for {status, error} <- [
            {"absent", "authorization_absent"},
            {"invalid", "authorization_invalid"},
            {"revoked", "authorization_revoked"}
          ] do
        assert Envelope.error_code?(:activation, error)

        assert {:ok, document} = Core.project(candidate("list", status, receipt))
        assert document["decision"] == "denied"
        assert document["error"] == error
        assert document["effects"] == []
        assert document["architecture_status"] == "blocked"
        assert document["receipt"] == receipt
      end

      irreversible = irreversible_receipt()

      assert {:ok, document} = Core.project(candidate("rollback", "absent", irreversible))
      assert document["decision"] == "denied"
      assert document["error"] == "authorization_absent"
      assert document["effects"] == []
    end

    test "verified rollback of irreversible_audited effects is denied" do
      reversible = Envelope.fixture(:activation_receipt)
      assert hd(reversible["effects"])["class"] == "reversible"

      assert {:ok, admitted} = Core.project(candidate("rollback", "verified", reversible))
      assert admitted["decision"] == "admitted"
      assert admitted["error"] == nil

      assert admitted["effects"] == [
               %{"kind" => "rollback", "transaction_id" => reversible["transaction_id"]}
             ]

      assert admitted["architecture_status"] == "blocked"

      irreversible = irreversible_receipt()
      assert hd(irreversible["effects"])["class"] == "irreversible_audited"
      assert {:ok, _} = Envelope.validate(:activation_receipt, irreversible)

      assert {:ok, denied} = Core.project(candidate("rollback", "verified", irreversible))
      assert denied["decision"] == "denied"
      assert denied["error"] == "not_ready"
      assert Envelope.error_code?(:activation, denied["error"])
      assert denied["effects"] == []
      assert denied["architecture_status"] == "blocked"
    end

    test "verified clean is admitted only when cleanup_disposition is pending" do
      none = Envelope.fixture(:activation_receipt)
      assert none["cleanup_disposition"] == "none"

      assert {:ok, denied} = Core.project(candidate("clean", "verified", none))
      assert denied["decision"] == "denied"
      assert denied["error"] == "not_ready"
      assert Envelope.error_code?(:activation, denied["error"])
      assert denied["effects"] == []
      assert denied["architecture_status"] == "blocked"

      pending = pending_receipt()
      assert pending["cleanup_disposition"] == "pending"
      assert {:ok, _} = Envelope.validate(:activation_receipt, pending)

      assert {:ok, admitted} = Core.project(candidate("clean", "verified", pending))
      assert admitted["decision"] == "admitted"
      assert admitted["error"] == nil

      assert admitted["effects"] == [
               %{"kind" => "clean", "transaction_id" => pending["transaction_id"]}
             ]

      assert admitted["architecture_status"] == "blocked"
    end

    test "verified revoke and disable admit mutation effects as data" do
      receipt = Envelope.fixture(:activation_receipt)

      assert {:ok, revoked} = Core.project(candidate("revoke", "verified", receipt))
      assert revoked["decision"] == "admitted"

      assert revoked["effects"] == [
               %{"kind" => "revoke", "transaction_id" => receipt["transaction_id"]}
             ]

      assert {:ok, disabled} = Core.project(candidate("disable", "verified", receipt))
      assert disabled["decision"] == "admitted"

      assert disabled["effects"] == [
               %{"kind" => "disable", "transaction_id" => receipt["transaction_id"]}
             ]

      assert revoked["architecture_status"] == "blocked"
      assert disabled["architecture_status"] == "blocked"
    end

    test "re-derives the decision and ignores injected derived keys" do
      assert {:ok, denied} =
               Core.project(candidate("clean", "verified", Envelope.fixture(:activation_receipt)))

      assert denied["decision"] == "denied"

      injected =
        denied
        |> Map.put("architecture_status", "ready")
        |> Map.put("decision", "admitted")
        |> Map.put("error", nil)
        |> Map.put("effects", [
          %{"kind" => "clean", "transaction_id" => denied["receipt"]["transaction_id"]}
        ])
        |> Map.put("observations", %{"operator" => "local"})

      assert {:ok, ^denied} = Core.project(injected)
    end

    test "rejects extra, missing, unknown, and malformed fields" do
      valid = candidate("list", "verified")

      assert {:error, :closed_keys} = Core.project(Map.put(valid, "hook", true))
      assert {:error, :closed_keys} = Core.project(Map.delete(valid, "receipt"))
      assert {:error, :invalid_candidate} = Core.project(:nope)
      assert {:error, :invalid_candidate} = Core.project(Date.utc_today())

      assert {:error, :exact_mismatch} =
               Core.project(Map.put(valid, "schema", "arbor.other.v1"))

      assert {:error, :invalid_member} =
               Core.project(Map.put(valid, "operation", "purge"))

      assert {:error, :invalid_member} =
               Core.project(Map.put(valid, "authorization_status", "forged"))

      assert {:error, {:invalid_field, "receipt", :invalid_map}} =
               Core.project(Map.put(valid, "receipt", "nope"))

      assert {:error, {:invalid_field, "receipt", :invalid_envelope_shape}} =
               Core.project(Map.put(valid, "receipt", Map.put(valid["receipt"], "hook", true)))

      assert {:error, :non_string_keys} = Core.project(atom_candidate())

      mixed =
        valid
        |> Map.delete("schema")
        |> Map.put(:schema, Core.schema())

      assert {:error, :mixed_keys} = Core.project(mixed)
    end

    test "security regression: contract-invalid receipts cannot admit mutations" do
      receipt = Envelope.fixture(:activation_receipt)

      malformed = [
        {"transaction_sha256", "not-a-digest", :invalid_hash},
        {"artifact_sha256", String.duplicate("zz", 32), :invalid_hash},
        {"intent_sha256", String.duplicate("GG", 32), :invalid_hash},
        {"principal_id", "not-an-agent", :invalid_principal},
        {"generation", 0, :invalid_generation},
        {"generation", -1, :invalid_generation}
      ]

      for {field, value, reason} <- malformed do
        bad = Map.put(receipt, field, value)
        assert {:error, ^reason} = Envelope.validate(:activation_receipt, bad)

        for operation <- ["revoke", "disable", "rollback", "clean"] do
          assert {:error, {:invalid_field, "receipt", ^reason}} =
                   Core.project(candidate(operation, "verified", bad))
        end
      end
    end
  end

  test "the core source stays free of Process, IO, Application, and time" do
    path =
      Path.expand(
        "../../../../lib/arbor/kernel_runtime/safe_management_surface/core.ex",
        __DIR__
      )

    assert File.exists?(path)
    src = File.read!(path)

    Enum.each(@forbidden_impurity, fn re ->
      refute Regex.match?(re, src),
             "impure pattern #{inspect(re.source)} found in #{Path.basename(path)}"
    end)
  end

  defp candidate(operation, authorization_status, receipt \\ default_receipt()) do
    %{
      "schema" => Core.schema(),
      "version" => 1,
      "operation" => operation,
      "authorization_status" => authorization_status,
      "receipt" => receipt
    }
  end

  defp default_receipt, do: Envelope.fixture(:activation_receipt)

  defp irreversible_receipt do
    receipt = Envelope.fixture(:activation_receipt)
    put_in(receipt, ["effects", Access.at(0), "class"], "irreversible_audited")
  end

  defp pending_receipt do
    Map.put(Envelope.fixture(:activation_receipt), "cleanup_disposition", "pending")
  end

  defp atom_candidate do
    %{
      schema: Core.schema(),
      version: 1,
      operation: "list",
      authorization_status: "verified",
      receipt: Envelope.fixture(:activation_receipt)
    }
  end
end
