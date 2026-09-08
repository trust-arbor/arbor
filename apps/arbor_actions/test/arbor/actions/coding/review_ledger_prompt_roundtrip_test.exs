defmodule Arbor.Actions.Coding.ReviewLedgerPromptRoundtripTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.ReviewLedgerCore
  alias Arbor.Actions.Consensus.DecideReview
  alias Arbor.Contracts.Consensus.CodeReviewRequest

  @moduletag :fast
  @perspectives ["correctness", "security", "maintainability"]

  test "ledger truncation regression: all admitted owned findings survive both prompts and recheck" do
    reports =
      Map.new(@perspectives, fn owner ->
        findings =
          for index <- 1..7 do
            %{
              "title" => "#{owner} issue #{index}",
              "required_action" => "Repair issue #{index}",
              "severity" => Enum.at(["major", "minor", "nit"], rem(index, 3)),
              "anchor" => %{"path" => "lib/a.ex", "side" => "new", "line" => index},
              "evidence" => String.duplicate("e", 1_800)
            }
          end

        {owner, %{"vote" => "reject", "finding_updates" => [], "new_findings" => findings}}
      end)

    assert {:ok, initial} = ReviewLedgerCore.new(%{"perspectives" => @perspectives})
    assert {:ok, ledger} = ReviewLedgerCore.apply_cycle(initial, 1, reports)
    assert {:ok, ^ledger} = ReviewLedgerCore.new(ledger)
    encoded = Jason.encode!(ledger)
    assert byte_size(encoded) > 32_768
    assert byte_size(encoded) <= 131_072

    # At least one real owner id must lie beyond the former prompt preview.
    assert Enum.any?(Map.keys(ledger["findings"]), fn id ->
             {offset, _length} = :binary.match(encoded, id)
             offset >= 32_768
           end)

    assert {:ok, request} =
             CodeReviewRequest.new(%{
               diff: "diff --git a/lib/a.ex b/lib/a.ex\n+def repaired, do: :ok",
               files: ["lib/a.ex"],
               branch: "fix/ledger-prompt-roundtrip",
               review_cycle: 2,
               finding_ledger: ledger
             })

    for render <- [&CodeReviewRequest.prompt_text/1, &CodeReviewRequest.prompt_conformance_text/1] do
      prompt = render.(request)

      [_, ledger_and_rest] =
        String.split(prompt, "Finding ledger (bounded JSON):\n```json\n", parts: 2)

      [ledger_json | _] = String.split(ledger_and_rest, "\n```", parts: 2)
      visible_ledger = Jason.decode!(ledger_json)
      assert visible_ledger == ledger

      results =
        Enum.map(@perspectives, fn owner ->
          updates =
            visible_ledger["findings"]
            |> Map.values()
            |> Enum.filter(&(&1["owner"] == owner))
            |> Enum.map(&%{"id" => &1["id"], "state" => "fixed"})

          assert length(updates) == 7

          %{
            "id" => owner,
            "status" => "success",
            "context_updates" => %{
              "last_response" =>
                Jason.encode!(%{
                  "vote" => "approve",
                  "finding_updates" => updates,
                  "new_findings" => []
                })
            }
          }
        end)

      assert {:ok, result} =
               DecideReview.run(
                 %{results: results, review_cycle: 2, finding_ledger: ledger, delta_ranges: %{}},
                 %{}
               )

      assert result["decision"] == "approved"
      assert result["review_disposition"] == "accept"
      assert result["abstain_count"] == 0
      assert length(result["findings"]) == 21
      assert Enum.all?(result["findings"], &(&1["state"] == "fixed"))

      assert Enum.all?(result["reviewer_outcomes"], fn {_owner, outcome} ->
               outcome["reason_code"] == "valid_report"
             end)
    end
  end
end
