defmodule Arbor.Eval.Graders.RecallAtK do
  @moduledoc """
  Recall@K grader for retrieval evals.

  Measures the fraction of expected matches that appear in the top-K
  results. Complements PrecisionAtK — precision asks "of what we returned,
  how many were right?" and recall asks "of what was right, how many did
  we return?"

  ## Expected format

      %{
        "primary" => "Arbor.Actions.File",
        "matches" => ["Arbor.Actions.File", "Arbor.Actions.Shell"]
      }

  ## Options

    * `:k` — cut-off (default: 5)
    * `:pass_threshold` — minimum score to mark passed (default: 0.5)

  ## Score

  `|matches ∩ top_k| / |matches|` — fraction of expected matches found within top-K.
  """

  @behaviour Arbor.Eval.Grader

  @impl true
  def grade(actual, expected, opts \\ []) do
    k = Keyword.get(opts, :k, 5)
    pass_threshold = Keyword.get(opts, :pass_threshold, 0.5)
    ranked = parse_actual(actual)
    matches = parse_matches(expected)

    cond do
      matches == [] ->
        %{score: 0.0, passed: false, detail: "no expected matches"}

      ranked == [] ->
        %{score: 0.0, passed: false, detail: "no ranked results returned"}

      true ->
        top_k = Enum.take(ranked, k) |> MapSet.new()
        match_set = MapSet.new(matches)
        hits = MapSet.intersection(top_k, match_set) |> MapSet.size()
        score = hits / length(matches)
        passed = score >= pass_threshold

        detail =
          "recall@#{k} = #{Float.round(score, 3)} (#{hits}/#{length(matches)} matches found in top-#{k})"

        %{score: score, passed: passed, detail: detail}
    end
  end

  defp parse_actual(actual) when is_binary(actual) do
    case Jason.decode(actual) do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp parse_actual(actual) when is_list(actual), do: Enum.map(actual, &to_string/1)
  defp parse_actual(_), do: []

  defp parse_matches(%{"matches" => matches}) when is_list(matches),
    do: Enum.map(matches, &to_string/1)

  defp parse_matches(_), do: []
end
