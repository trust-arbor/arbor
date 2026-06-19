defmodule Arbor.Agent.Eval.SecurityReview.Report do
  @moduledoc """
  Renders a scored L2-review eval run (`Arbor.Agent.Eval.SecurityReview.Scorer`
  output) into a human-readable markdown report — the readable face of the eval,
  the table you actually look at to pick a model × strategy.

  Two sections: the headline **recall by reviewer × strategy** table (the decision
  table), and a **per-item match matrix** (which reviewer/strategy caught each
  labeled bug, with the cross-file items flagged — the per-file vs whole-subsystem
  story at a glance).
  """

  @doc """
  Render `scored` (the `Scorer.score/3` result) to a markdown string. `meta` carries
  run context: `:timestamp, :corpus_dir, :reviewers, :strategies, :k, :item_count,
  :cross_file_count`.
  """
  @spec render(map(), map()) :: String.t()
  def render(scored, meta) do
    """
    # Security Sentinel L2-review eval — #{meta[:timestamp] || "run"}

    - **Corpus:** `#{meta[:corpus_dir]}` — #{meta[:item_count] || "?"} items \
    (#{meta[:cross_file_count] || 0} cross-file)
    - **Reviewers:** #{Enum.join(meta[:reviewers] || [], ", ")}
    - **Strategies:** #{Enum.join(strategy_labels(meta[:strategies] || []), ", ")}
    - **Runs per cell (k):** #{meta[:k] || 1}
    - **Judge:** #{meta[:judge] || "deterministic (category + file)"}

    > Recall = fraction of labeled bugs re-found. `unmatched` is a false-positive
    > *proxy* only (one label per item), not ground-truth FP.

    ## Recall by reviewer × strategy

    #{recall_table(scored[:by_reviewer_strategy] || [])}

    ## Recall by difficulty

    #{difficulty_table(scored[:cells] || [])}

    ## Per-item match matrix

    #{item_matrix(scored[:cells] || [])}
    """
  end

  @doc "Render and write the report to `path`. Returns `path`."
  @spec write(map(), map(), String.t()) :: String.t()
  def write(scored, meta, path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, render(scored, meta))
    path
  end

  # ---------------------------------------------------------------------------

  defp recall_table([]), do: "_(no results)_"

  defp recall_table(aggs) do
    header =
      "| Reviewer | Strategy | Items | Recall (any) | Recall (mean) | " <>
        "Cross-file recall | Unmatched | Time (s) |\n" <>
        "|---|---|---|---|---|---|---|---|"

    rows =
      Enum.map_join(aggs, "\n", fn a ->
        "| #{a.reviewer} | #{strategy_label(a.strategy)} | #{a.items} | " <>
          "#{pct(a.recall_any)} | #{pct(a.recall_mean)} | " <>
          "#{cross_cell(a)} | #{a.unmatched_total} | #{secs(a.elapsed_ms_total)} |"
      end)

    header <> "\n" <> rows
  end

  defp cross_cell(%{cross_file_items: 0}), do: "— (none)"
  defp cross_cell(%{cross_file_recall_any: r, cross_file_items: n}), do: "#{pct(r)} (#{n})"

  # Reviewer × difficulty → matched items / total (matched in ≥1 run per item). The
  # hard tier is where models separate; easy-only corpora produce misleading ties.
  @diff_order ["easy", "medium", "hard", "unknown"]

  defp difficulty_table([]), do: "_(no cells)_"

  defp difficulty_table(cells) do
    diffs =
      cells
      |> Enum.map(&diff_of/1)
      |> Enum.uniq()
      |> Enum.sort_by(fn d -> Enum.find_index(@diff_order, &(&1 == d)) || 99 end)

    reviewers = cells |> Enum.map(& &1.reviewer) |> Enum.uniq() |> Enum.sort()

    header = "| Reviewer | " <> Enum.map_join(diffs, " | ", &String.capitalize/1) <> " |"
    sep = "|---|" <> Enum.map_join(diffs, "", fn _ -> "---|" end)

    rows =
      Enum.map_join(reviewers, "\n", fn rev ->
        cells_r = Enum.filter(cells, &(&1.reviewer == rev))

        scores =
          Enum.map_join(diffs, " | ", fn d ->
            by_item =
              cells_r
              |> Enum.filter(&(diff_of(&1) == d))
              |> Enum.group_by(& &1.item_id)

            total = map_size(by_item)
            matched = Enum.count(by_item, fn {_id, runs} -> Enum.any?(runs, & &1.matched) end)
            if total == 0, do: "—", else: "#{matched}/#{total}"
          end)

        "| #{rev} | #{scores} |"
      end)

    header <> "\n" <> sep <> "\n" <> rows
  end

  defp diff_of(cell), do: to_string(Map.get(cell, :difficulty, "unknown"))

  defp item_matrix([]), do: "_(no cells)_"

  defp item_matrix(cells) do
    # rows = items, columns = reviewer/strategy; ✓ if matched in any run.
    cols = cells |> Enum.map(&{&1.reviewer, &1.strategy}) |> Enum.uniq() |> Enum.sort()

    matched? = fn item_id, {rev, strat} ->
      cells
      |> Enum.filter(&(&1.item_id == item_id and &1.reviewer == rev and &1.strategy == strat))
      |> Enum.any?(& &1.matched)
    end

    items = cells |> Enum.map(&{&1.item_id, &1.cross_file}) |> Enum.uniq() |> Enum.sort()

    header =
      "| Item | " <>
        Enum.map_join(cols, " | ", fn {r, s} -> "#{r}/#{strategy_label(s)}" end) <> " |"

    sep = "|---|" <> Enum.map_join(cols, "", fn _ -> "---|" end)

    rows =
      Enum.map_join(items, "\n", fn {item_id, cross?} ->
        label = if cross?, do: "#{item_id} ⨯", else: item_id

        marks =
          Enum.map_join(cols, " | ", fn col -> if matched?.(item_id, col), do: "✓", else: "·" end)

        "| #{label} | #{marks} |"
      end)

    header <> "\n" <> sep <> "\n" <> rows <> "\n\n_(⨯ = cross-file item; ✓ = matched in ≥1 run)_"
  end

  defp strategy_labels(strategies), do: Enum.map(strategies, &strategy_label/1)
  defp strategy_label(:a), do: "A (per-file)"
  defp strategy_label(:b_lite), do: "B-lite (whole-subsystem)"
  defp strategy_label(other), do: to_string(other)

  defp pct(nil), do: "—"
  defp pct(f) when is_number(f), do: :erlang.float_to_binary(f * 1.0, decimals: 2)

  defp secs(ms) when is_number(ms), do: :erlang.float_to_binary(ms / 1000, decimals: 1)
  defp secs(_), do: "—"
end
