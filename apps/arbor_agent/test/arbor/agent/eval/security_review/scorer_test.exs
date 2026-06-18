defmodule Arbor.Agent.Eval.SecurityReview.ScorerTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.Eval.SecurityReview.Scorer

  defp cell(attrs) do
    Map.merge(
      %{
        reviewer: "r",
        strategy: :a,
        run: 1,
        item_id: "i1",
        item_cross_file: false,
        findings: [],
        elapsed_ms: 10
      },
      attrs
    )
  end

  defp finding(cat, file),
    do: %{category: cat, title: "t", file: file, line: 1, severity: :high, rationale: "r"}

  defp labels(extra \\ %{}) do
    Map.merge(
      %{"i1" => %{category: "fail_open_authz", files: ["lib/a.ex"], cross_file: false}},
      extra
    )
  end

  test "a finding in the right file with the right category matches (recall 1.0)" do
    cells = [cell(%{findings: [finding(:fail_open_authz, "lib/a.ex")]})]
    scored = Scorer.score(cells, labels())

    assert [c] = scored.cells
    assert c.matched
    assert [agg] = scored.by_reviewer_strategy
    assert agg.recall_any == 1.0
    assert agg.recall_mean == 1.0
    assert agg.unmatched_total == 0
  end

  test "a finding in the WRONG file is not a candidate (no match, counts unmatched)" do
    cells = [cell(%{findings: [finding(:fail_open_authz, "lib/other.ex")]})]
    scored = Scorer.score(cells, labels())

    refute hd(scored.cells).matched
    assert hd(scored.by_reviewer_strategy).recall_any == 0.0
    assert hd(scored.by_reviewer_strategy).unmatched_total == 1
  end

  test "right file but WRONG category is rejected by the default judge" do
    cells = [cell(%{findings: [finding(:crypto_weakness, "lib/a.ex")]})]
    scored = Scorer.score(cells, labels())
    refute hd(scored.cells).matched
  end

  test "variance: matched in 1 of 2 runs → recall_any 1.0, recall_mean 0.5" do
    cells = [
      cell(%{run: 1, findings: [finding(:fail_open_authz, "lib/a.ex")]}),
      cell(%{run: 2, findings: []})
    ]

    agg = hd(Scorer.score(cells, labels()).by_reviewer_strategy)
    assert agg.recall_any == 1.0
    assert agg.recall_mean == 0.5
  end

  test "cross-file discriminator: :a misses, :b_lite matches" do
    lbls = %{
      "i2" => %{
        category: "capability_overmatch",
        files: ["lib/a.ex", "lib/b.ex"],
        cross_file: true
      }
    }

    cells = [
      cell(%{item_id: "i2", item_cross_file: true, strategy: :a, findings: []}),
      cell(%{
        item_id: "i2",
        item_cross_file: true,
        strategy: :b_lite,
        findings: [finding(:capability_overmatch, "lib/a.ex")]
      })
    ]

    aggs = Scorer.score(cells, lbls).by_reviewer_strategy
    a = Enum.find(aggs, &(&1.strategy == :a))
    b = Enum.find(aggs, &(&1.strategy == :b_lite))

    assert a.cross_file_recall_any == 0.0
    assert b.cross_file_recall_any == 1.0
  end

  test "judge is injectable (a refusing judge yields no matches)" do
    cells = [cell(%{findings: [finding(:fail_open_authz, "lib/a.ex")]})]
    scored = Scorer.score(cells, labels(), judge: fn _f, _l -> false end)
    refute hd(scored.cells).matched
  end
end
