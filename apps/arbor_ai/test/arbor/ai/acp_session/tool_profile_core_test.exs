defmodule Arbor.AI.AcpSession.ToolProfileCoreTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.AI.AcpSession.ToolProfileCore, as: Core

  defp modes(map), do: fn uri -> Map.get(map, uri, :deny) end

  test "no tool capabilities → nothing allowed, everything unlisted denied" do
    profile =
      Core.derive(["arbor://memory/write", "arbor://orchestrator/execute"], fn _ -> :auto end)

    assert profile == %{
             allowed_tools: [],
             gated_tools: [],
             wildcard?: false,
             deny_unlisted?: true
           }

    assert Core.adapter_opts(profile) == [
             allowed_tools: [],
             askable_tools: [],
             deny_unlisted_tools: true
           ]
  end

  test "exact tool capabilities split by trust mode" do
    uris = [
      "arbor://acp/tool/Read",
      "arbor://acp/tool/Bash",
      "arbor://acp/tool/Edit",
      "arbor://acp/tool/Read"
    ]

    profile =
      Core.derive(
        uris,
        modes(%{
          "arbor://acp/tool/Read" => :auto,
          "arbor://acp/tool/Bash" => :gated,
          "arbor://acp/tool/Edit" => :deny
        })
      )

    assert profile.allowed_tools == ["Read"]
    assert profile.gated_tools == ["Bash"]
    refute profile.wildcard?
    assert profile.deny_unlisted?

    assert Core.adapter_opts(profile) == [
             allowed_tools: ["Read"],
             askable_tools: ["Bash"],
             deny_unlisted_tools: true
           ]
  end

  test "a prefix capability is a wildcard: no launch-time restriction" do
    for wildcard <- ["arbor://acp/tool", "arbor://acp/tool/", "arbor://acp/tool/**"] do
      profile = Core.derive([wildcard, "arbor://acp/tool/Read"], fn _ -> :auto end)
      assert profile.wildcard?
      refute profile.deny_unlisted?
      assert profile.allowed_tools == ["Read"]
      assert Core.adapter_opts(profile) == []
    end
  end

  test "malformed tool names and a raising mode function fail closed" do
    profile =
      Core.derive(
        ["arbor://acp/tool/", "arbor://acp/tool/bad name", "arbor://acp/tool/Ok"],
        fn _ -> raise "boom" end
      )

    assert profile.allowed_tools == []
    assert profile.gated_tools == []
  end

  test "non-list input yields the closed profile" do
    assert Core.derive(nil, fn _ -> :auto end).deny_unlisted?
  end
end
