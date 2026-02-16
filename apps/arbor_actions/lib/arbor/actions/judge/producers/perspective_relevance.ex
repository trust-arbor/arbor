defmodule Arbor.Actions.Judge.Producers.PerspectiveRelevance do
  @moduledoc """
  Evidence producer that checks if a response is relevant to its assigned perspective.

  Extracts keywords from the perspective name and description, then counts
  how many appear in the response content. Normalized to 0.0–1.0.
  """

  @behaviour Arbor.Contracts.Judge.EvidenceProducer

  alias Arbor.Contracts.Judge.Evidence

  # Perspective-specific keywords for when context doesn't provide them
  @perspective_keywords %{
    security:
      ~w(security vulnerability attack threat authentication authorization access control encryption trust),
    stability: ~w(stability reliability crash error recovery fault resilience restart supervisor),
    performance:
      ~w(performance latency throughput benchmark optimization bottleneck cache memory cpu),
    privacy: ~w(privacy data personal sensitive consent gdpr pii encryption),
    brainstorming: ~w(idea creative alternative approach option possibility novel),
    user_experience: ~w(user experience interface usability feedback interaction design),
    capability: ~w(capability permission grant revoke access authorization resource),
    emergence: ~w(emerge pattern behavior evolve adapt self-organize complex),
    vision: ~w(vision architecture roadmap strategy long-term design pattern),
    consistency: ~w(consistent uniform standard convention pattern format style),
    generalization: ~w(general reusable abstract flexible extensible portable),
    resource_usage: ~w(resource cost token budget memory cpu usage efficient)
  }

  @impl true
  def name, do: :perspective_relevance

  @impl true
  def description, do: "Checks keyword overlap between perspective and response"

  @impl true
  def produce(subject, context, _opts) do
    start = System.monotonic_time(:millisecond)
    content = Map.get(subject, :content, "") |> String.downcase()
    perspective = Map.get(subject, :perspective) || Map.get(context, :perspective)

    keywords = extract_keywords(perspective, context)
    {score, detail} = compute_relevance(content, keywords, perspective)
    duration = System.monotonic_time(:millisecond) - start

    {:ok,
     %Evidence{
       type: :perspective_relevance,
       score: score,
       passed: score >= 0.3,
       detail: detail,
       producer: __MODULE__,
       duration_ms: duration
     }}
  end

  defp extract_keywords(perspective, context) do
    # First try context-provided keywords
    context_keywords =
      case Map.get(context, :perspective_prompt, "") do
        prompt when is_binary(prompt) and byte_size(prompt) > 0 ->
          prompt
          |> String.downcase()
          |> String.split(~r/[^a-z]+/)
          |> Enum.filter(&(String.length(&1) >= 4))
          |> Enum.uniq()
          |> Enum.take(20)

        _ ->
          []
      end

    # Fall back to built-in perspective keywords (normalize string keys to atoms)
    builtin =
      cond do
        is_atom(perspective) ->
          Map.get(@perspective_keywords, perspective, [])

        is_binary(perspective) ->
          # Try atom lookup — perspective names are defined at compile time
          try do
            Map.get(@perspective_keywords, String.to_existing_atom(perspective), [])
          rescue
            ArgumentError -> []
          end

        true ->
          []
      end

    case context_keywords do
      [] -> builtin
      kw -> Enum.uniq(kw ++ builtin)
    end
  end

  defp compute_relevance(_content, [], perspective) do
    {0.5, "No keywords available for perspective #{inspect(perspective)}"}
  end

  defp compute_relevance(content, keywords, perspective) do
    matches = Enum.count(keywords, &String.contains?(content, &1))
    total = length(keywords)
    # Normalize with diminishing returns — 50% keyword match = perfect score
    raw_score = matches / max(total, 1)
    score = min(raw_score * 2.0, 1.0)

    detail = "#{matches}/#{total} perspective keywords found for #{inspect(perspective)}"
    {Float.round(score, 3), detail}
  end
end
