defmodule Arbor.Actions.Coding.ReviewLedgerCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.ReviewLedgerCore

  @moduletag :fast
  @perspectives ["correctness", "security", "maintainability"]

  test "generates stable owner-scoped IDs without candidate identity" do
    finding = finding("same issue", "major", 10)

    {:ok, first} =
      apply_cycle(new_ledger(), 1, %{"correctness" => report(new_findings: [finding])})

    {:ok, second} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report(new_findings: [Map.put(finding, "evidence", "candidate-2")])
      })

    first_finding = first["findings"] |> Map.values() |> hd()
    second_finding = second["findings"] |> Map.values() |> hd()
    assert first_finding["id"] == second_finding["id"]
    assert first_finding["issue_key"] == second_finding["issue_key"]

    {:ok, owned_by_security} =
      apply_cycle(new_ledger(), 1, %{
        "security" => report(new_findings: [finding])
      })

    refute first_finding["id"] == (owned_by_security["findings"] |> Map.values() |> hd())["id"]
  end

  test "rejects unknown owners, embedded owner changes, and cross-owner updates" do
    assert {:error, :unknown_perspective} =
             apply_cycle(new_ledger(), 1, %{"unknown" => report()})

    assert {:error, _reason} =
             apply_cycle(new_ledger(), 1, %{
               "correctness" => report(new_findings: [Map.put(finding(), "owner", "security")])
             })

    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{"correctness" => report(new_findings: [finding()])})

    id = ledger["findings"] |> Map.keys() |> hd()

    assert {:error, {:cross_owner_update, "security"}} =
             apply_cycle(ledger, 2, %{
               "security" => report(finding_updates: [%{"id" => id, "state" => "fixed"}])
             })

    assert {:error, :invalid_new_finding_state} =
             apply_cycle(new_ledger(), 1, %{
               "correctness" => report(new_findings: [Map.put(finding(), "state", "fixed")])
             })
  end

  test "rejects immutable changes and keeps fixed findings closed" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{"correctness" => report(new_findings: [finding()])})

    id = ledger["findings"] |> Map.keys() |> hd()

    assert {:error, :immutable_finding_field} =
             apply_cycle(ledger, 2, %{
               "correctness" =>
                 report(
                   finding_updates: [%{"id" => id, "state" => "open", "severity" => "blocking"}]
                 )
             })

    assert {:error, :immutable_finding_field} =
             apply_cycle(ledger, 2, %{
               "correctness" =>
                 report(
                   finding_updates: [
                     %{"id" => id, "state" => "open", "title" => "changed identity"}
                   ]
                 )
             })

    {:ok, fixed} =
      apply_cycle(ledger, 2, %{
        "correctness" => report(finding_updates: [%{"id" => id, "state" => "fixed"}])
      })

    assert fixed["findings"][id]["state"] == "fixed"

    assert {:error, :fixed_finding_cannot_reopen} =
             apply_cycle(fixed, 3, %{
               "correctness" => report(finding_updates: [%{"id" => id, "state" => "open"}])
             })
  end

  test "recheck reports must update every owned active finding exactly once" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report(new_findings: [finding("must fix", "blocking")])
      })

    id = ledger["findings"] |> Map.keys() |> hd()

    # Omitting an owned active finding is invalid on recheck (not silent stale open).
    assert {:error, {:incomplete_owned_finding_updates, "correctness"}} =
             apply_cycle(ledger, 2, %{"correctness" => report()})

    # Without a valid owner report, the stale blocker stays and routes human_review.
    {:ok, unconfirmed} = apply_cycle(ledger, 2, %{})
    assert unconfirmed["findings"][id]["state"] == "open"
    decision = ReviewLedgerCore.decision(unconfirmed)
    assert decision["disposition"] == "human_review"
    assert decision["blocking_reasons"] == [%{"id" => id, "reason" => "unconfirmed_blocker"}]
  end

  test "projects foreign finding updates away without mutating them or invalidating same-owner evidence" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report(new_findings: [finding("owned by correctness", "blocking", 10)]),
        "security" => report(new_findings: [finding("owned by security", "blocking", 20)]),
        "maintainability" =>
          report(new_findings: [finding("owned by maintainability", "blocking", 30)])
      })

    correctness_id =
      ledger["findings"]
      |> Map.values()
      |> Enum.find(&(&1["owner"] == "correctness"))
      |> Map.fetch!("id")

    security_id =
      ledger["findings"]
      |> Map.values()
      |> Enum.find(&(&1["owner"] == "security"))
      |> Map.fetch!("id")

    maintainability_id =
      ledger["findings"]
      |> Map.values()
      |> Enum.find(&(&1["owner"] == "maintainability"))
      |> Map.fetch!("id")

    mixed_report =
      report(
        finding_updates: [
          %{"id" => correctness_id, "state" => "fixed"},
          # Semantically duplicate foreign id — must be ignored by projection.
          %{"id" => security_id, "state" => "fixed"}
        ]
      )

    projected =
      ReviewLedgerCore.project_report_to_authority("correctness", mixed_report, ledger)

    assert projected["finding_updates"] == [%{"id" => correctness_id, "state" => "fixed"}]

    # Direct apply_cycle still rejects retained cross-owner mutation attempts.
    assert {:error, {:cross_owner_update, "correctness"}} =
             apply_cycle(ledger, 2, %{"correctness" => mixed_report})

    # After projection, complete same-owner evidence applies; foreign stays open.
    {:ok, fixed} =
      apply_cycle(ledger, 2, %{
        "correctness" => projected,
        "security" => report(finding_updates: [%{"id" => security_id, "state" => "fixed"}]),
        "maintainability" =>
          report(finding_updates: [%{"id" => maintainability_id, "state" => "fixed"}])
      })

    assert fixed["findings"][correctness_id]["state"] == "fixed"
    assert fixed["findings"][security_id]["state"] == "fixed"
    assert fixed["findings"][maintainability_id]["state"] == "fixed"
    assert ReviewLedgerCore.decision(fixed)["disposition"] == "accept"
  end

  test "unknown finding ids still fail closed after authority projection" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{"correctness" => report(new_findings: [finding()])})

    id = ledger["findings"] |> Map.keys() |> hd()

    report_with_unknown =
      report(
        finding_updates: [
          %{"id" => id, "state" => "fixed"},
          %{"id" => "deadbeef" <> String.duplicate("0", 56), "state" => "fixed"}
        ]
      )

    projected =
      ReviewLedgerCore.project_report_to_authority("correctness", report_with_unknown, ledger)

    # Unknown id is preserved (not a known foreign finding) and fails closed.
    assert length(projected["finding_updates"]) == 2

    assert {:error, :unknown_finding} =
             apply_cycle(ledger, 2, %{"correctness" => projected})
  end

  test "explicitly reconfirmed blockers remain rework; unconfirmed blockers escalate" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report(new_findings: [finding("must fix", "blocking", 10)]),
        "security" => report(new_findings: [finding("also blocking", "blocking", 20)])
      })

    correctness_id =
      ledger["findings"]
      |> Map.values()
      |> Enum.find(&(&1["owner"] == "correctness"))
      |> Map.fetch!("id")

    security_id =
      ledger["findings"]
      |> Map.values()
      |> Enum.find(&(&1["owner"] == "security"))
      |> Map.fetch!("id")

    # Correctness reconfirms open; security never reports this cycle.
    {:ok, rechecked} =
      apply_cycle(ledger, 2, %{
        "correctness" => report(finding_updates: [%{"id" => correctness_id, "state" => "open"}])
      })

    decision = ReviewLedgerCore.decision(rechecked)
    # Unconfirmed security blocker dominates routing to human_review.
    assert decision["disposition"] == "human_review"

    assert %{"id" => ^security_id, "reason" => "unconfirmed_blocker"} =
             Enum.find(decision["blocking_reasons"], &(&1["id"] == security_id))

    assert %{"id" => ^correctness_id, "reason" => "active_blocking"} =
             Enum.find(decision["blocking_reasons"], &(&1["id"] == correctness_id))

    # When every owner reconfirms, confirmed blockers route rework.
    {:ok, reconfirmed} =
      apply_cycle(ledger, 2, %{
        "correctness" => report(finding_updates: [%{"id" => correctness_id, "state" => "open"}]),
        "security" => report(finding_updates: [%{"id" => security_id, "state" => "open"}])
      })

    reconfirmed_decision = ReviewLedgerCore.decision(reconfirmed)
    assert reconfirmed_decision["disposition"] == "rework"

    assert Enum.all?(
             reconfirmed_decision["blocking_reasons"],
             &(&1["reason"] == "active_blocking")
           )
  end

  test "preserves a new architectural blocker and escalates it regardless of severity" do
    architectural =
      Map.merge(finding("design boundary", "nit"), %{"state" => "architectural_blocker"})

    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{"correctness" => report(new_findings: [architectural])})

    stored = ledger["findings"] |> Map.values() |> hd()
    assert stored["state"] == "architectural_blocker"
    refute stored["blocks_merge"]

    decision = ReviewLedgerCore.decision(ledger)
    assert decision["disposition"] == "human_review"
    assert decision["blocking_ids"] == [stored["id"]]

    assert decision["blocking_reasons"] == [
             %{"id" => stored["id"], "reason" => "architectural_blocker"}
           ]
  end

  test "gates cycle-two new findings on explicit merged delta ranges" do
    {:ok, ledger} = apply_cycle(new_ledger(), 1, %{})
    inside = finding("inside delta", "major", 10)
    outside = finding("outside delta", "major", 30)

    {:ok, rechecked} =
      apply_cycle(ledger, 2, %{
        "reports" => %{"correctness" => report(new_findings: [inside, outside])},
        "delta_ranges" => %{"lib/a.ex" => [[9, 11]]}
      })

    findings = Map.values(rechecked["findings"])
    assert length(findings) == 1
    assert hd(findings)["state"] == "new_regression"
    assert length(rechecked["out_of_scope"]) == 1
    assert hd(rechecked["out_of_scope"])["reason"] == "outside_delta"

    assert {:error, :invalid_delta_ranges} =
             apply_cycle(ledger, 2, %{
               "reports" => %{},
               "delta_ranges" => %{"lib/a.ex" => [[11, 12], [12, 14]]}
             })

    forged = put_in(rechecked, ["out_of_scope", Access.at(0), "reason"], "forged")
    assert ReviewLedgerCore.decision(forged)["security_veto"]

    unbounded =
      put_in(
        rechecked,
        ["out_of_scope", Access.at(0), "evidence"],
        String.duplicate("x", 2_049)
      )

    assert ReviewLedgerCore.decision(unbounded)["security_veto"]
  end

  test "derives corroborated major and blocking gates, but not minor gates" do
    major = finding("shared major", "major", 10)
    blocking = finding("single blocker", "blocking", 20)
    minor = finding("small issue", "minor", 30)

    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report(new_findings: [major, blocking, minor]),
        "security" => report(new_findings: [major])
      })

    findings = Map.values(ledger["findings"])
    assert Enum.count(findings, &(&1["severity"] == "major" and &1["blocks_merge"])) == 2
    assert Enum.count(findings, &(&1["severity"] == "blocking" and &1["blocks_merge"])) == 1
    assert Enum.count(findings, &(&1["severity"] == "minor" and &1["blocks_merge"])) == 0

    decision = ReviewLedgerCore.decision(ledger)
    assert decision["disposition"] == "rework"
    assert length(decision["blocking_ids"]) == 3
    assert Enum.any?(decision["blocking_reasons"], &(&1["reason"] == "corroborated_major"))
  end

  test "independent majors from distinct owners rework even with different titles and lines" do
    # Live shape: same real defect, distinct titles and nearby-but-different anchors.
    four_owners = [
      "correctness",
      "security",
      "maintainability",
      "edge_cases_error_handling"
    ]

    {:ok, empty} = ReviewLedgerCore.new(%{"perspectives" => four_owners})

    {:ok, ledger} =
      apply_cycle(empty, 1, %{
        "correctness" => report(new_findings: [finding("Missing blank rejection", "major", 12)]),
        "security" =>
          report(new_findings: [finding("Whitespace-only returns ok empty", "major", 14)]),
        "maintainability" =>
          report(new_findings: [finding("Blank binary not treated as error", "major", 11)]),
        "edge_cases_error_handling" =>
          report(new_findings: [finding("normalize_label blank path", "major", 15)])
      })

    findings = Map.values(ledger["findings"])
    assert length(findings) == 4
    assert Enum.all?(findings, &(&1["blocks_merge"] == true))
    assert MapSet.size(MapSet.new(Enum.map(findings, & &1["issue_key"]))) == 4

    decision = ReviewLedgerCore.decision(ledger)
    assert decision["disposition"] == "rework"
    assert length(decision["blocking_ids"]) == 4

    assert Enum.all?(
             decision["blocking_reasons"],
             &(&1["reason"] == "independent_major_quorum")
           )
  end

  test "one owner cannot veto with one or many uncorroborated majors" do
    {:ok, single} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("reject", new_findings: [finding("solo major", "major", 10)]),
        "security" => report("approve"),
        "maintainability" => report("approve")
      })

    single_decision = ReviewLedgerCore.decision(single)
    assert single_decision["disposition"] == "accept"
    assert single_decision["blocking_ids"] == []
    refute Enum.any?(Map.values(single["findings"]), & &1["blocks_merge"])

    {:ok, multi} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" =>
          report("reject",
            new_findings: [
              finding("first solo major", "major", 10),
              finding("second solo major", "major", 20)
            ]
          ),
        "security" => report("approve"),
        "maintainability" => report("approve")
      })

    multi_decision = ReviewLedgerCore.decision(multi)
    assert multi_decision["disposition"] == "accept"
    assert multi_decision["blocking_ids"] == []
    refute Enum.any?(Map.values(multi["findings"]), & &1["blocks_merge"])
  end

  test "fixing one independent major clears the quorum when only one owner remains" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report(new_findings: [finding("owner a major", "major", 10)]),
        "security" => report(new_findings: [finding("owner b major", "major", 20)])
      })

    correctness_id =
      ledger["findings"]
      |> Map.values()
      |> Enum.find(&(&1["owner"] == "correctness"))
      |> Map.fetch!("id")

    security_id =
      ledger["findings"]
      |> Map.values()
      |> Enum.find(&(&1["owner"] == "security"))
      |> Map.fetch!("id")

    assert ReviewLedgerCore.decision(ledger)["disposition"] == "rework"

    {:ok, reduced} =
      apply_cycle(ledger, 2, %{
        "correctness" => report(finding_updates: [%{"id" => correctness_id, "state" => "fixed"}]),
        "security" => report(finding_updates: [%{"id" => security_id, "state" => "open"}])
      })

    remaining = reduced["findings"][security_id]
    refute remaining["blocks_merge"]
    assert remaining["state"] == "open"

    decision = ReviewLedgerCore.decision(reduced)
    assert decision["disposition"] == "accept"
    assert decision["blocking_ids"] == []
    refute Enum.any?(decision["blocking_reasons"], &(&1["reason"] == "independent_major_quorum"))
  end

  test "architectural blockers and security veto force human review" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{"correctness" => report(new_findings: [finding()])})

    id = ledger["findings"] |> Map.keys() |> hd()

    {:ok, architectural} =
      apply_cycle(ledger, 2, %{
        "correctness" =>
          report(finding_updates: [%{"id" => id, "state" => "architectural_blocker"}])
      })

    assert ReviewLedgerCore.decision(architectural)["disposition"] == "human_review"

    {:ok, vetoed} =
      apply_cycle(new_ledger(), 1, %{
        "security" => report("reject"),
        "correctness" => report("approve")
      })

    assert ReviewLedgerCore.decision(vetoed) ==
             %{
               "disposition" => "human_review",
               "security_veto" => true,
               "blocking_ids" => [],
               "blocking_reasons" => [%{"id" => "security", "reason" => "security_veto"}],
               "vote_counts" => %{"approve" => 1, "reject" => 1, "abstain" => 1}
             }
  end

  test "downgrades unsupported non-security rejects without changing the raw audit vote" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("reject"),
        "security" => report("approve"),
        "maintainability" => report("approve")
      })

    decision = ReviewLedgerCore.decision(ledger)
    assert decision["disposition"] == "accept"
    assert decision["vote_counts"] == %{"approve" => 2, "reject" => 0, "abstain" => 1}
    assert ledger["cycles"]["1"]["votes"]["correctness"] == "reject"

    assert ReviewLedgerCore.to_context(ledger)["review.perspective_votes"]["correctness"] ==
             "abstain"

    {:ok, only_reject} = apply_cycle(new_ledger(), 1, %{"correctness" => report("reject")})
    only_reject_decision = ReviewLedgerCore.decision(only_reject)
    assert only_reject_decision["disposition"] == "human_review"
    assert only_reject_decision["vote_counts"] == %{"approve" => 0, "reject" => 0, "abstain" => 3}

    assert only_reject_decision["blocking_reasons"] == [
             %{"id" => "council", "reason" => "all_abstain"}
           ]
  end

  test "an uncorroborated major reject plus an approve is accepted" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("reject", new_findings: [finding("single major", "major")]),
        "security" => report("approve"),
        "maintainability" => report("approve")
      })

    decision = ReviewLedgerCore.decision(ledger)
    assert decision["disposition"] == "accept"
    assert decision["vote_counts"] == %{"approve" => 2, "reject" => 0, "abstain" => 1}
    assert decision["blocking_ids"] == []
  end

  test "blocking and architectural findings keep their owners' rejects effective" do
    {:ok, blocking} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("reject", new_findings: [finding("must block", "blocking")]),
        "security" => report("approve"),
        "maintainability" => report("approve")
      })

    blocking_decision = ReviewLedgerCore.decision(blocking)
    assert blocking_decision["vote_counts"] == %{"approve" => 2, "reject" => 1, "abstain" => 0}
    assert blocking_decision["disposition"] == "rework"

    assert ReviewLedgerCore.to_context(blocking)["review.perspective_votes"]["correctness"] ==
             "reject"

    architectural =
      Map.merge(finding("design boundary", "nit"), %{"state" => "architectural_blocker"})

    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("reject", new_findings: [architectural]),
        "security" => report("approve"),
        "maintainability" => report("approve")
      })

    decision = ReviewLedgerCore.decision(ledger)
    assert decision["vote_counts"] == %{"approve" => 2, "reject" => 1, "abstain" => 0}
    assert decision["disposition"] == "human_review"
  end

  test "corroborated major rejects remain effective for both independent owners" do
    major = finding("shared major", "major")

    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("reject", new_findings: [major]),
        "security" => report("approve"),
        "maintainability" => report("reject", new_findings: [major])
      })

    decision = ReviewLedgerCore.decision(ledger)
    assert decision["vote_counts"] == %{"approve" => 1, "reject" => 2, "abstain" => 0}
    assert decision["disposition"] == "rework"
    assert length(decision["blocking_ids"]) == 2

    votes = ReviewLedgerCore.to_context(ledger)["review.perspective_votes"]
    assert votes["correctness"] == "reject"
    assert votes["maintainability"] == "reject"
  end

  test "uses symbolic majority and treats all abstain as human_review" do
    {:ok, accepted} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("approve"),
        "security" => report("approve"),
        "maintainability" => report("reject")
      })

    assert ReviewLedgerCore.decision(accepted)["disposition"] == "accept"

    {:ok, abstained} = apply_cycle(new_ledger(), 1, %{})
    decision = ReviewLedgerCore.decision(abstained)
    assert decision["disposition"] == "human_review"
    assert decision["vote_counts"] == %{"approve" => 0, "reject" => 0, "abstain" => 3}
    assert decision["blocking_reasons"] == [%{"id" => "council", "reason" => "all_abstain"}]
  end

  test "returns deterministic sorted findings and JSON-clean context" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "security" => report(new_findings: [finding("z", "nit", 3), finding("a", "nit", 2)])
      })

    context = ReviewLedgerCore.to_context(ledger)
    ids = Enum.map(context["review.findings"], & &1["id"])
    assert ids == Enum.sort(ids)
    assert {:ok, _encoded} = Jason.encode(context)
    refute inspect(context) =~ "%ReviewLedgerCore"
  end

  test "recomputes forged derived fields and fails closed on forged identity or votes" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report(new_findings: [finding("must block", "blocking")])
      })

    {id, stored} = Enum.at(ledger["findings"], 0)
    forged_gate = put_in(ledger, ["findings", id, "blocks_merge"], false)
    decision = ReviewLedgerCore.decision(forged_gate)
    assert decision["blocking_ids"] == [id]

    forged_id = put_in(ledger, ["findings", id, "id"], "forged")
    assert ReviewLedgerCore.decision(forged_id)["security_veto"]

    assert ReviewLedgerCore.to_context(forged_id)["review.decision"]["disposition"] ==
             "human_review"

    forged_anchor =
      put_in(ledger, ["findings", id, "anchor", "line"], stored["anchor"]["line"] + 1)

    assert ReviewLedgerCore.decision(forged_anchor)["security_veto"]

    forged_vote = put_in(ledger, ["cycles", "1", "votes", "security"], "reject")
    assert ReviewLedgerCore.decision(forged_vote)["security_veto"]
  end

  test "recomputes forged merge gates before deriving effective rejects" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("reject", new_findings: [finding("shared major", "major")]),
        "security" => report("approve"),
        "maintainability" => report("reject", new_findings: [finding("shared major", "major")])
      })

    forged =
      Map.update!(ledger, "findings", fn findings ->
        Map.new(findings, fn {id, finding} -> {id, Map.put(finding, "blocks_merge", false)} end)
      end)

    decision = ReviewLedgerCore.decision(forged)
    assert decision["vote_counts"] == %{"approve" => 1, "reject" => 2, "abstain" => 0}
    assert length(decision["blocking_ids"]) == 2
  end

  test "rejects noncanonical cycle owners and oversized otherwise-valid ledgers" do
    {:ok, ledger} = ReviewLedgerCore.new(%{})

    reports =
      Map.new(ledger["perspectives"], fn owner ->
        findings = Enum.map(1..8, &finding("#{owner}-#{&1}", "minor", &1))
        {owner, report(new_findings: findings)}
      end)

    {:ok, populated} = ReviewLedgerCore.apply_cycle(ledger, 1, reports)

    reversed_owners =
      put_in(
        populated,
        ["cycles", "1", "reported_owners"],
        Enum.reverse(populated["cycles"]["1"]["reported_owners"])
      )

    assert ReviewLedgerCore.decision(reversed_owners)["security_veto"]

    oversized_findings =
      Map.new(populated["findings"], fn {id, stored} ->
        {id, Map.put(stored, "evidence", String.duplicate("x", 2_048))}
      end)

    oversized = Map.put(populated, "findings", oversized_findings)
    assert byte_size(Jason.encode!(oversized)) > 131_072

    decision = ReviewLedgerCore.decision(oversized)
    assert decision["disposition"] == "human_review"
    assert decision["security_veto"]
    assert decision["blocking_reasons"] == [%{"id" => "ledger", "reason" => "invalid_ledger"}]
  end

  test "defaults to all ten static owners and abstains missing reports" do
    {:ok, ledger} = ReviewLedgerCore.new(%{})
    assert length(ledger["perspectives"]) == 10

    {:ok, completed} = ReviewLedgerCore.apply_cycle(ledger, 1, %{})
    cycle = completed["cycles"]["1"]
    assert map_size(cycle["votes"]) == 10
    assert Enum.all?(cycle["votes"], fn {_owner, vote} -> vote == "abstain" end)
    assert cycle["reported_owners"] == []

    assert ReviewLedgerCore.decision(completed)["vote_counts"] == %{
             "approve" => 0,
             "reject" => 0,
             "abstain" => 10
           }
  end

  test "rejects non-JSON reports and bounded finding data" do
    {:ok, ledger} = ReviewLedgerCore.new(%{"perspectives" => @perspectives})

    assert {:error, :non_json_clean} =
             ReviewLedgerCore.apply_cycle(ledger, 1, %{"security" => %{vote: "approve"}})

    assert {:error, _reason} =
             apply_cycle(new_ledger(), 1, %{
               "security" =>
                 report(
                   new_findings: [Map.put(finding(), "evidence", String.duplicate("x", 2_049))]
                 )
             })
  end

  defp new_ledger do
    {:ok, ledger} = ReviewLedgerCore.new(%{"perspectives" => @perspectives})
    ledger
  end

  defp apply_cycle(ledger, cycle, reports),
    do: ReviewLedgerCore.apply_cycle(ledger, cycle, reports)

  defp report, do: report("approve", [])
  defp report(vote) when is_binary(vote), do: report(vote, [])
  defp report(opts) when is_list(opts), do: report("approve", opts)

  defp report(vote, opts) do
    options = Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end)
    Map.merge(%{"vote" => vote, "finding_updates" => [], "new_findings" => []}, options)
  end

  defp finding(title \\ "issue", severity \\ "major", line \\ 10) do
    %{
      "title" => title,
      "required_action" => "Address #{title}",
      "severity" => severity,
      "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => line}
    }
  end
end
