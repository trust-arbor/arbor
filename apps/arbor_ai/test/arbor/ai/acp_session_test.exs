defmodule Arbor.AI.AcpSessionTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.Config

  @moduletag :fast

  describe "Config.resolve/2" do
    test "resolves native ACP providers" do
      assert {:ok, opts} = Config.resolve(:gemini)
      assert opts[:command] == ["gemini", "--acp"]
    end

    test "resolves adapted providers" do
      assert {:ok, opts} = Config.resolve(:claude)
      assert opts[:transport_mod] == ExMCP.ACP.AdapterTransport
      assert opts[:adapter] == ExMCP.ACP.Adapters.Claude
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
        if original do
          Application.put_env(:arbor_ai, :acp_providers, original)
        else
          Application.delete_env(:arbor_ai, :acp_providers)
        end
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
    end

    test "marks providers correctly as native or adapted" do
      providers = Config.list_providers() |> Map.new()

      assert providers[:gemini] == :native
      assert providers[:claude] == :adapted
      assert providers[:codex] == :adapted
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
      assert status.status == :starting

      GenServer.stop(session)
    end

    test "send_message fails when session not yet created" do
      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: @test_client_opts)

      # Status is :starting (not :ready) because create_session hasn't been called
      assert {:error, {:not_ready, :starting}} = AcpSession.send_message(session, "hello")

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
      assert status.status == :starting

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

  describe "AcpSession.Handler" do
    alias Arbor.AI.AcpSession.Handler

    test "init creates handler state" do
      assert {:ok, state} = Handler.init(cwd: "/tmp/project")
      assert state.roots == [%{uri: "file:///tmp/project", name: "workspace"}]
    end

    test "init with no cwd creates empty roots" do
      assert {:ok, state} = Handler.init([])
      assert state.roots == []
    end

    test "handle_session_update returns ok" do
      {:ok, state} = Handler.init([])
      assert {:ok, ^state} = Handler.handle_session_update("s1", %{"kind" => "status"}, state)
    end

    test "handle_permission_request auto-approves" do
      {:ok, state} = Handler.init([])

      assert {:ok, %{"outcome" => "approved"}, ^state} =
               Handler.handle_permission_request("session-1", %{}, %{}, state)
    end

    test "handle_file_read reads existing file" do
      {:ok, state} = Handler.init([])
      path = Path.join(System.tmp_dir!(), "acp_handler_test_#{:rand.uniform(100_000)}")

      try do
        File.write!(path, "test content")
        assert {:ok, "test content", ^state} = Handler.handle_file_read("s1", path, %{}, state)
      after
        File.rm(path)
      end
    end

    test "handle_file_read returns error for missing file" do
      {:ok, state} = Handler.init([])
      assert {:error, _, _} = Handler.handle_file_read("s1", "/nonexistent/file", %{}, state)
    end

    test "handle_file_write writes file" do
      {:ok, state} = Handler.init([])
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
end
