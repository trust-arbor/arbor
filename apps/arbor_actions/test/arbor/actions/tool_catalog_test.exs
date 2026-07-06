defmodule Arbor.Actions.ToolCatalogTest do
  @moduledoc """
  Regression guard for the tool-discovery loop fix (progressive disclosure).

  The loop happened because tool discovery was "search against a hidden
  catalog": the model had no up-front list of callable tools, so it kept
  re-querying `tool_find_tools`. The fix ports the proven skill-catalog pattern
  to tools — `Arbor.AI.CatalogSection.build(:action, ...)` injects a compact,
  byte-capped catalog of tool NAMES into the stable system prompt so the model
  selects from what it can see.

  This test lives in `arbor_actions` (not `arbor_ai`) on purpose: the catalog's
  list source is `Arbor.Actions.all_tools/0`, and arbor_actions is the lowest
  library where BOTH `Arbor.AI.SystemPromptBuilder` and `Arbor.Actions` are
  loaded in the same BEAM (arbor_actions deps arbor_ai). In arbor_ai's own
  isolated test BEAM the action module isn't loaded, so the catalog is empty
  there by design.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.AI.CatalogSection
  alias Arbor.AI.SystemPromptBuilder

  describe "tool catalog reaches the stable system prompt (Fix 1)" do
    test "build_stable_system_prompt injects a '# Available Tools' catalog listing real tool names" do
      prompt =
        SystemPromptBuilder.build_stable_system_prompt("agent_tool_catalog_test", tools: :enabled)

      assert prompt =~ "# Available Tools"

      # Load-bearing assertions — FAIL without the CatalogSection.build(:action, opts)
      # call in build_stable_system_prompt's `sections` list. Deliberately assert
      # on strings UNIQUE to the catalog (the bullet format + the exact catalog
      # instruction) rather than substrings the static tool_guidance section also
      # contains (e.g. bare "file_read" or "# Available Tools"), so this cannot
      # pass on the guidance text alone.
      assert prompt =~ "- **file_read**:"

      assert prompt =~
               "These tools are callable directly. Only use tool_find_tools to discover something NOT listed here:"
    end

    test "the catalog instructs direct calling, not searching" do
      prompt =
        SystemPromptBuilder.build_stable_system_prompt("agent_tool_catalog_test", tools: :enabled)

      # "callable directly" (vs the guidance's "call ... directly by name") is
      # unique to the catalog instruction — also load-bearing on Fix 1.
      assert prompt =~ "callable directly"
      assert prompt =~ "tool_find_tools"
    end
  end

  describe "CatalogSection.build(:action, ...)" do
    test "lists real tool names when enabled" do
      section = CatalogSection.build(:action, tools: :enabled)

      assert String.starts_with?(section, "# Available Tools")
      assert section =~ "- **file_read**:"
    end

    test "is byte-capped (stays a summary, not a schema dump)" do
      section = CatalogSection.build(:action, tools: :enabled)

      # The bullet body is capped at 13_000 bytes (+ header/instruction). Assert
      # the whole section stays bounded well under the ~50k a full-schema dump of
      # ~172 tools would cost — this is a name+purpose summary.
      assert byte_size(section) < 13_500
    end

    test "renders nothing when gated off" do
      assert CatalogSection.build(:action, tools: :disabled) == ""
    end

    test "unknown kind renders nothing" do
      assert CatalogSection.build(:nonexistent_kind, []) == ""
    end
  end
end
