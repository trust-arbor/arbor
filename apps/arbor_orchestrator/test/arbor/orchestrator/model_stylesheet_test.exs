defmodule Arbor.Orchestrator.ModelStylesheetTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Transforms.ModelStylesheet

  test "parses multiline stylesheet rules and declarations" do
    stylesheet = """
    * {
      llm_provider: anthropic;
      reasoning_effort: medium;
    }

    .code {
      llm_model: claude-opus;
    }

    #critical {
      llm_model: gpt-5;
      reasoning_effort: high;
    }
    """

    rules = ModelStylesheet.parse_rules(stylesheet)

    assert length(rules) == 3

    assert Enum.any?(
             rules,
             &(&1.selector == "*" and &1.declarations["llm_provider"] == "anthropic")
           )

    assert Enum.any?(
             rules,
             &(&1.selector == ".code" and &1.declarations["llm_model"] == "claude-opus")
           )

    assert Enum.any?(
             rules,
             &(&1.selector == "#critical" and &1.declarations["reasoning_effort"] == "high")
           )
  end

  test "handles quoted values with separators" do
    stylesheet = """
    * { llm_model: "gpt:5;preview"; llm_provider: openai; }
    """

    rules = ModelStylesheet.parse_rules(stylesheet)
    [rule] = rules
    assert rule.declarations["llm_model"] == "gpt:5;preview"
  end
end
