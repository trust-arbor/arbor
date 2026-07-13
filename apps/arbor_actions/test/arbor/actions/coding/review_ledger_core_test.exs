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

  test "missing updates leave active findings open" do
    {:ok, ledger} =
      apply_cycle(new_ledger(), 1, %{"correctness" => report(new_findings: [finding()])})

    id = ledger["findings"] |> Map.keys() |> hd()

    {:ok, rechecked} = apply_cycle(ledger, 2, %{"correctness" => report()})
    assert rechecked["findings"][id]["state"] == "open"
    assert ReviewLedgerCore.decision(rechecked)["security_veto"] == false
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

  test "uses symbolic majority and treats all abstain as rework" do
    {:ok, accepted} =
      apply_cycle(new_ledger(), 1, %{
        "correctness" => report("approve"),
        "security" => report("approve"),
        "maintainability" => report("reject")
      })

    assert ReviewLedgerCore.decision(accepted)["disposition"] == "accept"

    {:ok, abstained} = apply_cycle(new_ledger(), 1, %{})
    decision = ReviewLedgerCore.decision(abstained)
    assert decision["disposition"] == "rework"
    assert decision["vote_counts"] == %{"approve" => 0, "reject" => 0, "abstain" => 3}
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
