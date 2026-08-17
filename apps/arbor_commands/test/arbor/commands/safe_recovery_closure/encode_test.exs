defmodule Arbor.Commands.SafeRecoveryClosure.EncodeTest do
  use ExUnit.Case, async: true

  alias Arbor.Commands.SafeRecoveryClosure.{Core, Encode}

  @moduletag :fast

  test "rejects a finding with an unknown id" do
    assert {:ok, evidence} = Core.project(closed_candidate())

    bad =
      put_in(evidence, ["findings"], [
        %{
          "id" => "made_up",
          "owner" => Encode.finding_owner(),
          "severity" => "blocker",
          "subject" => "x"
        }
      ])

    assert {:error, {:invalid_field, "findings", :invalid_member}} =
             Encode.validate_evidence(bad)
  end

  test "rejects mixed observation keys leaking into evidence" do
    assert {:ok, evidence} = Core.project(closed_candidate())
    assert {:error, :closed_keys} = Encode.validate_evidence(Map.put(evidence, "os_pid", 1))
  end

  test "emits compact canonical bytes and a framed domain digest" do
    assert {:ok, evidence} = Core.project(closed_candidate())
    assert {:ok, json} = Encode.canonical_json(evidence)
    refute String.contains?(json, "\n")
    refute String.contains?(json, "\": ")

    assert {:ok, digest} = Encode.evidence_digest(evidence)
    assert digest == Encode.framed_digest(Encode.domain(), json)
    assert Regex.match?(~r/\A[0-9a-f]{64}\z/, digest)

    mutated = put_in(evidence, ["shutdown", "remaining_names"], ["peer_probe"])
    assert {:ok, other} = Encode.evidence_digest(mutated)
    refute other == digest
  end

  test "validate_candidate/1 rejects projected evidence and unknown keys" do
    assert {:ok, evidence} = Core.project(closed_candidate())
    assert {:error, :closed_keys} = Encode.validate_candidate(evidence)
    assert {:error, :invalid_candidate} = Encode.validate_candidate(:nope)
    assert :ok = Encode.validate_candidate(closed_candidate())
  end

  defp closed_candidate do
    digest = String.duplicate("cd", 32)

    %{
      "schema" => Encode.schema(),
      "version" => 1,
      "profile" => %{"name" => "safe_recovery", "digest" => digest},
      "artifact" => %{"payload_tree_digest" => digest},
      "selected_applications" => ["arbor_kernel"],
      "artifact_applications" => [
        %{"name" => "arbor_kernel", "class" => "selected_first_party"}
      ],
      "pre_start" => empty_snapshot(),
      "post_start" =>
        empty_snapshot()
        |> Map.put("applications", [
          %{"name" => "arbor_kernel", "state" => "started"}
        ]),
      "shutdown" => %{"status" => "bounded", "remaining_names" => []}
    }
  end

  defp empty_snapshot do
    %{
      "applications" => [],
      "modules" => [],
      "registered_names" => [],
      "supervisors" => [],
      "ets_tables" => [],
      "ports" => [],
      "nifs" => [],
      "logger_handlers" => [],
      "telemetry_handlers" => [],
      "listeners" => []
    }
  end
end
