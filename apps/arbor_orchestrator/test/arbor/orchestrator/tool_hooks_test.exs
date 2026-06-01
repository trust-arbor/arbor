defmodule Arbor.Orchestrator.ToolHooksTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Orchestrator.ToolHooks

  test "shell hook receives payload JSON via env var" do
    # H14: payload delivery moved from stdin (which required a shell
    # wrapper with attacker-influenceable interpolation) to the
    # TOOL_HOOK_PAYLOAD env var. Hook commands now read the payload
    # from $TOOL_HOOK_PAYLOAD directly.
    payload = %{tool_name: "lookup", tool_call_id: "1", phase: "pre", arguments: %{"k" => "a"}}

    result =
      ToolHooks.run(
        :pre,
        ~S(printf '%s' "$TOOL_HOOK_PAYLOAD"),
        payload,
        []
      )

    assert result.status == :ok
    assert result.decision == :proceed
    assert String.contains?(result.output || "", "\"tool_name\":\"lookup\"")
    assert String.contains?(result.output || "", "\"tool_call_id\":\"1\"")
  end

  test "security regression (H14): hook command runs in non-login shell" do
    # H14: pre-fix this ran `/bin/sh -lc`, sourcing the user's shell
    # profiles. If an attacker controlled ~/.bashrc (e.g. a compromised
    # dependency that wrote to dotfiles), every hook invocation executed
    # that profile. The fix uses `/bin/sh -c` (no -l).
    #
    # The behavioral check: a shell that's been forced into login mode
    # sets $0 to start with `-` (e.g. `-sh`). Non-login shells leave $0
    # as the program name. Assert non-login.
    payload = %{tool_name: "x", tool_call_id: "1", phase: "pre"}

    result =
      ToolHooks.run(
        :pre,
        ~S(printf '%s' "$0"),
        payload,
        []
      )

    assert result.status == :ok

    refute String.starts_with?(result.output || "", "-"),
           "Hook shell must NOT be a login shell ($0=#{inspect(result.output)}) — H14 regression"
  end

  test "pre hook non-zero exit marks decision skip" do
    payload = %{tool_name: "lookup", tool_call_id: "2", phase: "pre"}
    result = ToolHooks.run(:pre, "exit 23", payload, [])

    assert result.status == :error
    assert result.decision == :skip
    assert result.exit_code == 23
  end
end
