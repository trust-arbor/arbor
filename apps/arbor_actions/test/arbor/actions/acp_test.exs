defmodule Arbor.Actions.AcpTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.Acp

  @moduletag :fast

  # ── StartSession ──

  describe "StartSession" do
    test "validates action metadata" do
      assert Acp.StartSession.name() == "acp_start_session"
      assert Acp.StartSession.category() == "acp"
      assert "acp" in Acp.StartSession.tags()
      assert "start" in Acp.StartSession.tags()
    end

    test "schema requires provider" do
      assert {:error, _} = Acp.StartSession.validate_params(%{})
    end

    test "schema accepts valid provider" do
      assert {:ok, _} = Acp.StartSession.validate_params(%{provider: "claude"})
    end

    test "schema accepts all optional fields" do
      assert {:ok, _} =
               Acp.StartSession.validate_params(%{
                 provider: "claude",
                 model: "opus",
                 cwd: "/tmp",
                 session_id: "sess_123",
                 use_pool: true,
                 permission_mode: "default",
                 allowed_tools: ["Read"],
                 disallowed_tools: ["Write"],
                 timeout: 60_000
               })
    end

    test "generates tool schema" do
      tool = Acp.StartSession.to_tool()
      assert is_map(tool)
      assert tool[:name] == "acp_start_session"
      assert tool[:description] =~ "ACP"
    end

    test "taint roles classify provider as control" do
      roles = Acp.StartSession.taint_roles()
      assert roles[:provider] == :control
      assert roles[:model] == :control
      assert roles[:timeout] == :data
      assert roles[:use_pool] == :data
    end

    test "taint roles classify cwd as path_traversal control" do
      roles = Acp.StartSession.taint_roles()
      assert roles[:cwd] == {:control, requires: [:path_traversal]}
    end

    test "returns error for unknown provider" do
      result = Acp.StartSession.run(%{provider: "unknown_agent"}, %{})
      assert {:error, msg} = result
      assert msg =~ "Unknown provider"
    end

    # SECURITY REGRESSION (codex authz.acp-session-anonymous-file-access, HIGH):
    # StartSession.run/2 discarded its context, so the caller's agent_id never
    # reached the ACP session — the handler then authorized the coding agent's
    # file/tool callbacks as ANONYMOUS. The identity must be forwarded into the
    # session opts. These pin the entrypoint half of the fix (the handler half
    # lives in arbor_ai/.../handler_authz_failclosed_test.exs). They fail on
    # `git checkout HEAD~1`.
    test "security regression: caller_agent_id extracts identity from atom- or string-keyed context" do
      assert Acp.StartSession.caller_agent_id(%{agent_id: "agent_42"}) == "agent_42"
      assert Acp.StartSession.caller_agent_id(%{"agent_id" => "agent_42"}) == "agent_42"
      assert Acp.StartSession.caller_agent_id(%{}) == nil
      assert Acp.StartSession.caller_agent_id(nil) == nil
    end

    test "security regression: build_opts threads the caller's agent_id into session opts" do
      opts =
        Acp.StartSession.build_opts(
          %{
            model: "opus",
            cwd: "/ws",
            permission_mode: "default",
            allowed_tools: ["Read", "Grep"],
            disallowed_tools: ["Write"]
          },
          "agent_42"
        )

      assert Keyword.get(opts, :agent_id) == "agent_42",
             "the session must carry the caller identity so file/tool callbacks are not anonymous"

      assert Keyword.get(opts, :model) == "opus"
      assert Keyword.get(opts, :cwd) == "/ws"

      adapter_opts = Keyword.fetch!(opts, :adapter_opts)
      assert Keyword.get(adapter_opts, :permission_mode) == :default
      assert Keyword.get(adapter_opts, :allowed_tools) == ["Read", "Grep"]
      assert Keyword.get(adapter_opts, :disallowed_tools) == ["Write"]
    end

    test "build_opts omits agent_id when there is no caller identity" do
      opts = Acp.StartSession.build_opts(%{model: "opus"}, nil)
      refute Keyword.has_key?(opts, :agent_id)
    end

    test "normalize_permission_mode refuses unknown values instead of atomizing input" do
      assert Acp.StartSession.normalize_permission_mode("default") == :default
      assert Acp.StartSession.normalize_permission_mode(:deny) == :deny
      assert Acp.StartSession.normalize_permission_mode("bypass") == :bypass
      assert Acp.StartSession.normalize_permission_mode("String.to_atom footgun") == nil
    end
  end

  # ── SendMessage ──

  describe "SendMessage" do
    test "validates action metadata" do
      assert Acp.SendMessage.name() == "acp_send_message"
      assert Acp.SendMessage.category() == "acp"
      assert "message" in Acp.SendMessage.tags()
    end

    test "schema requires session_pid and prompt" do
      assert {:error, _} = Acp.SendMessage.validate_params(%{})
      assert {:error, _} = Acp.SendMessage.validate_params(%{session_pid: self()})
    end

    test "schema accepts valid params" do
      assert {:ok, _} =
               Acp.SendMessage.validate_params(%{
                 session_pid: self(),
                 prompt: "Add tests",
                 timeout: 123_456,
                 inactivity_timeout_ms: 654_321
               })
    end

    test "generates tool schema" do
      tool = Acp.SendMessage.to_tool()
      assert is_map(tool)
      assert tool[:name] == "acp_send_message"
    end

    test "taint roles classify prompt as prompt_injection control" do
      roles = Acp.SendMessage.taint_roles()
      assert roles[:prompt] == {:control, requires: [:prompt_injection]}
      assert roles[:session_pid] == :control
      assert roles[:timeout] == :data
      assert roles[:inactivity_timeout_ms] == :data
    end

    test "returns error for dead PID" do
      # Spawn and kill a process to get a dead PID
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      result = Acp.SendMessage.run(%{session_pid: pid, prompt: "test"}, %{})
      assert {:error, msg} = result
      assert msg =~ "not found" or msg =~ "dead"
    end
  end

  # ── SessionStatus ──

  describe "SessionStatus" do
    test "validates action metadata" do
      assert Acp.SessionStatus.name() == "acp_session_status"
      assert Acp.SessionStatus.category() == "acp"
      assert "status" in Acp.SessionStatus.tags()
    end

    test "schema requires session_pid" do
      assert {:error, _} = Acp.SessionStatus.validate_params(%{})
    end

    test "schema accepts valid params" do
      assert {:ok, _} = Acp.SessionStatus.validate_params(%{session_pid: self()})
    end

    test "generates tool schema" do
      tool = Acp.SessionStatus.to_tool()
      assert is_map(tool)
      assert tool[:name] == "acp_session_status"
    end

    test "taint roles classify session_pid as control" do
      roles = Acp.SessionStatus.taint_roles()
      assert roles[:session_pid] == :control
    end

    test "returns error for dead PID" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      result = Acp.SessionStatus.run(%{session_pid: pid}, %{})
      assert {:error, msg} = result
      assert msg =~ "not found" or msg =~ "dead"
    end
  end

  # ── CloseSession ──

  describe "CloseSession" do
    test "validates action metadata" do
      assert Acp.CloseSession.name() == "acp_close_session"
      assert Acp.CloseSession.category() == "acp"
      assert "close" in Acp.CloseSession.tags()
    end

    test "schema requires session_pid" do
      assert {:error, _} = Acp.CloseSession.validate_params(%{})
    end

    test "schema accepts valid params" do
      assert {:ok, _} = Acp.CloseSession.validate_params(%{session_pid: self()})
    end

    test "schema accepts return_to_pool option" do
      assert {:ok, _} =
               Acp.CloseSession.validate_params(%{
                 session_pid: self(),
                 return_to_pool: true
               })
    end

    test "generates tool schema" do
      tool = Acp.CloseSession.to_tool()
      assert is_map(tool)
      assert tool[:name] == "acp_close_session"
    end

    test "taint roles classify return_to_pool as data" do
      roles = Acp.CloseSession.taint_roles()
      assert roles[:session_pid] == :control
      assert roles[:return_to_pool] == :data
    end

    test "returns error for dead PID" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      result = Acp.CloseSession.run(%{session_pid: pid}, %{})
      assert {:error, msg} = result
      assert msg =~ "not found" or msg =~ "dead"
    end
  end

  # ── Shared Helpers ──

  describe "module structure" do
    test "all action modules compile and are usable" do
      assert Code.ensure_loaded?(Acp.StartSession)
      assert Code.ensure_loaded?(Acp.SendMessage)
      assert Code.ensure_loaded?(Acp.SessionStatus)
      assert Code.ensure_loaded?(Acp.CloseSession)

      assert function_exported?(Acp.StartSession, :run, 2)
      assert function_exported?(Acp.SendMessage, :run, 2)
      assert function_exported?(Acp.SessionStatus, :run, 2)
      assert function_exported?(Acp.CloseSession, :run, 2)
    end

    test "acp_available? returns boolean" do
      result = Acp.acp_available?()
      assert is_boolean(result)
    end
  end

  describe "allowed_providers/0 (catalog-derived, no static drift)" do
    test "derives the allowlist from the Arbor.AI ACP catalog" do
      providers = Acp.allowed_providers()
      assert is_list(providers)
      assert Enum.all?(providers, &is_atom/1)
      # Catalog == authoritative source. Compare against the facade directly.
      assert MapSet.new(providers) == MapSet.new(Arbor.AI.acp_providers())
    end

    test "includes config-only providers the old static list missed (grok)" do
      # `grok` is registered purely via `config :arbor_ai, :acp_providers` in
      # config/config.exs — it was never in the hardcoded @allowed_providers, so
      # the action layer used to reject it. Deriving from the catalog fixes that.
      assert :grok in Acp.allowed_providers()
    end

    test "includes cursor (native ACP provider)" do
      assert :cursor in Acp.allowed_providers()
    end
  end

  describe "resolve_pid/1" do
    test "passes through actual PIDs" do
      assert Acp.resolve_pid(self()) == self()
    end

    test "resolves stringified PIDs" do
      pid_string = inspect(self())
      resolved = Acp.resolve_pid(pid_string)
      assert resolved == self()
    end

    test "returns nil for invalid input" do
      assert Acp.resolve_pid("not_a_pid") == nil
      assert Acp.resolve_pid(123) == nil
      assert Acp.resolve_pid(nil) == nil
    end
  end

  describe "name_to_module integration" do
    test "acp actions are discoverable by name" do
      assert {:ok, Acp.StartSession} = Arbor.Actions.name_to_module("acp.start_session")
      assert {:ok, Acp.SendMessage} = Arbor.Actions.name_to_module("acp.send_message")
      assert {:ok, Acp.SessionStatus} = Arbor.Actions.name_to_module("acp.session_status")
      assert {:ok, Acp.CloseSession} = Arbor.Actions.name_to_module("acp.close_session")
    end

    test "acp actions appear in list_actions" do
      actions = Arbor.Actions.list_actions()
      assert Map.has_key?(actions, :acp)
      assert length(actions[:acp]) == 4
    end
  end
end
