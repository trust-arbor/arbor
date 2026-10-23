defmodule Arbor.AI.AcpSessionCodexSecurityRegressionTest do
  @moduledoc """
  Security regression: Codex app-server must not load user-level
  `~/.codex/config.toml` `mcp_servers`. RuntimeHome previously isolated
  HOME only for Antigravity, Grok, and Kiro, so an Arbor Codex session
  inherited the operator `CODEX_HOME` / `~/.codex` tree. A full-access
  turn can persist `codex mcp add` there; later sessions would load it.

  Parent behavior (must fail on checkout of the exact parent):
  `RuntimeHome.inject/3` for `:codex` only injects `ARBOR_HOME` and
  leaves ambient `CODEX_HOME` (and therefore its `mcp_servers`) in the
  launched adapter environment.

  Fixed behavior: each session gets a private 0700 `CODEX_HOME` under
  the runtime-home root, seeded with auth only, and a config.toml that
  does not contain the pre-seeded ambient `mcp_servers` entry.
  """
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.{Config, RuntimeHome}

  @moduletag :fast
  @moduletag :security_regression

  @ambient_mcp_marker "must-not-load-ambient-mcp"
  @ambient_config """
  [mcp_servers.ambient]
  command = "npx"
  args = ["-y", "#{@ambient_mcp_marker}"]
  """

  @fake_auth_json ~s({"tokens":{"access_token":"arbor-codex-test-token"}})

  defmodule ProbeClient do
    def start_link(opts) do
      {:ok, client} = Agent.start_link(fn -> opts end)
      send(opts[:test_pid], {:codex_probe_started, client, opts})
      {:ok, client}
    end

    def new_session(_client, _cwd, _opts),
      do: {:ok, %{"sessionId" => "codex-session"}}

    def set_config_option(_client, _session_id, _key, value),
      do: {:ok, %{"configOptions" => [%{"id" => "model", "currentValue" => value}]}}

    def disconnect(client) do
      if Process.alive?(client), do: Agent.stop(client, :normal)
      :ok
    end
  end

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "codex-acp-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    ambient_home = Path.join(root, "ambient-codex-home")
    File.mkdir!(ambient_home)
    File.chmod!(ambient_home, 0o700)
    File.write!(Path.join(ambient_home, "config.toml"), @ambient_config)
    File.chmod!(Path.join(ambient_home, "config.toml"), 0o600)

    auth_path = Path.join(root, "auth.json")
    File.write!(auth_path, @fake_auth_json)
    File.chmod!(auth_path, 0o600)

    prior_client = Application.get_env(:arbor_ai, :acp_client_module, :unset)
    prior_auth = Application.get_env(:arbor_ai, :codex_auth_file, :unset)

    Application.put_env(:arbor_ai, :acp_client_module, ProbeClient)
    Application.put_env(:arbor_ai, :codex_auth_file, auth_path)

    on_exit(fn ->
      restore_application_env(:acp_client_module, prior_client)
      restore_application_env(:codex_auth_file, prior_auth)
      File.rm_rf!(root)
    end)

    {:ok, root: root, ambient_home: ambient_home, auth_path: auth_path}
  end

  test "security regression: pre-seeded ~/.codex mcp_servers are not visible to inject",
       %{ambient_home: ambient_home, auth_path: auth_path} do
    assert {:ok, cleanup} = RuntimeHome.create()

    opts = [
      transport_mod: ExMCP.ACP.AdapterTransport,
      adapter: ExMCP.ACP.Adapters.Codex,
      adapter_opts: [
        model: "gpt-6-astra",
        environment_policy: :isolated,
        env: [{"CODEX_HOME", ambient_home}, {"KEEP_ME", "codex"}]
      ]
    ]

    assert {:ok, isolated_opts} = RuntimeHome.inject(opts, cleanup, :codex)

    env = isolated_opts |> Keyword.fetch!(:adapter_opts) |> Keyword.fetch!(:env) |> Map.new()
    codex_home = Map.fetch!(env, "CODEX_HOME")

    assert env["KEEP_ME"] == "codex"
    assert env["ARBOR_HOME"] == cleanup.path
    assert Path.dirname(codex_home) == cleanup.path
    refute codex_home == ambient_home

    assert_private_directory(codex_home)
    refute_ambient_mcp_visible(codex_home)
    assert_codex_mcp_override(isolated_opts)

    auth_dest = Path.join(codex_home, "auth.json")
    assert File.read!(auth_dest) == File.read!(auth_path)
    assert_private_file(auth_dest)
    assert File.read!(Path.join(ambient_home, "config.toml")) == @ambient_config

    assert :ok = RuntimeHome.cleanup(cleanup)
    refute File.exists?(cleanup.path)
    assert File.read!(auth_path) == @fake_auth_json
  end

  test "security regression: Arbor-launched Codex session cannot see ambient mcp_servers",
       %{ambient_home: ambient_home} do
    assert {:ok, configured_opts} = Config.resolve(:codex, [])

    client_opts =
      configured_opts
      |> put_adapter_env([{"CODEX_HOME", ambient_home}, {"KEEP_ME", "session"}])
      |> Keyword.put(:test_pid, self())

    assert {:ok, session} =
             AcpSession.start_link(
               provider: :codex,
               client_opts: client_opts,
               timeout: 1_000
             )

    assert_receive {:codex_probe_started, _client, started_opts}, 2_000
    assert :ok = AcpSession.await_ready(session, timeout: 2_000)

    env =
      started_opts
      |> Keyword.fetch!(:adapter_opts)
      |> Keyword.fetch!(:env)
      |> Map.new()

    runtime_home = :sys.get_state(session).runtime_home_cleanup.path
    codex_home = Map.fetch!(env, "CODEX_HOME")

    assert env["KEEP_ME"] == "session"
    assert env["ARBOR_HOME"] == runtime_home
    assert Path.dirname(codex_home) == runtime_home
    refute codex_home == ambient_home
    assert_private_directory(codex_home)
    refute_ambient_mcp_visible(codex_home)
    assert_codex_mcp_override(started_opts)
    refute File.read!(Path.join(codex_home, "config.toml")) == @ambient_config

    assert :ok = AcpSession.close(session)
    refute File.exists?(runtime_home)
    assert File.read!(Path.join(ambient_home, "config.toml")) =~ @ambient_mcp_marker
  end

  test "security regression: Codex isolation requires the adapter transport" do
    assert {:ok, cleanup} = RuntimeHome.create()

    assert {:error, :codex_runtime_adapter_transport_required} =
             RuntimeHome.inject([command: ["codex", "app-server"]], cleanup, :codex)

    assert :ok = RuntimeHome.cleanup(cleanup)
  end

  defp put_adapter_env(opts, values) do
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    env = Keyword.get(adapter_opts, :env, [])
    Keyword.put(opts, :adapter_opts, Keyword.put(adapter_opts, :env, env ++ values))
  end

  defp refute_ambient_mcp_visible(codex_home) do
    config_path = Path.join(codex_home, "config.toml")
    assert File.regular?(config_path)
    assert_private_file(config_path)
    content = File.read!(config_path)
    refute content =~ @ambient_mcp_marker
    refute content =~ "[mcp_servers"
    assert content =~ "mcp_servers = {}"
  end

  defp assert_codex_mcp_override(opts) do
    extra_args =
      opts
      |> Keyword.fetch!(:adapter_opts)
      |> Keyword.get(:extra_args, [])

    assert extra_args == ["-c", "mcp_servers={}"]
  end

  defp assert_private_file(path) do
    assert {:ok, %File.Stat{type: :regular, links: 1, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, 0o7777) == 0o600
  end

  defp assert_private_directory(path) do
    assert {:ok, %File.Stat{type: :directory, mode: mode}} = File.lstat(path)
    assert Bitwise.band(mode, 0o7777) == 0o700
  end

  defp restore_application_env(key, :unset), do: Application.delete_env(:arbor_ai, key)
  defp restore_application_env(key, value), do: Application.put_env(:arbor_ai, key, value)
end
