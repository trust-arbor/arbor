defmodule Arbor.Common.CapabilityProviders.SkillProviderTest do
  use ExUnit.Case, async: false

  alias Arbor.Common.CapabilityProviders.SkillProvider
  alias Arbor.Common.SkillLibrary
  alias Arbor.Contracts.{CapabilityDescriptor, Skill}

  @moduletag :fast

  # ETS table used by SkillLibrary
  @skill_table :arbor_skill_library

  setup do
    # Ensure SkillLibrary is started
    case Process.whereis(SkillLibrary) do
      nil -> start_supervised!(SkillLibrary)
      _pid -> :ok
    end

    # Register test skills
    skill1 = %Skill{
      name: "test-email-triage",
      description: "Triage and prioritize emails",
      body: "You are an email triage assistant...",
      tags: ["email", "productivity"],
      category: "productivity",
      source: :skill,
      taint: :trusted,
      metadata: %{}
    }

    skill2 = %Skill{
      name: "test-code-review",
      description: "Review code changes",
      body: "You are a code review assistant...",
      tags: ["code", "review", "quality"],
      category: "development",
      source: :skill,
      taint: :derived,
      metadata: %{}
    }

    :ok = SkillLibrary.register(skill1)
    :ok = SkillLibrary.register(skill2)

    on_exit(fn ->
      # Clean up test skills — table may already be gone if SkillLibrary was stopped
      try do
        :ets.delete(@skill_table, "test-email-triage")
        :ets.delete(@skill_table, "test-code-review")
      rescue
        ArgumentError -> :ok
      end
    end)

    %{skill1: skill1, skill2: skill2}
  end

  describe "list_capabilities/1" do
    test "returns descriptors for all skills" do
      capabilities = SkillProvider.list_capabilities()
      assert is_list(capabilities)
      assert Enum.all?(capabilities, &match?(%CapabilityDescriptor{kind: :skill}, &1))

      ids = Enum.map(capabilities, & &1.id)
      assert "skill:test-email-triage" in ids
      assert "skill:test-code-review" in ids
    end

    test "descriptors have correct fields" do
      capabilities = SkillProvider.list_capabilities()

      email = Enum.find(capabilities, &(&1.id == "skill:test-email-triage"))

      assert email.name == "test-email-triage"
      assert email.description == "Triage and prioritize emails"
      assert email.tags == ["email", "productivity"]
      assert email.provider == SkillProvider
      assert email.kind == :skill
    end

    test "taint maps to trust_required" do
      capabilities = SkillProvider.list_capabilities()

      email = Enum.find(capabilities, &(&1.id == "skill:test-email-triage"))
      assert email.trust_required == :new

      code = Enum.find(capabilities, &(&1.id == "skill:test-code-review"))
      assert code.trust_required == :provisional
    end
  end

  describe "describe/1" do
    test "returns descriptor for valid skill ID" do
      assert {:ok, %CapabilityDescriptor{} = desc} =
               SkillProvider.describe("skill:test-email-triage")

      assert desc.name == "test-email-triage"
      assert desc.kind == :skill
    end

    test "returns error for non-existent skill" do
      assert {:error, :not_found} = SkillProvider.describe("skill:nonexistent")
    end

    test "returns error for wrong ID prefix" do
      assert {:error, :not_found} = SkillProvider.describe("action:test-email-triage")
    end
  end

  describe "execute/3" do
    test "returns skill body" do
      assert {:ok, %{body: body, name: "test-email-triage"}} =
               SkillProvider.execute("skill:test-email-triage", %{}, [])

      assert body =~ "email triage assistant"
    end

    test "returns error for non-existent skill" do
      assert {:error, :not_found} = SkillProvider.execute("skill:nonexistent", %{}, [])
    end
  end

  describe "skill_to_descriptor/1" do
    test "converts skill struct to descriptor" do
      skill = %Skill{
        name: "my-skill",
        description: "Does things",
        tags: ["tag1"],
        category: "cat",
        source: :skill,
        path: "/some/path.md",
        taint: :trusted,
        metadata: %{custom: true}
      }

      desc = SkillProvider.skill_to_descriptor(skill)

      assert %CapabilityDescriptor{} = desc
      assert desc.id == "skill:my-skill"
      assert desc.source_ref == "/some/path.md"
      assert desc.metadata.category == "cat"
      assert desc.metadata.custom == true
    end
  end
end
