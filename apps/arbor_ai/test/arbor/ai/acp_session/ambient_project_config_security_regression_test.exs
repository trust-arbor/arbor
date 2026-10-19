defmodule Arbor.AI.AcpSession.AmbientProjectConfigSecurityRegressionTest do
  @moduledoc """
  Security regression (Arbor Exposure Check, 2026-10-19): Codex CLI and Pi
  load project-level MCP / settings from the session cwd, the same class as
  Junie CLI / ZCode repo-local MCP RCE (CVE-2026-111091 / CVE-2026-88755).

  Findings, with citations:

  - **codex-cli** loads layered config. User config lives under `CODEX_HOME`
    (default `~/.codex`, including `config.toml` MCP servers). Project layers
    are discovered by walking from the session cwd looking for `.codex/`
    folders (`load_config_layers_state` in openai/codex
    `codex-rs/core/src/config/mod.rs`; confirmed in
    https://github.com/openai/codex/issues/9932). Project-level MCP in
    `.codex/config.toml` is a Codex CLI feature
    (https://github.com/openai/codex/issues/13025). Arbor previously left
    `CODEX_HOME` pointing at the host home (agent-security-gates #12).

  - **pi** (ExMCP.ACP.Adapters.Pi.Settings): `load/2` reads
    `{cwd}/.pi/settings.json` and deep-merges it over the agent-dir global
    file. `pi_command/2` then uses `settings["piCommand"]` unless
    `:cli_path`, `:pi_command`, or `PI_ACP_PI_COMMAND` is set
    (`deps/ex_mcp/lib/ex_mcp/acp/adapters/pi/settings.ex`). A worktree can
    therefore choose the executable Arbor launches.

  Acceptance: a worktree containing `.codex/config.toml`, or
  `.pi/settings.json` with `piCommand`, is refused or isolated by default.
  """
  use ExUnit.Case, async: false
  import Bitwise

  alias Arbor.AI.AcpSession.GrokSandbox
  alias Arbor.AI.AcpSession.RuntimeHome

  @moduletag :fast

  defp worktree!(files) do
    root =
      Path.join(
        System.tmp_dir!(),
        "arbor-ambient-cfg-#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Enum.each(files, fn {relative, contents} ->
      path = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end)

    root
  end

  defp adapter_client_opts(adapter) do
    [adapter: adapter, adapter_opts: [model: "test", env: [{"KEEP_ME", "1"}]]]
  end

  test "security regression: a worktree .codex/config.toml is refused by default" do
    cwd = worktree!([{".codex/config.toml", "[mcp_servers.evil]\ncommand = \"cal\"\n"}])

    assert {:error, :codex_project_config_forbidden} =
             GrokSandbox.with_launch(
               :codex,
               adapter_client_opts(ExMCP.ACP.Adapters.Codex),
               cwd,
               nil,
               self(),
               fn _ -> flunk("callback should not run") end
             )
  end

  test "security regression: a worktree .pi/settings.json with piCommand is refused by default" do
    cwd =
      worktree!([
        {".pi/settings.json", ~s({"piCommand": "/tmp/not-the-pi-binary"})}
      ])

    assert {:error, :pi_project_command_forbidden} =
             GrokSandbox.with_launch(
               :pi,
               adapter_client_opts(ExMCP.ACP.Adapters.Pi),
               cwd,
               nil,
               self(),
               fn _ -> flunk("callback should not run") end
             )
  end

  test "security regression: Codex and Pi launch homes are isolated from the host" do
    assert {:ok, cleanup} = RuntimeHome.create()

    assert {:ok, codex_opts} =
             RuntimeHome.inject(
               adapter_client_opts(ExMCP.ACP.Adapters.Codex),
               cleanup,
               :codex
             )

    codex_env = codex_opts |> Keyword.fetch!(:adapter_opts) |> Keyword.fetch!(:env) |> Map.new()
    codex_home = Map.fetch!(codex_env, "CODEX_HOME")
    assert codex_home == Path.join(cleanup.path, "codex")
    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(codex_home)
    assert band(mode, 0o777) == 0o700

    assert {:ok, pi_opts} =
             RuntimeHome.inject(adapter_client_opts(ExMCP.ACP.Adapters.Pi), cleanup, :pi)

    pi_adapter = Keyword.fetch!(pi_opts, :adapter_opts)
    pi_env = pi_adapter |> Keyword.fetch!(:env) |> Map.new()
    pi_home = Map.fetch!(pi_env, "PI_CODING_AGENT_DIR")
    assert pi_home == Path.join(cleanup.path, "pi")
    assert Keyword.fetch!(pi_adapter, :agent_dir) == pi_home
    assert Keyword.fetch!(pi_adapter, :pi_command) == "pi"
    assert {:ok, %File.Stat{type: :directory, mode: pi_mode}} = File.lstat(pi_home)
    assert band(pi_mode, 0o777) == 0o700

    assert :ok = RuntimeHome.cleanup(cleanup)
  end

  test "a clean worktree still launches after isolation" do
    cwd = worktree!([])

    assert {:ok, :ready} =
             GrokSandbox.with_launch(
               :codex,
               adapter_client_opts(ExMCP.ACP.Adapters.Codex),
               cwd,
               nil,
               self(),
               fn opts ->
                 assert opts[:adapter] == ExMCP.ACP.Adapters.Codex
                 :ready
               end
             )
  end

  test "security regression: Codex project config above cwd is refused inside a git worktree" do
    root =
      worktree!([
        {".git/HEAD", "ref: refs/heads/main\n"},
        {".codex/config.toml", "[mcp_servers.evil]\ncommand = \"cal\"\n"},
        {"nested/README", "x"}
      ])

    assert {:error, :codex_project_config_forbidden} =
             GrokSandbox.with_launch(
               :codex,
               adapter_client_opts(ExMCP.ACP.Adapters.Codex),
               Path.join(root, "nested"),
               nil,
               self(),
               fn _ -> flunk("callback should not run") end
             )
  end

  test "a .pi/settings.json without piCommand is not refused" do
    cwd = worktree!([{".pi/settings.json", ~s({"model": "test"})}])

    assert {:ok, :ready} =
             GrokSandbox.with_launch(
               :pi,
               adapter_client_opts(ExMCP.ACP.Adapters.Pi),
               cwd,
               nil,
               self(),
               fn _ -> :ready end
             )
  end
end
