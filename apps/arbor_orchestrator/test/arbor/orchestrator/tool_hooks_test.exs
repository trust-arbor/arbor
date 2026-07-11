defmodule Arbor.Orchestrator.ToolHooksTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.ToolHooks

  test "trusted injected hook runner receives the structured payload" do
    payload = %{tool_name: "lookup", tool_call_id: "1", phase: "pre", arguments: %{"k" => "a"}}
    parent = self()

    runner = fn command, received_payload, _opts ->
      send(parent, {:hook_runner_called, command, received_payload})
      {:command, "trusted-output", 0}
    end

    result =
      ToolHooks.run(
        :pre,
        "operator-hook",
        payload,
        tool_hook_runner: runner
      )

    assert result.status == :ok
    assert result.decision == :proceed
    assert result.output == "trusted-output"
    assert_received {:hook_runner_called, "operator-hook", ^payload}
  end

  test "security regression: graph string hooks fail closed without a shell" do
    payload = %{tool_name: "x", tool_call_id: "1", phase: "pre"}
    result = ToolHooks.run(:pre, "echo must-not-run", payload, [])

    assert result.status == :error
    assert result.decision == :skip
    assert result.reason =~ "string tool hooks are unavailable"
  end

  test "pre hook non-zero exit marks decision skip" do
    payload = %{tool_name: "lookup", tool_call_id: "2", phase: "pre"}
    result = ToolHooks.run(:pre, fn _payload -> 23 end, payload, [])

    assert result.status == :error
    assert result.decision == :skip
    assert result.exit_code == 23
  end
end
