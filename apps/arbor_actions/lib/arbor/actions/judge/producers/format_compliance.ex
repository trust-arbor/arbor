defmodule Arbor.Actions.Judge.Producers.FormatCompliance do
  @moduledoc """
  Evidence producer that checks format compliance of LLM output.

  Validates:
  - JSON parseability (if output looks like JSON)
  - Required fields present (analysis, considerations, alternatives, recommendation)
  - Score ranges within expected bounds
  """

  @behaviour Arbor.Contracts.Judge.EvidenceProducer

  alias Arbor.Contracts.Judge.Evidence

  @required_keys ["analysis", "considerations", "alternatives", "recommendation"]

  @impl true
  def name, do: :format_compliance

  @impl true
  def description, do: "Checks JSON validity, required fields, and score ranges"

  @impl true
  def produce(subject, _context, _opts) do
    start = System.monotonic_time(:millisecond)
    content = Map.get(subject, :content, "")

    {score, detail} = evaluate_format(content)
    duration = System.monotonic_time(:millisecond) - start

    {:ok,
     %Evidence{
       type: :format_compliance,
       score: score,
       passed: score >= 0.5,
       detail: detail,
       producer: __MODULE__,
       duration_ms: duration
     }}
  end

  defp evaluate_format(content) when is_binary(content) and byte_size(content) == 0 do
    {0.0, "Empty content"}
  end

  defp evaluate_format(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      json_like?(trimmed) ->
        evaluate_json(trimmed)

      true ->
        evaluate_text(trimmed)
    end
  end

  defp evaluate_format(_), do: {0.0, "Content is not a string"}

  defp json_like?(text), do: String.starts_with?(text, "{") or String.starts_with?(text, "[")

  defp evaluate_json(text) do
    case Jason.decode(text) do
      {:ok, parsed} when is_map(parsed) ->
        present = Enum.count(@required_keys, &Map.has_key?(parsed, &1))
        total = length(@required_keys)
        score = present / total
        missing = Enum.reject(@required_keys, &Map.has_key?(parsed, &1))

        detail =
          if missing == [] do
            "Valid JSON with all #{total} required fields"
          else
            "Valid JSON but missing fields: #{Enum.join(missing, ", ")}"
          end

        {score, detail}

      {:ok, _} ->
        {0.5, "Valid JSON but not a map/object"}

      {:error, _} ->
        {0.25, "Appears to be JSON but failed to parse"}
    end
  end

  defp evaluate_text(text) do
    checks = [
      {String.length(text) >= 50, "sufficient length"},
      {String.contains?(text, "\n"), "has paragraph structure"},
      {Regex.match?(~r/\b(recommend|suggest|consider|should)\b/i, text), "contains recommendations"},
      {Regex.match?(~r/\b(because|since|therefore|however)\b/i, text), "contains reasoning connectors"}
    ]

    passed = Enum.count(checks, fn {pass, _} -> pass end)
    score = passed / length(checks)

    passed_items = checks |> Enum.filter(fn {p, _} -> p end) |> Enum.map(fn {_, d} -> d end)

    detail =
      if passed_items == [] do
        "Text response with no quality indicators"
      else
        "Text response: #{Enum.join(passed_items, ", ")}"
      end

    {score, detail}
  end
end
