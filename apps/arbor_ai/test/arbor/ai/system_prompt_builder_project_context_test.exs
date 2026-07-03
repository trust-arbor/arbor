defmodule Arbor.AI.SystemPromptBuilderProjectContextTest do
  @moduledoc """
  Regression: the auto-loaded AGENTS.md/CLAUDE.md project context must reach the agent's STABLE
  system prompt (Arbor.AI.build_stable_system_prompt) — the path APIAgent chat turns actually use
  (api_agent.ex:386). An earlier wiring landed only on the DOT-pipeline path (LlmHandler) and
  never reached chat turns; this test pins the correct path.
  """
  use ExUnit.Case, async: false
  @moduletag :fast

  setup do
    root = Path.join(System.tmp_dir!(), "spb-pctx-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join(root, "CLAUDE.md"), "PROJECT_MARKER_CONVENTIONS")
    prev = Application.get_env(:arbor_common, :project_context_enabled)

    on_exit(fn ->
      if prev == nil,
        do: Application.delete_env(:arbor_common, :project_context_enabled),
        else: Application.put_env(:arbor_common, :project_context_enabled, prev)

      File.rm_rf(root)
    end)

    {:ok, root: root}
  end

  test "project context reaches the stable system prompt when enabled", %{root: root} do
    Application.put_env(:arbor_common, :project_context_enabled, true)
    prompt = Arbor.AI.build_stable_system_prompt("agent_pctx_probe", workdir: root)
    assert prompt =~ "PROJECT_MARKER_CONVENTIONS"
    assert prompt =~ "Context from:"
  end

  test "project context is excluded when disabled", %{root: root} do
    Application.put_env(:arbor_common, :project_context_enabled, false)
    prompt = Arbor.AI.build_stable_system_prompt("agent_pctx_probe", workdir: root)
    refute prompt =~ "PROJECT_MARKER_CONVENTIONS"
  end
end
