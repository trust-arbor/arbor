defmodule Arbor.Eval.Graders.PrecisionAtK do
  @moduledoc """
  Precision@K grader for retrieval evals.

  Compares an actual ranked list (JSON-encoded list of strings, e.g.
  `["Arbor.Actions.File", "Arbor.Actions.Shell"]`) against expected
  matches, computing precision at cut-off K.

  ## Expected format

      %{
        "primary" => "Arbor.Actions.File",
        "matches" => ["Arbor.Actions.File", "Arbor.Actions.Shell"]
      }

  ## Options

    * `:k` — cut-off (default: 5). Use 1 for top-1 precision (primary match check).
    * `:pass_threshold` — minimum score to mark passed (default: depends on k —
      1.0 for k=1, 0.4 for k=5)

  ## Score

  - For `k=1`: 1.0 if actual[0] == expected.primary, else 0.0
  - For `k>1`: |actual[0..k-1] ∩ matches| / min(k, |matches|)
  """

  @behaviour Arbor.Eval.Grader

  @impl true
  def grade(actual, expected, opts \\ []) do
    k = Keyword.get(opts, :k, 5)
    ranked = parse_actual(actual)
    {primary, matches} = parse_expected(expected)

    if ranked == [] do
      %{score: 0.0, passed: false, detail: "no ranked results returned"}
    else
      score = compute_score(ranked, primary, matches, k)
      pass_threshold = Keyword.get(opts, :pass_threshold, default_threshold(k))
      passed = score >= pass_threshold

      detail = build_detail(ranked, primary, matches, k, score)
      %{score: score, passed: passed, detail: detail}
    end
  end

  defp default_threshold(1), do: 1.0
  defp default_threshold(_), do: 0.4

  defp parse_actual(actual) when is_binary(actual) do
    case Jason.decode(actual) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp parse_actual(actual) when is_list(actual), do: Enum.map(actual, &to_string/1)
  defp parse_actual(_), do: []

  defp parse_expected(%{"primary" => primary, "matches" => matches})
       when is_binary(primary) and is_list(matches) do
    {to_string(primary), Enum.map(matches, &to_string/1)}
  end

  defp parse_expected(%{"matches" => matches}) when is_list(matches) do
    matches_str = Enum.map(matches, &to_string/1)
    {List.first(matches_str), matches_str}
  end

  defp parse_expected(expected), do: {to_string(expected), [to_string(expected)]}

  defp compute_score(ranked, primary, _matches, 1) do
    case List.first(ranked) do
      ^primary -> 1.0
      _ -> 0.0
    end
  end

  defp compute_score(ranked, _primary, matches, k) do
    top_k = Enum.take(ranked, k)
    hits = Enum.count(top_k, fn r -> r in matches end)
    denom = min(k, length(matches))

    if denom == 0, do: 0.0, else: hits / denom
  end

  defp build_detail(ranked, primary, _matches, 1, score) do
    top = List.first(ranked) || "(none)"

    if score == 1.0 do
      "top-1 hit: #{top}"
    else
      "top-1 miss: got #{top}, expected #{primary}"
    end
  end

  defp build_detail(ranked, _primary, matches, k, score) do
    top_k = Enum.take(ranked, k)
    hits = Enum.filter(top_k, fn r -> r in matches end)
    "precision@#{k} = #{Float.round(score, 3)} (hits: #{Enum.join(hits, ", ")})"
  end
end
