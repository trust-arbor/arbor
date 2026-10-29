defmodule Arbor.AI.AcpSession.CodexApprovalSecurityRegressionTest do
  @moduledoc """
  Security regression (Exposure Check item AB): Codex must not decide its own
  command, file-write, or network approvals through the built-in AI reviewer
  (`approvalsReviewer: auto_review`) or auto-approve (`approvalPolicy: never`).

  Arbor's ACP handler is the only approval authority. A deny from Arbor blocks
  the Codex exec request. Missing Arbor/security infrastructure fails closed.
  """
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.AI.AcpSession.Config
  alias Arbor.AI.AcpSession.Handler
  alias Arbor.AI.TestSupport.AutoTrustPolicy
  alias ExMCP.ACP.Adapters.Codex
  alias ExMCP.ACP.Adapters.Codex.Config, as: CodexAdapterConfig
  alias ExMCP.ACP.Adapters.Codex.Protocol, as: CodexProtocol

  defmodule RecordingDenySecurity do
    @moduledoc false

    def authorize(_agent_id, uri, action, _opts) do
      send(Application.fetch_env!(:arbor_ai, :codex_approval_test_pid), {:authorize, uri, action})
      {:error, :capability_denied}
    end
  end

  defmodule UnreachableSecurity do
    @moduledoc false

    def authorize(_agent_id, _uri, _action, _opts), do: exit(:noproc)
  end

  setup do
    previous = %{
      security: Application.get_env(:arbor_ai, :security_module),
      trust: Application.get_env(:arbor_ai, :trust_policy_module),
      test_pid: Application.get_env(:arbor_ai, :codex_approval_test_pid),
      opt_out: Application.get_env(:arbor_ai, :codex_allow_builtin_approval_reviewer)
    }

    on_exit(fn ->
      restore_env(:security_module, previous.security)
      restore_env(:trust_policy_module, previous.trust)
      restore_env(:codex_approval_test_pid, previous.test_pid)
      restore_env(:codex_allow_builtin_approval_reviewer, previous.opt_out)
    end)

    :ok
  end

  describe "Codex launch default routes approvals to Arbor" do
    test "security regression: default Codex launch asks Arbor, not Codex auto_review" do
      assert {:ok, opts} = Config.resolve(:codex)
      adapter_opts = Keyword.fetch!(opts, :adapter_opts)

      assert Keyword.fetch!(adapter_opts, :mode_id) == "read-only"
      refute Keyword.get(adapter_opts, :allow_builtin_approval_reviewer) == true

      turn =
        CodexAdapterConfig.merge_turn_mode_wire_params(
          %{},
          Keyword.fetch!(adapter_opts, :mode_id)
        )

      assert turn["approvalPolicy"] == "on-request"
      assert turn["approvalsReviewer"] == "user"
      refute turn["approvalsReviewer"] == "auto_review"
      refute turn["approvalPolicy"] == "never"

      cwd = System.tmp_dir!()
      {:ok, state} = Codex.init(adapter_opts ++ [cwd: cwd])

      assert {:ok, request, _state} =
               Codex.translate_outbound(
                 %{
                   "method" => "session/new",
                   "id" => 1,
                   "params" => %{"cwd" => cwd, "mcpServers" => []}
                 },
                 state
               )

      wire = request |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      assert get_in(wire, ["params", "approvalPolicy"]) == "on-request"
      refute get_in(wire, ["params", "approvalPolicy"]) == "never"
    end

    test "security regression: Codex builtin reviewer modes are refused without explicit opt-out" do
      Application.delete_env(:arbor_ai, :codex_allow_builtin_approval_reviewer)

      for mode <- ["agent", "agent-full-access"] do
        assert {:error, {:codex_builtin_approval_reviewer_refused, ^mode}} =
                 Config.resolve(:codex, adapter_opts: [mode_id: mode])
      end
    end

    test "explicit opt-out keeps Codex builtin reviewer modes available" do
      assert {:ok, opts} =
               Config.resolve(:codex,
                 adapter_opts: [
                   mode_id: "agent",
                   allow_builtin_approval_reviewer: true
                 ]
               )

      assert Keyword.fetch!(opts[:adapter_opts], :mode_id) == "agent"
    end
  end

  describe "Codex exec approval is decided by Arbor" do
    test "security regression: a Codex exec approval request reaches Arbor's handler and a deny blocks it" do
      Application.put_env(:arbor_ai, :security_module, RecordingDenySecurity)
      Application.put_env(:arbor_ai, :trust_policy_module, AutoTrustPolicy)
      Application.put_env(:arbor_ai, :codex_approval_test_pid, self())

      assert {:ok, opts} = Config.resolve(:codex)
      cwd = System.tmp_dir!()
      {:ok, state} = Codex.init(Keyword.fetch!(opts, :adapter_opts) ++ [cwd: cwd])

      inbound =
        CodexProtocol.encode_request(7, "item/commandExecution/requestApproval", %{
          "threadId" => "thread-arbor-approval",
          "itemId" => "item-exec-1",
          "command" => "rm -rf /",
          "cwd" => cwd
        })

      assert {:messages, [permission_request], state} = Codex.translate_inbound(inbound, state)
      assert permission_request["method"] == "session/request_permission"

      tool_call = get_in(permission_request, ["params", "toolCall"])
      options = get_in(permission_request, ["params", "options"])

      assert tool_call["toolName"] == "execute"
      assert tool_call["kind"] == "execute"
      assert is_list(options) and options != []

      {:ok, handler} = Handler.init(agent_id: "agent_codex_approval", provider: :codex, cwd: cwd)

      assert {:ok, outcome, ^handler} =
               Handler.handle_permission_request(
                 "thread-arbor-approval",
                 tool_call,
                 options,
                 handler
               )

      assert_receive {:authorize, "arbor://acp/tool/execute", :execute}
      assert denied_permission?(outcome)

      assert {:ok, encoded, _state} =
               Codex.translate_outbound(
                 %{"id" => permission_request["id"], "result" => outcome},
                 state
               )

      reply = encoded |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
      decision = get_in(reply, ["result", "decision"])
      assert decision in ["decline", "cancel"]
      refute decision in ["accept", "acceptForSession"]
    end

    test "security regression: unreachable Arbor security fails closed and blocks Codex exec" do
      Application.put_env(:arbor_ai, :security_module, UnreachableSecurity)
      Application.put_env(:arbor_ai, :trust_policy_module, AutoTrustPolicy)

      {:ok, handler} =
        Handler.init(
          agent_id: "agent_codex_approval",
          provider: :codex,
          permission_timeout_ms: 10
        )

      tool_call = %{
        "toolName" => "execute",
        "kind" => "execute",
        "rawInput" => %{"command" => "id"}
      }

      options = [
        %{"optionId" => "allow_once", "name" => "Allow", "kind" => "allow_once"},
        %{"optionId" => "decline", "name" => "Deny", "kind" => "reject_once"}
      ]

      assert {:ok, outcome, ^handler} =
               Handler.handle_permission_request("s1", tool_call, options, handler)

      assert denied_permission?(outcome)
    end
  end

  defp denied_permission?(%{"outcome" => %{"outcome" => "selected", "optionId" => option_id}}) do
    option_id in ["decline", "cancel", "reject_once", "reject_always"]
  end

  defp denied_permission?(%{"outcome" => "denied"}), do: true
  defp denied_permission?(%{"outcome" => "cancelled"}), do: true
  defp denied_permission?(%{"outcome" => %{"outcome" => "cancelled"}}), do: true
  defp denied_permission?(_), do: false

  defp restore_env(key, nil), do: Application.delete_env(:arbor_ai, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_ai, key, value)
end
