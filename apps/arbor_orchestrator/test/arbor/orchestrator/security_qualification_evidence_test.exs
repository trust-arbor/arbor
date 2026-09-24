defmodule Arbor.Orchestrator.SecurityQualificationEvidenceTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  alias Arbor.Orchestrator.SecurityQualification.EvidenceCore
  alias Arbor.Persistence

  @fingerprint "sha256:" <> String.duplicate("a", 64)
  @digest "sha256:" <> String.duplicate("b", 64)
  @profile %{fingerprint: @fingerprint}

  defp result(kind) do
    %{
      id: kind <> "_result",
      sample_id: kind,
      passed: true,
      precondition_met: true,
      actual: "observed",
      metadata: %{
        "kind" => kind,
        "profile_fingerprint" => @fingerprint,
        "producer" => "source_owner",
        "producer_digest" => @digest,
        "artifact_digest" => @digest,
        "observations" => %{"effect_count" => 0, "attempted" => true}
      }
    }
  end

  defp run do
    %{
      id: "qualification_evidence",
      domain: "security_verify",
      status: "completed",
      config_fingerprint: @fingerprint,
      sample_count: 4,
      metadata: %{
        "qualification_schema" => "arbor.security.qualification.v1",
        "live_model_status" => "passed"
      },
      results:
        Enum.map(
          ~w(hostile_export_journey audit_restart native_containment skill_revocation),
          &result/1
        )
    }
  end

  defp admit(run, profile \\ @profile),
    do: profile |> EvidenceCore.new(run) |> EvidenceCore.show()

  test "complete evidence admits and ordering does not change its approval fingerprint" do
    run = run()
    assert {:ok, evidence} = admit(run)
    assert {:ok, reordered} = admit(%{run | results: Enum.reverse(run.results)})

    assert Persistence.eval_config_fingerprint(evidence) ==
             Persistence.eval_config_fingerprint(reordered)
  end

  test "model, tool, workflow, policy or skill fingerprint drift rejects old evidence" do
    assert {:error, :incomplete_security_qualification} = admit(run(), %{fingerprint: @digest})
  end

  test "a missing or duplicated evidence kind is not complete" do
    run = run()
    assert {:error, _} = admit(%{run | results: tl(run.results)})
    assert {:error, _} = admit(%{run | results: List.duplicate(hd(run.results), 4)})
  end

  test "failed or undelivered checks cannot be counted as a safe qualification" do
    run = run()

    for change <- [%{passed: false}, %{precondition_met: false}, %{precondition_met: nil}] do
      [first | rest] = run.results
      assert {:error, _} = admit(%{run | results: [Map.merge(first, change) | rest]})
    end
  end

  test "unavailable live model evidence and unfinished persistence are refused" do
    run = run()
    assert {:error, _} = admit(%{run | status: "running"})

    assert {:error, _} =
             admit(%{run | metadata: Map.put(run.metadata, "live_model_status", "unavailable")})
  end

  test "safe model refusal remains distinct from the independent deterministic gate proof" do
    run = run()

    assert {:ok, evidence} =
             admit(%{
               run
               | metadata: Map.put(run.metadata, "live_model_status", "safe_without_export")
             })

    assert evidence["metadata"]["live_model_status"] == "safe_without_export"
    assert length(evidence["results"]) == 4
  end

  test "every observation and artifact is covered by the operator approval digest" do
    run = run()
    assert {:ok, initial} = admit(run)
    [first | rest] = run.results
    changed = put_in(first, [:metadata, "observations", "effect_count"], 1)
    assert {:ok, altered} = admit(%{run | results: [changed | rest]})

    refute Persistence.eval_config_fingerprint(initial) ==
             Persistence.eval_config_fingerprint(altered)
  end

  test "cross-profile artifacts and missing producer or artifact digests are refused" do
    run = run()
    [first | rest] = run.results

    for {key, value} <- [
          {"profile_fingerprint", @digest},
          {"producer_digest", nil},
          {"artifact_digest", "alias"}
        ] do
      changed = put_in(first, [:metadata, key], value)
      assert {:error, _} = admit(%{run | results: [changed | rest]})
    end
  end
end
