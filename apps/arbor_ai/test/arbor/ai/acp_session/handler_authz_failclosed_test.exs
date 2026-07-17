defmodule Arbor.AI.AcpSession.HandlerAuthzFailClosedTest do
  @moduledoc """
  Security regression: the ACP session handler's authorization helpers must FAIL
  CLOSED when the underlying security check raises or exits. Before the
  2026-06-09 fix:

    - `authorize_file/3` rescued/caught to `:ok` (file op auto-authorized)
    - `check_security_authorize/4` rescued/caught to `:authorized` (action
      auto-granted)

  so any exception — or a Security GenServer timeout (`:exit`) — silently
  granted access. These tests force the injected security module to raise/exit
  and assert denial; they fail on `git checkout HEAD~1` of the fix.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.AcpSession.Handler

  defmodule RaisingFileGuard do
    @moduledoc false
    def authorize(_agent_id, _path, _op), do: raise("boom in file guard")
  end

  defmodule ExitingFileGuard do
    @moduledoc false
    def authorize(_agent_id, _path, _op), do: exit(:timeout)
  end

  defmodule RaisingSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _action, _opts), do: raise("boom in security")
  end

  defmodule ExitingSecurity do
    @moduledoc false
    def authorize(_agent_id, _uri, _action, _opts), do: exit(:timeout)
  end

  defmodule RecordingSecurity do
    @moduledoc false

    def authorize(_agent_id, uri, action, _opts) do
      send(Application.fetch_env!(:arbor_ai, :handler_authz_test_pid), {uri, action})
      {:ok, :authorized}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:arbor_ai, :file_guard_module)
      Application.delete_env(:arbor_ai, :security_module)
      Application.delete_env(:arbor_ai, :handler_authz_test_pid)
    end)

    :ok
  end

  describe "authorize_file/3 fails closed" do
    test "denies (error) when FileGuard raises" do
      Application.put_env(:arbor_ai, :file_guard_module, RaisingFileGuard)
      assert {:error, _reason} = Handler.authorize_file("agent_x", "/ws/secret", :write)
    end

    test "denies (error) when FileGuard exits" do
      Application.put_env(:arbor_ai, :file_guard_module, ExitingFileGuard)
      assert {:error, _reason} = Handler.authorize_file("agent_x", "/ws/secret", :write)
    end
  end

  describe "check_security_authorize/4 fails closed" do
    test "denies when Security.authorize raises" do
      Application.put_env(:arbor_ai, :security_module, RaisingSecurity)

      assert {:denied, _reason} =
               Handler.check_security_authorize("agent_x", "arbor://shell/exec/rm", :execute, %{})
    end

    test "denies when Security.authorize exits" do
      Application.put_env(:arbor_ai, :security_module, ExitingSecurity)

      assert {:denied, _reason} =
               Handler.check_security_authorize("agent_x", "arbor://shell/exec/rm", :execute, %{})
    end
  end

  describe "ACP tool identity security regression" do
    test "uses structured kind instead of a human-readable command title" do
      Application.put_env(:arbor_ai, :security_module, RecordingSecurity)
      Application.put_env(:arbor_ai, :handler_authz_test_pid, self())
      {:ok, state} = Handler.init(agent_id: "agent_x")

      tool_call = %{
        "kind" => "execute",
        "title" => "Execute `cd /workspace && git status`",
        "toolCallId" => "call-7752274a-0d51-433c-99e4-2899adc362d4-27"
      }

      assert {:ok, %{"outcome" => "approved"}, ^state} =
               Handler.handle_permission_request("s1", tool_call, [], state)

      assert_receive {"arbor://acp/tool/execute", :execute}
    end

    test "fails closed when only a descriptive title and opaque call id are available" do
      Application.put_env(:arbor_ai, :security_module, RecordingSecurity)
      Application.put_env(:arbor_ai, :handler_authz_test_pid, self())
      {:ok, state} = Handler.init(agent_id: "agent_x")

      tool_call = %{
        "title" => "Execute `rm -rf /workspace`",
        "toolCallId" => "call-opaque-27"
      }

      assert {:ok, %{"outcome" => "denied", "reason" => reason}, ^state} =
               Handler.handle_permission_request("s1", tool_call, [], state)

      assert reason =~ "tool identity"
      refute_receive {_uri, :execute}
    end
  end

  # SECURITY REGRESSION (codex authz.acp-session-anonymous-file-access, HIGH):
  # an ACP session with no caller identity (agent_id == nil) must NOT authorize
  # the external coding agent's file/tool callbacks. Pre-fix, the handler's
  # authorize_file(nil,...) returned :ok and authorize_action(nil,...) returned
  # :authorized — anonymous auto-grant (bounded only by workspace_root, and
  # UNBOUNDED with no workspace_root). The companion entrypoint fix
  # (Arbor.Actions.Acp.StartSession) threads the caller's agent_id so this nil
  # case should not arise in production; these assert the handler fails closed
  # regardless. They fail on `git checkout HEAD~1` of the fix.
  describe "anonymous (nil agent_id) fails closed" do
    test "authorize_file/3 denies a nil-agent file read" do
      assert {:error, _reason} = Handler.authorize_file(nil, "/etc/passwd", :read)
    end

    test "authorize_file/3 denies a nil-agent file write" do
      assert {:error, _reason} = Handler.authorize_file(nil, "/etc/cron.d/x", :write)
    end

    test "handle_file_read denies when the session has no agent_id (no workspace root)" do
      {:ok, state} = Handler.init([])
      assert state.agent_id == nil

      # No workspace_root => path validation passes; the ONLY gate is identity.
      # Pre-fix this read /etc/hostname; post-fix it denies.
      assert {:error, _msg, ^state} = Handler.handle_file_read("s1", "/etc/hostname", %{}, state)
    end

    test "handle_file_write denies when the session has no agent_id (no workspace root)" do
      {:ok, state} = Handler.init([])
      path = Path.join(System.tmp_dir!(), "acp_anon_write_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)

      assert {:error, _msg, ^state} = Handler.handle_file_write("s1", path, "pwned", %{}, state)
      refute File.exists?(path), "anonymous session must not create files"
    end

    test "handle_permission_request rejects a nil-agent tool request" do
      {:ok, state} = Handler.init([])

      assert {:ok, %{"outcome" => "denied"}, ^state} =
               Handler.handle_permission_request("s1", %{"name" => "edit"}, %{}, state)
    end
  end
end
