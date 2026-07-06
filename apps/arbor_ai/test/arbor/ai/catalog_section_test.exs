defmodule Arbor.AI.CatalogSectionTest do
  @moduledoc """
  Unit tests for the kind-parameterized progressive-disclosure catalog.

  The `:skill` path is exercised here (skills live in arbor_common, a
  compile-time dep of arbor_ai). It doubles as the no-regression / equivalence
  guard: after extracting `build_skill_catalog_section` into `CatalogSection`,
  the skill catalog must still render byte-for-byte the same header +
  instruction + bullet format it did before.

  The `:action` path's list source (`Arbor.Actions.all_tools/0`) is NOT loadable
  in arbor_ai's isolated test BEAM (arbor_actions sits ABOVE arbor_ai and
  depends on it), so its end-to-end rendering is asserted in
  `apps/arbor_actions/test/arbor/actions/tool_catalog_test.exs`. Here we only
  assert the gate + graceful-empty behavior that hold regardless of loading.
  """
  use ExUnit.Case, async: false

  alias Arbor.AI.CatalogSection

  @skill_table :arbor_skill_library

  setup do
    ensure_skill_table()
    :ok
  end

  defp ensure_skill_table do
    if :ets.whereis(@skill_table) == :undefined do
      :ets.new(@skill_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  defp seed_skill(name, description) do
    :ets.insert(@skill_table, {name, %{name: name, description: description}})
    # If we created the table it dies with this test process (auto-cleanup); if
    # a running SkillLibrary owns it, drop just our key. Guard against the table
    # being gone by the time on_exit fires.
    on_exit(fn ->
      if :ets.whereis(@skill_table) != :undefined do
        :ets.delete(@skill_table, name)
      end
    end)

    name
  end

  describe "build(:skill, ...) — no-regression equivalence" do
    test "renders the exact header + instruction + bullet format" do
      seed_skill(
        "zzz-catalog-test-skill",
        "A test skill for catalog rendering.\nsecond line ignored"
      )

      section = CatalogSection.build(:skill, skills: :enabled)

      # Byte-identical header + instruction to the pre-extraction skill catalog.
      assert String.starts_with?(
               section,
               "# Available Skills\n\nActivate any of these with the skill tool to load its full guidance:\n\n"
             )

      # Bullet format is `- **name**: <first line of description>`.
      assert section =~ "- **zzz-catalog-test-skill**: A test skill for catalog rendering."
      # Only the first line of a multi-line description is kept.
      refute section =~ "second line ignored"
    end

    test "is gated off by a per-agent :disabled override" do
      seed_skill("zzz-catalog-test-skill-2", "desc")
      assert CatalogSection.build(:skill, skills: :disabled) == ""
    end

    test "is byte-capped so it can't blow up the prompt" do
      # A single skill whose one-line description alone exceeds the 4_000-byte cap.
      huge = String.duplicate("x", 6_000)
      seed_skill("zzz-catalog-huge-skill", huge)

      section = CatalogSection.build(:skill, skills: :enabled)

      # Graceful overflow, NOT silent truncation: it must announce more exist AND point to the
      # discovery tool, so the model degrades to search rather than treating the hidden tail as
      # nonexistent (which is the very loop the catalog exists to remove).
      assert section =~ "catalog truncated"
      assert section =~ "discovery"
      # Header + instruction + capped body + the overflow note — still bounded well under the raw 6k.
      assert byte_size(section) < 4_400
    end
  end

  describe "build(:action, ...) — gate + graceful empty" do
    test "renders nothing when gated off" do
      assert CatalogSection.build(:action, tools: :disabled) == ""
    end

    test "does not raise when enabled even if the action module isn't loaded here" do
      # In arbor_ai's isolated BEAM Arbor.Actions isn't loaded → empty catalog,
      # never a crash. (Real tool names are asserted in the arbor_actions suite.)
      assert is_binary(CatalogSection.build(:action, tools: :enabled))
    end
  end

  describe "build/2 — unknown kind" do
    test "renders nothing" do
      assert CatalogSection.build(:pipeline, []) == ""
      assert CatalogSection.build(:bogus, foo: :bar) == ""
    end
  end
end
