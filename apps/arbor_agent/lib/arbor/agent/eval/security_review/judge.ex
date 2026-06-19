defmodule Arbor.Agent.Eval.SecurityReview.Judge do
  @moduledoc """
  An LLM **judge** for the L2-review scorer: decides whether a reviewer's finding
  describes the *same underlying bug* as a corpus label — a semantic match, fixing
  the deterministic scorer's category-strict undercount (e.g. a taint-provenance
  drop tagged `serialization_drop` vs the label's `fail_open_authz`, which both
  describe the same bug).

  `make/1` returns a `(finding, label -> boolean)` fn that plugs straight into
  `Scorer.score(results, labels, judge: ...)`. The judge runs only on candidates the
  scorer's deterministic file-prefilter already selected (findings in the label's
  files), so it's a handful of calls per cell, not per finding in the corpus.

  ## Independence + fail-closed

  The judge should be a **fixed model that is NOT under evaluation** (bias). It is
  doing objective adjudication against a *known* label ("is this finding that bug?"),
  which is far less bias-prone than judging quality, but still: don't point it at a
  reviewer in the same run. On any LLM/parse error the judge returns **false** — an
  unverifiable match is not credited (conservative; never inflates recall).
  """

  alias Arbor.Agent.Eval.SecurityReview.AnthropicLoop

  @default_base_url "http://localhost:1234"
  @default_model "gemma-4-31b-it-qat"

  @system "You are a precise security-finding adjudicator. You are given ONE reviewer " <>
            "finding and ONE known labeled bug. Decide whether the finding describes the " <>
            "SAME underlying vulnerability as the labeled bug (the category labels may " <>
            "differ — judge the substance, not the category string). Answer with EXACTLY " <>
            "one word: YES or NO."

  @doc """
  Build a judge fn `(finding, label -> boolean)`.

  ## Options
    * `:model` — judge model id (default `#{@default_model}`)
    * `:base_url` — Anthropic-compatible endpoint (default `#{@default_base_url}`)
    * `:single_shot` — inject `AnthropicLoop.single_shot`-shaped fn for tests
    * `:receive_timeout` — per-call ms (default 120_000)
  """
  @spec make(keyword()) :: (map(), map() -> boolean())
  def make(opts \\ []) do
    model = opts[:model] || @default_model
    base_url = opts[:base_url] || @default_base_url
    recv = opts[:receive_timeout] || 120_000
    single_shot = opts[:single_shot] || (&AnthropicLoop.single_shot/1)

    fn finding, label ->
      case single_shot.(%{
             base_url: base_url,
             model: model,
             system: @system,
             user: prompt(finding, label),
             receive_timeout: recv
           }) do
        {:ok, text} -> affirmative?(text)
        {:error, _} -> false
      end
    end
  end

  # ---------------------------------------------------------------------------

  defp prompt(finding, label) do
    """
    LABELED BUG:
      category: #{val(label, :category)}
      invariant violated: #{val(label, :invariant)}
      file(s): #{label |> file_list() |> Enum.join(", ")}

    REVIEWER FINDING:
      category: #{fval(finding, :category)}
      title: #{fval(finding, :title)}
      file: #{fval(finding, :file)}  line: #{fval(finding, :line)}
      rationale: #{fval(finding, :rationale)}

    Does the finding describe the SAME underlying vulnerability as the labeled bug? Answer YES or NO.
    """
  end

  # First YES/NO token wins; anything else (or no match) is treated as NO.
  defp affirmative?(text) do
    case Regex.run(~r/\b(yes|no)\b/i, text) do
      [_, word] -> String.downcase(word) == "yes"
      _ -> false
    end
  end

  defp val(label, key), do: label[key] || label[to_string(key)] || ""
  defp file_list(label), do: label[:files] || label["files"] || []
  defp fval(f, key), do: f[key] || f[to_string(key)] || ""
end
