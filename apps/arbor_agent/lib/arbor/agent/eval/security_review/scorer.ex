defmodule Arbor.Agent.Eval.SecurityReview.Scorer do
  @moduledoc """
  Scores reviewer-runner results against the corpus labels — the analysis half of
  the Security Sentinel L2-review eval (Phase 0).

  Each corpus item carries exactly one labeled bug (its category + the file(s) it
  lives in + the invariant it violates). A reviewer cell "matched" the item if any
  of its findings is judged to be that bug.

  ## Matching (deterministic prefilter → judge)

    1. **Prefilter (deterministic, cheap):** candidate findings are those whose
       `file` is one of the label's files — narrows to the right location.
    2. **Judge (injectable):** decides whether a candidate actually describes the
       labeled bug. The default judge is deterministic — category equality — so the
       scorer runs (and is unit-tested) with no model. The real LLM judge (a fixed,
       independent model — never the one under evaluation) drops in via `:judge`.

  A finding the reviewer reported that is NOT the labeled bug counts as `unmatched`
  — a false-positive *proxy* only: our corpus labels one bug per item, so an
  unmatched finding may be a genuine unlabeled issue, not noise. Reported, caveated,
  not treated as ground-truth FP. (True precision needs reviewing the clean/fixed
  snapshots — a later refinement.)

  ## Aggregation (per reviewer × strategy)

    * `recall_any`  — fraction of items matched in ≥1 of the k runs
    * `recall_mean` — mean over items of the per-item match-rate (k runs) — variance
    * `cross_file_recall_any` — `recall_any` restricted to cross-file items (the
      per-file vs whole-subsystem discriminator)
    * `unmatched_total`, `elapsed_ms_total`
  """

  @type label :: %{
          category: term(),
          files: [String.t()],
          cross_file: boolean(),
          invariant: String.t()
        }
  @type judge :: (map(), label() -> boolean())

  @doc """
  Score `results` (the runner summary's `:results` list) against `labels`
  (a map `item_id => label`). Returns `%{cells: [...], by_reviewer_strategy: [...]}`.

  ## Options

    * `:judge` — `(finding, label -> boolean)`; default deterministic category match.
  """
  @spec score([map()], %{optional(String.t()) => label()}, keyword()) :: map()
  def score(results, labels, opts \\ []) do
    judge = opts[:judge] || (&default_judge/2)

    cells = Enum.map(results, &score_cell(&1, labels[&1.item_id], judge))

    %{
      cells: cells,
      by_reviewer_strategy: aggregate(cells)
    }
  end

  @doc """
  Load the label map (`item_id => %{category, files, cross_file, invariant}`) from a
  corpus dir's `manifest.json` — the ground truth the scorer matches findings against.
  """
  @spec labels_from_manifest(String.t()) ::
          {:ok, %{optional(String.t()) => label()}} | {:error, term()}
  def labels_from_manifest(corpus_dir) do
    with {:ok, json} <- File.read(Path.join(corpus_dir, "manifest.json")),
         {:ok, entries} <- Jason.decode(json) do
      labels =
        Map.new(entries, fn e ->
          {e["id"],
           %{
             category: e["category"],
             files: e["files"] || [],
             cross_file: e["cross_file"] || false,
             difficulty: e["difficulty"] || "unknown",
             invariant: e["invariant"] || ""
           }}
        end)

      {:ok, labels}
    end
  end

  # ---------------------------------------------------------------------------
  # Per-cell scoring
  # ---------------------------------------------------------------------------

  defp score_cell(cell, nil, _judge) do
    # No label for this item (shouldn't happen) — record as unmatched, no credit.
    base(cell)
    |> Map.merge(%{matched: false, matched_findings: [], unmatched: length(cell.findings)})
  end

  defp score_cell(cell, label, judge) do
    files = label[:files] || label["files"] || []
    candidates = Enum.filter(cell.findings, &(finding_file(&1) in files))
    matched_findings = Enum.filter(candidates, &judge.(&1, label))

    base(cell)
    |> Map.merge(%{
      matched: matched_findings != [],
      matched_findings: Enum.map(matched_findings, &finding_title/1),
      unmatched: length(cell.findings) - length(matched_findings)
    })
  end

  defp base(cell) do
    %{
      reviewer: cell.reviewer,
      strategy: cell.strategy,
      run: cell.run,
      item_id: cell.item_id,
      cross_file: cell.item_cross_file,
      finding_count: length(cell.findings),
      elapsed_ms: cell.elapsed_ms
    }
  end

  # The default judge: a candidate (already in the right file) matches when its
  # category equals the label's. Normalized to strings (findings carry atoms,
  # manifest labels arrive as JSON strings).
  defp default_judge(finding, label) do
    to_string(finding_category(finding)) == to_string(label[:category] || label["category"])
  end

  # ---------------------------------------------------------------------------
  # Aggregation
  # ---------------------------------------------------------------------------

  defp aggregate(cells) do
    cells
    |> Enum.group_by(&{&1.reviewer, &1.strategy})
    |> Enum.map(fn {{reviewer, strategy}, group} ->
      by_item = Enum.group_by(group, & &1.item_id)
      items = Map.values(by_item)

      per_item =
        Enum.map(items, fn runs ->
          matched = Enum.count(runs, & &1.matched)

          %{
            cross_file: hd(runs).cross_file,
            matched_any: matched > 0,
            match_rate: matched / length(runs)
          }
        end)

      cross = Enum.filter(per_item, & &1.cross_file)

      %{
        reviewer: reviewer,
        strategy: strategy,
        items: length(per_item),
        recall_any: mean(Enum.map(per_item, &bool01(&1.matched_any))),
        recall_mean: mean(Enum.map(per_item, & &1.match_rate)),
        cross_file_items: length(cross),
        cross_file_recall_any: mean(Enum.map(cross, &bool01(&1.matched_any))),
        unmatched_total: group |> Enum.map(& &1.unmatched) |> Enum.sum(),
        elapsed_ms_total: group |> Enum.map(& &1.elapsed_ms) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{&1.reviewer, &1.strategy})
  end

  # ---------------------------------------------------------------------------
  # Field access (cells come from JSON-decode or in-memory; tolerate both)
  # ---------------------------------------------------------------------------

  defp finding_file(f), do: f[:file] || f["file"]
  defp finding_category(f), do: f[:category] || f["category"]
  defp finding_title(f), do: f[:title] || f["title"]

  defp bool01(true), do: 1
  defp bool01(false), do: 0

  defp mean([]), do: 0.0
  defp mean(list), do: Enum.sum(list) / length(list)
end
