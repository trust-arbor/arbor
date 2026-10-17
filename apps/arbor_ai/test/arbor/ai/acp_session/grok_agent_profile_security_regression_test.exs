defmodule Arbor.AI.AcpSession.GrokAgentProfileSecurityRegressionTest do
  @moduledoc """
  Security regression: the Grok `--agent-profile` must be derived from the
  agent's granted capabilities. A hardcoded native file-tool list would let a
  session with no `arbor://fs/*` grants still expose `read_file` /
  `search_replace` / `grep` / `list_dir` inside the attested profile.

  Parent behavior (must fail on checkout of the exact parent):
  `RuntimeHome.inject/3` stages `@grok_agent_profile_content` with those four
  tools regardless of capabilities.

  Fixed behavior: missing/empty grants stage `tools: []`. `run_terminal_cmd`
  and subagent tools stay in `disallowedTools` even when shell caps exist.
  """
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession.RuntimeHome

  @moduletag :fast
  @moduletag :security_regression

  @expected_grok_command [
    "grok",
    "--sandbox",
    "strict",
    "--no-memory",
    "--no-subagents",
    "--disable-web-search",
    "--deny",
    "MCPTool(*)",
    "--deny",
    "Bash(*)",
    "agent",
    "--no-leader",
    "--model",
    "grok-4.6",
    "stdio"
  ]

  test "security regression: inject without capabilities does not stage native file tools" do
    assert {:ok, cleanup} = RuntimeHome.create()

    try do
      assert {:ok, opts} =
               RuntimeHome.inject(
                 [command: @expected_grok_command],
                 cleanup,
                 :grok
               )

      grok_home = opts |> Keyword.fetch!(:env) |> Map.new() |> Map.fetch!("GROK_HOME")
      profile_path = RuntimeHome.grok_agent_profile_path(grok_home)
      content = File.read!(profile_path)

      refute content =~ "\n  - read_file\n",
             "hardcoded profile leaked read_file without fs/read: #{inspect(content)}"

      refute content =~ "\n  - search_replace\n",
             "hardcoded profile leaked search_replace without fs/write: #{inspect(content)}"

      refute content =~ "\n  - grep\n",
             "hardcoded profile leaked grep without fs/read: #{inspect(content)}"

      refute content =~ "\n  - list_dir\n",
             "hardcoded profile leaked list_dir without fs/read: #{inspect(content)}"

      assert content =~ "\n  - run_terminal_cmd\n"
      assert content =~ "\n  - task\n"
      assert content =~ "\n  - get_task_output\n"
      assert content =~ "\n  - kill_task\n"
      assert RuntimeHome.verify_grok_agent_profile(profile_path) == :ok
    after
      _ = RuntimeHome.cleanup(cleanup)
    end
  end

  test "security regression: fs/read-only omits search_replace and never allows shell tools" do
    assert {:ok, cleanup} = RuntimeHome.create()

    try do
      assert {:ok, opts} =
               RuntimeHome.inject(
                 [command: @expected_grok_command],
                 cleanup,
                 :grok,
                 capability_uris: ["arbor://fs/read/workspace/**"]
               )

      grok_home = opts |> Keyword.fetch!(:env) |> Map.new() |> Map.fetch!("GROK_HOME")
      content = File.read!(RuntimeHome.grok_agent_profile_path(grok_home))

      assert content =~ "\n  - read_file\n"
      assert content =~ "\n  - grep\n"
      assert content =~ "\n  - list_dir\n"
      refute content =~ "\n  - search_replace\n"
      assert tools_block(content) |> String.contains?("read_file")
      refute tools_block(content) |> String.contains?("run_terminal_cmd")
      refute tools_block(content) |> String.contains?("search_replace")
      assert disallowed_block(content) =~ "run_terminal_cmd"
    after
      _ = RuntimeHome.cleanup(cleanup)
    end
  end

  test "security regression: shell capabilities cannot enable run_terminal_cmd in the profile" do
    assert {:ok, cleanup} = RuntimeHome.create()

    try do
      assert {:ok, opts} =
               RuntimeHome.inject(
                 [command: @expected_grok_command],
                 cleanup,
                 :grok,
                 capability_uris: [
                   "arbor://fs/read/**",
                   "arbor://fs/write/**",
                   "arbor://shell/exec/**",
                   "arbor://agent/spawn"
                 ]
               )

      grok_home = opts |> Keyword.fetch!(:env) |> Map.new() |> Map.fetch!("GROK_HOME")
      content = File.read!(RuntimeHome.grok_agent_profile_path(grok_home))
      tools = tools_block(content)

      assert tools =~ "search_replace"
      refute tools =~ "run_terminal_cmd"
      refute tools =~ "task"
      assert disallowed_block(content) =~ "run_terminal_cmd"
      assert disallowed_block(content) =~ "kill_task"
    after
      _ = RuntimeHome.cleanup(cleanup)
    end
  end

  defp tools_block(content) do
    case Regex.run(~r/\ntools:\n(.*?)\ndisallowedTools:/s, content) do
      [_, tools] -> tools
      _ -> Regex.run(~r/\ntools: \[\]\n/, content) |> then(&(&1 || [content])) |> hd()
    end
  end

  defp disallowed_block(content) do
    case Regex.run(~r/\ndisallowedTools:\n(.*)\n---/s, content) do
      [_, block] -> block
      _ -> content
    end
  end
end
