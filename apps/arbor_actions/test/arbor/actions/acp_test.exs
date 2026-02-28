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
                 prompt: "Add tests"
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
