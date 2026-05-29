defmodule Arbor.Actions.Review do
  @moduledoc """
  Actions for the multi-model review council pipeline.

  See `.arbor/roadmap/1-brainstorming/multi-model-review-council.md`.
  """

  defmodule Synthesize do
    @moduledoc """
    Merge and classify findings from parallel reviewer branches into a report.

    Reads `parallel.results` (each branch's `context_updates.last_response`),
    parses each reviewer's JSON findings, dedups across reviewers, and classifies
    by **verification status** — a finding with evidence is `grounded`, one without
    is `needs_followup` — rather than by how many reviewers agreed. Solitary
    findings are preserved (convergence is reported, never used to down-weight),
    because in the worked example the single most serious bug was found by exactly
    one reviewer.
    """

    use Jido.Action,
      name: "review_synthesize",
      description: "Merge and classify multi-model review findings by verification status",
      schema: [
        results: [type: {:list, :map}, required: false, doc: "Parallel reviewer branch results"]
      ]

    @impl true
    def run(params, _context) do
      results = params["parallel.results"] || params[:results] || params["results"] || []

      extracted = Enum.flat_map(results, &extract/1)
      {parsed, unparsed} = Enum.split_with(extracted, & &1.parsed?)
      merged = merge(parsed)

      {:ok,
       %{
         report: render(merged, unparsed, length(results)),
         reviewer_count: length(results),
         finding_count: length(merged),
         grounded_count: Enum.count(merged, &(&1.status == :grounded)),
         needs_followup_count: Enum.count(merged, &(&1.status == :needs_followup)),
         unparsed_reviewers: length(unparsed),
         status: "synthesized"
       }}
    end

    # --- extraction ---

    defp extract(result) do
      branch = Map.get(result, "id", "reviewer")
      text = get_in(result, ["context_updates", "last_response"]) || Map.get(result, "notes", "")

      case parse_findings(text) do
        {:ok, list} -> Enum.map(list, &normalize(&1, branch))
        :error -> [%{parsed?: false, reviewer: branch, raw: truncate(text)}]
      end
    end

    defp parse_findings(text) when is_binary(text) and text != "" do
      case Jason.decode(strip_fences(text)) do
        {:ok, list} when is_list(list) -> {:ok, list}
        {:ok, %{"findings" => list}} when is_list(list) -> {:ok, list}
        _ -> :error
      end
    end

    defp parse_findings(_), do: :error

    defp strip_fences(text) do
      case Regex.run(~r/```(?:json)?\s*(\[.*\]|\{.*\})\s*```/s, text) do
        [_, body] -> body
        _ -> String.trim(text)
      end
    end

    defp normalize(f, branch) when is_map(f) do
      evidence = blank_to_nil(f["evidence"] || f[:evidence])

      %{
        parsed?: true,
        reviewer: branch,
        title: to_string(f["title"] || f[:title] || "untitled"),
        file: to_string(f["file"] || f[:file] || ""),
        line: f["line"] || f[:line],
        claim: to_string(f["claim"] || f[:claim] || ""),
        severity: normalize_severity(f["severity"] || f[:severity]),
        evidence: evidence,
        status: if(is_nil(evidence), do: :needs_followup, else: :grounded)
      }
    end

    defp normalize(other, branch), do: %{parsed?: false, reviewer: branch, raw: inspect(other)}

    # --- merge / dedup (across reviewers) ---

    defp merge(parsed) do
      parsed
      |> Enum.group_by(fn f -> {f.file, String.downcase(f.title)} end)
      |> Enum.map(fn {_key, group} ->
        reviewers = group |> Enum.map(& &1.reviewer) |> Enum.uniq()
        grounded? = Enum.any?(group, &(&1.status == :grounded))

        group
        |> hd()
        |> Map.merge(%{
          reviewers: reviewers,
          convergence: length(reviewers),
          status: if(grounded?, do: :grounded, else: :needs_followup),
          evidence: Enum.find_value(group, & &1.evidence)
        })
      end)
      |> Enum.sort_by(fn f -> {severity_rank(f.severity), -f.convergence} end)
    end

    # --- render ---

    defp render(merged, unparsed, reviewer_count) do
      [
        "# Review Council — #{length(merged)} distinct findings from #{reviewer_count} reviewer(s)\n",
        section("Grounded (evidence provided)", Enum.filter(merged, &(&1.status == :grounded))),
        section(
          "Needs follow-up (no evidence — verify before trusting)",
          Enum.filter(merged, &(&1.status == :needs_followup))
        ),
        unparsed_note(unparsed)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end

    defp section(_title, []), do: ""

    defp section(title, findings) do
      lines =
        Enum.map_join(findings, "\n", fn f ->
          conv = if f.convergence > 1, do: " [#{f.convergence} reviewers]", else: " [1 reviewer]"
          loc = if f.file == "", do: "", else: " (#{f.file}#{line_suffix(f.line)})"
          ev = if f.evidence, do: "\n    evidence: #{f.evidence}", else: ""
          "- **[#{f.severity}]** #{f.title}#{loc}#{conv}\n    #{f.claim}#{ev}"
        end)

      "## #{title}\n#{lines}\n"
    end

    defp unparsed_note([]), do: ""

    defp unparsed_note(unparsed) do
      who = unparsed |> Enum.map(& &1.reviewer) |> Enum.uniq() |> Enum.join(", ")

      "## Unparsed responses\n#{length(unparsed)} reviewer response(s) were not valid JSON findings (#{who}). " <>
        "If running in simulate mode this is expected; otherwise tighten the reviewer prompt.\n"
    end

    # --- helpers ---

    defp line_suffix(nil), do: ""
    defp line_suffix(line), do: ":#{line}"

    defp normalize_severity(s) do
      case s |> to_string() |> String.downcase() do
        "high" -> "high"
        "critical" -> "high"
        "med" -> "med"
        "medium" -> "med"
        "low" -> "low"
        _ -> "unknown"
      end
    end

    defp severity_rank("high"), do: 0
    defp severity_rank("med"), do: 1
    defp severity_rank("low"), do: 2
    defp severity_rank(_), do: 3

    defp blank_to_nil(v) when v in [nil, ""], do: nil
    defp blank_to_nil(v), do: v

    defp truncate(text) when is_binary(text), do: String.slice(text, 0, 200)
    defp truncate(other), do: inspect(other)
  end
end
