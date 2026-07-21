defmodule Arbor.AI.AcpSessionTest do
  # async: false — the Handler describes inject :arbor_ai app-env (file_guard /
  # security module) to exercise authorized file ops without a real grant, after
  # the H3 anonymous-access fix made nil-agent callbacks fail closed.
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.Config
  alias Arbor.AI.AcpSession.RuntimeHome
  alias Arbor.AI.AcpManaged
  alias Arbor.AI.AcpManaged.SessionRegistry

  @moduletag :fast

  # Passthrough authz stubs: stand in for a granted agent so the Handler's
  # workspace/path-validation behavior can be tested without a CapabilityStore
  # grant. (The anonymous nil-agent path now fails closed — see
  # handler_authz_failclosed_test.exs.)
  defmodule PassthroughFileGuard do
    @moduledoc false
    def authorize(_agent_id, path, _op), do: {:ok, path}
  end

  defmodule PassthroughSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _action, _opts), do: {:ok, :authorized}
  end

  defmodule SlowCallServer do
    @moduledoc false
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok)
    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(_message, _from, state) do
      Process.sleep(40)
      {:reply, {:ok, %{}}, state}
    end
  end

  defmodule FakeUsageClient do
    @moduledoc false

    def start_link(opts), do: Agent.start_link(fn -> opts end)

    def new_session(_client, _cwd, _opts), do: {:ok, %{"sessionId" => "fake-session"}}
    def load_session(_client, session_id, _cwd, _opts), do: {:ok, %{"sessionId" => session_id}}
    def set_config_option(_client, _session_id, _key, _value), do: :ok
    def cancel(_client, _session_id), do: :ok

    def disconnect(client) do
      Agent.stop(client, :normal)
      :ok
    end

    def prompt(client, _session_id, _content, _opts) do
      result =
        Agent.get_and_update(client, fn state ->
          case Keyword.get(state, :results, []) do
            [next | rest] -> {next, Keyword.put(state, :results, rest)}
            [] -> {Keyword.get(state, :default_result, %{"text" => "ok"}), state}
          end
        end)

      {:ok, result}
    end
  end

  defmodule FakeProgressClient do
    @moduledoc false

    def start_link(opts) do
      case opts[:start_mode] do
        :stall ->
          send(opts[:test_pid], {:fake_start_stalled, self()})
          Process.sleep(:infinity)

        _other ->
          Agent.start_link(fn -> %{opts: opts} end)
      end
    end

    def new_session(client, cwd, opts) do
      state = Agent.get(client, & &1)
      send(state.opts[:test_pid], {:fake_new_session, cwd})
      send(state.opts[:test_pid], {:fake_new_session_opts, opts})

      case state.opts[:new_session_mode] do
        :stall ->
          send(state.opts[:test_pid], {:fake_new_session_stalled, self()})
          Process.sleep(:infinity)

        :throw ->
          throw({:hostile_new_session, :erlang.bsl(1, 1_000_000)})

        :exit ->
          exit({:hostile_new_session, :erlang.bsl(1, 1_000_000)})

        _other ->
          {:ok, %{"sessionId" => "fake-session"}}
      end
    end

    def load_session(client, session_id, _cwd, opts) do
      state = Agent.get(client, & &1)
      send(state.opts[:test_pid], {:fake_load_session_opts, opts})

      case state.opts[:resume_mode] do
        :stall ->
          send(state.opts[:test_pid], {:fake_resume_stalled, self()})
          Process.sleep(:infinity)

        _other ->
          {:ok, %{"sessionId" => session_id}}
      end
    end

    def set_config_option(_client, _session_id, _key, _value), do: :ok

    def disconnect(client) do
      test_pid = test_pid(client)
      send(test_pid, {:fake_disconnect, client})

      state = Agent.get(client, & &1)

      case state.opts[:disconnect_mode] do
        :stall ->
          send(test_pid, {:fake_disconnect_stalled, self()})
          Process.sleep(:infinity)

        _other ->
          Agent.stop(client, :normal)
          :ok
      end
    end

    def cancel(client, session_id) do
      send(test_pid(client), {:fake_cancel, session_id})
      :ok
    end

    def prompt(client, session_id, content, opts) do
      state = Agent.get(client, & &1)
      listener = state.opts[:event_listener]
      send(state.opts[:test_pid], {:fake_prompt_started, self(), content, opts})

      case content do
        "stall" ->
          receive do
            :release -> {:ok, %{"text" => "released"}}
          after
            5_000 -> {:ok, %{"text" => "late"}}
          end

        "steady_progress" ->
          for sequence <- 1..5 do
            Process.sleep(15)
            send_progress(listener, session_id, sequence)
          end

          {:ok, %{"text" => "done"}}

        "progress_forever" ->
          progress_forever(listener, session_id)

        _ ->
          {:ok, %{"text" => "ok"}}
      end
    end

    defp progress_forever(listener, session_id) do
      send_progress(listener, session_id, nil)
      Process.sleep(10)
      progress_forever(listener, session_id)
    end

    defp send_progress(listener, session_id, sequence) do
      send(
        listener,
        {:acp_session_update, session_id,
         %{
           "sessionUpdate" => "agent_message_chunk",
           "content" => %{"text" => "."},
           "sequence" => sequence
         }}
      )
    end

    defp test_pid(client) do
      Agent.get(client, & &1.opts[:test_pid])
    end
  end

  defp install_passthrough_authz do
    original_file_guard = Application.get_env(:arbor_ai, :file_guard_module)
    original_security = Application.get_env(:arbor_ai, :security_module)

    Application.put_env(:arbor_ai, :file_guard_module, PassthroughFileGuard)
    Application.put_env(:arbor_ai, :security_module, PassthroughSecurity)

    on_exit(fn ->
      restore_env(:file_guard_module, original_file_guard)
      restore_env(:security_module, original_security)
    end)
  end

  defp install_fake_progress_client(inactivity_timeout_ms) do
    original_client = Application.get_env(:arbor_ai, :acp_client_module)
    original_inactivity = Application.get_env(:arbor_ai, :acp_inactivity_timeout_ms)

    Application.put_env(:arbor_ai, :acp_client_module, FakeProgressClient)
    Application.put_env(:arbor_ai, :acp_inactivity_timeout_ms, inactivity_timeout_ms)

    on_exit(fn ->
      restore_env(:acp_client_module, original_client)
      restore_env(:acp_inactivity_timeout_ms, original_inactivity)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_ai, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_ai, key, value)

  defp start_fake_progress_session do
    AcpSession.start_link(provider: :test, client_opts: [test_pid: self()])
  end

  test "security regression: ACP subprocesses cannot inherit the live Arbor home" do
    install_fake_progress_client(100)
    live_arbor_home = Path.join(System.tmp_dir!(), "must-not-reach-live-arbor-home")

    launch_cases = [
      native: [
        command: ["fake", "stdio"],
        env: [{"KEEP_ME", "native"}, {"ARBOR_HOME", live_arbor_home}],
        test_pid: self()
      ],
      adapted: [
        adapter: __MODULE__,
        adapter_opts: [
          env: [{"KEEP_ME", "adapted"}, {"ARBOR_HOME", live_arbor_home}]
        ],
        test_pid: self()
      ]
    ]

    Enum.each(launch_cases, fn {kind, client_opts} ->
      assert {:ok, session} =
               AcpSession.start_link(provider: :test, client_opts: client_opts, timeout: 1_000)

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      state = :sys.get_state(session)
      started_opts = Agent.get(state.client, & &1.opts)

      env =
        case kind do
          :native -> Keyword.fetch!(started_opts, :env)
          :adapted -> started_opts |> Keyword.fetch!(:adapter_opts) |> Keyword.fetch!(:env)
        end

      env = Map.new(env, fn {key, value} -> {to_string(key), value} end)
      runtime_home = Map.fetch!(env, "ARBOR_HOME")

      assert env["KEEP_ME"] == Atom.to_string(kind)
      refute runtime_home == live_arbor_home
      assert Path.type(runtime_home) == :absolute
      assert state.runtime_home_cleanup.path == runtime_home
      assert {:ok, stat} = File.lstat(runtime_home)
      assert stat.type == :directory
      assert Bitwise.band(stat.mode, 0o777) == 0o700

      monitor = Process.monitor(session)
      assert :ok = AcpSession.close(session)
      assert_receive {:DOWN, ^monitor, :process, ^session, :normal}, 1_000
      refute File.exists?(runtime_home)
    end)
  end

  test "security regression: ACP session MCP servers cannot be widened per operation" do
    install_fake_progress_client(100)

    bound_server = %{
      "type" => "http",
      "name" => "arbor-tools",
      "url" => "http://127.0.0.1:41001/mcp"
    }

    hostile_server = %{
      "type" => "http",
      "name" => "ambient-host",
      "url" => "http://127.0.0.1:41002/mcp"
    }

    for bound <- [[], [bound_server]] do
      assert {:ok, session} =
               AcpSession.start_link(
                 provider: :test,
                 mcp_servers: bound,
                 client_opts: [test_pid: self()],
                 timeout: 1_000
               )

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, %{"sessionId" => "fake-session"}} =
               AcpSession.create_session(session,
                 mcp_servers: [hostile_server],
                 timeout: 1_000
               )

      assert_receive {:fake_new_session_opts, new_session_opts}
      assert Keyword.fetch!(new_session_opts, :mcp_servers) == bound

      assert {:ok, %{"sessionId" => "existing-session"}} =
               AcpSession.resume_session(session, "existing-session",
                 mcp_servers: [hostile_server],
                 timeout: 1_000
               )

      assert_receive {:fake_load_session_opts, load_session_opts}
      assert Keyword.fetch!(load_session_opts, :mcp_servers) == bound
      assert :ok = AcpSession.close(session)
    end
  end

  test "create_session uses directory workspace for provider session/new cwd" do
    install_fake_progress_client(100)
    workspace = temporary_directory("acp-session-cwd-workspace")

    assert {:ok, session} =
             AcpSession.start_link(
               provider: :test,
               client_opts: [test_pid: self()],
               timeout: 1_000
             )

    assert :ok = AcpSession.await_ready(session, timeout: 1_000)

    assert {:ok, %{"sessionId" => "fake-session"}} =
             AcpSession.create_session(session, workspace: {:directory, workspace})

    assert_receive {:fake_new_session, ^workspace}
    assert :ok = AcpSession.close(session)
  end

  test "create_session uses initialized directory workspace when cwd and workspace opts are absent" do
    install_fake_progress_client(100)
    workspace = temporary_directory("acp-session-initialized-workspace")

    assert {:ok, session} =
             AcpSession.start_link(
               provider: :test,
               workspace: {:directory, workspace},
               client_opts: [test_pid: self()],
               timeout: 1_000
             )

    assert :ok = AcpSession.await_ready(session, timeout: 1_000)
    assert {:ok, %{"sessionId" => "fake-session"}} = AcpSession.create_session(session)
    assert_receive {:fake_new_session, ^workspace}
    assert :ok = AcpSession.close(session)
  end

  test "create_session explicit cwd overrides directory workspace for provider session/new" do
    install_fake_progress_client(100)
    workspace = temporary_directory("acp-session-cwd-workspace")
    explicit_cwd = temporary_directory("acp-session-explicit-cwd")

    assert {:ok, session} =
             AcpSession.start_link(
               provider: :test,
               workspace: {:directory, workspace},
               client_opts: [test_pid: self()],
               timeout: 1_000
             )

    assert :ok = AcpSession.await_ready(session, timeout: 1_000)

    assert {:ok, %{"sessionId" => "fake-session"}} =
             AcpSession.create_session(session, cwd: explicit_cwd)

    assert_receive {:fake_new_session, ^explicit_cwd}
    assert :ok = AcpSession.close(session)
  end

  test "security regression: ACP clients cannot log raw debug notification payloads" do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    secret = "provider-secret-#{System.unique_integer([:positive])}"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, client} = ExMCP.ACP.Client.start_link(_skip_connect: true)

        send(client, {
          :transport_message,
          %{
            "jsonrpc" => "2.0",
            "method" => "_provider/settings/update",
            "params" => %{"credential" => secret}
          }
        })

        _state = :sys.get_state(client)
        GenServer.stop(client)
      end)

    refute log =~ secret
  end

  test "security regression: Grok receives an isolated config home without ambient MCPs" do
    install_fake_progress_client(100)

    source_home =
      Path.join(
        System.tmp_dir!(),
        "arbor-ai-grok-source-home-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(source_home)
    auth = ~s({"access_token":"test-only","refresh_token":"test-only"})
    File.write!(Path.join(source_home, "auth.json"), auth)
    File.chmod!(Path.join(source_home, "auth.json"), 0o600)

    File.write!(
      Path.join(source_home, "config.toml"),
      ~s([mcp_servers.ambient]\nurl = "http://127.0.0.1:4001/mcp"\n)
    )

    workspace = Path.join(source_home, "standalone-workspace")
    File.mkdir!(workspace)

    previous_grok_home = System.get_env("GROK_HOME")
    System.put_env("GROK_HOME", source_home)

    on_exit(fn ->
      if previous_grok_home,
        do: System.put_env("GROK_HOME", previous_grok_home),
        else: System.delete_env("GROK_HOME")

      File.rm_rf!(source_home)
    end)

    assert {:ok, configured_opts} = Config.resolve(:grok, [])

    client_opts =
      configured_opts
      |> Keyword.update(:env, [], fn env ->
        env ++ [{"RUST_LOG", "debug"}, {"GROK_LOG_FILE", "/tmp/unsafe-grok.log"}]
      end)
      |> Keyword.put(:test_pid, self())

    assert {:ok, session} =
             AcpSession.start_link(
               provider: :grok,
               client_opts: client_opts,
               cwd: workspace,
               timeout: 1_000
             )

    assert :ok = AcpSession.await_ready(session, timeout: 1_000)

    state = :sys.get_state(session)
    started_opts = Agent.get(state.client, & &1.opts)
    env = Map.new(Keyword.fetch!(started_opts, :env))
    grok_home = Map.fetch!(env, "GROK_HOME")

    assert Path.dirname(grok_home) == state.runtime_home_cleanup.path
    refute grok_home == source_home
    assert env["GROK_CLAUDE_MCPS_ENABLED"] == "false"
    assert env["GROK_CURSOR_MCPS_ENABLED"] == "false"
    assert env["GROK_CODEX_MCPS_ENABLED"] == "false"
    assert env["GROK_MANAGED_MCPS_ENABLED"] == "false"
    assert env["GROK_MCP_RECURSIVE_CONFIG_WATCH"] == "0"
    assert env["GROK_CLAUDE_HOOKS_ENABLED"] == "false"
    assert env["GROK_CURSOR_HOOKS_ENABLED"] == "false"
    assert env["GROK_CODEX_HOOKS_ENABLED"] == "false"
    assert env["GROK_OFFICIAL_MARKETPLACE_AUTO_REGISTER"] == "false"
    assert env["GROK_TELEMETRY_ENABLED"] == "false"
    assert env["GROK_FEEDBACK_ENABLED"] == "false"
    assert env["GROK_MEMORY"] == "0"
    assert env["GROK_SUBAGENTS"] == "0"
    assert env["GROK_WEB_FETCH"] == "0"
    assert env["RUST_LOG"] == "warn"
    assert env["GROK_LOG_FILE"] == Path.join(grok_home, "grok.log")

    assert File.read!(Path.join(grok_home, "auth.json")) == auth
    refute File.exists?(Path.join(grok_home, "config.toml"))

    assert {:ok, %File.Stat{type: :regular, mode: mode}} =
             File.lstat(Path.join(grok_home, "auth.json"))

    assert Bitwise.band(mode, 0o777) == 0o600

    command = Keyword.fetch!(started_opts, :command)
    assert "--no-subagents" in command
    assert "--disable-web-search" in command
    assert Enum.chunk_every(command, 2, 1, :discard) |> Enum.member?(["--deny", "MCPTool(*)"])

    refute "--disallowed-tools" in command
    refute "--tools" in command

    assert "--no-leader" in command
    profile_index = Enum.find_index(command, &(&1 == "--agent-profile"))
    profile_path = Enum.at(command, profile_index + 1)
    assert profile_path == RuntimeHome.grok_agent_profile_path(grok_home)
    assert {:ok, %File.Stat{type: :regular, mode: profile_mode}} = File.lstat(profile_path)
    assert Bitwise.band(profile_mode, 0o7777) == 0o600
    assert RuntimeHome.verify_grok_agent_profile(profile_path) == :ok

    runtime_home = state.runtime_home_cleanup.path
    assert :ok = AcpSession.close(session)
    refute File.exists?(runtime_home)
  end

  test "security regression: lifecycle aliases cannot widen the caller deadline" do
    server = start_supervised!(SlowCallServer)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             AcpSession.create_session(server, timeout: 100, receive_timeout: 5)

    assert System.monotonic_time(:millisecond) - started_at < 35
  end

  test "security regression: send_message queue wait consumes the original deadline" do
    server = start_supervised!(SlowCallServer)
    blocker = Task.async(fn -> GenServer.call(server, :occupy) end)
    Process.sleep(5)
    started_at = System.monotonic_time(:millisecond)

    assert {:error, :timeout} = AcpSession.send_message(server, "queued", timeout: 10)
    assert System.monotonic_time(:millisecond) - started_at < 35
    assert {:ok, %{}} = Task.await(blocker)
  end

  @tag timeout: 1_000
  test "security regression: pre-accept timeout cannot start an orphan prompt" do
    install_fake_progress_client(100)
    {:ok, session} = start_fake_progress_session()

    :ok = :sys.suspend(session)
    assert {:error, :timeout} = AcpSession.send_message(session, "must-not-start", timeout: 20)

    :ok = :sys.resume(session)
    refute_receive {:fake_prompt_started, _worker, "must-not-start", _opts}, 100
    assert %{status: :ready} = AcpSession.status(session)

    assert :ok = AcpSession.close(session)
  end

  test "send_message resolves local and via registered server identities" do
    install_fake_progress_client(100)

    local_name = :"acp_local_#{System.unique_integer([:positive])}"

    {:ok, local_session} =
      AcpSession.start_link(
        name: local_name,
        provider: :test,
        client_opts: [test_pid: self()]
      )

    assert {:ok, %{"text" => "ok"}} = AcpSession.send_message(local_name, "local")
    assert_receive {:fake_prompt_started, _worker, "local", _opts}
    assert :ok = AcpSession.close(local_name)
    refute Process.alive?(local_session)

    registry = :"acp_registry_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :unique, name: registry})
    via_name = {:via, Registry, {registry, :session}}

    {:ok, via_session} =
      AcpSession.start_link(
        name: via_name,
        provider: :test,
        client_opts: [test_pid: self()]
      )

    assert {:ok, %{"text" => "ok"}} = AcpSession.send_message(via_name, "via")
    assert_receive {:fake_prompt_started, _worker, "via", _opts}
    assert :ok = AcpSession.close(via_name)
    refute Process.alive?(via_session)

    assert {:error, :session_unavailable} =
             AcpSession.send_message(:missing_acp_session, "missing", timeout: 20)

    assert {:error, :session_unavailable} =
             AcpSession.send_message(
               {:via, Registry, {registry, :missing}},
               "missing-via",
               timeout: 20
             )
  end

  test "security regression: arbitrary-size absolute deadlines are rejected before calls" do
    server = start_supervised!(SlowCallServer)
    huge_deadline = :erlang.bsl(1, 1_000_000)

    assert {:error, :invalid_deadline} =
             AcpSession.send_message(server, "invalid", timeout: 100, deadline_ms: huge_deadline)
  end

  describe "Config.resolve/2" do
    test "resolves native ACP providers" do
      assert {:ok, opts} = Config.resolve(:gemini)
      assert opts[:command] == ["gemini", "--experimental-acp"]
    end

    test "resolves adapted providers" do
      assert {:ok, opts} = Config.resolve(:claude)
      assert opts[:transport_mod] == ExMCP.ACP.AdapterTransport
      assert opts[:adapter] == ExMCP.ACP.Adapters.ClaudeSDK
    end

    test "resolves codex adapter" do
      assert {:ok, opts} = Config.resolve(:codex)
      assert opts[:transport_mod] == ExMCP.ACP.AdapterTransport
      assert opts[:adapter] == ExMCP.ACP.Adapters.Codex
    end

    test "returns error for unknown provider" do
      assert {:error, {:unknown_provider, :nonexistent}} = Config.resolve(:nonexistent)
    end

    test "merges user options" do
      assert {:ok, opts} = Config.resolve(:gemini, model: "gemini-2.0", cwd: "/tmp")
      assert opts[:model] == "gemini-2.0"
      assert opts[:cwd] == "/tmp"
    end

    test "merges adapter_opts for adapted providers" do
      assert {:ok, opts} = Config.resolve(:claude, adapter_opts: [model: "opus"])
      assert Keyword.get(opts[:adapter_opts], :model) == "opus"
    end

    test "respects application config overrides" do
      original = Application.get_env(:arbor_ai, :acp_providers)

      try do
        Application.put_env(:arbor_ai, :acp_providers, %{
          custom_agent: %{command: ["my-agent", "--acp"]}
        })

        assert {:ok, opts} = Config.resolve(:custom_agent)
        assert opts[:command] == ["my-agent", "--acp"]
      after
        restore_env(:acp_providers, original)
      end
    end
  end

  describe "Config.list_providers/0" do
    test "lists native and adapted providers" do
      providers = Config.list_providers()
      provider_names = Enum.map(providers, &elem(&1, 0))

      assert :gemini in provider_names
      assert :opencode in provider_names
      assert :goose in provider_names
      assert :claude in provider_names
      assert :codex in provider_names
      assert :cursor in provider_names
    end

    test "marks providers correctly as native or adapted" do
      providers = Config.list_providers() |> Map.new()

      assert providers[:gemini] == :native
      assert providers[:claude] == :adapted
      assert providers[:codex] == :adapted
      # cursor-agent speaks ACP natively (`cursor-agent acp`) — no adapter shim.
      assert providers[:cursor] == :native
    end
  end

  describe "Config.resolve/2 for cursor (native ACP)" do
    test "resolves to a bare command, not an adapter transport" do
      assert {:ok, opts} = Config.resolve(:cursor, [])
      assert Keyword.get(opts, :command) == ["cursor-agent", "acp"]
      refute Keyword.has_key?(opts, :adapter)
      refute Keyword.has_key?(opts, :transport_mod)
    end

    test "is not adapted" do
      refute Config.adapted?(:cursor)
    end
  end

  describe "Config.adapted?/1" do
    test "claude is adapted" do
      assert Config.adapted?(:claude)
    end

    test "codex is adapted" do
      assert Config.adapted?(:codex)
    end

    test "gemini is not adapted" do
      refute Config.adapted?(:gemini)
    end

    test "unknown providers are not adapted" do
      refute Config.adapted?(:nonexistent)
    end
  end

  describe "AcpSession lifecycle" do
    # Use _skip_connect: true to avoid spawning real agent processes.
    # Pass client_opts directly to bypass config provider resolution.
    @test_client_opts [command: ["echo", "test"], _skip_connect: true]

    test "start_link requires :provider option" do
      Process.flag(:trap_exit, true)
      assert {:error, {%KeyError{key: :provider}, _stacktrace}} = AcpSession.start_link([])
    end

    test "starts successfully with test client opts" do
      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: @test_client_opts)

      status = AcpSession.status(session)
      assert status.provider == :test
      assert status.status == :ready

      GenServer.stop(session)
    end

    test "status returns provider and session info" do
      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "test-model",
          client_opts: @test_client_opts
        )

      status = AcpSession.status(session)
      assert status.provider == :test
      assert status.model == "test-model"
      assert status.session_id == nil
      assert status.status == :ready

      GenServer.stop(session)
    end

    test "close stops the session normally" do
      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: @test_client_opts)

      ref = Process.monitor(session)
      assert :ok = AcpSession.close(session)
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    end
  end

  defp temporary_directory(prefix) do
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{suffix}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  describe "AcpSession prompt timeout behavior" do
    @tag timeout: 1_000
    test "security regression: inactivity timeout preserves the handle in recovery until close" do
      install_fake_progress_client(30)

      {:ok, session} = start_fake_progress_session()
      ref = Process.monitor(session)

      registry = :"acp_recovery_registry_#{System.unique_integer([:positive])}"
      start_supervised!({SessionRegistry, name: registry})

      assert {:ok, registered} =
               SessionRegistry.register(
                 %{
                   session_pid: session,
                   session_module: AcpSession,
                   provider: :test,
                   session_id: "fake-session",
                   status: :ready,
                   pooled: false,
                   return_to_pool: false
                 },
                 server: registry
               )

      assert {:error, :inactivity_timeout} = AcpSession.send_message(session, "stall")

      assert_receive {:fake_prompt_started, worker, "stall", opts}
      assert Keyword.get(opts, :timeout) in 1..120_000
      assert_receive {:fake_cancel, "fake-session"}
      refute Process.alive?(worker)
      refute_receive {:fake_disconnect, _client}, 50
      refute_receive {:DOWN, ^ref, :process, ^session, _reason}, 50

      assert Process.alive?(session)

      assert %{status: :recovery_required, session_id: "fake-session"} =
               AcpSession.status(session)

      assert {:ok, resolved} =
               SessionRegistry.resolve(registered.worker_session_id, server: registry)

      assert resolved.session_pid == session

      assert {:ok, managed_status} =
               AcpManaged.session_status(registered.worker_session_id, server: registry)

      assert managed_status.status == "recovery_required"
      assert managed_status.session_id == "fake-session"
      refute Map.has_key?(managed_status, :client)
      refute Map.has_key?(managed_status, :opts)

      assert {:error, {:not_ready, :recovery_required}} =
               AcpSession.send_message(session, "must-not-run")

      assert {:error, {:not_ready, :recovery_required}} =
               AcpSession.create_session(session)

      send(
        session,
        {:acp_session_update, "fake-session",
         %{"sessionUpdate" => "agent_message_chunk", "content" => %{"text" => "late"}}}
      )

      _ = AcpSession.status(session)
      assert :sys.get_state(session).accumulated_text == ""
      refute_receive {:fake_prompt_started, _worker, "must-not-run", _opts}, 50

      assert {:ok, closed} =
               SessionRegistry.close(registered.worker_session_id, server: registry)

      assert closed.status == "closed"
      assert_receive {:fake_disconnect, _client}
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}

      assert {:error, :not_found} =
               SessionRegistry.resolve(registered.worker_session_id, server: registry)
    end

    @tag timeout: 1_000
    test "progress updates keep a prompt alive past the inactivity window" do
      install_fake_progress_client(40)

      {:ok, session} = start_fake_progress_session()

      assert {:ok, result} = AcpSession.send_message(session, "steady_progress")

      assert_receive {:fake_prompt_started, _worker, "steady_progress", opts}
      assert Keyword.get(opts, :timeout) in 1..120_000
      assert result["text"] == "done"
      assert Process.alive?(session)

      GenServer.stop(session)
    end

    @tag timeout: 1_000
    test "security regression: completed prompt cancels real timer handles and flushes mailbox" do
      # Layer-0 regression: synthetic make_ref() correlation tokens passed to
      # Process.cancel_timer/1 leave live send_after timers. After a fast prompt
      # succeeds, suspend the session before short hard/inactivity windows fire
      # and prove no timeout messages remain in the GenServer mailbox.
      install_fake_progress_client(40)

      {:ok, session} = start_fake_progress_session()

      on_exit(fn ->
        if Process.alive?(session) do
          try do
            :sys.resume(session)
          catch
            :exit, _ -> :ok
          end
        end

        safely_close_session(session)
      end)

      assert {:ok, %{"text" => "ok"}} =
               AcpSession.send_message(session, "hello",
                 timeout: 40,
                 inactivity_timeout_ms: 30
               )

      # Freeze the session before either short timer would fire so delivered
      # stale timeouts accumulate in the mailbox rather than handle_info/2.
      :sys.suspend(session)
      Process.sleep(80)

      messages =
        case Process.info(session, :messages) do
          {:messages, msgs} when is_list(msgs) -> msgs
          _other -> []
        end

      refute Enum.any?(messages, &prompt_timer_message?/1),
             "expected cancelled prompt timers to leave no mailbox residue, got: #{inspect(messages)}"

      :sys.resume(session)
      assert Process.alive?(session)
      assert :ok = AcpSession.close(session)
    end

    @tag timeout: 1_000
    test "explicit timeout is a hard wall-clock cap even while progress continues" do
      install_fake_progress_client(200)

      {:ok, session} = start_fake_progress_session()
      ref = Process.monitor(session)

      assert {:error, :timeout} =
               AcpSession.send_message(session, "progress_forever",
                 timeout: 50,
                 inactivity_timeout_ms: 200
               )

      assert_receive {:fake_prompt_started, worker, "progress_forever", opts}
      assert Keyword.get(opts, :timeout) in 1..50
      assert_receive {:fake_cancel, "fake-session"}
      refute Process.alive?(worker)
      refute_receive {:fake_disconnect, _client}, 50
      refute_receive {:DOWN, ^ref, :process, ^session, _reason}, 50

      assert %{status: :recovery_required, session_id: "fake-session"} =
               AcpSession.status(session)

      assert :ok = AcpSession.close(session)
      assert_receive {:fake_disconnect, _client}
      assert_receive {:DOWN, ^ref, :process, ^session, :normal}
    end

    @tag timeout: 1_000
    test "security regression: hard prompt deadline wins over stream callback timeout" do
      install_fake_progress_client(200)
      test_pid = self()

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          client_opts: [test_pid: self()],
          stream_callback: fn _update ->
            send(test_pid, :stream_callback_started)
            Process.sleep(100)
            :ok
          end
        )

      on_exit(fn -> safely_close_session(session) end)

      assert {:error, :timeout} =
               AcpSession.send_message(session, "steady_progress",
                 timeout: 50,
                 inactivity_timeout_ms: 200
               )

      assert_receive :stream_callback_started

      assert %{status: :recovery_required, session_id: "fake-session"} =
               AcpSession.status(session)
    end

    @tag timeout: 1_000
    test "security regression: late client DOWN cannot clear the recovery fence" do
      install_fake_progress_client(30)

      {:ok, session} = start_fake_progress_session()
      assert {:error, :inactivity_timeout} = AcpSession.send_message(session, "stall")

      client = :sys.get_state(session).client
      assert is_pid(client)
      Process.exit(client, :kill)
      Process.sleep(50)

      assert :sys.get_state(session).client == nil

      assert %{status: :recovery_required, session_id: "fake-session"} =
               AcpSession.status(session)

      assert :ok = AcpSession.close(session)
    end

    @tag timeout: 2_000
    test "cancels in-flight prompt and tears the session down when the owner disappears" do
      install_fake_progress_client(5_000)

      parent = self()

      owner =
        spawn(fn ->
          {:ok, session} =
            AcpSession.start_link(
              provider: :test,
              client_opts: [test_pid: parent]
            )

          send(parent, {:session_started, session})
          # Block inside send_message while the fake prompt stalls.
          _ = AcpSession.send_message(session, "stall")
        end)

      assert_receive {:session_started, session}, 1_000
      session_ref = Process.monitor(session)

      assert_receive {:fake_prompt_started, _worker, "stall", _opts}, 1_000
      assert Process.alive?(session)

      # Simulate orchestration cancel killing the owning action/turn process.
      Process.exit(owner, :kill)

      assert_receive {:fake_cancel, "fake-session"}, 1_000
      assert_receive {:fake_disconnect, _client}, 1_000
      assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 1_000
    end
  end

  describe "hostile ACP callbacks" do
    test "finite stream callbacks preserve serial state and event order" do
      install_fake_progress_client(100)
      {:ok, seen} = Agent.start_link(fn -> [] end)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          client_opts: [test_pid: self()],
          stream_callback: fn update -> Agent.update(seen, &(&1 ++ [update])) end
        )

      on_exit(fn -> safely_close_session(session) end)

      assert {:ok, %{"text" => "done"}} =
               AcpSession.send_message(session, "steady_progress", timeout: 250)

      callbacks = Agent.get(seen, & &1)
      assert length(callbacks) == 5
      assert Enum.map(callbacks, & &1["sequence"]) == [1, 2, 3, 4, 5]
    end

    @tag timeout: 1_000
    test "security regression: non-returning create and resume callbacks are killed" do
      install_fake_progress_client(100)

      for {mode, invoke, message} <- [
            {:new_session_mode, &AcpSession.create_session(&1, timeout: 30),
             :fake_new_session_stalled},
            {:resume_mode, &AcpSession.resume_session(&1, "resume-me", timeout: 30),
             :fake_resume_stalled}
          ] do
        {:ok, session} =
          AcpSession.start_link(
            provider: :test,
            client_opts: [{:test_pid, self()}, {mode, :stall}]
          )

        session_ref = Process.monitor(session)
        assert {:error, :timeout} = invoke.(session)
        assert_receive {^message, callback_worker}, 200
        assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 300
        refute Process.alive?(callback_worker)
      end
    end

    @tag timeout: 1_000
    test "security regression: non-returning disconnect is killed and close terminates" do
      install_fake_progress_client(100)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          client_opts: [test_pid: self(), disconnect_mode: :stall]
        )

      session_ref = Process.monitor(session)
      assert {:error, :timeout} = AcpSession.close(session, timeout: 30)
      assert_receive {:fake_disconnect_stalled, callback_worker}, 200
      callback_ref = Process.monitor(callback_worker)
      assert_receive {:DOWN, ^session_ref, :process, ^session, down_reason}, 300
      assert down_reason in [:normal, :killed]
      assert_receive {:DOWN, ^callback_ref, :process, ^callback_worker, callback_reason}, 300
      assert callback_reason in [:killed, :noproc]
      refute Process.alive?(callback_worker)
    end

    @tag timeout: 7_000
    test "security regression: non-returning stream callback cannot wedge the session" do
      install_fake_progress_client(10_000)
      test_pid = self()

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          client_opts: [test_pid: self()],
          stream_callback: fn _update ->
            send(test_pid, {:stream_callback_stalled, self()})
            Process.sleep(:infinity)
          end
        )

      session_ref = Process.monitor(session)

      assert {:error, reason} =
               AcpSession.send_message(session, "steady_progress",
                 timeout: 10_000,
                 inactivity_timeout_ms: 10_000
               )

      assert reason == :stream_callback_timeout
      assert_receive {:stream_callback_stalled, callback_worker}, 200
      assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 5_500
      refute Process.alive?(callback_worker)
    end

    test "security regression: stream callback throws are bounded and do not kill the session" do
      install_fake_progress_client(100)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          client_opts: [test_pid: self()],
          stream_callback: fn _update ->
            throw({:callback_throw, :erlang.bsl(1, 1_000_000)})
          end
        )

      on_exit(fn -> safely_close_session(session) end)

      assert {:ok, %{"text" => "done"}} =
               AcpSession.send_message(session, "steady_progress", timeout: 250)

      assert Process.alive?(session)
    end

    test "security regression: new-session throws return bounded errors without killing the session" do
      install_fake_progress_client(100)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          client_opts: [test_pid: self(), new_session_mode: :throw]
        )

      on_exit(fn -> safely_close_session(session) end)

      assert {:error, reason} = AcpSession.send_message(session, "hello", timeout: 100)
      assert byte_size(Arbor.LLM.inspect_external_reason(reason)) < 1_024
      assert Process.alive?(session)
    end
  end

  describe "AcpSession.Handler" do
    alias Arbor.AI.AcpSession.Handler

    test "init creates handler state with workspace_root" do
      assert {:ok, state} = Handler.init(cwd: "/tmp/project")
      assert state.roots == [%{uri: "file:///tmp/project", name: "workspace"}]
      assert state.workspace_root == "/tmp/project"
    end

    test "init with no cwd creates empty roots and nil workspace_root" do
      assert {:ok, state} = Handler.init([])
      assert state.roots == []
      assert state.workspace_root == nil
    end

    test "handle_session_update returns ok" do
      {:ok, state} = Handler.init([])
      assert {:ok, ^state} = Handler.handle_session_update("s1", %{"kind" => "status"}, state)
    end

    test "handle_permission_request DENIES when no agent_id (anonymous session) — H3 regression" do
      {:ok, state} = Handler.init([])

      # SECURITY (codex authz.acp-session-anonymous-file-access): pre-fix,
      # authorize_action(nil,...) returned :authorized and this approved. A
      # session with no caller identity must not auto-approve tool requests.
      assert {:ok, %{"outcome" => "denied"} = outcome, ^state} =
               Handler.handle_permission_request("session-1", %{"name" => "tool"}, %{}, state)

      assert outcome["reason"] =~ "identity"
    end

    # Spec regression — surfaced during the Gemini E2E HITL smoke test on
    # 2026-06-07. The handler previously returned `%{"outcome" =>
    # "approved"}` regardless of what options the agent offered. ACP spec
    # (https://agentclientprotocol.com/protocol/tool-calls) requires
    # `%{"outcome" => %{"outcome" => "selected", "optionId" => "<id>"}}`
    # referencing one of the offered options. Gemini, being spec-compliant,
    # rejected the non-spec response and re-asked — yielding 3 Signal
    # prompts for a single tool use until it gave up.
    test "handle_permission_request returns spec-shaped outcome when options are offered" do
      install_passthrough_authz()
      {:ok, state} = Handler.init(agent_id: "test-agent")

      options = [
        %{
          "optionId" => "proceed_always",
          "name" => "Allow for this session",
          "kind" => "allow_always"
        },
        %{"optionId" => "proceed_once", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "cancel", "name" => "Reject", "kind" => "reject_once"}
      ]

      assert {:ok, response, _state} =
               Handler.handle_permission_request("s1", %{"name" => "tool"}, options, state)

      # Authorized → picks the first allow_once-kind option.
      assert response == %{"outcome" => %{"outcome" => "selected", "optionId" => "proceed_once"}}
    end

    test "handle_permission_request infers tool name from toolCallId when name is absent" do
      {:ok, state} = Handler.init([])

      # Gemini's toolCall payload pattern: name lives in toolCallId
      tool_call = %{"toolCallId" => "run_shell_command__run_shell_command_1780853379688_0"}

      # No name field — should infer "run_shell_command" without crashing.
      assert {:ok, _response, _state} =
               Handler.handle_permission_request("s1", tool_call, [], state)
    end

    test "handle_permission_request with agent_id respects security authorization" do
      {:ok, state} = Handler.init(agent_id: "test-agent")

      # Behavior depends on whether CapabilityStore is running:
      # - If running: denied (no capability granted for test-agent)
      # - If not running: approved (permissive fallback)
      {:ok, result, ^state} =
        Handler.handle_permission_request("s1", %{"name" => "edit"}, %{}, state)

      if Process.whereis(Arbor.Security.CapabilityStore) do
        assert result["outcome"] == "denied"
      else
        assert result["outcome"] == "approved"
      end
    end

    test "handle_file_read reads existing file (no workspace root)" do
      install_passthrough_authz()
      {:ok, state} = Handler.init(agent_id: "test-agent")
      path = Path.join(System.tmp_dir!(), "acp_handler_test_#{:rand.uniform(100_000)}")

      try do
        File.write!(path, "test content")
        assert {:ok, "test content", ^state} = Handler.handle_file_read("s1", path, %{}, state)
      after
        File.rm(path)
      end
    end

    test "handle_file_read returns error for missing file" do
      install_passthrough_authz()
      {:ok, state} = Handler.init(agent_id: "test-agent")
      assert {:error, _, _} = Handler.handle_file_read("s1", "/nonexistent/file", %{}, state)
    end

    test "handle_file_write writes file (no workspace root)" do
      install_passthrough_authz()
      {:ok, state} = Handler.init(agent_id: "test-agent")
      path = Path.join(System.tmp_dir!(), "acp_handler_write_test_#{:rand.uniform(100_000)}")

      try do
        assert {:ok, ^state} =
                 Handler.handle_file_write("s1", path, "written content", %{}, state)

        assert File.read!(path) == "written content"
      after
        File.rm(path)
      end
    end
  end

  defp safely_close_session(session) do
    if Process.alive?(session) do
      AcpSession.close(session)
    end
  catch
    :exit, _reason -> :ok
  end

  # Matches both the broken send_after correlation-token format and the
  # fixed start_timer {:timeout, tref, payload} format.
  defp prompt_timer_message?({:acp_prompt_inactivity_timeout, _ref, _timer_ref}), do: true
  defp prompt_timer_message?({:acp_prompt_hard_timeout, _ref, _timer_ref}), do: true

  defp prompt_timer_message?({:timeout, _timer_ref, {:acp_prompt_inactivity_timeout, _ref}}),
    do: true

  defp prompt_timer_message?({:timeout, _timer_ref, {:acp_prompt_hard_timeout, _ref}}), do: true
  defp prompt_timer_message?(_other), do: false

  describe "Handler path validation (workspace_root set)" do
    alias Arbor.AI.AcpSession.Handler

    setup do
      # Passthrough authz + a real agent_id: these tests exercise workspace_root
      # / SafePath bounds, not capability grants. The anonymous (nil-agent) path
      # now fails closed, so an authorized identity is required for the
      # within-workspace success cases. Traversal/outside cases still deny via
      # validate_path (which runs before authorization).
      install_passthrough_authz()

      # Create a temp workspace directory
      workspace = Path.join(System.tmp_dir!(), "acp_ws_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(workspace)
      {:ok, state} = Handler.init(cwd: workspace, agent_id: "test-agent")

      on_exit(fn -> File.rm_rf(workspace) end)
      %{state: state, workspace: workspace}
    end

    test "file read within workspace root succeeds", %{state: state, workspace: workspace} do
      file = Path.join(workspace, "allowed.txt")
      File.write!(file, "hello")

      assert {:ok, "hello", ^state} = Handler.handle_file_read("s1", file, %{}, state)
    end

    test "file write within workspace root succeeds", %{state: state, workspace: workspace} do
      file = Path.join(workspace, "new_file.txt")

      assert {:ok, ^state} = Handler.handle_file_write("s1", file, "data", %{}, state)
      assert File.read!(file) == "data"
    end

    test "file read with path traversal is denied", %{state: state, workspace: workspace} do
      # Create a file outside the workspace
      outside = Path.join(System.tmp_dir!(), "outside_ws_#{:rand.uniform(100_000)}")
      File.write!(outside, "secret")

      on_exit(fn -> File.rm(outside) end)

      # Try to traverse out
      traversal_path = Path.join(workspace, "../" <> Path.basename(outside))
      assert {:error, msg, _state} = Handler.handle_file_read("s1", traversal_path, %{}, state)
      assert msg =~ "access denied"
    end

    test "file write with path traversal is denied", %{state: state, workspace: workspace} do
      traversal_path = Path.join(workspace, "../../../tmp/evil.txt")

      assert {:error, msg, _state} =
               Handler.handle_file_write("s1", traversal_path, "bad", %{}, state)

      assert msg =~ "access denied"
    end

    test "file read of absolute path outside workspace is denied", %{state: state} do
      assert {:error, msg, _state} = Handler.handle_file_read("s1", "/etc/passwd", %{}, state)
      assert msg =~ "access denied"
    end

    test "file write to absolute path outside workspace is denied", %{state: state} do
      assert {:error, msg, _state} =
               Handler.handle_file_write("s1", "/tmp/outside.txt", "x", %{}, state)

      assert msg =~ "access denied"
    end

    test "nested subdirectory within workspace succeeds", %{
      state: state,
      workspace: workspace
    } do
      subdir = Path.join(workspace, "src/lib")
      File.mkdir_p!(subdir)
      file = Path.join(subdir, "module.ex")
      File.write!(file, "defmodule M, do: nil")

      assert {:ok, "defmodule M, do: nil", ^state} =
               Handler.handle_file_read("s1", file, %{}, state)
    end
  end

  describe "Handler workspace: {:directory, path}" do
    alias Arbor.AI.AcpSession.Handler

    test "init sets workspace_root from cwd option" do
      dir = System.tmp_dir!()
      {:ok, state} = Handler.init(cwd: dir)
      assert state.workspace_root == dir
    end

    test "roots reflect workspace path" do
      {:ok, state} = Handler.init(cwd: "/my/project")
      assert [%{uri: "file:///my/project", name: "workspace"}] = state.roots
    end
  end

  describe "merge_accumulated_text/2" do
    test "returns result unchanged when accumulated text is empty" do
      result = %{"text" => "agent text", "stopReason" => "end_turn"}
      assert AcpSession.merge_accumulated_text(result, "") == result
    end

    test "prefers agent-provided text over accumulated" do
      result = %{"text" => "agent text", "stopReason" => "end_turn"}
      merged = AcpSession.merge_accumulated_text(result, "streamed text")
      assert merged["text"] == "agent text"
    end

    test "uses accumulated text when agent text is empty" do
      result = %{"text" => "", "stopReason" => "end_turn"}
      merged = AcpSession.merge_accumulated_text(result, "streamed text")
      assert merged["text"] == "streamed text"
    end

    test "uses accumulated text when agent text is nil" do
      result = %{"stopReason" => "end_turn"}
      merged = AcpSession.merge_accumulated_text(result, "streamed text")
      assert merged["text"] == "streamed text"
    end

    test "handles atom-keyed result maps" do
      result = %{text: "", stop_reason: "end_turn"}
      merged = AcpSession.merge_accumulated_text(result, "streamed")
      assert merged["text"] == "streamed"
    end

    test "returns non-map result unchanged" do
      assert AcpSession.merge_accumulated_text("raw", "accumulated") == "raw"
    end
  end

  describe "drain_pending_updates/1 (regression: Claude ACP empty response)" do
    test "drains queued streaming chunks from the mailbox and accumulates their text" do
      # Simulates the bug: agent_message_chunk updates arrive as {:acp_session_update} messages
      # queued in the mailbox during the blocking prompt/4 call. The drain must process them so the
      # streamed text isn't lost — Claude returns its answer ONLY via these chunks, not the result.
      state = %{accumulated_text: "", stream_callback: nil}

      send(
        self(),
        {:acp_session_update, "s1",
         %{
           "sessionUpdate" => "agent_message_chunk",
           "content" => %{"type" => "text", "text" => "Hello "}
         }}
      )

      send(
        self(),
        {:acp_session_update, "s1",
         %{
           "sessionUpdate" => "agent_message_chunk",
           "content" => %{"type" => "text", "text" => "world"}
         }}
      )

      drained = AcpSession.drain_pending_updates(state)
      assert drained.accumulated_text == "Hello world"
    end

    test "returns state unchanged when the mailbox has no updates" do
      state = %{accumulated_text: "", stream_callback: nil}
      assert AcpSession.drain_pending_updates(state).accumulated_text == ""
    end
  end

  describe "status includes usage" do
    @test_client_opts [command: ["echo", "test"], _skip_connect: true]

    defp install_fake_usage_client(client_opts) do
      original_client = Application.get_env(:arbor_ai, :acp_client_module)
      Application.put_env(:arbor_ai, :acp_client_module, FakeUsageClient)

      on_exit(fn ->
        restore_env(:acp_client_module, original_client)
      end)

      client_opts
    end

    defp start_usage_session(results) do
      client_opts = install_fake_usage_client(results: results)

      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: client_opts)

      on_exit(fn -> safely_close_session(session) end)

      session
    end

    test "status returns zero usage on fresh session" do
      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: @test_client_opts)

      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: 0, output_tokens: 0}

      GenServer.stop(session)
    end

    test "security regression: nested Grok _meta.usage camelCase updates cumulative status" do
      # Observed Grok ACP 0.2.106 shape: usage lives under string-keyed _meta,
      # not top-level, with camelCase inputTokens/outputTokens.
      session =
        start_usage_session([
          %{
            "text" => "done",
            "stopReason" => "end_turn",
            "_meta" => %{
              "usage" => %{"inputTokens" => 120, "outputTokens" => 45}
            }
          }
        ])

      assert {:ok, result} = AcpSession.send_message(session, "hello", timeout: 1_000)
      assert Map.keys(result) |> Enum.sort() == ["_meta", "stopReason", "text"]
      refute Map.has_key?(result, "usage")
      assert result["_meta"]["usage"]["inputTokens"] == 120

      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: 120, output_tokens: 45}
      assert status.context_tokens == 120
    end

    test "top-level usage retains precedence over nested _meta.usage" do
      session =
        start_usage_session([
          %{
            "text" => "done",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 2},
            "_meta" => %{
              "usage" => %{"inputTokens" => 999, "outputTokens" => 999}
            }
          }
        ])

      assert {:ok, _result} = AcpSession.send_message(session, "hello", timeout: 1_000)

      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: 10, output_tokens: 2}
      assert status.context_tokens == 10
    end

    test "malformed nested _meta usage is ignored without corrupting counters" do
      session =
        start_usage_session([
          %{
            "text" => "done",
            "_meta" => %{
              "usage" => %{
                "inputTokens" => -5,
                "outputTokens" => "not-an-int",
                "extra" => %{nested: true}
              },
              "other" => "ignored-noise"
            }
          }
        ])

      assert {:ok, result} = AcpSession.send_message(session, "hello", timeout: 1_000)
      # Public result is unchanged; we never promote or strip _meta.
      assert result["_meta"]["usage"]["inputTokens"] == -5

      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: 0, output_tokens: 0}
      assert status.context_tokens == 0
    end

    test "successive turns accumulate usage from nested and top-level shapes" do
      session =
        start_usage_session([
          %{
            "text" => "turn-1",
            "_meta" => %{"usage" => %{"inputTokens" => 100, "outputTokens" => 20}}
          },
          %{
            "text" => "turn-2",
            "usage" => %{"input_tokens" => 50, "output_tokens" => 10}
          },
          %{
            "text" => "turn-3",
            :_meta => %{usage: %{"inputTokens" => 25, "outputTokens" => 5}}
          }
        ])

      assert {:ok, _} = AcpSession.send_message(session, "one", timeout: 1_000)
      assert AcpSession.status(session).usage == %{input_tokens: 100, output_tokens: 20}

      assert {:ok, _} = AcpSession.send_message(session, "two", timeout: 1_000)
      assert AcpSession.status(session).usage == %{input_tokens: 150, output_tokens: 30}

      assert {:ok, _} = AcpSession.send_message(session, "three", timeout: 1_000)
      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: 175, output_tokens: 35}
      assert status.context_tokens == 25
    end

    test "security regression: first-present usage alias does not fall through on invalid preferred key" do
      # Nested under _meta so validation admits the result; preferred snake_case
      # keys are present but invalid while camelCase aliases are valid. First-
      # present semantics must return 0, not fall through to the later alias.
      session =
        start_usage_session([
          %{
            "text" => "done",
            "_meta" => %{
              "usage" => %{
                "input_tokens" => -1,
                "inputTokens" => 999,
                "output_tokens" => "bad",
                "outputTokens" => 50
              }
            }
          }
        ])

      assert {:ok, result} = AcpSession.send_message(session, "hello", timeout: 1_000)
      assert result["_meta"]["usage"]["inputTokens"] == 999

      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: 0, output_tokens: 0}
      assert status.context_tokens == 0
    end

    test "security regression: cumulative usage preserves last valid signed-64 count on overflow" do
      # Both turn deltas are individually finite; their sum is not. Counters must
      # keep the pre-overflow cumulative value rather than widening past signed-64.
      near_max = 9_223_372_036_854_775_800

      session =
        start_usage_session([
          %{
            "text" => "turn-1",
            "usage" => %{"input_tokens" => near_max, "output_tokens" => near_max}
          },
          %{
            "text" => "turn-2",
            "usage" => %{"input_tokens" => 20, "output_tokens" => 20}
          }
        ])

      assert {:ok, _} = AcpSession.send_message(session, "one", timeout: 1_000)

      assert AcpSession.status(session).usage == %{
               input_tokens: near_max,
               output_tokens: near_max
             }

      assert {:ok, _} = AcpSession.send_message(session, "two", timeout: 1_000)

      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: near_max, output_tokens: near_max}
      # Latest turn input still updates context size; only cumulative is clamped.
      assert status.context_tokens == 20
    end
  end

  describe "Handler trust tier integration" do
    alias Arbor.AI.AcpSession.Handler

    test "authorize never crashes regardless of trust/security availability" do
      # Handler should never crash — it either authorizes or denies gracefully
      {:ok, state} = Handler.init(agent_id: "test-agent")

      {:ok, result, ^state} =
        Handler.handle_permission_request("s1", %{"name" => "edit"}, %{}, state)

      assert result["outcome"] in ["approved", "denied"]
    end
  end

  describe "status includes context_tokens" do
    @test_client_opts [command: ["echo", "test"], _skip_connect: true]

    test "status returns zero context_tokens on fresh session" do
      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: @test_client_opts)

      status = AcpSession.status(session)
      assert status.context_tokens == 0

      GenServer.stop(session)
    end
  end

  describe "context_pressure?/1" do
    @test_client_opts [command: ["echo", "test"], _skip_connect: true]

    test "returns false for fresh session" do
      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: @test_client_opts)

      refute AcpSession.context_pressure?(session)

      GenServer.stop(session)
    end
  end

  describe "resume_session/3" do
    test "last_session_id is preserved in struct" do
      state = %AcpSession{}
      assert state.last_session_id == nil
      assert state.reconnect_attempted == false
      assert state.context_tokens == 0
    end

    test "resume_session returns error when not available" do
      # Start with a deliberately broken provider to force :error status
      # The _skip_connect trick starts the client but the echo process dies immediately
      # Use an approach that doesn't involve a real ACP client
      {:ok, session} =
        AcpSession.start_link(
          provider: :nonexistent_provider_xyz,
          client_opts: [command: ["false"], _skip_connect: true]
        )

      # Session may be in error state (config resolution failed) or ready (echo started)
      status = AcpSession.status(session)

      if status.status == :error do
        assert {:error, _} = AcpSession.resume_session(session, "session-123")
      end

      GenServer.stop(session)
    end
  end

  describe "Arbor.AI facade" do
    @test_client_opts [command: ["echo", "test"], _skip_connect: true]

    test "acp_start_session delegates to AcpSession" do
      assert {:ok, pid} =
               Arbor.AI.acp_start_session(:test, client_opts: @test_client_opts)

      assert is_pid(pid)
      GenServer.stop(pid)
    end

    test "acp_close_session stops the session" do
      {:ok, pid} = Arbor.AI.acp_start_session(:test, client_opts: @test_client_opts)
      ref = Process.monitor(pid)

      assert :ok = Arbor.AI.acp_close_session(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    end
  end

  describe "Handler.await_human_approval/4 — HITL bridge" do
    alias Arbor.AI.AcpSession.Handler
    alias Arbor.Contracts.Comms.Interaction

    @pubsub Arbor.Comms.PubSub

    # Ensure Arbor.Comms.PubSub is up so the helper can subscribe. arbor_ai
    # doesn't depend on arbor_comms, so we start the PubSub here if it's
    # not already running.
    setup do
      case Process.whereis(@pubsub) do
        nil ->
          start_supervised!({Phoenix.PubSub, name: @pubsub})
          :ok

        _pid ->
          :ok
      end
    end

    defp test_state(timeout_ms) do
      {:ok, state} = Handler.init(permission_timeout_ms: timeout_ms)
      state
    end

    defp broadcast_response(agent_id, request_id, response) do
      topic = Interaction.response_topic_for_agent(agent_id)

      payload =
        {:interaction_response,
         %{
           request_id: request_id,
           response: response,
           metadata: %{},
           resolved_at: DateTime.utc_now()
         }}

      Phoenix.PubSub.broadcast(@pubsub, topic, payload)
    end

    test "returns :authorized when operator approves" do
      agent_id = "agent_hitl_#{:erlang.unique_integer([:positive])}"
      request_id = "req_#{:erlang.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          Handler.await_human_approval(
            agent_id,
            request_id,
            "arbor://acp/tool/web_search",
            test_state(2_000)
          )
        end)

      # Give the inner subscribe a moment to land before broadcasting.
      Process.sleep(50)
      broadcast_response(agent_id, request_id, :approved)

      assert :authorized = Task.await(task, 3_000)
    end

    test "returns {:denied, _} when operator rejects" do
      agent_id = "agent_hitl_#{:erlang.unique_integer([:positive])}"
      request_id = "req_#{:erlang.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          Handler.await_human_approval(
            agent_id,
            request_id,
            "arbor://acp/tool/write",
            test_state(2_000)
          )
        end)

      Process.sleep(50)
      broadcast_response(agent_id, request_id, :rejected)

      assert {:denied, reason} = Task.await(task, 3_000)
      assert reason =~ "human operator"
    end

    test "returns {:denied, _} on timeout when no response arrives" do
      agent_id = "agent_hitl_#{:erlang.unique_integer([:positive])}"
      request_id = "req_#{:erlang.unique_integer([:positive])}"

      # Tight timeout — 100ms — so the test runs fast.
      result =
        Handler.await_human_approval(
          agent_id,
          request_id,
          "arbor://acp/tool/timeout_demo",
          test_state(100)
        )

      assert {:denied, reason} = result
      assert reason =~ "did not respond in time"
    end

    test "ignores responses for other request_ids and times out" do
      agent_id = "agent_hitl_#{:erlang.unique_integer([:positive])}"
      our_request_id = "req_target_#{:erlang.unique_integer([:positive])}"
      other_request_id = "req_other_#{:erlang.unique_integer([:positive])}"

      task =
        Task.async(fn ->
          Handler.await_human_approval(
            agent_id,
            our_request_id,
            "arbor://acp/tool/mismatch_demo",
            test_state(200)
          )
        end)

      Process.sleep(50)
      # Broadcast a response for a different request_id; our task should
      # ignore it and time out.
      broadcast_response(agent_id, other_request_id, :approved)

      assert {:denied, reason} = Task.await(task, 1_000)
      assert reason =~ "did not respond in time"
    end
  end

  describe "Handler.init/1 — permission timeout configuration" do
    alias Arbor.AI.AcpSession.Handler

    test "defaults to 60_000 ms when no opt and no app env" do
      original = Application.get_env(:arbor_ai, :acp_permission_timeout_ms)
      Application.delete_env(:arbor_ai, :acp_permission_timeout_ms)

      on_exit(fn ->
        if is_nil(original) do
          Application.delete_env(:arbor_ai, :acp_permission_timeout_ms)
        else
          Application.put_env(:arbor_ai, :acp_permission_timeout_ms, original)
        end
      end)

      {:ok, state} = Handler.init([])
      assert state.permission_timeout_ms == 60_000
    end

    test "explicit opt wins over app env" do
      original = Application.get_env(:arbor_ai, :acp_permission_timeout_ms)
      Application.put_env(:arbor_ai, :acp_permission_timeout_ms, 999)

      on_exit(fn ->
        restore_env(:acp_permission_timeout_ms, original)
      end)

      {:ok, state} = Handler.init(permission_timeout_ms: 12_345)
      assert state.permission_timeout_ms == 12_345
    end

    test "app env wins when no explicit opt" do
      original = Application.get_env(:arbor_ai, :acp_permission_timeout_ms)
      Application.put_env(:arbor_ai, :acp_permission_timeout_ms, 7_777)

      on_exit(fn ->
        restore_env(:acp_permission_timeout_ms, original)
      end)

      {:ok, state} = Handler.init([])
      assert state.permission_timeout_ms == 7_777
    end
  end

  describe "select_and_confirm_model — ACP model selection regression" do
    # Configurable fake ACP client for model selection tests.
    # The :model_response option controls what set_config_option returns.
    # Each call to set_config_option pops from a queue (model_responses list),
    # falling back to :model_response_default when the queue is exhausted.
    defmodule ModelSelectClient do
      @moduledoc false

      def start_link(opts), do: Agent.start_link(fn -> opts end)

      def new_session(_client, _cwd, _opts),
        do: {:ok, %{"sessionId" => "model-select-session"}}

      def load_session(_client, session_id, _cwd, _opts),
        do: {:ok, %{"sessionId" => session_id}}

      def set_config_option(client, _session_id, _key, _value) do
        Agent.get_and_update(client, fn s ->
          count = Keyword.get(s, :set_config_option_count, 0) + 1
          s = Keyword.put(s, :set_config_option_count, count)

          {result, s} =
            case Keyword.get(s, :model_responses, []) do
              [next | rest] -> {next, Keyword.put(s, :model_responses, rest)}
              [] -> {Keyword.get(s, :model_response_default, :ok), s}
            end

          {result, s}
        end)
        |> case do
          {:raise, exception} -> raise exception
          {:exit, reason} -> exit(reason)
          {:throw, value} -> throw(value)
          other -> other
        end
      end

      def set_config_option_count(client) do
        Agent.get(client, &Keyword.get(&1, :set_config_option_count, 0))
      end

      def cancel(_client, _session_id), do: :ok

      def disconnect(client) do
        Agent.stop(client, :normal)
        :ok
      end

      def prompt(_client, _session_id, _content, _opts),
        do: {:ok, %{"text" => "ok"}}
    end

    defp model_confirmed_response(model) do
      {:ok, %{"configOptions" => [%{"id" => "model", "currentValue" => model}]}}
    end

    defp install_model_select_client(opts) do
      original_client = Application.get_env(:arbor_ai, :acp_client_module)
      Application.put_env(:arbor_ai, :acp_client_module, ModelSelectClient)

      on_exit(fn ->
        restore_env(:acp_client_module, original_client)
      end)

      opts
    end

    defp start_model_session(model, client_opts \\ []) do
      client_opts =
        Keyword.merge(
          [model_response_default: model_confirmed_response(model)],
          client_opts
        )

      client_opts = install_model_select_client(client_opts)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: model,
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      session
    end

    defp poll_reconnect_ready(session, old_client, attempts \\ 50)

    defp poll_reconnect_ready(_session, _old_client, 0) do
      flunk("reconnect did not complete after 50 attempts")
    end

    defp poll_reconnect_ready(session, old_client, attempts) do
      Process.sleep(20)
      st = :sys.get_state(session)

      if st.status == :ready and st.client != old_client,
        do: :ok,
        else: poll_reconnect_ready(session, old_client, attempts - 1)
    end

    # Read the GenServer state directly because the public status does not
    # expose client_monitor or last_session_id atomically. Wait for status
    # :error with client, client_monitor, session_id and last_session_id all nil.
    # Do not catch exits or accept :recovery_required / :ready, and flunk on
    # exhaustion so the test cannot silently succeed.
    defp poll_reconnect_terminal(session, attempts \\ 50)

    defp poll_reconnect_terminal(_session, 0) do
      flunk("reconnect did not reach exact terminal :error state after 50 attempts")
    end

    defp poll_reconnect_terminal(session, attempts) do
      Process.sleep(20)
      st = :sys.get_state(session)

      if reconnect_terminal_error?(st) do
        :ok
      else
        poll_reconnect_terminal(session, attempts - 1)
      end
    end

    defp reconnect_terminal_error?(st) do
      st.status == :error and
        is_nil(st.client) and
        is_nil(st.client_monitor) and
        is_nil(st.session_id) and
        is_nil(st.last_session_id)
    end

    test "exact model confirmation succeeds" do
      session = start_model_session("zai-coding-plan/glm-5.2")
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)
      assert %{status: :ready, model: "zai-coding-plan/glm-5.2"} = AcpSession.status(session)
    end

    test "no model preserves provider-default behavior (no RPC)" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)
      assert %{status: :ready, model: nil} = AcpSession.status(session)

      assert {:ok, _info} = AcpSession.create_session(session, timeout: 1_000)
      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "confirmed mismatch fails closed" do
      # Provider returns a different model than requested
      mismatch_response =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "provider-default-model"}
           ]
         }}

      session =
        start_model_session("requested-model", model_responses: [mismatch_response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      # create_session triggers model verification → mismatch → error
      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "explicit rejection from provider fails closed" do
      session =
        start_model_session("unsupported-model", model_responses: [{:error, :not_supported}])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "malformed response (non-list configOptions) fails closed" do
      malformed = {:ok, %{"configOptions" => "not-a-list"}}

      session =
        start_model_session("any-model", model_responses: [malformed])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "duplicate model options in configOptions fails closed" do
      duplicate =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "model-a"},
             %{"id" => "model", "currentValue" => "model-b"}
           ]
         }}

      session =
        start_model_session("model-a", model_responses: [duplicate])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "non-string currentValue on sibling option is accepted (Claude SDK fast flag)" do
      # The ex_mcp Claude SDK mapper emits a boolean "fast" configOption with a
      # boolean currentValue alongside the canonical "model" option. The walk
      # must only require a bounded string currentValue on the unique model
      # option; sibling options may legitimately carry non-string scalars.
      response =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "fast", "currentValue" => true},
             %{"id" => "model", "currentValue" => "claude-sonnet-4"},
             %{"id" => "effort", "currentValue" => "default"}
           ]
         }}

      session =
        start_model_session("claude-sonnet-4", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} = AcpSession.create_session(session, timeout: 1_000)
      assert %{status: :ready, model: "claude-sonnet-4"} = AcpSession.status(session)
    end

    test "non-string currentValue on the model option fails closed" do
      # The model option specifically must carry a bounded string currentValue;
      # a boolean there is rejected.
      response =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "fast", "currentValue" => true},
             %{"id" => "model", "currentValue" => true}
           ]
         }}

      session =
        start_model_session("any-model", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, {:model_not_confirmed, :missing_current_value}}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "missing currentValue on the model option fails closed" do
      response =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "fast", "currentValue" => true},
             %{"id" => "model"}
           ]
         }}

      session =
        start_model_session("any-model", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, {:model_not_confirmed, :missing_current_value}}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "option with missing id fails closed" do
      # The bounded walk requires every scanned option to carry a bounded string
      # id; an option missing the id field entirely is rejected.
      response =
        {:ok,
         %{
           "configOptions" => [
             %{"currentValue" => true},
             %{"id" => "model", "currentValue" => "any-model"}
           ]
         }}

      session =
        start_model_session("any-model", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "missing configOptions key fails closed" do
      session =
        start_model_session("any-model", model_responses: [{:ok, %{"unexpected" => "shape"}}])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "transient missing option then success (bounded retry)" do
      # First call: option not available; second call: confirmed
      session =
        start_model_session("retry-model",
          model_responses: [
            {:ok, %{"configOptions" => []}},
            model_confirmed_response("retry-model")
          ]
        )

      assert :ok = AcpSession.await_ready(session, timeout: 2_000)
      assert %{status: :ready, model: "retry-model"} = AcpSession.status(session)

      # create_session should succeed after retry confirms the model
      assert {:ok, _info} = AcpSession.create_session(session, timeout: 2_000)
    end

    test "bounded missing-option exhaustion fails closed" do
      # Always return empty configOptions — should exhaust retries
      # Need 4+ entries: 3 retries + 1 more so the default confirmed response is never reached
      session =
        start_model_session("exhaust-model",
          model_responses: [
            {:ok, %{"configOptions" => []}},
            {:ok, %{"configOptions" => []}},
            {:ok, %{"configOptions" => []}},
            {:ok, %{"configOptions" => []}}
          ]
        )

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 2_000)
    end

    test "timeout from set_config_option fails closed" do
      session =
        start_model_session("timeout-model", model_responses: [{:error, :timeout}])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "explicit create_session verifies model" do
      confirmed = model_confirmed_response("explicit-model")
      install_model_select_client(model_response_default: confirmed)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "explicit-model",
          client_opts: [test_pid: self(), model_response_default: confirmed]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "lazy creation (send_message) verifies model" do
      session = start_model_session("lazy-model")
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      # send_message triggers ensure_session → lazy creation → model verification
      assert {:ok, _result} =
               AcpSession.send_message(session, "hello", timeout: 5_000)
    end

    test "resume_session verifies model" do
      confirmed = model_confirmed_response("resume-model")
      install_model_select_client(model_response_default: confirmed)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "resume-model",
          client_opts: [test_pid: self(), model_response_default: confirmed]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} =
               AcpSession.resume_session(session, "resume-session-id", timeout: 1_000)

      assert %{status: :ready, session_id: "resume-session-id"} = AcpSession.status(session)
    end

    test "reconnect verifies model" do
      confirmed = model_confirmed_response("reconnect-model")
      install_model_select_client(model_response_default: confirmed)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "reconnect-model",
          client_opts: [test_pid: self(), model_response_default: confirmed]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      # Create a session first so there's a session_id to reconnect.
      assert {:ok, _info} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      assert is_binary(state.session_id)

      # Kill the client to trigger DOWN → maybe_reconnect.
      first_client = state.client
      assert is_pid(first_client)
      Process.exit(first_client, :kill)

      # The reconnect path reuses state.opts[:client_opts], which still carries
      # the confirmed response, so the new client reaches :ready.
      poll_reconnect_ready(session, first_client)

      final_state = :sys.get_state(session)
      assert final_state.status == :ready
      assert final_state.reconnect_attempted == true
      assert final_state.client != nil
      assert final_state.client != first_client

      # The new client confirmed the model exactly once during reconnect.
      assert ModelSelectClient.set_config_option_count(final_state.client) == 1
    end

    test "model mismatch in resume fails closed" do
      mismatch =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "wrong-model"}
           ]
         }}

      install_model_select_client(model_responses: [mismatch])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "requested-model",
          client_opts: [test_pid: self(), model_responses: [mismatch]]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.resume_session(session, "some-session", timeout: 1_000)
    end

    test "model mismatch in create_session fails closed" do
      mismatch =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "wrong-model"}
           ]
         }}

      install_model_select_client(model_responses: [mismatch])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "requested-model",
          client_opts: [test_pid: self(), model_responses: [mismatch]]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "exact confirmation makes exactly one set_config_option call" do
      session = start_model_session("count-model")
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} = AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 1
    end

    test "transient retry makes exactly two set_config_option calls" do
      session =
        start_model_session("retry-count-model",
          model_responses: [
            {:ok, %{"configOptions" => []}},
            model_confirmed_response("retry-count-model")
          ]
        )

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} = AcpSession.create_session(session, timeout: 2_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 2
    end

    test "exhausted retries makes N+1 set_config_option calls (initial + N retries)" do
      max_retries = 3

      responses =
        for _ <- 1..(max_retries + 1),
            do: {:ok, %{"configOptions" => []}}

      session = start_model_session("exhaust-count-model", model_responses: responses)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 3_000)

      state = :sys.get_state(session)
      client = state.client

      # 1 initial + max_retries retries = max_retries + 1
      assert ModelSelectClient.set_config_option_count(client) == max_retries + 1
    end

    test "resume model failure transitions to :error and clears session_id" do
      mismatch =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "wrong-model"}
           ]
         }}

      install_model_select_client(model_responses: [mismatch])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "requested-model",
          client_opts: [test_pid: self(), model_responses: [mismatch]]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      :sys.replace_state(session, fn s -> %{s | last_session_id: "prior-session"} end)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.resume_session(session, "new-session", timeout: 1_000)

      status = AcpSession.status(session)
      assert status.status == :error
      assert status.session_id == nil
    end

    test "send_message blocked after create_session model failure" do
      mismatch =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "wrong-model"}
           ]
         }}

      session =
        start_model_session("create-fail-send", model_responses: [mismatch])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      # Session is now in :error — session_id and last_session_id are cleared,
      # send_message is blocked.
      state = :sys.get_state(session)
      assert state.status == :error
      assert state.session_id == nil
      assert state.last_session_id == nil

      assert {:error, {:not_ready, :error}} =
               AcpSession.send_message(session, "hello", timeout: 1_000)
    end

    test "send_message after resume model failure returns error" do
      mismatch =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "wrong-model"}
           ]
         }}

      install_model_select_client(model_responses: [mismatch])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "requested-model",
          client_opts: [test_pid: self(), model_responses: [mismatch]]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.resume_session(session, "some-session", timeout: 1_000)

      # Session is now in :error — send_message should fail
      assert {:error, {:not_ready, :error}} =
               AcpSession.send_message(session, "hello", timeout: 1_000)
    end

    test "oversized option id scalar fails closed" do
      oversized_id = String.duplicate("x", 300)

      response =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => oversized_id, "currentValue" => "some-model"}
           ]
         }}

      session =
        start_model_session("any-model", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "oversized option currentValue scalar fails closed" do
      oversized_value = String.duplicate("y", 300)

      response =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => oversized_value}
           ]
         }}

      session =
        start_model_session("any-model", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "expired deadline prevents any post-deadline RPC" do
      session = start_model_session("deadline-model")
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      # Verify pre_rpc_deadline_check rejects expired deadlines at the unit level.
      # The public create_session path recomputes deadlines via start_deadline,
      # so we test the check directly by calling select_and_confirm_model with
      # opts that carry an already-expired :deadline_ms.
      expired_opts = [deadline_ms: System.monotonic_time(:millisecond) - 1000]
      state = :sys.get_state(session)
      sid = state.session_id || "test-session"
      client = state.client

      result = AcpSession.select_and_confirm_model(client, sid, "deadline-model", expired_opts)

      assert {:error, :deadline_exceeded} = result
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "invalid model string (non-binary) fails before RPC" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: :not_a_string,
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "oversized model string (257 bytes) fails before RPC" do
      oversized_model = String.duplicate("x", 257)

      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: oversized_model,
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "atom-key config response is rejected (canonical string-key only)" do
      # Atom-key response is NOT the canonical format and must be rejected.
      atom_response = %{configOptions: [%{id: :model, currentValue: "any-model"}]}

      install_model_select_client(model_responses: [atom_response])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "any-model",
          client_opts: [test_pid: self(), model_responses: [atom_response]]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      # create_session calls set_config_option, gets atom response,
      # verify_model_response rejects it (no "configOptions" key in map).
      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "improper list in configOptions fails closed" do
      # Build a response with an improper tail: [head | non_list].
      response = {:ok, %{"configOptions" => [%{"id" => "model"} | "not-a-list"]}}
      session = start_model_session("improper-model", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 1
    end

    test "deeply nested configOptions exceeds budget" do
      # Build a deeply nested map that exceeds max_depth=8.
      deep_value =
        Enum.reduce(1..20, "leaf", fn _i, acc -> %{"nested" => acc} end)

      response =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "any-model", "meta" => deep_value}
           ]
         }}

      session = start_model_session("deep-model", model_responses: [response])

      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)
    end

    test "empty string model is rejected (not no-op)" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "",
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "blank model string (whitespace only) fails before RPC" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "   ",
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "model string with NUL byte fails before RPC" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "model\0hidden",
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "model string with tab byte fails before RPC" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "model\x09tab",
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "model string with newline byte fails before RPC" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "model\x0Anl",
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "model string with DEL byte fails before RPC" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "model\x7Fdel",
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "model string with invalid UTF-8 fails before RPC" do
      client_opts = install_model_select_client(client_opts: [])

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "model\xFF\xFE",
          client_opts: client_opts
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:error, {:model_selection_failed, _reason}} =
               AcpSession.create_session(session, timeout: 1_000)

      state = :sys.get_state(session)
      client = state.client
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "invalid deadline error propagates without wrapping through retry path" do
      # Exercise the public AcpSession.select_and_confirm_model/4 API directly
      # with an invalid deadline value. Timeout.deadline/1 returns
      # {:error, :invalid_deadline}, which pre_rpc_deadline_check/1 must surface
      # verbatim (no {:model_selection_failed, _} wrapping) and before any RPC.
      # send_message does NOT reselect a model on existing sessions, so the
      # public model-selection entrypoint is the only path that exercises the
      # retry helper's pre-RPC deadline guard.
      session = start_model_session("deadline-model")
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      state = :sys.get_state(session)
      sid = state.session_id || "test-session"
      client = state.client

      opts = [deadline_ms: :not_a_number]

      result = AcpSession.select_and_confirm_model(client, sid, "deadline-model", opts)

      assert {:error, :invalid_deadline} = result
      assert ModelSelectClient.set_config_option_count(client) == 0
    end

    test "reconnect success reaches ready with model confirmation on new client" do
      confirmed = model_confirmed_response("reconnect-model")
      install_model_select_client(model_response_default: confirmed)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "reconnect-model",
          client_opts: [test_pid: self(), model_response_default: confirmed]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} =
               AcpSession.create_session(session, timeout: 1_000)

      # Establish last_session_id so maybe_reconnect will attempt a reconnect.
      :sys.replace_state(session, fn s -> %{s | last_session_id: "reconnect-target"} end)

      state = :sys.get_state(session)
      first_client = state.client
      assert is_pid(first_client)

      # Kill the client to trigger DOWN → maybe_reconnect
      Process.exit(first_client, :kill)

      # Poll until reconnect completes (deterministic — no broad sleep).
      poll_reconnect_ready(session, first_client)

      final_state = :sys.get_state(session)
      assert final_state.status == :ready
      assert final_state.client != nil
      assert final_state.client != first_client
      assert final_state.reconnect_attempted == true

      new_client = final_state.client
      assert ModelSelectClient.set_config_option_count(new_client) == 1
    end

    test "reconnect mismatch terminates client and session is unusable" do
      confirmed = model_confirmed_response("reconnect-mismatch-model")

      # Initial session uses a client that confirms the model.
      install_model_select_client(model_response_default: confirmed)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "reconnect-mismatch-model",
          client_opts: [test_pid: self(), model_response_default: confirmed]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} =
               AcpSession.create_session(session, timeout: 1_000)

      # Establish last_session_id so maybe_reconnect will attempt a reconnect.
      :sys.replace_state(session, fn s -> %{s | last_session_id: "reconnect-target"} end)

      state = :sys.get_state(session)
      first_client = state.client
      assert is_pid(first_client)

      # The reconnect path reads the client_opts stored in state.opts, NOT the
      # process dictionary / app env at the time the DOWN fires. Reinstalling
      # the fake client module above does not alter what the new client returns.
      # Mutate state.opts[:client_opts] directly so the reconnect's
      # start_acp_client receives the mismatch response.
      mismatch =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "wrong-model"}
           ]
         }}

      :sys.replace_state(session, fn s ->
        new_opts =
          Keyword.update(s.opts, :client_opts, [], fn co ->
            Keyword.put(co, :model_response_default, mismatch)
          end)

        %{s | opts: new_opts}
      end)

      # Kill the client to trigger DOWN → maybe_reconnect.
      Process.exit(first_client, :kill)

      # Poll until reconnect reaches the exact terminal :error state.
      poll_reconnect_terminal(session)

      final_state = :sys.get_state(session)
      assert final_state.status == :error
      assert final_state.session_id == nil
      assert final_state.last_session_id == nil
      assert final_state.client == nil
      assert final_state.client_monitor == nil

      # Session is broken: send_message is blocked.
      assert {:error, {:not_ready, :error}} =
               AcpSession.send_message(session, "hello", timeout: 1_000)
    end

    test "reconnect mismatch demonitors the failed new client (no orphan DOWN)" do
      # The reconnect path attaches a fresh client monitor before running
      # select_and_confirm_model/4. If model confirmation fails, the
      # new monitor must be demonitored with [:flush] before terminate_client/1
      # so no {:DOWN, ^new_monitor, ...} remains in the mailbox. Otherwise the
      # DOWN arrives after the error branch has nilled state.client and falls
      # through to the catch-all handle_info, surfacing as an "unexpected
      # message" debug log. This test proves the lifecycle is closed.
      previous_level = Logger.level()
      Logger.configure(level: :debug)

      on_exit(fn ->
        Logger.configure(level: previous_level)
      end)

      confirmed = model_confirmed_response("reconnect-orphan-model")

      install_model_select_client(model_response_default: confirmed)

      {:ok, session} =
        AcpSession.start_link(
          provider: :test,
          model: "reconnect-orphan-model",
          client_opts: [test_pid: self(), model_response_default: confirmed]
        )

      on_exit(fn -> safely_close_session(session) end)
      assert :ok = AcpSession.await_ready(session, timeout: 1_000)

      assert {:ok, _info} = AcpSession.create_session(session, timeout: 1_000)

      :sys.replace_state(session, fn s -> %{s | last_session_id: "reconnect-target"} end)

      state = :sys.get_state(session)
      first_client = state.client

      mismatch =
        {:ok,
         %{
           "configOptions" => [
             %{"id" => "model", "currentValue" => "wrong-model"}
           ]
         }}

      :sys.replace_state(session, fn s ->
        new_opts =
          Keyword.update(s.opts, :client_opts, [], fn co ->
            Keyword.put(co, :model_response_default, mismatch)
          end)

        %{s | opts: new_opts}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Process.exit(first_client, :kill)

          poll_reconnect_terminal(session)

          # Give any orphan DOWN a generous window to arrive and (without the
          # fix) be logged by the catch-all handler.
          Process.sleep(100)
        end)

      final_state = :sys.get_state(session)
      assert final_state.status == :error
      assert final_state.client == nil
      assert final_state.client_monitor == nil
      assert final_state.session_id == nil
      assert final_state.last_session_id == nil

      refute log =~ "unexpected message",
             "orphan DOWN reached the catch-all handler:\n#{log}"
    end
  end
end
