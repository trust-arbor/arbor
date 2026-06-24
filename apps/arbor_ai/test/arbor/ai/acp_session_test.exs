defmodule Arbor.AI.AcpSessionTest do
  # async: false — the Handler describes inject :arbor_ai app-env (file_guard /
  # security module) to exercise authorized file ops without a real grant, after
  # the H3 anonymous-access fix made nil-agent callbacks fail closed.
  use ExUnit.Case, async: false

  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.Config

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

  defp install_passthrough_authz do
    Application.put_env(:arbor_ai, :file_guard_module, PassthroughFileGuard)
    Application.put_env(:arbor_ai, :security_module, PassthroughSecurity)

    on_exit(fn ->
      Application.delete_env(:arbor_ai, :file_guard_module)
      Application.delete_env(:arbor_ai, :security_module)
    end)
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

  describe "status includes usage" do
    @test_client_opts [command: ["echo", "test"], _skip_connect: true]

    test "status returns zero usage on fresh session" do
      {:ok, session} =
        AcpSession.start_link(provider: :test, client_opts: @test_client_opts)

      status = AcpSession.status(session)
      assert status.usage == %{input_tokens: 0, output_tokens: 0}

      GenServer.stop(session)
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

    defp test_state(timeout_ms \\ 200) do
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
      Application.put_env(:arbor_ai, :acp_permission_timeout_ms, 999)

      on_exit(fn ->
        Application.delete_env(:arbor_ai, :acp_permission_timeout_ms)
      end)

      {:ok, state} = Handler.init(permission_timeout_ms: 12_345)
      assert state.permission_timeout_ms == 12_345
    end

    test "app env wins when no explicit opt" do
      Application.put_env(:arbor_ai, :acp_permission_timeout_ms, 7_777)

      on_exit(fn ->
        Application.delete_env(:arbor_ai, :acp_permission_timeout_ms)
      end)

      {:ok, state} = Handler.init([])
      assert state.permission_timeout_ms == 7_777
    end
  end
end
