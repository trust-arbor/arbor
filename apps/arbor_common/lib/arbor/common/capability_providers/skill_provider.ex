defmodule Arbor.Common.CapabilityProviders.SkillProvider do
  @moduledoc """
  CapabilityProvider adapter for the SkillLibrary.

  Converts `Arbor.Contracts.Skill` entries into `CapabilityDescriptor`s
  for the unified capability index.
  """

  @behaviour Arbor.Contracts.CapabilityProvider

  alias Arbor.Common.SkillLibrary
  alias Arbor.Contracts.{CapabilityDescriptor, Skill}

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
  def execute(id, _input, _opts) do
    # Skills are prompts/instructions, not directly executable.
    # Execution means "load and return the skill body for use in a prompt".
    case parse_skill_id(id) do
      {:ok, name} ->
        case SkillLibrary.get(name) do
          {:ok, skill} -> {:ok, %{body: skill.body, name: skill.name}}
          {:error, _} = err -> err
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc false
  def skill_to_descriptor(%Skill{} = skill) do
    %CapabilityDescriptor{
      id: "skill:#{skill.name}",
      name: skill.name,
      kind: :skill,
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

  defp parse_skill_id("skill:" <> name), do: {:ok, name}
  defp parse_skill_id(_), do: :error

  defp taint_to_trust(:trusted), do: :new
  defp taint_to_trust(:derived), do: :provisional
  defp taint_to_trust(:untrusted), do: :established
  defp taint_to_trust(:hostile), do: :system
  defp taint_to_trust(_), do: :new
end
