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

  test "admits a projected document with more than 64 unexplained_module findings" do
    candidate = put_in(closed_candidate(), ["post_start", "modules"], unexplained_modules(65))

    assert {:ok, evidence} = Core.project(candidate)
    assert length(evidence["findings"]) > 64
    assert Enum.all?(evidence["findings"], &(&1["id"] == "unexplained_module"))
    assert :ok = Encode.validate_evidence(evidence)
  end

  test "validate_evidence/1 admits a 65-entry findings list" do
    assert {:ok, evidence} = Core.project(closed_candidate())
    document = Map.put(evidence, "findings", findings_list(65))

    assert length(document["findings"]) == 65
    assert :ok = Encode.validate_evidence(document)
  end

  test "admits a 117-finding live-shaped document" do
    assert {:ok, evidence} = Core.project(closed_candidate())

    live =
      evidence
      |> Map.put("closure_status", "open")
      |> Map.put("findings", live_shaped_findings(117))

    assert length(live["findings"]) == 117
    assert :ok = Encode.validate_evidence(live)
  end

  test "validate_evidence/1 admits the findings ceiling and rejects one over" do
    assert {:ok, evidence} = Core.project(closed_candidate())
    ceiling = Encode.max_findings()

    at_ceiling = Map.put(evidence, "findings", findings_list(ceiling))
    assert length(at_ceiling["findings"]) == ceiling
    assert :ok = Encode.validate_evidence(at_ceiling)

    over = Map.put(evidence, "findings", findings_list(ceiling + 1))

    assert {:error, {:invalid_field, "findings", :unbounded}} =
             Encode.validate_evidence(over)
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

  defp unexplained_modules(count) do
    for i <- 1..count do
      %{"module" => "Elixir.Unexplained#{i}", "application" => "mix"}
    end
  end

  defp findings_list(count) do
    for i <- 1..count do
      finding("unexplained_module", "Elixir.Finding#{i}")
    end
  end

  defp live_shaped_findings(count) do
    prefix = [
      finding("forbidden_facility_present", "full_signals_monitor_and_os_mon"),
      finding("selected_start_failed", "arbor_security"),
      finding("selected_start_failed", "arbor_trust"),
      finding("third_party_started", "castore"),
      finding("third_party_started", "finch")
    ]

    modules =
      for i <- 1..(count - length(prefix)) do
        finding("unexplained_module", "Elixir.LiveModule#{i}")
      end

    prefix ++ modules
  end

  defp finding(id, subject) do
    %{
      "id" => id,
      "owner" => Encode.finding_owner(),
      "severity" => "blocker",
      "subject" => subject
    }
  end
end
