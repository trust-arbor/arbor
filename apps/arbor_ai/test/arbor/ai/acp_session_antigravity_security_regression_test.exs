defmodule Arbor.AI.AcpSessionAntigravitySecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.RuntimeHome

  @moduletag :fast
  @moduletag :security_regression

  defmodule ProbeClient do
    def start_link(opts) do
      {:ok, client} = Agent.start_link(fn -> opts end)
      send(opts[:test_pid], {:antigravity_probe_started, client, opts})
      {:ok, client}
    end

    def new_session(_client, _cwd, _opts),
      do: {:ok, %{"sessionId" => "antigravity-session"}}

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
        "antigravity-acp-test-" <>
          Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    prior_client = Application.get_env(:arbor_ai, :acp_client_module, :unset)
    prior_source = Application.get_env(:arbor_ai, :antigravity_acp_token_file, :unset)
    prior_env = System.get_env("ARBOR_ANTIGRAVITY_ACP_TOKEN_FILE")

    Application.put_env(:arbor_ai, :acp_client_module, ProbeClient)
    System.delete_env("ARBOR_ANTIGRAVITY_ACP_TOKEN_FILE")

    on_exit(fn ->
      restore_application_env(:acp_client_module, prior_client)
      restore_application_env(:antigravity_acp_token_file, prior_source)
      restore_system_env("ARBOR_ANTIGRAVITY_ACP_TOKEN_FILE", prior_env)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "security regression: replaces ambient HOME and GEMINI_HOME with one owned root",
       %{root: root} do
    source = write_token!(root, "source.json", token("selected-access", "selected-refresh"))
    Application.put_env(:arbor_ai, :antigravity_acp_token_file, source)

    ambient_home = Path.join(root, "ambient-home")
    ambient_gemini = Path.join(root, "ambient-gemini")
    File.mkdir!(ambient_home)
    File.mkdir!(ambient_gemini)
    File.write!(Path.join(ambient_gemini, "settings.json"), ~s({"ambient":"must-not-load"}))

    assert {:ok, cleanup} = RuntimeHome.create()

    opts = [
      command: ["antigravity-acp"],
      env: [
        {"HOME", ambient_home},
        {"GEMINI_HOME", ambient_gemini},
        {"AGY_ACP_FORCE_FILE_STORAGE", "0"},
        {"KEEP_ME", "yes"}
      ]
    ]

    assert {:ok, isolated_opts} = RuntimeHome.inject(opts, cleanup, :antigravity)
    assert :ok = RuntimeHome.stage_antigravity_credentials(cleanup)

    env = isolated_opts |> Keyword.fetch!(:env) |> Map.new()
    assert env["HOME"] == cleanup.path
    assert env["GEMINI_HOME"] == cleanup.path
    assert env["ARBOR_HOME"] == cleanup.path
    assert env["AGY_ACP_FORCE_FILE_STORAGE"] == "1"
    assert env["KEEP_ME"] == "yes"
    assert isolated_opts[:environment_policy] == :isolated

    settings_path = RuntimeHome.antigravity_settings_path(cleanup.path)
    token_path = RuntimeHome.antigravity_token_path(cleanup.path)

    assert Path.dirname(settings_path) == Path.dirname(token_path)
    assert Path.basename(settings_path) == "settings.json"
    assert File.read!(settings_path) == ~s({"auth":{"type":"oauth-personal"}})
    assert File.read!(token_path) == File.read!(source)
    assert_private_file(settings_path)
    assert_private_file(token_path)
    assert_private_directory(cleanup.path)
    assert_private_directory(Path.dirname(token_path))
    refute File.read!(settings_path) =~ "must-not-load"

    File.write!(Path.join(env["HOME"], "child-harness-write"), "inside")
    assert File.regular?(Path.join(cleanup.path, "child-harness-write"))
    refute File.exists?(Path.join(ambient_home, "child-harness-write"))

    assert :ok = RuntimeHome.cleanup(cleanup)
    refute File.exists?(cleanup.path)
    assert File.read!(source) =~ "selected-refresh"
  end

  test "security regression: inherited or alternate provider credentials are rejected",
       %{root: root} do
    source = write_token!(root, "source.json", token("client", "refresh"))
    Application.put_env(:arbor_ai, :antigravity_acp_token_file, source)

    for {extra_opts, expected} <- [
          {[environment_policy: :inherit], :antigravity_acp_runtime_isolation_required},
          {[env: [{"GEMINI_API_KEY", "ambient-secret"}]],
           :antigravity_acp_provider_env_forbidden},
          {[env: [{"AGY_ACP_BAIC_BASE_URL", "https://untrusted.invalid"}]],
           :antigravity_acp_provider_env_forbidden}
        ] do
      assert {:ok, cleanup} = RuntimeHome.create()

      opts =
        [command: ["antigravity-acp"]]
        |> Keyword.merge(extra_opts)

      assert {:error, ^expected} = RuntimeHome.inject(opts, cleanup, :antigravity)
      assert :ok = RuntimeHome.cleanup(cleanup)
    end
  end

  test "security regression: raw transport and permission-handler overrides cause zero provider IO",
       %{root: root} do
    source = write_token!(root, "source.json", token("client", "refresh"))
    Application.put_env(:arbor_ai, :antigravity_acp_token_file, source)

    for forbidden <- [
          [transport_mod: ProbeClient],
          [handler: ProbeClient],
          [handler_opts: [permission_mode: :bypass]],
          [args: ["--alternate-server"]]
        ] do
      client_opts =
        [command: ["antigravity-acp"], test_pid: self()]
        |> Keyword.merge(forbidden)

      assert {:ok, session} =
               AcpSession.start_link(provider: :antigravity, client_opts: client_opts)

      assert {:error, :antigravity_acp_runtime_native_transport_required} =
               AcpSession.await_ready(session, timeout: 2_000)

      refute_receive {:antigravity_probe_started, _client, _opts}, 50
      GenServer.stop(session)
    end
  end

  test "environment credential override wins over application config", %{root: root} do
    app_source = write_token!(root, "app.json", token("app-access", "app-refresh"))
    env_source = write_token!(root, "env.json", token("env-access", "env-refresh"))
    Application.put_env(:arbor_ai, :antigravity_acp_token_file, app_source)
    System.put_env("ARBOR_ANTIGRAVITY_ACP_TOKEN_FILE", env_source)

    assert {:ok, cleanup} = RuntimeHome.create()
    assert :ok = RuntimeHome.stage_antigravity_credentials(cleanup)

    projected = cleanup.path |> RuntimeHome.antigravity_token_path() |> File.read!()
    assert projected == File.read!(env_source)
    refute projected == File.read!(app_source)
    assert :ok = RuntimeHome.cleanup(cleanup)
  end

  test "security regression: reconnect rejects a schema-valid staged credential mutation", %{
    root: root
  } do
    source = write_token!(root, "source.json", token("operator-client", "operator-refresh"))
    Application.put_env(:arbor_ai, :antigravity_acp_token_file, source)

    assert {:ok, cleanup} = RuntimeHome.create()
    assert :ok = RuntimeHome.stage_antigravity_credentials(cleanup)

    runtime_token = RuntimeHome.antigravity_token_path(cleanup.path)
    File.write!(runtime_token, token("worker-client", "worker-refresh"))

    assert {:error, :antigravity_acp_runtime_attestation_failed} =
             RuntimeHome.verify_antigravity_runtime(cleanup)

    assert File.read!(source) =~ "operator-refresh"
    assert :ok = RuntimeHome.cleanup(cleanup)
  end

  test "security regression: unsafe credential sources fail closed", %{root: root} do
    valid = write_token!(root, "valid.json", token("access", "refresh"))

    symlink = Path.join(root, "symlink.json")
    File.ln_s!(valid, symlink)

    hardlink = Path.join(root, "hardlink.json")
    File.ln!(valid, hardlink)

    insecure = write_token!(root, "insecure.json", token("access", "refresh"))
    File.chmod!(insecure, 0o640)

    directory = Path.join(root, "directory.json")
    File.mkdir!(directory)

    cases = [
      {Path.join(root, "missing.json"), :antigravity_acp_credential_missing},
      {symlink, :antigravity_acp_credential_symlink},
      {hardlink, :antigravity_acp_credential_hardlinked},
      {insecure, :antigravity_acp_credential_insecure_mode},
      {directory, :antigravity_acp_credential_nonregular}
    ]

    for {source, expected} <- cases do
      Application.put_env(:arbor_ai, :antigravity_acp_token_file, source)
      assert {:ok, cleanup} = RuntimeHome.create()
      assert {:error, ^expected} = RuntimeHome.stage_antigravity_credentials(cleanup)
      assert :ok = RuntimeHome.cleanup(cleanup)
    end
  end

  test "security regression: malformed, incomplete, and oversized tokens fail closed",
       %{root: root} do
    cases = [
      {"malformed.json", "{", :antigravity_acp_credential_malformed},
      {"missing-refresh.json", Jason.encode!(%{"client_id" => "client"}),
       :antigravity_acp_credential_incomplete},
      {"nested.json",
       Jason.encode!(%{
         "client_id" => "client",
         "client_secret" => "secret",
         "project_id" => "project",
         "refresh_token" => "refresh",
         "scopes" => ["scope"],
         "token_uri" => "https://oauth2.googleapis.com/token",
         "configuration" => %{"ambient" => true}
       }), :antigravity_acp_credential_incomplete},
      {"invalid-scopes.json",
       Jason.encode!(%{
         "client_id" => "client",
         "client_secret" => "secret",
         "project_id" => "project",
         "refresh_token" => "refresh",
         "scopes" => "not-a-list",
         "token_uri" => "https://oauth2.googleapis.com/token"
       }), :antigravity_acp_credential_incomplete},
      {"oversized.json", String.duplicate("x", 65_537), :antigravity_acp_credential_too_large}
    ]

    for {name, bytes, expected} <- cases do
      source = write_token!(root, name, bytes)
      Application.put_env(:arbor_ai, :antigravity_acp_token_file, source)
      assert {:ok, cleanup} = RuntimeHome.create()
      assert {:error, ^expected} = RuntimeHome.stage_antigravity_credentials(cleanup)
      assert :ok = RuntimeHome.cleanup(cleanup)
    end
  end

  test "credential failure causes zero provider IO and successful close removes runtime", %{
    root: root
  } do
    missing = Path.join(root, "missing.json")
    Application.put_env(:arbor_ai, :antigravity_acp_token_file, missing)

    assert {:ok, failed_session} =
             AcpSession.start_link(
               provider: :antigravity,
               client_opts: [command: ["antigravity-acp"], test_pid: self()]
             )

    assert {:error, :antigravity_acp_credential_missing} =
             AcpSession.await_ready(failed_session, timeout: 2_000)

    refute_receive {:antigravity_probe_started, _client, _opts}, 100
    GenServer.stop(failed_session)

    source = write_token!(root, "working.json", token("access", "refresh"))
    Application.put_env(:arbor_ai, :antigravity_acp_token_file, source)

    assert {:ok, session} =
             AcpSession.start_link(
               provider: :antigravity,
               model: "observed-model",
               client_opts: [command: ["antigravity-acp"], test_pid: self()]
             )

    assert_receive {:antigravity_probe_started, _client, opts}, 2_000
    assert :ok = AcpSession.await_ready(session, timeout: 2_000)

    env = opts |> Keyword.fetch!(:env) |> Map.new()
    runtime_home = env["HOME"]
    assert env["GEMINI_HOME"] == runtime_home
    assert {:ok, _info} = AcpSession.create_session(session, timeout: 2_000)
    assert :ok = AcpSession.close(session)
    refute File.exists?(runtime_home)
  end

  defp token(access, refresh) do
    Jason.encode!(%{
      "client_id" => access,
      "client_secret" => "test-client-secret",
      "project_id" => "test-project-id",
      "refresh_token" => refresh,
      "scopes" => [
        "openid",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/cloud-platform"
      ],
      "token_uri" => "https://oauth2.googleapis.com/token"
    })
  end

  defp write_token!(root, name, bytes) do
    path = Path.join(root, name)
    File.write!(path, bytes)
    File.chmod!(path, 0o600)
    path
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

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)
end
