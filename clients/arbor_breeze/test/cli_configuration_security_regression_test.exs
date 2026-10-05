defmodule ArborBreeze.CLIConfigurationSecurityRegressionTest.ClientProbe do
  def load_key(path) do
    send(self(), {:auth_call, :load_key, [path]})

    {:ok,
     %{
       agent_id: Process.get(:probe_principal, "agent_operator"),
       private_key: :binary.copy(<<1>>, 32)
     }}
  end

  def start_login(url, target) do
    send(self(), {:auth_call, :start_login, [url, target]})
    {:error, :probe_stopped}
  end

  def resolve_agent(identity, url, target) do
    send(self(), {:auth_call, :resolve_agent, [identity, url, target]})
    {:error, :ambiguous}
  end

  def stop_agent(identity, url, target) do
    send(self(), {:auth_call, :stop_agent, [identity, url, target]})
    {:error, :probe_stopped}
  end
end

defmodule ArborBreeze.CLIConfigurationSecurityRegressionTest do
  use ExUnit.Case, async: true
  @moduletag :fast
  import ExUnit.CaptureIO
  alias ArborBreeze.CLI
  alias ArborBreeze.CLIConfigurationSecurityRegressionTest.ClientProbe

  test "public startup preserves URL precedence and canonicalizes the selected origin" do
    cases = [
      {["--url", "wss://explicit.test/api/chat/socket"], "url = https://configured.test",
       %{"ARBOR_GATEWAY_URL" => "https://environment.test"}, "https://explicit.test"},
      {[], "url = https://configured.test", %{"ARBOR_GATEWAY_URL" => "https://environment.test"},
       "https://configured.test"},
      {[], :missing, %{"ARBOR_GATEWAY_URL" => "wss://environment.test/"},
       "https://environment.test"},
      {[], :missing, %{}, "http://127.0.0.1:4000"},
      {[], "url = ws://127.0.0.1:4000/api/chat/socket", %{}, "http://127.0.0.1:4000"}
    ]

    for {argv, body, env, expected} <- cases do
      assert {:ok, options} = CLI.resolve(argv, sources(body, env))
      assert options[:url] == expected
      assert :ok = detached(options, :human, nil, expected)
      refute_received {:auth_call, _, _}
    end
  end

  test "configured chat target receives fresh human login and explicit target wins" do
    for {argv, expected} <- [
          {[], "agent_configured"},
          {["-a", "agent_explicit"], "agent_explicit"}
        ] do
      assert {:ok, options} =
               CLI.resolve(
                 argv,
                 sources("url = https://configured.test\nagent = agent_configured")
               )

      assert {:error, :probe_stopped} = CLI.run(options, ClientProbe, &unexpected_native/1)
      assert_received {:auth_call, :start_login, ["https://configured.test", ^expected]}
      refute_received {:auth_call, :load_key, _}
      refute_received {:auth_call, :resolve_agent, _}
    end
  end

  test "config agent never changes an explicit signed operator command" do
    assert {:ok, options} =
             CLI.resolve(
               ["stop", "agent_explicit", "--key", "/private/selected.key"],
               sources("url = https://configured.test\nagent = agent_other\nkey = ignored")
             )

    refute Keyword.has_key?(options, :agent)
    assert {:error, :probe_stopped} = CLI.run(options, ClientProbe, &unexpected_native/1)
    assert_received {:auth_call, :load_key, ["/private/selected.key"]}

    assert_received {:auth_call, :stop_agent,
                     [%{agent_id: "agent_operator"}, "https://configured.test", "agent_explicit"]}

    refute_received {:auth_call, :start_login, _}
  end

  test "short aliases are equivalent and mixed duplicate spellings fail before sources are consulted" do
    short = ["-a", "agent_fixture", "-u", "https://gateway.test", "-k", "/private/key"]
    long = ["--agent", "agent_fixture", "--url", "https://gateway.test", "--key", "/private/key"]
    assert CLI.parse(short) == CLI.parse(long)
    assert CLI.resolve(short, unused_sources()) == CLI.resolve(long, unused_sources())

    for argv <- [
          ["-a", "agent_a", "--agent", "agent_b"],
          ["--agent=agent_a", "-a", "agent_b"],
          ["-u", "https://a.test", "--url", "https://b.test"],
          ["--key", "a", "-k", "b"],
          ["-u", "https://a.test", "-u", "https://b.test"]
        ] do
      assert {:error, :invalid_options} = CLI.resolve(argv, unused_sources())
    end
  end

  test "argument parsing and help never consult file or environment sources" do
    assert {:ok, options} = CLI.parse([])
    assert options[:url] == "http://127.0.0.1:4000"
    assert :help = CLI.resolve(["--help"], unused_sources())
    assert :help = CLI.parse(["--help"])
  end

  test "security regression legacy credential selectors cannot change human authentication intent" do
    assert {:ok, options} =
             CLI.resolve(
               [],
               sources(
                 "key = /private/configured.key\ntoken = do-not-adopt",
                 %{"ARBOR_KEY" => "/private/implicit.key"}
               )
             )

    refute Keyword.has_key?(options, :key)
    assert :ok = detached(options, :human, nil, "http://127.0.0.1:4000")
    refute_received {:env_read, "ARBOR_KEY"}
    refute_received {:auth_call, _, _}
    assert_received {:config_read, "/test-home/.arbor/tui.conf"}
    refute_received {:config_read, _}
  end

  test "explicit signing retains both agent and human subjects verbatim" do
    for principal <- ["agent_operator", "human_operator"] do
      Process.put(:probe_principal, principal)
      assert {:ok, options} = CLI.resolve(["-k", "/private/selected.key"], sources(:missing))
      assert :ok = detached(options, :signed, principal, "http://127.0.0.1:4000")
      assert_received {:auth_call, :load_key, ["/private/selected.key"]}
      refute_received {:auth_call, :start_login, _}
      refute_received {:auth_call, :resolve_agent, _}
    end
  end

  test "signed aliases resolve once under the exact selected signing principal" do
    assert {:ok, options} =
             CLI.resolve(
               ["--agent", "cedar", "--key", "/private/selected.key"],
               sources("url = wss://configured.test")
             )

    assert {:error, :ambiguous} = CLI.run(options, ClientProbe, &unexpected_native/1)
    assert_received {:auth_call, :load_key, ["/private/selected.key"]}

    assert_received {:auth_call, :resolve_agent,
                     [%{agent_id: "agent_operator"}, "https://configured.test", "cedar"]}

    refute_received {:auth_call, :start_login, _}
    refute_received {:auth_call, :resolve_agent, _}
  end

  test "security regression unsafe destinations do not read a signing key or initiate login" do
    for url <- [
          "http://remote.test:4000",
          "https://user:secret@remote.test",
          "https://remote.test?credential=secret",
          "https://remote.test#secret",
          "https://remote.test/private",
          "https://remote.test:0"
        ] do
      assert {:ok, options} =
               CLI.parse(["--agent", "agent_fixture", "--url", url, "--key", "/private/key"])

      result = CLI.run(options, ClientProbe, &unexpected_native/1)
      refute_received {:auth_call, _, _}
      assert {:error, :unsafe_gateway_url} = result
    end

    assert {:ok, options} =
             CLI.parse(["--agent", "agent_fixture", "--url", "http://localhost:4000"])

    assert {:error, :unsafe_gateway_url} = CLI.run(options, ClientProbe, &unexpected_native/1)
    refute_received {:auth_call, _, _}
  end

  test "human localhost configuration is refused while explicit signing retains its existing policy" do
    config = sources("url = ws://localhost:4000")
    assert {:error, :unsafe_gateway_url} = CLI.resolve([], config)
    refute_received {:auth_call, _, _}
    assert {:ok, options} = CLI.resolve(["--key", "/private/key"], config)
    assert options[:url] == "http://localhost:4000"
    assert :ok = detached(options, :signed, "agent_operator", "http://localhost:4000")
    assert_received {:auth_call, :load_key, ["/private/key"]}
  end

  test "selected malformed configuration and bad environment URL never fall back" do
    for body <- [
          "url = https://a.test\nurl = https://b.test",
          "agent = agent_a\nagent = agent_b",
          "url =",
          "agent =",
          "broken configuration line",
          "url = https://gateway.test\x00",
          <<255>>,
          String.duplicate("x", 4_097)
        ] do
      assert {:error, :configuration_unavailable} =
               CLI.resolve([], sources(body, %{"ARBOR_GATEWAY_URL" => "https://fallback.test"}))
    end

    for url <- [
          "",
          "http://remote.test",
          "https://gateway.test?secret=value",
          "https://bad.test\n"
        ] do
      assert {:error, reason} = CLI.resolve([], sources(:missing, %{"ARBOR_GATEWAY_URL" => url}))
      assert reason in [:unsafe_gateway_url, :invalid_options]
    end

    refute_received {:auth_call, _, _}
  end

  test "unreadable selected config fails statically and complete explicit settings skip it" do
    assert {:error, :configuration_unavailable} = CLI.resolve([], sources({:error, :eacces}))

    assert {:ok, _} =
             CLI.resolve(
               ["--agent", "agent_fixture", "--url", "https://explicit.test"],
               unused_sources()
             )

    assert {:ok, _} =
             CLI.resolve(
               ["agents", "--key", "/private/key", "--url", "https://explicit.test"],
               unused_sources()
             )
  end

  test "explicit ARBOR_HOME selects only its own config and invalid roots never fall through" do
    assert {:ok, options} =
             CLI.resolve([], sources(:missing, %{"ARBOR_HOME" => "/isolated/arbor"}))

    assert options[:url] == "http://127.0.0.1:4000"
    assert_received {:config_read, "/isolated/arbor/tui.conf"}
    refute_received {:config_read, _}

    for root <- ["", "relative/arbor", "\x00/private/home"] do
      assert {:error, :configuration_unavailable} =
               CLI.resolve([], sources(:missing, %{"ARBOR_HOME" => root}))
    end

    refute_received {:config_read, _}
  end

  test "real bounded config IO rejects symlinks directories and oversize while leaving unscoped state untouched" do
    root =
      Path.join(
        System.tmp_dir!(),
        "breeze-config-" <> Base.encode16(:crypto.strong_rand_bytes(12))
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "tui.conf")
    state = Path.join(root, "tui.state")
    File.write!(state, "last_agent = agent_legacy\ncredential = legacy-secret\n")

    config =
      ArborBreeze.Config.default_sources()
      |> Map.put(:get_env, fn
        "ARBOR_HOME" -> root
        "ARBOR_GATEWAY_URL" -> nil
        other -> flunk("unexpected environment read: #{other}")
      end)

    assert {:ok, options} = CLI.resolve([], config)
    refute Keyword.has_key?(options, :agent)
    File.write!(path, "url = https://configured.test\n# comment\nkey = never-loaded\n")
    assert {:ok, options} = CLI.resolve([], config)
    assert :ok = detached(options, :human, nil, "https://configured.test")
    refute_received {:auth_call, _, _}
    assert File.read!(state) == "last_agent = agent_legacy\ncredential = legacy-secret\n"

    File.write!(path, String.duplicate("x", 4_097))
    assert {:error, :configuration_unavailable} = CLI.resolve([], config)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, :configuration_unavailable} = CLI.resolve([], config)
    File.rmdir!(path)
    File.ln_s!(state, path)
    assert {:error, :configuration_unavailable} = CLI.resolve([], config)
    assert File.read!(state) == "last_agent = agent_legacy\ncredential = legacy-secret\n"
  end

  test "help static failures and detached snapshots expose no credential material or key path" do
    text =
      CLI.usage() <>
        CLI.error_message(:configuration_unavailable) <> CLI.error_message(:unsafe_gateway_url)

    assert text =~ "ARBOR_KEY"
    refute text =~ "/private/selected.key"
    refute text =~ "private_key_b64"
    assert {:ok, options} = CLI.resolve(["--key", "/private/selected.key"], sources(:missing))

    output =
      capture_io(fn ->
        assert :ok = detached(options, :signed, "agent_operator", options[:url])
      end)

    assert output == ""
  end

  defp sources(body, env \\ %{}) do
    %{
      home: "/test-home",
      get_env: fn name ->
        send(self(), {:env_read, name})
        Map.get(env, name)
      end,
      read_config: fn path ->
        send(self(), {:config_read, path})

        case body do
          :missing -> {:error, :enoent}
          {:error, _} = error -> error
          bytes -> {:ok, bytes}
        end
      end
    }
  end

  defp unused_sources do
    %{
      home: "/test-home",
      get_env: fn _ -> flunk("consulted environment") end,
      read_config: fn _ -> flunk("consulted config") end
    }
  end

  defp detached(options, mode, principal, gateway) do
    CLI.run(options, ClientProbe, fn controller ->
      {:ok, snapshot} = ArborBreeze.Controller.subscribe(controller)
      assert snapshot.navigation.mode == mode
      assert snapshot.navigation.principal == principal
      assert snapshot.navigation.gateway == gateway
      assert snapshot.navigation.target == nil
      refute snapshot.connected
      assert snapshot.projection["messages"] == []
      refute inspect(snapshot) =~ "/private/"
      refute inspect(snapshot) =~ "private_key"
      :ok
    end)
  end

  defp unexpected_native(_), do: flunk("unexpected terminal attachment")
end
