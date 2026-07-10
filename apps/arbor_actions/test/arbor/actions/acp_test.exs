defmodule Arbor.Actions.AcpTest.FakeAI do
  @moduledoc false

  def acp_providers, do: Arbor.AI.acp_providers()

  def acp_managed_start_session(provider, opts) when is_atom(provider) and is_list(opts) do
    notify({:managed_start, provider, opts})

    :persistent_term.get(
      {__MODULE__, :start_result},
      {:ok,
       %{
         worker_session_id:
           "acp_worker_" <> Integer.to_string(System.unique_integer([:positive])),
         session_id: "provider_sess_1",
         provider: Atom.to_string(provider),
         model: Keyword.get(opts, :model) || "default",
         status: "ready",
         pooled: Keyword.get(opts, :use_pool, false) == true
       }}
    )
  end

  def acp_managed_send_message(worker_session_id, content, opts)
      when is_binary(worker_session_id) and is_binary(content) and is_list(opts) do
    notify({:managed_send, worker_session_id, content, opts})

    {:ok,
     %{
       "text" => "echo:#{content}",
       "stop_reason" => "end_turn",
       "session_id" => "provider_sess_1",
       "usage" => %{}
     }}
  end

  def acp_managed_session_status(worker_session_id, opts)
      when is_binary(worker_session_id) and is_list(opts) do
    notify({:managed_status, worker_session_id, opts})

    {:ok,
     %{
       worker_session_id: worker_session_id,
       session_id: "provider_sess_1",
       provider: "claude",
       model: "opus",
       status: "ready",
       pooled: false,
       context_pressure: true,
       context_tokens: 42,
       usage: %{"input_tokens" => 10, "output_tokens" => 5}
     }}
  end

  def acp_managed_close_session(worker_session_id, opts)
      when is_binary(worker_session_id) and is_list(opts) do
    notify({:managed_close, worker_session_id, opts})

    status =
      if Keyword.get(opts, :return_to_pool) == true do
        "returned_to_pool"
      else
        "closed"
      end

    {:ok,
     %{
       worker_session_id: worker_session_id,
       session_id: "provider_sess_1",
       provider: "claude",
       model: "opus",
       status: status,
       pooled: Keyword.get(opts, :return_to_pool) == true,
       active: false
     }}
  end

  # Legacy PID APIs kept so availability / accidental fallback stay testable.
  def acp_start_session(_provider, _opts), do: {:error, :use_managed}

  def acp_send_message(pid, content, opts) do
    notify({:legacy_send, pid, content, opts})
    {:ok, %{text: "legacy", stop_reason: "end_turn", session_id: "", usage: %{}}}
  end

  def acp_close_session(pid), do: notify({:legacy_close, pid})

  def acp_checkin(pid) do
    notify({:legacy_checkin, pid})
    :ok
  end

  defp notify(msg) do
    case :persistent_term.get({__MODULE__, :parent}, nil) do
      pid when is_pid(pid) -> send(pid, msg)
      _ -> :ok
    end
  end
end

defmodule Arbor.Actions.AcpTest do
  use Arbor.Actions.ActionCase, async: false

  alias Arbor.Actions.Acp
  alias Arbor.Actions.AcpTest.FakeAI
  alias Arbor.Actions.Config
  alias Arbor.Contracts.Security.AuthContext

  @moduletag :fast

  setup do
    original_ai = Application.get_env(:arbor_actions, :ai_module)

    on_exit(fn ->
      if is_nil(original_ai) do
        Application.delete_env(:arbor_actions, :ai_module)
      else
        Application.put_env(:arbor_actions, :ai_module, original_ai)
      end

      :persistent_term.erase({FakeAI, :parent})
      :persistent_term.erase({FakeAI, :start_result})
    end)

    :ok
  end

  # StartSession

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
    # reached the ACP session; the handler then authorized the coding agent's
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

    test "public run returns JSON-encodable handle metadata and no PID/ref/function/struct" do
      install_fake_ai()

      assert {:ok, result} =
               Acp.StartSession.run(
                 %{provider: "claude", model: "opus", cwd: "/ws", use_pool: false},
                 %{agent_id: "agent_start", task_id: "task_start"}
               )

      assert is_binary(result.worker_session_id)
      assert String.starts_with?(result.worker_session_id, "acp_worker_")
      assert result.session_id == "provider_sess_1"
      assert result.provider == "claude"
      assert result.model == "opus"
      assert result.status == "ready"
      assert result.pooled == false
      refute Map.has_key?(result, :session_pid)

      assert json_clean?(result)
      refute_pid_like(result)

      assert {:ok, _} = Jason.encode(result)
    end

    test "rejects managed start success without a durable worker handle" do
      install_fake_ai()
      :persistent_term.put({FakeAI, :start_result}, {:ok, %{session_id: "provider_sess_1"}})

      assert {:error, error} =
               Acp.StartSession.run(
                 %{provider: "claude", cwd: "/ws", use_pool: false},
                 %{agent_id: "agent_start", task_id: "task_start"}
               )

      assert error =~ "invalid_worker_session_handle"
    end

    test "security regression: public StartSession forwards AuthContext/agent_id and task_id to managed start" do
      install_fake_ai()

      auth = %AuthContext{principal_id: "agent_auth_ctx"}

      assert {:ok, _result} =
               Acp.StartSession.run(
                 %{
                   provider: "claude",
                   model: "sonnet",
                   cwd: "/repo",
                   permission_mode: "default",
                   allowed_tools: ["Read"],
                   timeout: 60_000
                 },
                 %{
                   auth_context: auth,
                   task_id: "task_secure_1",
                   agent_id: "agent_should_not_win"
                 }
               )

      assert_receive {:managed_start, :claude, opts}
      assert Keyword.get(opts, :agent_id) == "agent_auth_ctx"
      assert Keyword.get(opts, :principal_id) == "agent_auth_ctx"
      assert Keyword.get(opts, :task_id) == "task_secure_1"
      assert Keyword.get(opts, :model) == "sonnet"
      assert Keyword.get(opts, :cwd) == "/repo"

      adapter_opts = Keyword.fetch!(opts, :adapter_opts)
      assert Keyword.get(adapter_opts, :permission_mode) == :default
      assert Keyword.get(adapter_opts, :allowed_tools) == ["Read"]
    end
  end

  # SendMessage

  describe "SendMessage" do
    test "validates action metadata" do
      assert Acp.SendMessage.name() == "acp_send_message"
      assert Acp.SendMessage.category() == "acp"
      assert "message" in Acp.SendMessage.tags()
    end

    test "schema requires prompt" do
      assert {:error, _} = Acp.SendMessage.validate_params(%{})
      assert {:error, _} = Acp.SendMessage.validate_params(%{session_pid: self()})
      assert {:error, _} = Acp.SendMessage.validate_params(%{worker_session_id: "acp_worker_x"})
    end

    test "schema accepts worker_session_id or legacy session_pid" do
      assert {:ok, _} =
               Acp.SendMessage.validate_params(%{
                 worker_session_id: "acp_worker_abc",
                 prompt: "Add tests"
               })

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
      assert roles[:worker_session_id] == :control
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

    test "handle-only one-of validation errors are clear" do
      result = Acp.SendMessage.run(%{prompt: "hello"}, %{})
      assert {:error, msg} = result
      assert msg =~ "worker_session_id" or msg =~ "session_pid"
    end

    test "prefers worker_session_id and passes matching authority opts" do
      install_fake_ai()
      live = self()

      assert {:ok, result} =
               Acp.SendMessage.run(
                 %{
                   worker_session_id: "acp_worker_send",
                   session_pid: live,
                   prompt: "implement feature",
                   timeout: 30_000
                 },
                 %{agent_id: "agent_send", task_id: "task_send"}
               )

      assert result.text == "echo:implement feature"
      assert result.stop_reason == "end_turn"
      assert result.context_pressure == true
      assert json_clean?(result)
      refute_pid_like(result)

      assert_receive {:managed_send, "acp_worker_send", "implement feature", opts}
      assert Keyword.get(opts, :task_id) == "task_send"
      assert Keyword.get(opts, :principal_id) == "agent_send"
      assert Keyword.get(opts, :timeout) == 30_000
      # worker_session_id wins over live session_pid; no legacy PID path is used.
      refute_received {:legacy_send, _, _, _}
    end
  end

  # SessionStatus

  describe "SessionStatus" do
    test "validates action metadata" do
      assert Acp.SessionStatus.name() == "acp_session_status"
      assert Acp.SessionStatus.category() == "acp"
      assert "status" in Acp.SessionStatus.tags()
    end

    test "schema accepts worker_session_id or legacy session_pid" do
      # Neither required at schema level (one-of is run-time).
      assert {:ok, _} = Acp.SessionStatus.validate_params(%{})
      assert {:ok, _} = Acp.SessionStatus.validate_params(%{session_pid: self()})
      assert {:ok, _} = Acp.SessionStatus.validate_params(%{worker_session_id: "acp_worker_s"})
    end

    test "generates tool schema" do
      tool = Acp.SessionStatus.to_tool()
      assert is_map(tool)
      assert tool[:name] == "acp_session_status"
    end

    test "taint roles classify session targets as control" do
      roles = Acp.SessionStatus.taint_roles()
      assert roles[:worker_session_id] == :control
      assert roles[:session_pid] == :control
    end

    test "returns error for dead PID" do
      pid = spawn(fn -> :ok end)
      Process.sleep(10)

      result = Acp.SessionStatus.run(%{session_pid: pid}, %{})
      assert {:error, msg} = result
      assert msg =~ "not found" or msg =~ "dead"
    end

    test "handle-only validation errors are clear" do
      result = Acp.SessionStatus.run(%{}, %{})
      assert {:error, msg} = result
      assert msg =~ "worker_session_id" or msg =~ "session_pid"
    end

    test "managed status preserves provider, model, session_id, status, pressure, tokens, usage, pooled, worker_session_id" do
      install_fake_ai()

      assert {:ok, status} =
               Acp.SessionStatus.run(
                 %{worker_session_id: "acp_worker_status"},
                 %{agent_id: "agent_status", task_id: "task_status"}
               )

      assert status.worker_session_id == "acp_worker_status"
      assert status.provider == "claude"
      assert status.model == "opus"
      assert status.session_id == "provider_sess_1"
      assert status.status == "ready"
      assert status.context_pressure == true
      assert status.context_tokens == 42
      assert status.usage == %{"input_tokens" => 10, "output_tokens" => 5}
      assert status.pooled == false

      assert json_clean?(status)
      refute_pid_like(status)

      assert_receive {:managed_status, "acp_worker_status", opts}
      assert Keyword.get(opts, :task_id) == "task_status"
      assert Keyword.get(opts, :principal_id) == "agent_status"
    end
  end

  # CloseSession

  describe "CloseSession" do
    test "validates action metadata" do
      assert Acp.CloseSession.name() == "acp_close_session"
      assert Acp.CloseSession.category() == "acp"
      assert "close" in Acp.CloseSession.tags()
    end

    test "schema accepts worker_session_id or legacy session_pid" do
      assert {:ok, _} = Acp.CloseSession.validate_params(%{})
      assert {:ok, _} = Acp.CloseSession.validate_params(%{session_pid: self()})

      assert {:ok, _} =
               Acp.CloseSession.validate_params(%{
                 worker_session_id: "acp_worker_c",
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
      assert roles[:worker_session_id] == :control
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

    test "managed close honors return_to_pool and remains idempotent" do
      install_fake_ai()

      assert {:ok, first} =
               Acp.CloseSession.run(
                 %{worker_session_id: "acp_worker_close", return_to_pool: true},
                 %{agent_id: "agent_close", task_id: "task_close"}
               )

      assert first.status == "returned_to_pool"
      assert first.worker_session_id == "acp_worker_close"
      assert json_clean?(first)
      refute_pid_like(first)

      assert_receive {:managed_close, "acp_worker_close", opts}
      assert Keyword.get(opts, :return_to_pool) == true
      assert Keyword.get(opts, :task_id) == "task_close"
      assert Keyword.get(opts, :principal_id) == "agent_close"

      assert {:ok, second} =
               Acp.CloseSession.run(
                 %{worker_session_id: "acp_worker_close"},
                 %{agent_id: "agent_close", task_id: "task_close"}
               )

      assert second.status in ["closed", "already_closed"]
      assert json_clean?(second)
      refute_pid_like(second)
    end
  end

  # Shared helpers

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

    test "Config.ai_module/0 defaults to Arbor.AI and is overridable" do
      assert Config.ai_module() == Arbor.AI
      Application.put_env(:arbor_actions, :ai_module, Arbor.Actions.AcpTest.FakeAI)
      assert Config.ai_module() == Arbor.Actions.AcpTest.FakeAI
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
      # config/config.exs; it was never in the hardcoded @allowed_providers, so
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

  describe "resolve_session_target/1" do
    test "prefers worker_session_id when both present" do
      assert {:ok, {:worker, "acp_worker_1"}} =
               Acp.resolve_session_target(%{
                 worker_session_id: "acp_worker_1",
                 session_pid: self()
               })
    end

    test "falls back to live session_pid" do
      assert {:ok, {:pid, pid}} = Acp.resolve_session_target(%{session_pid: self()})
      assert pid == self()
    end

    test "errors when neither target is present" do
      assert {:error, msg} = Acp.resolve_session_target(%{})
      assert msg =~ "worker_session_id" or msg =~ "session_pid"
    end
  end

  describe "name_to_module integration" do
    test "acp actions are discoverable by name" do
      assert {:ok, Acp.StartSession} = Arbor.Actions.name_to_module("acp.start_session")
      assert {:ok, Acp.SendMessage} = Arbor.Actions.name_to_module("acp.send_message")
      assert {:ok, Acp.SessionStatus} = Arbor.Actions.name_to_module("acp.session_status")
      assert {:ok, Acp.CloseSession} = Arbor.Actions.name_to_module("acp.close_session")
    end

    test "acp actions appear in list_actions with unchanged canonical URIs" do
      actions = Arbor.Actions.list_actions()
      assert Map.has_key?(actions, :acp)
      assert length(actions[:acp]) == 4

      for mod <- [Acp.StartSession, Acp.SendMessage, Acp.SessionStatus, Acp.CloseSession] do
        assert Arbor.Actions.canonical_uri_for(mod, %{}) == "arbor://acp/tool"
      end
    end
  end

  # Fake AI facade helpers

  defp install_fake_ai do
    Application.put_env(:arbor_actions, :ai_module, FakeAI)
    :persistent_term.put({FakeAI, :parent}, self())
    :ok
  end

  defp json_clean?(term) do
    case Jason.encode(term) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp refute_pid_like(term) do
    refute contains_forbidden?(term),
           "expected JSON-clean value without PID/ref/function/struct, got: #{inspect(term)}"
  end

  defp contains_forbidden?(term) when is_pid(term) or is_reference(term) or is_function(term),
    do: true

  defp contains_forbidden?(%_{}), do: true

  defp contains_forbidden?(list) when is_list(list), do: Enum.any?(list, &contains_forbidden?/1)

  defp contains_forbidden?(map) when is_map(map) do
    Enum.any?(map, fn {k, v} -> contains_forbidden?(k) or contains_forbidden?(v) end)
  end

  defp contains_forbidden?(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> Enum.any?(&contains_forbidden?/1)
  end

  defp contains_forbidden?(_), do: false
end
