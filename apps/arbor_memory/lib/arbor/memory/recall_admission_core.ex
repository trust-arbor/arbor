defmodule Arbor.Memory.RecallAdmissionCore do
  @moduledoc """
  Pure exclusion policy for recognized conversation records on interactive reads.

  Conversation ownership has not yet been admitted by a trusted writer. All
  recognized conversations are therefore withheld, including records carrying
  claimed owners, public visibility or verified taint provenance. Other records
  passing this policy are not thereby proven safe to share.

  Callers validate storage envelopes before applying this policy. It neither
  validates records nor changes the stored data.
  """

  @doc "Whether a validated entry is outside the recognized conversation class."
  @spec admissible?(map()) :: boolean()
  def admissible?(entry) when is_map(entry) do
    not (Map.get(entry, :recall_admission) == :exclude_conversation or
           conversation_marker?(entry) or
           metadata_conversation?(Map.get(entry, :metadata)) or
           metadata_conversation?(Map.get(entry, "metadata")) or
           body_conversation?(Map.get(entry, :body)) or
           body_conversation?(Map.get(entry, "body")))
  end

  @doc "Prepend a validated result only when its original view is admissible."
  @spec prepend_if_admissible(map(), map(), [map()]) :: [map()]
  def prepend_if_admissible(view, result, acc) do
    if admissible?(view), do: [result | acc], else: acc
  end

  @doc "Preserve restrictive evidence when deriving a cache entry from a validated view."
  @spec preserve_classification(map(), map()) :: map()
  def preserve_classification(view, entry) do
    if admissible?(view) do
      entry
    else
      Map.put(entry, :recall_admission, :exclude_conversation)
    end
  end

  defp body_conversation?(body) when is_map(body) do
    metadata_conversation?(Map.get(body, :metadata)) or
      metadata_conversation?(Map.get(body, "metadata"))
  end

  defp body_conversation?(_body), do: false

  defp metadata_conversation?(metadata) when is_map(metadata) do
    conversation?(Map.get(metadata, :type)) or
      conversation?(Map.get(metadata, "type"))
  end

  defp metadata_conversation?(_metadata), do: false

  defp conversation_marker?(entry) do
    conversation?(Map.get(entry, :type)) or
      conversation?(Map.get(entry, "type")) or
      conversation?(Map.get(entry, :category)) or
      conversation?(Map.get(entry, "category"))
  end

  defp conversation?(:conversation), do: true
  defp conversation?("conversation"), do: true
  defp conversation?(_value), do: false
end
