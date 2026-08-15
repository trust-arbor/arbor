defmodule Arbor.Common.CapabilityProviders.SkillProvider do
  @moduledoc """
  CapabilityProvider adapter for the SkillLibrary.

  Converts `Arbor.Contracts.Skill` entries into `CapabilityDescriptor`s
  for the unified capability index.

  Skills in prompt-related categories (heartbeat, cognitive, advisory) are
  exposed with `kind: :prompt` and a `"prompt:"` id prefix, making them
  discoverable via prompt-aware capability searches.
  """

  @behaviour Arbor.Contracts.CapabilityProvider

  alias Arbor.Common.SkillLibrary
  alias Arbor.Contracts.{CapabilityDescriptor, Skill}

  @prompt_categories ~w(heartbeat cognitive advisory)

  @impl true
  def list_capabilities(opts \\ []) do
    SkillLibrary.list(opts)
    |> Enum.map(&skill_to_descriptor/1)
  end

  @impl true
  def describe(id) do
    case parse_skill_id(id) do
      {:ok, name} ->
        case SkillLibrary.get(name) do
          {:ok, skill} -> {:ok, skill_to_descriptor(skill)}
          {:error, _} = err -> err
        end

      :error ->
        {:error, :not_found}
    end
  end

  @impl true
  def execute(id, input, _opts) do
    case parse_skill_id(id) do
      {:ok, name} ->
        case SkillLibrary.get(name) do
          {:ok, skill} ->
            body = maybe_render_template(skill, input)
            {:ok, %{body: body, name: skill.name}}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc false
  def skill_to_descriptor(%Skill{} = skill) do
    {kind, id_prefix} = kind_and_prefix(skill)

    %CapabilityDescriptor{
      id: "#{id_prefix}#{skill.name}",
      name: skill.name,
      kind: kind,
      description: skill.description || "",
      tags: skill.tags || [],
      trust_required: taint_to_trust(skill.taint),
      provider: __MODULE__,
      source_ref: skill.path,
      metadata:
        Map.merge(
          %{category: skill.category, source: skill.source},
          skill.metadata || %{}
        )
    }
  end

  # For plain maps (fallback when Skill struct not available)
  def skill_to_descriptor(%{} = skill) do
    category = Map.get(skill, :category)
    is_prompt = category in @prompt_categories
    kind = if is_prompt, do: :prompt, else: :skill
    prefix = if is_prompt, do: "prompt:", else: "skill:"
    name = Map.get(skill, :name, "unknown")

    %CapabilityDescriptor{
      id: "#{prefix}#{name}",
      name: name,
      kind: kind,
      description: Map.get(skill, :description, ""),
      tags: Map.get(skill, :tags, []),
      trust_required: taint_to_trust(Map.get(skill, :taint, :trusted)),
      provider: __MODULE__,
      source_ref: Map.get(skill, :path),
      metadata:
        Map.merge(
          %{category: category, source: Map.get(skill, :source)},
          Map.get(skill, :metadata, %{})
        )
    }
  end

  defp kind_and_prefix(%Skill{category: category}) when category in @prompt_categories do
    {:prompt, "prompt:"}
  end

  defp kind_and_prefix(%Skill{}) do
    {:skill, "skill:"}
  end

  defp parse_skill_id("skill:" <> name), do: {:ok, name}
  defp parse_skill_id("prompt:" <> name), do: {:ok, name}
  defp parse_skill_id(_), do: :error

  defp taint_to_trust(:trusted), do: :new
  defp taint_to_trust(:derived), do: :provisional
  defp taint_to_trust(:untrusted), do: :established
  defp taint_to_trust(:hostile), do: :system
  defp taint_to_trust(_), do: :new

  defp maybe_render_template(skill, input) do
    bindings = if is_map(input), do: Map.get(input, :bindings, %{}), else: %{}
    renderer = Arbor.Common.TemplateRenderer

    if map_size(bindings) > 0 and Code.ensure_loaded?(renderer) do
      renderer.render(skill.body, bindings)
    else
      skill.body
    end
  end
end
