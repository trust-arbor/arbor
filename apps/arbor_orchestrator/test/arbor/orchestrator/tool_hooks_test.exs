defmodule Arbor.Orchestrator.ToolHooksTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.ToolHooks

  test "shell hook receives payload JSON on stdin" do
    payload = %{tool_name: "lookup", tool_call_id: "1", phase: "pre", arguments: %{"k" => "a"}}

    result =
      ToolHooks.run(
        :pre,
        "read body; printf '%s' \"$body\"",
        payload,
        []
      )

    assert result.status == :ok
    assert result.decision == :proceed
    assert String.contains?(result.output || "", "\"tool_name\":\"lookup\"")
    assert String.contains?(result.output || "", "\"tool_call_id\":\"1\"")
  end

  test "pre hook non-zero exit marks decision skip" do
    payload = %{tool_name: "lookup", tool_call_id: "2", phase: "pre"}
    result = ToolHooks.run(:pre, "exit 23", payload, [])

    assert result.status == :error
    assert result.decision == :skip
    assert result.exit_code == 23
  end
end
