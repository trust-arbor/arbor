defmodule Arbor.Actions.ToolCatalogTest do
  @moduledoc """
  The tool catalog (a prompt listing of tool names) is OFF by default since
  2026-08-25: disclosure is floor ∪ held, so the tool array already carries
  everything callable, and `tool_find_tools` is a self-describing semantic
  search constrained to what discovery can actually deliver. The catalog cost
  ~8 KB of every cached prefix for a section most turns never used.

  When enabled per agent it must be TRUTHFUL: it lists discoverable tools —
  policy-mintable, not held, not blocked — never "callable directly".

  Lives in `arbor_actions` because it is the lowest library where both
  `Arbor.AI.SystemPromptBuilder` and `Arbor.Actions` load in one BEAM.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.CatalogSection
  alias Arbor.AI.SystemPromptBuilder

  describe "default stable prompt" do
    test "carries no tool catalog — the tool array and find_tools cover it" do
      prompt = SystemPromptBuilder.build_stable_system_prompt("agent_tool_catalog_test", [])

      refute prompt =~ "# Available Tools"
      refute prompt =~ "# Discoverable Tools"
      refute prompt =~ "- **file_read**:"
    end
  end

  describe "CatalogSection.build(:action, ...) when enabled" do
    test "renders nothing without an agent to compute the discoverable set for" do
      assert CatalogSection.build(:action, tools: :enabled) == ""
    end

    test "never claims tools are callable directly" do
      section =
        CatalogSection.build(:action, tools: :enabled, state: %{id: "agent_tool_catalog_test"})

      refute section =~ "callable directly"
      refute section =~ "# Available Tools"
    end

    test "renders nothing when gated off" do
      assert CatalogSection.build(:action, tools: :disabled) == ""
    end

    test "unknown kind renders nothing" do
      assert CatalogSection.build(:nonexistent_kind, []) == ""
    end
  end
end
