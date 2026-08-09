defmodule Arbor.Orchestrator.CodingPlan.AuthorityHorizonCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.CodingPlan.AuthorityHorizonCore

  describe "horizon_unix_ms/2" do
    test "adds cleanup reserve to the run deadline" do
      assert {:ok, 1_030_000} = AuthorityHorizonCore.horizon_unix_ms(1_000_000, 30_000)
    end

    test "allows a zero cleanup reserve" do
      assert {:ok, 1_000_000} = AuthorityHorizonCore.horizon_unix_ms(1_000_000, 0)
    end

    test "rejects invalid inputs" do
      assert {:error, :invalid_horizon} = AuthorityHorizonCore.horizon_unix_ms(-1, 30_000)
      assert {:error, :invalid_horizon} = AuthorityHorizonCore.horizon_unix_ms(1_000, -1)
      assert {:error, :invalid_horizon} = AuthorityHorizonCore.horizon_unix_ms(nil, 30_000)
    end
  end

  describe "principals/2" do
    test "always includes the execution principal" do
      assert AuthorityHorizonCore.principals("agent_1", nil) == [
               {:execution_principal, "agent_1"}
             ]
    end

    test "deduplicates when caller equals execution principal" do
      assert AuthorityHorizonCore.principals("agent_1", "agent_1") == [
               {:execution_principal, "agent_1"}
             ]
    end

    test "includes a distinct authenticated caller" do
      assert AuthorityHorizonCore.principals("agent_1", "caller_9") == [
               {:execution_principal, "agent_1"},
               {:authenticated_caller, "caller_9"}
             ]
    end
  end

  describe "union_resources/1" do
    test "sorts unique non-blank URIs" do
      assert AuthorityHorizonCore.union_resources([
               ["arbor://b", "arbor://a", ""],
               ["arbor://a", "arbor://c"],
               nil
             ]) == ["arbor://a", "arbor://b", "arbor://c"]
    end
  end

  describe "classify_resource_coverage/2" do
    setup do
      horizon = ~U[2026-08-06 12:00:00.000000Z]
      %{horizon: horizon}
    end

    test "permanent authority covers the horizon", %{horizon: horizon} do
      assert :ok =
               AuthorityHorizonCore.classify_resource_coverage(
                 [%{expires_at: nil}],
                 horizon
               )
    end

    test "adequate finite authority covers the horizon", %{horizon: horizon} do
      expires = DateTime.add(horizon, 60, :second)

      assert :ok =
               AuthorityHorizonCore.classify_resource_coverage(
                 [%{expires_at: expires}],
                 horizon
               )
    end

    test "missing authority when no authorizing caps", %{horizon: horizon} do
      assert :missing = AuthorityHorizonCore.classify_resource_coverage([], horizon)
    end

    test "malformed authority without an expiry field cannot cover the horizon", %{
      horizon: horizon
    } do
      assert :expiring =
               AuthorityHorizonCore.classify_resource_coverage([%{}], horizon)
    end

    test "expiring authority when finite expiry is at or before horizon", %{horizon: horizon} do
      assert :expiring =
               AuthorityHorizonCore.classify_resource_coverage(
                 [%{expires_at: horizon}],
                 horizon
               )

      assert :expiring =
               AuthorityHorizonCore.classify_resource_coverage(
                 [%{expires_at: DateTime.add(horizon, -1, :second)}],
                 horizon
               )
    end
  end

  describe "aggregate_findings/1" do
    test "returns ok when every resource is covered" do
      assert :ok =
               AuthorityHorizonCore.aggregate_findings([
                 {:execution_principal, "arbor://a", :ok},
                 {:authenticated_caller, "arbor://a", :ok}
               ])
    end

    test "retains complete URI lists and stable role/classification order" do
      assert {:error, findings} =
               AuthorityHorizonCore.aggregate_findings([
                 {:authenticated_caller, "arbor://z", :expiring},
                 {:execution_principal, "arbor://b", :missing},
                 {:execution_principal, "arbor://a", :missing},
                 {:authenticated_caller, "arbor://m", :missing}
               ])

      assert [
               %{
                 role: :execution_principal,
                 classification: :missing,
                 resource_uris: ["arbor://a", "arbor://b"],
                 total_count: 2
               },
               %{
                 role: :authenticated_caller,
                 classification: :missing,
                 resource_uris: ["arbor://m"],
                 total_count: 1
               },
               %{
                 role: :authenticated_caller,
                 classification: :expiring,
                 resource_uris: ["arbor://z"],
                 total_count: 1
               }
             ] = findings
    end
  end

  describe "project_diagnostic_payload/2" do
    test "missing wins over expiring for diagnostic code" do
      findings = [
        %{
          role: :execution_principal,
          classification: :missing,
          resource_uris: ["arbor://a"],
          total_count: 1
        },
        %{
          role: :authenticated_caller,
          classification: :expiring,
          resource_uris: ["arbor://b"],
          total_count: 1
        }
      ]

      payload =
        AuthorityHorizonCore.project_diagnostic_payload(
          findings,
          "2026-08-06T12:00:00.000000Z"
        )

      assert payload.gate_id == "authority_horizon"
      assert payload.code == "authority_horizon_missing"
      assert payload.phase == "preflight"
      assert payload.decision == "blocked"
      assert payload.evidence_ref =~ "missing_n=1"
      assert payload.evidence_ref =~ "expiring_n=1"
      assert payload.evidence_ref =~ "digest="
    end

    test "only-expiring findings use authority_horizon_expiring" do
      findings = [
        %{
          role: :authenticated_caller,
          classification: :expiring,
          resource_uris: ["arbor://x"],
          total_count: 1
        }
      ]

      payload =
        AuthorityHorizonCore.project_diagnostic_payload(
          findings,
          "2026-08-06T12:00:00.000000Z"
        )

      assert payload.code == "authority_horizon_expiring"
    end

    test "truncates projected URI lists only after full classification" do
      uris =
        for i <- 1..70 do
          "arbor://resource/#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        end

      findings = [
        %{
          role: :execution_principal,
          classification: :missing,
          resource_uris: uris,
          total_count: 70
        }
      ]

      payload =
        AuthorityHorizonCore.project_diagnostic_payload(
          findings,
          "2026-08-06T12:00:00.000000Z"
        )

      [projected] = payload.findings
      assert projected["total_count"] == 70
      assert length(projected["resource_uris"]) == AuthorityHorizonCore.projected_uri_limit()
      assert projected["resource_uris_digest"] == AuthorityHorizonCore.uri_list_digest(uris)
      assert payload.evidence_ref =~ "missing_n=70"
      assert byte_size(payload.message) <= 256
      assert byte_size(payload.evidence_ref) <= 256
    end

    test "uses injected observed_at and a deterministic fallback without wall-clock" do
      findings = [
        %{
          role: :execution_principal,
          classification: :missing,
          resource_uris: ["arbor://a"],
          total_count: 1
        }
      ]

      payload =
        AuthorityHorizonCore.project_diagnostic_payload(
          findings,
          "2026-08-06T12:00:00.000000Z"
        )

      assert payload.observed_at == "2026-08-06T12:00:00.000000Z"

      fallback = AuthorityHorizonCore.project_diagnostic_payload(findings, nil)
      assert fallback.observed_at == "1970-01-01T00:00:00.000000Z"
    end
  end

  describe "bound_text/2" do
    test "never splits a multi-byte UTF-8 codepoint under the byte budget" do
      # Each snowman is 3 bytes (U+2603). Budget of 5 allows one codepoint only.
      text = "☃☃☃"
      bounded = AuthorityHorizonCore.bound_text(text, 5)
      assert String.valid?(bounded)
      assert byte_size(bounded) <= 5
      assert bounded == "☃"
    end

    test "strips control characters and never returns blank text" do
      assert AuthorityHorizonCore.bound_text("\n\t", 32) == "authority horizon blocked"
      assert AuthorityHorizonCore.bound_text("ok\x00path", 32) == "ok path"
      assert AuthorityHorizonCore.bound_text(<<255>>, 32) == "authority horizon blocked"
    end
  end

  describe "project_resource_set/1" do
    test "bounds samples while retaining complete count and digest" do
      uris =
        for i <- 1..70 do
          "arbor://resource/#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        end

      projected = AuthorityHorizonCore.project_resource_set(Enum.shuffle(uris))

      assert projected["total_count"] == 70
      assert length(projected["resource_uris"]) == AuthorityHorizonCore.projected_uri_limit()
      assert projected["resource_uris"] == Enum.take(Enum.sort(uris), 64)

      assert projected["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest(Enum.sort(uris))
    end
  end

  describe "projection_status/1" do
    test "missing wins over expiring" do
      findings = [
        %{
          role: :execution_principal,
          classification: :missing,
          resource_uris: ["arbor://a"],
          total_count: 1
        },
        %{
          role: :authenticated_caller,
          classification: :expiring,
          resource_uris: ["arbor://b"],
          total_count: 1
        }
      ]

      assert AuthorityHorizonCore.projection_status(findings) == "missing"
      assert AuthorityHorizonCore.projection_status(:ok) == "ready"

      assert AuthorityHorizonCore.projection_status([
               %{
                 role: :execution_principal,
                 classification: :expiring,
                 resource_uris: ["arbor://a"],
                 total_count: 1
               }
             ]) == "expiring"
    end

    test "fails closed without raising on malformed finding entries" do
      assert AuthorityHorizonCore.projection_status([%{}]) == "error"
      assert AuthorityHorizonCore.projection_status([:malformed]) == "error"
    end
  end

  describe "project_horizon_report/1" do
    test "emits a string-keyed JSON-clean projection with digests" do
      findings = [
        %{
          role: :execution_principal,
          classification: :missing,
          resource_uris: ["arbor://b", "arbor://a"],
          total_count: 2
        }
      ]

      report =
        AuthorityHorizonCore.project_horizon_report(%{
          observed_at: "2026-08-06T12:00:00.000000Z",
          findings: findings,
          resources: ["arbor://b", "arbor://a", "arbor://c"],
          principals: [{:execution_principal, "agent_exec"}],
          scope_mode: :future_task,
          task_id: "task_smuggled",
          session_id: "session_smuggled",
          run_deadline_unix_ms: 1_000_000,
          cleanup_reserve_ms: 30_000,
          horizon_unix_ms: 1_030_000
        })

      assert report["version"] == 1
      assert report["kind"] == "authority_horizon_projection"
      assert report["status"] == "missing"
      assert report["scope"]["mode"] == "future_task"
      assert report["scope"]["task_id"] == nil
      assert report["scope"]["session_id"] == nil
      assert report["required_resources"]["total_count"] == 3

      assert report["required_resources"]["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest(["arbor://a", "arbor://b", "arbor://c"])

      assert report["summary"]["missing_n"] == 2
      assert is_binary(report["summary"]["findings_digest"])
      assert Jason.encode!(report)
      refute Map.has_key?(report, :findings)
    end

    test "bounds finding samples above 64 while retaining full total_count and digest" do
      uris =
        for i <- 1..70 do
          "arbor://resource/#{String.pad_leading(Integer.to_string(i), 3, "0")}"
        end

      findings = [
        %{
          role: :execution_principal,
          classification: :missing,
          resource_uris: uris,
          total_count: 70
        }
      ]

      report =
        AuthorityHorizonCore.project_horizon_report(%{
          findings: findings,
          resources: uris,
          status: "missing"
        })

      [projected] = report["findings"]
      assert projected["total_count"] == 70
      assert length(projected["resource_uris"]) == AuthorityHorizonCore.projected_uri_limit()

      assert projected["resource_uris_digest"] ==
               AuthorityHorizonCore.uri_list_digest(Enum.sort(uris))

      assert report["summary"]["missing_n"] == 70
    end

    test "returns a stable error report for malformed findings" do
      report = AuthorityHorizonCore.project_horizon_report(%{findings: [%{}]})

      assert report["status"] == "error"
      assert report["findings"] == []
      assert Jason.encode!(report)
    end
  end
end
