defmodule Arbor.AI.AcpSessionGrokOAuthSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.{Config, GrokSandbox, RuntimeHome}
  alias Arbor.LLM.OAuth

  @moduletag :fast
  @moduletag :security_regression
  @moduletag spec: "VOICE-6"

  defmodule ProbeClient do
    def start_link(opts) do
      {:ok, client} = Agent.start_link(fn -> opts end)
      send(opts[:test_pid], {:grok_probe_started, client, opts, payload(opts)})
      {:ok, client}
    end

    def auth_methods(client) do
      opts = Agent.get(client, & &1)

      {:ok,
       Keyword.get(opts, :auth_methods, [
         %{"id" => "grok.com", "name" => "Arbor", "description" => "Sign in with Arbor"}
       ])}
    end

    def authenticate(client, method_id, auth_opts) do
      opts = Agent.get(client, & &1)
      send(opts[:test_pid], {:grok_probe_authenticated, client, method_id, auth_opts})
      result = Keyword.get(opts, :auth_result, {:ok, %{}})

      if match?({:ok, _result}, result), do: write_external_auth_cache(opts)
      result
    end

    def new_session(_client, _cwd, _opts), do: {:ok, %{"sessionId" => "grok-probe-session"}}

    def load_session(client, session_id, _cwd, _opts) do
      opts = Agent.get(client, & &1)
      send(opts[:test_pid], {:grok_probe_loaded, client, session_id, payload(opts)})
      {:ok, %{"sessionId" => session_id}}
    end

    def set_config_option(_client, _session_id, _key, _value), do: :ok
    def cancel(_client, _session_id), do: :ok

    def disconnect(client) do
      if Process.alive?(client), do: Agent.stop(client, :normal)
      :ok
    end

    def prompt(client, _session_id, content, _opts) do
      opts = Agent.get(client, & &1)
      send(opts[:test_pid], {:grok_probe_prompt, self(), content, payload(opts)})

      if content == "hold" do
        receive do
          :release -> {:ok, %{"text" => "released"}}
        after
          5_000 -> {:error, :probe_timeout}
        end
      else
        {:ok, %{"text" => "ok"}}
      end
    end

    defp payload(opts) do
      env = opts |> Keyword.fetch!(:env) |> Map.new()
      env |> Map.fetch!("ARBOR_GROK_AUTH_PAYLOAD_PATH") |> File.read!() |> Jason.decode!()
    end

    defp write_external_auth_cache(opts) do
      env = opts |> Keyword.fetch!(:env) |> Map.new()
      grok_home = Map.fetch!(env, "GROK_HOME")
      access_token = Keyword.get(opts, :auth_cache_access_token, payload(opts)["access_token"])

      cache =
        Jason.encode!(%{
          "https://auth.x.ai::00000000-0000-4000-8000-000000000000" => %{
            "auth_mode" => "external",
            "expires_at" => "2026-08-03T23:59:59Z",
            "key" => access_token
          }
        })

      auth_path = Path.join(grok_home, "auth.json")
      lock_path = Path.join(grok_home, "auth.json.lock")
      File.write!(auth_path, cache)
      File.chmod!(auth_path, 0o600)
      File.write!(lock_path, "grok-lock-state\n")
      File.chmod!(lock_path, 0o644)
    end
  end

  defmodule MissingAuthClient do
    def start_link(opts) do
      {:ok, client} = Agent.start_link(fn -> opts end)
      send(opts[:test_pid], {:grok_missing_auth_client_started, client})
      {:ok, client}
    end
  end

  setup do
    app_keys = [
      {:arbor_ai, :acp_client_module},
      {:arbor_llm, :oauth_store_dir},
      {:arbor_llm, :oauth_refresh_fun}
    ]

    prior =
      Map.new(app_keys, fn {app, key} -> {{app, key}, Application.get_env(app, key, :unset)} end)

    root = Path.join(System.tmp_dir!(), "grok-external-auth-#{unique_suffix()}")
    store = Path.join(root, "oauth")
    File.mkdir_p!(store)
    Application.put_env(:arbor_ai, :acp_client_module, ProbeClient)
    Application.put_env(:arbor_llm, :oauth_store_dir, store)
    Application.delete_env(:arbor_llm, :oauth_refresh_fun)

    on_exit(fn ->
      Enum.each(prior, fn
        {{app, key}, :unset} -> Application.delete_env(app, key)
        {{app, key}, value} -> Application.put_env(app, key, value)
      end)

      File.rm_rf!(root)
    end)

    {:ok, root: root, store: store}
  end

  test "security regression: hostile source auth is unchanged and absent from the worker",
       %{root: root} do
    access = jwt(System.system_time(:second) + 7_200, "access-a")
    refresh = "hostile-refresh-#{unique_suffix()}"
    publish_xai!(access, "arbor-refresh-a")

    source_home = Path.join(root, "operator-grok")
    File.mkdir_p!(source_home)
    source_path = Path.join(source_home, "auth.json")
    source_bytes = Jason.encode!(%{"access_token" => "hostile", "refresh_token" => refresh})
    File.write!(source_path, source_bytes)
    File.chmod!(source_path, 0o600)
    source_identity = file_identity(source_path)
    prior_home = System.get_env("GROK_HOME")
    System.put_env("GROK_HOME", source_home)
    on_exit(fn -> restore_env("GROK_HOME", prior_home) end)

    workspace = standalone_workspace!(root, "sentinel")
    session = start_grok_session!(workspace)
    assert_receive {:grok_probe_started, client, started_opts, payload}, 2_000
    assert_grok_authenticated(client)
    assert :ok = AcpSession.await_ready(session, timeout: 2_000)
    refute_grok_auth_cache(started_opts)

    env = started_opts |> Keyword.fetch!(:env) |> Map.new()
    command = Keyword.fetch!(started_opts, :command)
    grok_home = Map.fetch!(env, "GROK_HOME")
    runtime_home = Path.dirname(grok_home)

    assert payload == %{"access_token" => access, "expires_in" => 300}
    assert File.read!(source_path) == source_bytes
    refute File.exists?(Path.join(grok_home, "auth.json"))
    refute inspect(env) =~ access
    refute inspect(env) =~ refresh
    refute inspect(command) =~ access
    refute inspect(command) =~ refresh
    refute inspect(AcpSession.status(session)) =~ refresh
    refute runtime_regular_file_bytes(runtime_home) =~ refresh
    assert Process.alive?(client)
    assert file_identity(source_path) == source_identity

    assert :ok = AcpSession.close(session)
    refute File.exists?(runtime_home)
    assert File.read!(source_path) == source_bytes
    assert file_identity(source_path) == source_identity
  end

  test "security regression: launch reconnect every prompt and owner follow-up refresh projection",
       %{root: root} do
    workspace = standalone_workspace!(root, "boundaries")
    access_a = jwt(System.system_time(:second) + 7_200, "access-a")
    publish_xai!(access_a, "refresh-a")
    session = start_grok_session!(workspace)

    assert_receive {:grok_probe_started, first_client, first_opts,
                    %{"access_token" => ^access_a}},
                   2_000

    assert_grok_authenticated(first_client)
    assert :ok = AcpSession.await_ready(session, timeout: 2_000)
    refute_grok_auth_cache(first_opts)

    assert {:ok, %{"sessionId" => "grok-probe-session"}} =
             AcpSession.create_session(session, timeout: 2_000)

    access_b = jwt(System.system_time(:second) + 7_200, "access-b")
    publish_xai!(access_b, "refresh-b")
    assert {:ok, %{"text" => "ok"}} = AcpSession.send_message(session, "one", timeout: 2_000)
    assert_grok_authenticated(first_client)
    assert_receive {:grok_probe_prompt, _worker, "one", %{"access_token" => ^access_b}}, 2_000
    refute_grok_auth_cache(first_opts)

    access_c = jwt(System.system_time(:second) + 7_200, "access-c")
    publish_xai!(access_c, "refresh-c")
    assert {:ok, %{"text" => "ok"}} = AcpSession.send_message(session, "two", timeout: 2_000)
    assert_grok_authenticated(first_client)
    assert_receive {:grok_probe_prompt, _worker, "two", %{"access_token" => ^access_c}}, 2_000
    refute_grok_auth_cache(first_opts)

    access_d = jwt(System.system_time(:second) + 7_200, "access-d")
    publish_xai!(access_d, "refresh-d")
    Process.exit(first_client, :kill)

    assert_receive {:grok_probe_started, reconnect_client, reconnect_opts,
                    %{"access_token" => ^access_d}},
                   2_000

    assert_grok_authenticated(reconnect_client)
    refute_grok_auth_cache(reconnect_opts)

    assert_receive {:grok_probe_loaded, ^reconnect_client, "grok-probe-session",
                    %{"access_token" => ^access_d}},
                   2_000

    caller = Task.async(fn -> AcpSession.send_message(session, "hold", timeout: 5_000) end)
    assert_grok_authenticated(reconnect_client)
    assert_receive {:grok_probe_prompt, hold_worker, "hold", _payload}, 2_000
    refute_grok_auth_cache(reconnect_opts)

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(session, %{
               "control_id" => "oauth-follow-up",
               "message" => "follow-up",
               "task_id" => "task-oauth"
             })

    access_e = jwt(System.system_time(:second) + 7_200, "access-e")
    publish_xai!(access_e, "refresh-e")
    send(hold_worker, :release)

    assert_grok_authenticated(reconnect_client)

    assert_receive {:grok_probe_prompt, _worker, "follow-up", %{"access_token" => ^access_e}},
                   2_000

    refute_grok_auth_cache(reconnect_opts)

    assert {:ok, %{"text" => "ok"}} = Task.await(caller, 5_000)

    assert :ok = AcpSession.close(session)
  end

  test "security regression: prompt refresh accepts bounded provider cache recreated while idle",
       %{root: root} do
    workspace = standalone_workspace!(root, "idle-cache")
    access_a = jwt(System.system_time(:second) + 7_200, "idle-access-a")
    publish_xai!(access_a, "idle-refresh-a")
    session = start_grok_session!(workspace)

    assert_receive {:grok_probe_started, client, opts, %{"access_token" => ^access_a}}, 2_000
    assert_grok_authenticated(client)
    assert :ok = AcpSession.await_ready(session, timeout: 2_000)
    refute_grok_auth_cache(opts)

    assert {:ok, %{"sessionId" => "grok-probe-session"}} =
             AcpSession.create_session(session, timeout: 2_000)

    write_grok_auth_cache!(opts, access_a)
    assert File.regular?(Path.join(grok_home(opts), "auth.json"))
    assert File.regular?(Path.join(grok_home(opts), "auth.json.lock"))

    access_b = jwt(System.system_time(:second) + 7_200, "idle-access-b")
    publish_xai!(access_b, "idle-refresh-b")

    assert {:ok, %{"text" => "ok"}} =
             AcpSession.send_message(session, "after-idle", timeout: 2_000)

    assert_grok_authenticated(client)

    assert_receive {:grok_probe_prompt, _worker, "after-idle", %{"access_token" => ^access_b}},
                   2_000

    refute_grok_auth_cache(opts)
    assert :ok = AcpSession.close(session)
  end

  test "security regression: missing projection and launch resolver failure cause zero provider IO",
       %{root: root, store: store} do
    workspace = standalone_workspace!(root, "failures")

    session = start_grok_session!(workspace)

    assert {:error, :grok_external_auth_unavailable} =
             AcpSession.await_ready(session, timeout: 2_000)

    refute_receive {:grok_probe_started, _client, _opts, _payload}, 100
    GenServer.stop(session)

    access = jwt(System.system_time(:second) + 7_200, "access-valid")
    publish_xai!(access, "refresh-valid")
    session = start_grok_session!(workspace)
    assert_receive {:grok_probe_started, client, opts, _payload}, 2_000
    assert_grok_authenticated(client)
    assert :ok = AcpSession.await_ready(session, timeout: 2_000)
    refute_grok_auth_cache(opts)
    assert {:ok, _} = AcpSession.create_session(session, timeout: 2_000)

    payload_path =
      opts |> Keyword.fetch!(:env) |> Map.new() |> Map.fetch!("ARBOR_GROK_AUTH_PAYLOAD_PATH")

    File.rm!(payload_path)

    assert {:error, :grok_external_auth_unavailable} =
             AcpSession.send_message(session, "must-not-run", timeout: 2_000)

    refute File.exists?(payload_path)
    refute_receive {:grok_probe_prompt, _worker, "must-not-run", _payload}, 100

    assert :ok = AcpSession.close(session)
    File.rm!(Path.join(store, "xai.json"))
  end

  test "security regression: Grok auth advertisement and authentication fail closed",
       %{root: root} do
    publish_xai!(jwt(System.system_time(:second) + 7_200, "auth-method"), "refresh-auth")
    workspace = standalone_workspace!(root, "auth-method")

    wrong_method_session =
      start_grok_session!(workspace,
        auth_methods: [%{"id" => "grok.com", "name" => "Unexpected"}]
      )

    assert_receive {:grok_probe_started, wrong_client, _opts, _payload}, 2_000

    assert {:error, :grok_external_auth_unavailable} =
             AcpSession.await_ready(wrong_method_session, timeout: 2_000)

    refute_receive {:grok_probe_authenticated, ^wrong_client, _method_id, _auth_opts}, 100
    refute inspect(AcpSession.status(wrong_method_session)) =~ "refresh-auth"
    GenServer.stop(wrong_method_session)

    sentinel = "auth-rejection-sentinel-#{unique_suffix()}"

    rejected_session =
      start_grok_session!(workspace, auth_result: {:error, %{"message" => sentinel}})

    assert_receive {:grok_probe_started, rejected_client, _opts, _payload}, 2_000
    assert_grok_authenticated(rejected_client)

    assert {:error, :grok_external_auth_unavailable} =
             AcpSession.await_ready(rejected_session, timeout: 2_000)

    refute inspect(AcpSession.status(rejected_session)) =~ sentinel
    refute_receive {:grok_probe_prompt, _worker, _content, _payload}, 100
    GenServer.stop(rejected_session)

    cache_sentinel = "cache-sentinel-#{unique_suffix()}"

    mismatched_cache_session =
      start_grok_session!(workspace, auth_cache_access_token: cache_sentinel)

    assert_receive {:grok_probe_started, cache_client, cache_opts, _payload}, 2_000
    assert_grok_authenticated(cache_client)

    assert {:error, :grok_external_auth_unavailable} =
             AcpSession.await_ready(mismatched_cache_session, timeout: 2_000)

    refute inspect(AcpSession.status(mismatched_cache_session)) =~ cache_sentinel
    refute File.exists?(Path.dirname(grok_home(cache_opts)))
    GenServer.stop(mismatched_cache_session)
  end

  test "security regression: Grok client missing ACP authentication fails closed",
       %{root: root} do
    publish_xai!(jwt(System.system_time(:second) + 7_200, "missing-auth"), "refresh-missing")
    workspace = standalone_workspace!(root, "missing-auth")
    Application.put_env(:arbor_ai, :acp_client_module, MissingAuthClient)

    session = start_grok_session!(workspace)
    assert_receive {:grok_missing_auth_client_started, client}, 2_000

    assert {:error, :grok_external_auth_unavailable} =
             AcpSession.await_ready(session, timeout: 2_000)

    refute Process.alive?(client)
    refute inspect(AcpSession.status(session)) =~ "refresh-missing"
    GenServer.stop(session)
  end

  test "security regression: resolver failure refuses prompt reconnect and follow-up IO",
       %{root: root, store: store} do
    workspace = standalone_workspace!(root, "resolver-boundaries")

    publish_xai!(jwt(System.system_time(:second) + 7_200, "prompt"), "refresh-prompt")
    prompt_session = start_grok_session!(workspace)
    assert_receive {:grok_probe_started, prompt_client, prompt_opts, _payload}, 2_000
    assert_grok_authenticated(prompt_client)
    assert :ok = AcpSession.await_ready(prompt_session, timeout: 2_000)
    refute_grok_auth_cache(prompt_opts)
    assert {:ok, _} = AcpSession.create_session(prompt_session, timeout: 2_000)
    prompt_payload = auth_payload_path(prompt_opts)
    File.rm!(Path.join(store, "xai.json"))

    assert {:error, :grok_external_auth_unavailable} =
             AcpSession.send_message(prompt_session, "resolver-must-not-run", timeout: 2_000)

    assert File.regular?(prompt_payload)
    refute_receive {:grok_probe_prompt, _worker, "resolver-must-not-run", _payload}, 100
    assert :ok = AcpSession.close(prompt_session)

    publish_xai!(jwt(System.system_time(:second) + 7_200, "reconnect"), "refresh-reconnect")
    reconnect_session = start_grok_session!(workspace)
    assert_receive {:grok_probe_started, reconnect_client, reconnect_opts, _payload}, 2_000
    assert_grok_authenticated(reconnect_client)
    assert :ok = AcpSession.await_ready(reconnect_session, timeout: 2_000)
    refute_grok_auth_cache(reconnect_opts)
    assert {:ok, _} = AcpSession.create_session(reconnect_session, timeout: 2_000)
    File.rm!(Path.join(store, "xai.json"))
    Process.exit(reconnect_client, :kill)
    assert_eventually(fn -> AcpSession.status(reconnect_session).status == :error end)
    refute_receive {:grok_probe_started, _client, _opts, _payload}, 100
    assert :ok = AcpSession.close(reconnect_session)

    publish_xai!(jwt(System.system_time(:second) + 7_200, "follow-up"), "refresh-follow-up")
    follow_up_session = start_grok_session!(workspace)
    assert_receive {:grok_probe_started, follow_up_client, follow_up_opts, _payload}, 2_000
    assert_grok_authenticated(follow_up_client)
    assert :ok = AcpSession.await_ready(follow_up_session, timeout: 2_000)
    refute_grok_auth_cache(follow_up_opts)
    assert {:ok, _} = AcpSession.create_session(follow_up_session, timeout: 2_000)

    caller =
      Task.async(fn -> AcpSession.send_message(follow_up_session, "hold", timeout: 5_000) end)

    assert_grok_authenticated(follow_up_client)
    assert_receive {:grok_probe_prompt, hold_worker, "hold", _payload}, 2_000
    refute_grok_auth_cache(follow_up_opts)

    assert {:ok, :queued, :same_session_follow_up} =
             AcpSession.deliver_task_control(follow_up_session, %{
               "control_id" => "resolver-failure-follow-up",
               "message" => "follow-up-must-not-run",
               "task_id" => "task-resolver-failure"
             })

    File.rm!(Path.join(store, "xai.json"))
    send(hold_worker, :release)

    assert {:error, :grok_external_auth_unavailable} = Task.await(caller, 5_000)
    refute_receive {:grok_probe_prompt, _worker, "follow-up-must-not-run", _payload}, 100
    assert :ok = AcpSession.close(follow_up_session)
  end

  test "security regression: launch attestation rejects payload and environment tampering",
       %{root: root} do
    publish_xai!(jwt(System.system_time(:second) + 7_200, "access-attested"), "refresh-attested")
    workspace = standalone_workspace!(root, "attestation")

    mutations = [
      fn payload, opts ->
        File.chmod!(payload, 0o640)
        opts
      end,
      fn payload, opts ->
        File.write!(payload, "not-json")
        opts
      end,
      fn payload, opts ->
        File.write!(
          payload,
          Jason.encode!(%{"access_token" => "x", "expires_in" => 1, "extra" => true})
        )

        opts
      end,
      fn payload, opts ->
        File.write!(payload, Jason.encode!(%{"access_token" => "x", "expires_in" => 301}))
        opts
      end,
      fn _payload, opts -> put_env(opts, "ARBOR_GROK_AUTH_PAYLOAD_PATH", "/tmp/wrong") end,
      fn _payload, opts -> put_env(opts, "GROK_AUTH_PROVIDER_COMMAND", "/bin/false") end,
      fn _payload, opts -> put_env(opts, "XAI_API_KEY", "ambient-secret") end,
      fn payload, opts ->
        File.rm!(payload)
        File.mkdir!(payload)
        opts
      end,
      fn payload, opts ->
        outside = payload <> ".outside"
        File.write!(outside, Jason.encode!(%{"access_token" => "x", "expires_in" => 1}))
        File.rm!(payload)
        File.ln_s!(outside, payload)
        opts
      end,
      fn payload, opts ->
        outside = payload <> ".hardlink"
        File.write!(outside, Jason.encode!(%{"access_token" => "x", "expires_in" => 1}))
        File.rm!(payload)
        File.ln!(outside, payload)
        opts
      end,
      fn _payload, opts ->
        env = Keyword.fetch!(opts, :env)
        Keyword.put(opts, :env, env ++ [{"XAI_API_KEY", ""}])
      end,
      fn payload, opts ->
        File.write!(Path.join(Path.dirname(payload), "auth.json"), "legacy")
        opts
      end,
      fn payload, opts ->
        File.write!(Path.join(Path.dirname(payload), "auth.json.lock"), "")
        opts
      end
    ]

    for mutate <- mutations do
      {cleanup, opts, payload} = staged_opts!()
      mutated = mutate.(payload, opts)

      assert {:error, _reason} =
               GrokSandbox.with_launch(:grok, mutated, workspace, nil, self(), fn _ ->
                 flunk("provider callback must not run")
               end)

      assert :ok = RuntimeHome.cleanup(cleanup)
    end
  end

  defp start_grok_session!(workspace, overrides \\ []) do
    assert {:ok, opts} = Config.resolve(:grok, [])
    opts = opts |> Keyword.merge(overrides) |> Keyword.put(:test_pid, self())

    assert {:ok, session} =
             AcpSession.start_link(provider: :grok, client_opts: opts, cwd: workspace)

    session
  end

  defp assert_grok_authenticated(client) do
    assert_receive {:grok_probe_authenticated, ^client, "grok.com", auth_opts}, 2_000
    assert is_integer(auth_opts[:timeout])
    assert auth_opts[:timeout] > 0
  end

  defp staged_opts! do
    assert {:ok, cleanup} = RuntimeHome.create()
    assert {:ok, base} = Config.resolve(:grok, [])
    assert {:ok, opts} = RuntimeHome.inject(base, cleanup, :grok)
    assert :ok = RuntimeHome.stage_grok_external_auth(cleanup)
    env = opts |> Keyword.fetch!(:env) |> Map.new()
    {cleanup, opts, Map.fetch!(env, "ARBOR_GROK_AUTH_PAYLOAD_PATH")}
  end

  defp put_env(opts, key, value) do
    env = opts |> Keyword.fetch!(:env) |> Enum.reject(fn {candidate, _} -> candidate == key end)
    Keyword.put(opts, :env, env ++ [{key, value}])
  end

  defp auth_payload_path(opts) do
    opts |> Keyword.fetch!(:env) |> Map.new() |> Map.fetch!("ARBOR_GROK_AUTH_PAYLOAD_PATH")
  end

  defp grok_home(opts) do
    opts |> Keyword.fetch!(:env) |> Map.new() |> Map.fetch!("GROK_HOME")
  end

  defp write_grok_auth_cache!(opts, access_token) do
    home = grok_home(opts)

    cache =
      Jason.encode!(%{
        "https://auth.x.ai::00000000-0000-4000-8000-000000000000" => %{
          "auth_mode" => "external",
          "expires_at" => "2026-08-03T23:59:59Z",
          "key" => access_token
        }
      })

    auth_path = Path.join(home, "auth.json")
    lock_path = Path.join(home, "auth.json.lock")
    File.write!(auth_path, cache)
    File.chmod!(auth_path, 0o600)
    File.write!(lock_path, "grok-lock-state\n")
    File.chmod!(lock_path, 0o644)
  end

  defp refute_grok_auth_cache(opts) do
    home = grok_home(opts)
    assert {:error, :enoent} = File.lstat(Path.join(home, "auth.json"))
    assert {:error, :enoent} = File.lstat(Path.join(home, "auth.json.lock"))
  end

  defp publish_xai!(access, refresh) do
    assert {:ok, credential} =
             OAuth.AcquiredCredential.new(%{
               provider: :xai,
               access_token: access,
               refresh_token: refresh
             })

    assert :ok = OAuth.publish_arbor_owned(:xai_oauth, credential)
  end

  defp standalone_workspace!(root, suffix) do
    workspace = Path.join(root, "workspace-#{suffix}")
    File.mkdir_p!(Path.join(workspace, ".git"))
    workspace
  end

  defp runtime_regular_file_bytes(root) do
    root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map_join(fn name ->
      path = Path.join(root, name)

      case File.lstat!(path) do
        %File.Stat{type: :regular, size: size} when size <= 65_600 -> File.read!(path)
        %File.Stat{type: :directory} -> runtime_regular_file_bytes(path)
        _ -> ""
      end
    end)
  end

  defp file_identity(path) do
    stat = File.lstat!(path)

    {stat.type, stat.mode, stat.size, stat.mtime, stat.ctime, stat.major_device,
     stat.minor_device, stat.inode, stat.links}
  end

  defp assert_eventually(fun, attempts \\ 50)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp jwt(exp, marker) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)

    payload =
      Base.url_encode64(Jason.encode!(%{"exp" => exp, "marker" => marker}), padding: false)

    "#{header}.#{payload}.sig"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp unique_suffix,
    do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
end
