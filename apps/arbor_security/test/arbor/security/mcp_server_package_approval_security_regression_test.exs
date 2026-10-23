defmodule Arbor.Security.McpServerPackageApprovalSecurityRegressionTest do
  @moduledoc """
  Security regression: operator approval of an agent-bound MCP server used to
  fingerprint transport/command/env/url but accepted unpinned `npx`/`uvx`/
  `bunx`/`pnpm dlx` specs. Those resolve to whatever the registry serves at
  spawn time, including archived `@modelcontextprotocol/server-*` packages
  remembered from training data (MCPhantom, 2026-10).

  `Arbor.Security.admit_mcp_server_config/2` is the public gate
  `Arbor.Agent.set_mcp_config/3` must call before granting
  `mcp_server_approval_uri/2`. It requires an exact `pkg@x.y.z`, refuses the
  archived reference-server denylist, and optionally consults an injectable
  `npm view <pkg>@<ver> deprecated` check that is off by default in tests
  and fails safe when the network is gone.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :fast

  @archived ~w(
    github
    gdrive
    postgres
    puppeteer
    brave-search
    slack
    sqlite
    redis
    gitlab
    google-maps
    sentry
    everart
    aws-kb-retrieval
  )

  defp admit(config, opts \\ []) do
    Arbor.Security.admit_mcp_server_config(config, opts)
  end

  defp uri!(name, config) do
    {:ok, uri} = Arbor.Security.mcp_server_approval_uri(name, config)
    uri
  end

  test "security regression: unpinned npx/uvx/bunx/pnpm dlx commands are refused" do
    for command <- [
          ["npx", "@scope/pkg"],
          ["npx", "-y", "@scope/pkg"],
          ["npx", "--yes", "some-mcp-server"],
          "npx -y @scope/pkg",
          ["uvx", "some-pkg"],
          ["bunx", "some-pkg"],
          ["pnpm", "dlx", "some-pkg"],
          ["npx", "--package=@scope/pkg", "bin"]
        ] do
      assert {:error, {:unpinned_mcp_package, message}} =
               admit(%{transport: :stdio, command: command})

      assert message =~ ~r/exact|x\.y\.z|version/i, inspect({command, message})
    end
  end

  test "security regression: ranges and tags are not exact versions" do
    for spec <- ["pkg@latest", "pkg@^1.0.0", "pkg@~1.2.3", "pkg@>=1.0.0", "pkg@1.0", "pkg@beta"] do
      assert {:error, {:unpinned_mcp_package, message}} = admit(%{command: ["npx", spec]})
      assert message =~ spec
    end
  end

  test "security regression: archived @modelcontextprotocol reference servers are refused" do
    Enum.each(@archived, fn short ->
      pkg = "@modelcontextprotocol/server-" <> short

      assert {:error, {:archived_mcp_package, message}} =
               admit(%{command: ["npx", "-y", pkg <> "@0.6.2"]})

      assert message =~ pkg

      case short do
        "github" ->
          assert message =~ "ghcr.io/github/github-mcp-server"

        "brave-search" ->
          assert message =~ "@brave/brave-search-mcp-server"

        "slack" ->
          assert message =~ "zencoderai/slack-mcp-server"

        _other ->
          :ok
      end
    end)
  end

  test "security regression: string-keyed unpinned and archived configs are gated too" do
    assert {:error, {:unpinned_mcp_package, _}} =
             admit(%{"transport" => "stdio", "command" => ["npx", "pkg"]})

    assert {:error, {:archived_mcp_package, message}} =
             admit(%{"command" => ["npx", "@modelcontextprotocol/server-github@1.0.0"]})

    assert message =~ "ghcr.io/github/github-mcp-server"
  end

  test "an exact pin that is not on the denylist is admitted" do
    for command <- [
          ["npx", "promptfoo@1.2.3"],
          ["npx", "-y", "@modelcontextprotocol/server-filesystem@1.0.0", "/workspace"],
          ["uvx", "mcp-server-git@1.2.3"],
          ["bunx", "some-pkg@0.1.0"],
          ["pnpm", "dlx", "some-pkg@2.0.0"],
          ["npx", "--package=@scope/pkg@1.0.0", "bin"],
          ["docker", "run", "-i", "--rm", "ghcr.io/github/github-mcp-server:v2.0.3"],
          "./local-mcp-server"
        ] do
      assert :ok = admit(%{transport: :stdio, command: command}), inspect(command)
    end

    assert :ok = admit(%{transport: :http, url: "https://mcp.example"})
  end

  test "security regression: the pinned version is part of the approval digest" do
    v1 = %{transport: :stdio, command: ["npx", "promptfoo@1.0.0"]}
    v2 = %{v1 | command: ["npx", "promptfoo@2.0.0"]}

    refute uri!("tools", v1) == uri!("tools", v2)
    assert uri!("tools", v1) == uri!("tools", %{"transport" => "stdio", "command" => v1.command})
  end

  test "security regression: deprecation check is off by default and is not invoked" do
    assert :ok =
             admit(%{command: ["npx", "promptfoo@1.2.3"]},
               deprecation_check: fn _pkg, _ver ->
                 flunk("deprecation check must stay off by default in tests")
               end
             )
  end

  test "security regression: warn mode logs and admits a deprecated package" do
    log =
      capture_log(fn ->
        assert :ok =
                 admit(%{command: ["npx", "promptfoo@1.2.3"]},
                   deprecation_mode: :warn,
                   deprecation_check: fn "promptfoo", "1.2.3" ->
                     {:deprecated, "Package no longer supported"}
                   end
                 )
      end)

    assert log =~ "promptfoo@1.2.3"
    assert log =~ "Package no longer supported"
  end

  test "security regression: reject mode refuses a deprecated package" do
    assert {:error, {:deprecated_mcp_package, message}} =
             admit(%{command: ["npx", "promptfoo@1.2.3"]},
               deprecation_mode: :reject,
               deprecation_check: fn "promptfoo", "1.2.3" ->
                 {:deprecated, "Package no longer supported"}
               end
             )

    assert message =~ "promptfoo@1.2.3"
    assert message =~ "Package no longer supported"
  end

  test "security regression: deprecation check fails safe when the network is gone" do
    for mode <- [:warn, :reject] do
      assert :ok =
               admit(%{command: ["npx", "promptfoo@1.2.3"]},
                 deprecation_mode: mode,
                 deprecation_check: fn _pkg, _ver -> {:error, :unavailable} end
               )
    end
  end
end
