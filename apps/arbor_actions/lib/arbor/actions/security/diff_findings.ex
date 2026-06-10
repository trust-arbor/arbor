defmodule Arbor.Actions.Security.DiffFindings do
  @moduledoc """
  Parses an L1 diff-review LLM output (a JSON array of findings) into
  `Arbor.Contracts.Security.Finding` structs.

  L1 is the LLM-reasoning detector: it reviews a git diff for *newly-introduced*
  security issues that the deterministic L0/L0b detectors can't see (contextual,
  novel). Its findings are inherently lower-confidence than a deterministic match,
  so they're tagged `detector.layer: "L1"` and `confidence: 0.5` — which is
  exactly what `Verifier.needs_verification?` always sends through adversarial
  verification.

  The parse is defensive: LLMs wrap JSON in ```fences, add prose, or emit a single
  object instead of an array. We strip fences, slice to the outermost JSON array,
  and tolerate a bare object. Unknown categories fall back to `:other` (no
  `String.to_atom` on model output).
  """

  alias Arbor.Contracts.Security.Finding

  @categories ~w(
    fail_open_authz crypto_weakness capability_overmatch serialization_drop
    missing_regression_test unsafe_atom config_fail_open unregistered_uri
    dependency_risk path_traversal secret_exposure injection other
  )a

  @severities ~w(critical high medium low info)a

  @doc """
  Parse LLM diff-review output into `Finding`s. Options: `:git_sha` (provenance).
  Returns `[]` on unparseable output.
  """
  @spec parse(String.t(), keyword()) :: [Finding.t()]
  def parse(llm_output, opts \\ []) when is_binary(llm_output) do
    git_sha = Keyword.get(opts, :git_sha)

    case decode(llm_output) do
      {:ok, items} when is_list(items) -> Enum.flat_map(items, &to_finding(&1, git_sha))
      {:ok, %{} = item} -> to_finding(item, git_sha)
      _ -> []
    end
  end

  # ---------------------------------------------------------------------------

  defp decode(text) do
    text
    |> strip_fences()
    |> slice_to_json()
    |> Jason.decode()
  end

  defp strip_fences(text) do
    text
    |> String.replace(~r/```(?:json)?\s*/i, "")
    |> String.replace("```", "")
    |> String.trim()
  end

  # Slice to the outermost [ ... ] (or { ... }) so leading/trailing prose doesn't
  # break the decode.
  defp slice_to_json(text) do
    cond do
      (a = open_close(text, "[", "]")) != nil -> a
      (o = open_close(text, "{", "}")) != nil -> o
      true -> text
    end
  end

  defp open_close(text, open, close) do
    with start when start != nil <- index_of(text, open),
         stop when stop != nil <- last_index_of(text, close),
         true <- stop > start do
      binary_part(text, start, stop - start + 1)
    else
      _ -> nil
    end
  end

  defp index_of(text, char) do
    case :binary.match(text, char) do
      {pos, _} -> pos
      :nomatch -> nil
    end
  end

  defp last_index_of(text, char) do
    case :binary.matches(text, char) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp to_finding(%{} = item, git_sha) do
    title = string(item["title"] || item["summary"])

    if title == "" do
      []
    else
      category = category(item["category"])

      [
        Finding.new(
          category: category,
          title: title,
          git_sha: git_sha,
          detector: %{layer: "L1", name: "diff_review", version: "1"},
          severity: %{level: severity(item["severity"])},
          confidence: %{score: 0.5, rationale: "LLM diff review (unverified)"},
          location: %{file: string(item["file"]), line: item["line"]},
          invariant_violated: string(item["rationale"]),
          evidence: %{rationale: string(item["rationale"]), source: "l1_diff_review"},
          recommendation: %{approach: string(item["recommendation"] || item["fix"])},
          actionability: %{auto_fixable: false, risk_class: :medium},
          verification: %{must_fail_on_revert: true}
        )
      ]
    end
  end

  defp to_finding(_, _), do: []

  defp category(c) when is_binary(c) do
    Enum.find(@categories, :other, &(Atom.to_string(&1) == String.trim(c)))
  end

  defp category(_), do: :other

  defp severity(s) when is_binary(s) do
    Enum.find(@severities, :medium, &(Atom.to_string(&1) == String.trim(s)))
  end

  defp severity(_), do: :medium

  defp string(v) when is_binary(v), do: String.trim(v)
  defp string(_), do: ""
end
