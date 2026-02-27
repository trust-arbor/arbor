defmodule Arbor.AI.AcpSessionTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.Config

  @moduletag :fast

  describe "Config.resolve/2" do
    test "resolves native ACP providers" do
      assert {:ok, opts} = Config.resolve(:gemini)
      assert opts[:command] == ["gemini", "--experimental-acp"]
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

    test "handle_permission_request approves when no agent_id" do
      {:ok, state} = Handler.init([])

      assert {:ok, %{"outcome" => "approved"}, ^state} =
               Handler.handle_permission_request("session-1", %{"name" => "tool"}, %{}, state)
    end

    test "handle_permission_request approves with agent_id but no CapabilityStore" do
      {:ok, state} = Handler.init(agent_id: "test-agent")

      assert {:ok, %{"outcome" => "approved"}, ^state} =
               Handler.handle_permission_request("s1", %{"name" => "edit"}, %{}, state)
    end

    test "handle_file_read reads existing file (no workspace root)" do
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

    test "handle_file_write writes file (no workspace root)" do
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

  describe "Handler path validation (workspace_root set)" do
    alias Arbor.AI.AcpSession.Handler

    setup do
      # Create a temp workspace directory
      workspace = Path.join(System.tmp_dir!(), "acp_ws_test_#{:rand.uniform(100_000)}")
      File.mkdir_p!(workspace)
      {:ok, state} = Handler.init(cwd: workspace)

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
