defmodule Arbor.Orchestrator.Handlers.LlmHandlerTerminalToolsTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Handlers.LlmHandler

  @moduletag :fast

  @tool_defs [
    %{
      "type" => "function",
      "function" => %{"name" => "coding_submit_review_report", "parameters" => %{}}
    },
    %{
      "type" => "function",
      "function" => %{"name" => "coding_review_tree_read", "parameters" => %{}}
    }
  ]

  test "absent or empty terminal_tools is compatible (no terminal contract)" do
    assert {:ok, []} = LlmHandler.parse_terminal_tools_attr(nil, @tool_defs)
    assert {:ok, []} = LlmHandler.parse_terminal_tools_attr("", @tool_defs)
  end

  test "normalizes CSV without minting atoms and requires resolved-tool subset" do
    assert {:ok, ["coding_submit_review_report"]} =
             LlmHandler.parse_terminal_tools_attr(
               "coding_submit_review_report",
               @tool_defs
             )

    assert {:error, {:terminal_tools_not_in_resolved_tools, ["not_resolved"]}} =
             LlmHandler.parse_terminal_tools_attr("not_resolved", @tool_defs)

    assert {:error, :invalid_terminal_tool_name} =
             LlmHandler.parse_terminal_tools_attr("bad name!", @tool_defs)
  end
end
