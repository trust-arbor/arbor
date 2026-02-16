defmodule Arbor.Memory.IdentityConsolidator.InsightIntegration do
  @moduledoc """
  Handles integration of individual insights into SelfKnowledge.

  Extracted from `Arbor.Memory.IdentityConsolidator` to reduce module size.
  Responsible for extracting traits, capabilities, and values from insight
  content and integrating them into the agent's self-knowledge.
  """

  alias Arbor.Memory.SelfKnowledge

  # Known trait atoms for extraction
  @known_traits ~w(curious methodical thorough reflective analytical detail_oriented)a

  # Known capability strings for extraction
  @known_capabilities ~w(associative_thinking evidence_based_reasoning knowledge_retention)

  # Known value atoms for extraction
  @known_values ~w(growth learning capability_development self_reflection)a

  @doc """
  Integrate an insight into SelfKnowledge based on its category.

  Returns `{:ok, updated_sk, change}` or `{:skip, reason}`.
  """
  def integrate_insight(sk, insight) do
    case insight.category do
      :personality ->
        integrate_personality_insight(sk, insight)

      :capability ->
        integrate_capability_insight(sk, insight)

      :value ->
        integrate_value_insight(sk, insight)

      _ ->
        {:skip, :unknown_category}
    end
  end

  @doc """
  Integrate a personality-type insight into SelfKnowledge.
  """
  def integrate_personality_insight(sk, insight) do
    trait = extract_trait_from_insight(insight)

    if trait do
      existing = Enum.find(sk.personality_traits, &(&1.trait == trait))

      if existing && contradicts?(existing.strength, insight.confidence) do
        updated_sk = SelfKnowledge.add_trait(sk, trait, insight.confidence, hd(insight.evidence))

        change = %{
          field: :personality_traits,
          old_value: {trait, existing.strength},
          new_value: {trait, insight.confidence},
          reason: "new_evidence"
        }

        {:ok, updated_sk, change}
      else
        updated_sk = SelfKnowledge.add_trait(sk, trait, insight.confidence, hd(insight.evidence))

        change = %{
          field: :personality_traits,
          old_value: existing && {trait, existing.strength},
          new_value: {trait, insight.confidence},
          reason: "insight_detected"
        }

        {:ok, updated_sk, change}
      end
    else
      {:skip, :could_not_extract_trait}
    end
  end

  @doc """
  Integrate a capability-type insight into SelfKnowledge.
  """
  def integrate_capability_insight(sk, insight) do
    capability = extract_capability_from_insight(insight)

    if capability do
      existing = Enum.find(sk.capabilities, &(&1.name == capability))
      evidence = if insight.evidence != [], do: hd(insight.evidence), else: nil

      updated_sk =
        SelfKnowledge.add_capability(
          sk,
          capability,
          insight.confidence,
          evidence
        )

      change = %{
        field: :capabilities,
        old_value: existing && {capability, existing.proficiency},
        new_value: {capability, insight.confidence},
        reason: "insight_detected"
      }

      {:ok, updated_sk, change}
    else
      {:skip, :could_not_extract_capability}
    end
  end

  @doc """
  Integrate a value-type insight into SelfKnowledge.
  """
  def integrate_value_insight(sk, insight) do
    value = extract_value_from_insight(insight)

    if value do
      existing = Enum.find(sk.values, &(&1.value == value))
      evidence = if insight.evidence != [], do: hd(insight.evidence), else: nil

      updated_sk =
        SelfKnowledge.add_value(
          sk,
          value,
          insight.confidence,
          evidence
        )

      change = %{
        field: :values,
        old_value: existing && {value, existing.importance},
        new_value: {value, insight.confidence},
        reason: "insight_detected"
      }

      {:ok, updated_sk, change}
    else
      {:skip, :could_not_extract_value}
    end
  end

  @doc """
  Check if two confidence values contradict (differ significantly).
  """
  def contradicts?(old_value, new_value) do
    abs(old_value - new_value) > 0.3
  end

  @doc """
  Extract a trait atom from insight content using known trait patterns.
  """
  def extract_trait_from_insight(insight) do
    content_lower = String.downcase(insight.content)

    Enum.find(@known_traits, fn trait ->
      trait_str = Atom.to_string(trait)
      String.contains?(content_lower, trait_str) or
        String.contains?(content_lower, String.replace(trait_str, "_", "-")) or
        String.contains?(content_lower, String.replace(trait_str, "_", " "))
    end)
  end

  @doc """
  Extract a capability name from insight content using known capability patterns.
  """
  def extract_capability_from_insight(insight) do
    content_lower = String.downcase(insight.content)

    found =
      Enum.find(@known_capabilities, fn cap ->
        String.contains?(content_lower, cap) or
          String.contains?(content_lower, String.replace(cap, "_", "-")) or
          String.contains?(content_lower, String.replace(cap, "_", " "))
      end)

    cond do
      found ->
        found

      String.contains?(content_lower, "interconnected") ->
        "associative_thinking"

      String.contains?(content_lower, "evidence") or
          String.contains?(content_lower, "supporting") ->
        "evidence_based_reasoning"

      String.contains?(content_lower, "knowledge base") ->
        "knowledge_retention"

      true ->
        nil
    end
  end

  @doc """
  Extract a value atom from insight content using known value patterns.
  """
  def extract_value_from_insight(insight) do
    content_lower = String.downcase(insight.content)

    found =
      Enum.find(@known_values, fn val ->
        val_str = Atom.to_string(val)

        String.contains?(content_lower, val_str) or
          String.contains?(content_lower, String.replace(val_str, "_", "-")) or
          String.contains?(content_lower, String.replace(val_str, "_", " "))
      end)

    found || match_value_pattern(content_lower)
  end

  @doc """
  Match value patterns from content string for fallback extraction.
  """
  def match_value_pattern(content) when is_binary(content) do
    cond do
      String.contains?(content, "growth mindset") or
          String.contains?(content, "capability development") ->
        :growth

      String.contains?(content, "self-reflection") or
          String.contains?(content, "metacognition") ->
        :self_reflection

      String.contains?(content, "learning") or
          String.contains?(content, "skills") ->
        :learning

      true ->
        nil
    end
  end
end
