defmodule Arbor.Actions.Judge.Producers.ReferenceEngagement do
  @moduledoc """
  Evidence producer that checks if a response engages with reference documents.

  Looks for mentions of reference document paths, filenames, or titles
  in the response content. A response that engages with provided references
  demonstrates deeper analysis.
  """

  @behaviour Arbor.Contracts.Judge.EvidenceProducer

  alias Arbor.Contracts.Judge.Evidence

  @impl true
  def name, do: :reference_engagement

  @impl true
  def description, do: "Checks if response mentions reference docs from context"

  @impl true
  def produce(subject, context, _opts) do
    start = System.monotonic_time(:millisecond)
    content = Map.get(subject, :content, "") |> String.downcase()
    reference_docs = Map.get(context, :reference_docs, [])

    {score, detail} = check_engagement(content, reference_docs)
    duration = System.monotonic_time(:millisecond) - start

    {:ok,
     %Evidence{
       type: :reference_engagement,
       score: score,
       passed: score >= 0.3,
       detail: detail,
       producer: __MODULE__,
       duration_ms: duration
     }}
  end

  defp check_engagement(_content, []) do
    {1.0, "No reference docs provided (pass by default)"}
  end

  defp check_engagement(content, docs) when is_list(docs) do
    # Extract searchable terms from each reference doc path/name
    doc_terms = Enum.map(docs, &extract_terms/1)

    matches =
      Enum.count(doc_terms, fn terms ->
        Enum.any?(terms, &String.contains?(content, &1))
      end)

    total = length(docs)
    score = matches / max(total, 1)

    detail =
      if matches == 0 do
        "No reference docs mentioned (#{total} available)"
      else
        "#{matches}/#{total} reference docs engaged"
      end

    {Float.round(score, 3), detail}
  end

  defp check_engagement(_content, _docs), do: {0.5, "Invalid reference_docs format"}

  defp extract_terms(doc) when is_binary(doc) do
    # Extract filename without extension, path segments, and the full path
    filename = Path.basename(doc, Path.extname(doc))
    segments = Path.split(doc) |> Enum.reject(&(&1 in [".", "..", "/", ""]))

    # Create lowercase searchable terms
    terms =
      [filename | segments]
      |> Enum.map(&String.downcase/1)
      |> Enum.map(&String.replace(&1, ~r/[_-]/, " "))
      |> Enum.flat_map(&[&1, String.replace(&1, " ", "_"), String.replace(&1, " ", "-")])
      |> Enum.uniq()
      |> Enum.filter(&(String.length(&1) >= 3))

    terms
  end

  defp extract_terms(doc) when is_map(doc) do
    # Support map-style docs with :path or :title keys
    path_terms = extract_terms(Map.get(doc, :path, Map.get(doc, "path", "")))
    title = Map.get(doc, :title, Map.get(doc, "title", ""))
    title_terms = if is_binary(title), do: [String.downcase(title)], else: []
    Enum.uniq(path_terms ++ title_terms)
  end

  defp extract_terms(_), do: []
end
