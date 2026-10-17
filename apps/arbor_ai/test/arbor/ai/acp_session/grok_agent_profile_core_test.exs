defmodule Arbor.AI.AcpSession.GrokAgentProfileCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.AcpSession.GrokAgentProfileCore, as: Core

  test "empty and non-list input render no native file tools" do
    for uris <- [[], nil, :invalid, ["arbor://memory/write"]] do
      content = Core.render(uris)
      refute content =~ "\n  - read_file\n"
      refute content =~ "\n  - search_replace\n"
      refute content =~ "\n  - grep\n"
      refute content =~ "\n  - list_dir\n"
      assert content =~ "tools: []\n"
      assert content =~ "\n  - run_terminal_cmd\n"
    end
  end

  test "fs/read enables read tools and omits search_replace" do
    content = Core.render(["arbor://fs/read/workspace/**"])
    assert content =~ "\n  - read_file\n"
    assert content =~ "\n  - grep\n"
    assert content =~ "\n  - list_dir\n"
    refute content =~ "\n  - search_replace\n"
    refute tools_block(content) =~ "run_terminal_cmd"
  end

  test "fs/write enables search_replace without read tools" do
    content = Core.render(["arbor://fs/write"])
    assert content =~ "\n  - search_replace\n"
    refute content =~ "\n  - read_file\n"
    refute content =~ "\n  - grep\n"
  end

  test "fs/** wildcard enables both read and write native tools" do
    content = Core.render(["arbor://fs/**"])
    assert content =~ "\n  - read_file\n"
    assert content =~ "\n  - search_replace\n"
    assert content =~ "\n  - grep\n"
    assert content =~ "\n  - list_dir\n"
  end

  test "shell and spawn capabilities cannot enable run_terminal_cmd" do
    content =
      Core.render([
        "arbor://fs/read/**",
        "arbor://fs/write/**",
        "arbor://shell/exec/**",
        "arbor://agent/spawn"
      ])

    refute tools_block(content) =~ "run_terminal_cmd"
    refute tools_block(content) =~ "task"
    assert content =~ "\n  - run_terminal_cmd\n"
    assert content =~ "\n  - kill_task\n"
  end

  defp tools_block(content) do
    case Regex.run(~r/\ntools:\n(.*?)\ndisallowedTools:/s, content) do
      [_, tools] -> tools
      _ -> ""
    end
  end
end
