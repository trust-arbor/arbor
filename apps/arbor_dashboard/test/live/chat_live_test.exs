defmodule Arbor.Dashboard.Live.ChatLiveTest do
  use Arbor.Dashboard.ConnCase, async: false

  defmodule FakeChatOrchestration do
    @moduledoc false

    def list_pending_approvals(opts) do
      notify({:list_pending_approvals, opts})
      {:ok, Application.get_env(:arbor_dashboard, :chat_live_pending_approvals, [])}
    end

    def answer_approval(id, decision, opts) do
      notify({:answer_approval, id, decision, opts})
      Application.get_env(:arbor_dashboard, :chat_live_answer_result, :ok)
    end

    defp notify(message) do
      case Application.get_env(:arbor_dashboard, :chat_live_test_pid) do
        pid when is_pid(pid) -> send(pid, message)
        _ -> :ok
      end
    end
  end

  # ChatLive mount calls Manager.find_first_agent/0 when connected, which reads
  # the GLOBAL :arbor_agent_registry ETS table. That table is process-wide
  # shared state with no per-test isolation — an agent registered (and still
  # alive) by concurrent activity elsewhere in the BEAM makes find_first_agent/0
  # return it, flipping ChatLive into its *with-agent* state. The "no-agent
  # state" test (line ~126) then renders the connected UI instead of the /start
  # hint and fails intermittently. See the test-isolation flake fixed here.
  #
  # We snapshot the registry, clear it so every test in this module sees a
  # genuinely empty agent listing, and restore it on exit so we don't disturb
  # entries other modules may depend on.
  setup do
    env_keys = [
      :chat_orchestration,
      :chat_live_pending_approvals,
      :chat_live_answer_result,
      :chat_live_test_pid
    ]

    previous_env =
      Map.new(env_keys, fn key ->
        {key, Application.fetch_env(:arbor_dashboard, key)}
      end)

    Application.put_env(:arbor_dashboard, :chat_orchestration, FakeChatOrchestration)
    Application.put_env(:arbor_dashboard, :chat_live_test_pid, self())
    Application.delete_env(:arbor_dashboard, :chat_live_pending_approvals)
    Application.delete_env(:arbor_dashboard, :chat_live_answer_result)

    if :ets.whereis(:arbor_agent_registry) == :undefined do
      :ets.new(:arbor_agent_registry, [:named_table, :set, :public])
    end

    snapshot = :ets.tab2list(:arbor_agent_registry)
    :ets.delete_all_objects(:arbor_agent_registry)

    on_exit(fn ->
      Enum.each(previous_env, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_dashboard, key, value)
        {key, :error} -> Application.delete_env(:arbor_dashboard, key)
      end)

      # The table is :public/:named — recreate it if a concurrent teardown
      # removed it, then restore the entries we snapshotted.
      if :ets.whereis(:arbor_agent_registry) == :undefined do
        :ets.new(:arbor_agent_registry, [:named_table, :set, :public])
      end

      :ets.insert(:arbor_agent_registry, snapshot)
    end)

    :ok
  end

  describe "ChatLive mount" do
    @tag :fast
    test "renders chat dashboard header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "Agent Chat"
      assert html =~ "Interactive conversation"
    end

    @tag :fast
    test "shows model selection when no agent is running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      # Should show available models for starting an agent
      # The chat panel renders model buttons when no agent is connected
      assert html =~ "Chat"
    end
  end

  describe "ChatLive toggle events" do
    @tag :fast
    test "toggle-thinking toggles show_thinking assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # First toggle: show_thinking starts true, becomes false
      html = render_click(view, "toggle-thinking")
      # The thinking panel visibility changes based on this assign
      assert is_binary(html)

      # Second toggle: back to true
      html = render_click(view, "toggle-thinking")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-memories toggles show_memories assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-memories")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-actions toggles show_actions assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-actions")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-goals toggles show_goals assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-goals")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-llm-panel toggles show_llm_panel assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-llm-panel")
      assert is_binary(html)
    end

    @tag :fast
    test "toggle-completed-goals toggles show_completed_goals assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "toggle-completed-goals")
      assert is_binary(html)
    end
  end

  describe "ChatLive input events" do
    @tag :fast
    test "update-input stores the message value", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "update-input", %{"message" => "hello world"})
      assert is_binary(html)
    end

    @tag :fast
    test "update-input with no message param does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "update-input", %{})
      assert is_binary(html)
    end

    @tag :fast
    test "send-message with no agent does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      # Send without an agent connected - should be a no-op
      html = render_click(view, "send-message")
      assert is_binary(html)
    end

    @tag :fast
    test "noop event does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "noop")
      assert is_binary(html)
    end
  end

  describe "ChatLive no-agent state (Phase 2c)" do
    @tag :fast
    test "renders the slash-command hint pointing at /start and Agents dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/chat")

      assert html =~ "/start"
      assert html =~ "Agents dashboard" or html =~ "/agents"
      # Negative: the old dropdown form is gone.
      refute html =~ ~s(phx-submit="start-agent")
      refute html =~ ~s(<select name="model")
    end
  end

  describe "ChatLive stop-agent without running agent" do
    @tag :fast
    test "stop-agent with no agent does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "stop-agent")
      assert is_binary(html)
    end
  end

  describe "ChatLive heartbeat model events" do
    @tag :fast
    test "set-heartbeat-model with empty string clears selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "set-heartbeat-model", %{"heartbeat_model" => ""})
      assert is_binary(html)
    end

    @tag :fast
    test "set-heartbeat-model with unknown id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/chat")

      html = render_click(view, "set-heartbeat-model", %{"heartbeat_model" => "unknown"})
      assert is_binary(html)
    end
  end

  describe "always-allow-tool security gate (H13 regression)" do
    alias Arbor.Dashboard.Cores.AutoPromoteGate

    @tag :fast
    test "security regression (H13): non-:authorized decisions deny the auto-promote" do
      # H13: ChatLive's "Always Allow" event used to call
      # Trust.Store.always_allow/2 unconditionally — any user that could click
      # Approve could permanently promote any agent's trust to :auto for any
      # resource. The gate now lives in
      # Arbor.Dashboard.Cores.AutoPromoteGate.decision/1; this test pins every
      # non-OK Security.authorize/3 result shape to the deny outcome so future
      # drift in the auth pipeline doesn't silently re-open the hole.
      for decision <- [
            {:error, :not_found},
            {:error, :no_capability},
            {:error, :security_unavailable},
            {:error, :no_actor},
            {:ok, :pending_approval, "cap_123"},
            {:requires_approval, %{id: "cap_x"}}
          ] do
        assert {:error, :unauthorized_auto_promote} =
                 AutoPromoteGate.decision(decision),
               "H13 regression: decision #{inspect(decision)} must deny auto-promote"
      end
    end

    @tag :fast
    test ":authorized passes the gate" do
      assert :ok = AutoPromoteGate.decision(:authorized)
      assert :ok = AutoPromoteGate.decision({:ok, :authorized})
    end

    @tag :fast
    test "authorize/2 denies the implicit 'system' actor" do
      # The "system" actor is the dev/test fallback when no OIDC session is
      # bound. Auto-promote is never appropriate to grant from a UI surface
      # under that identity — fail closed.
      assert {:error, :unauthorized_auto_promote} =
               AutoPromoteGate.authorize("system", "agent_target")

      assert {:error, :unauthorized_auto_promote} =
               AutoPromoteGate.authorize(nil, "agent_target")

      assert {:error, :unauthorized_auto_promote} =
               AutoPromoteGate.authorize("", "agent_target")
    end

    @tag :fast
    test "behavioral: always-allow-tool denies when actor lacks auto_promote cap",
         %{conn: conn} do
      # H13 behavioral assertion. A naked "always-allow-tool" click from a
      # fresh dashboard session must produce the deny-flash, never silently call
      # Trust.Store.always_allow/2. Approval-answer authority is not enough to
      # mutate the trust profile.
      #
      # Pre-H13, this handler unconditionally called the trust mutation; this
      # test pins the gated behavior so a future refactor that bypasses
      # AutoPromoteGate.authorize/2 is caught here.
      {:ok, view, _html} = live(conn, "/chat")

      html =
        render_click(view, "always-allow-tool", %{
          "id" => "irq_synthetic_test",
          "agent" => "agent_target_xyz",
          "resource" => "arbor://shell/exec/rm"
        })

      assert html =~ "Approvals are unavailable in this private conversation",
             "Private chat must not turn an Always Allow event into trust mutation"
    end
  end

  describe "private chat excludes approval and group authority" do
    @tag :fast
    test "security regression: mount and crafted approval messages never grant or expose approval data",
         %{conn: conn} do
      trace_calls_for_new_processes([{Arbor.Security, :grant, 1}])
      {:ok, view, _html} = live(conn, "/chat")
      pid = view.pid

      {:ok, interaction} =
        Arbor.Contracts.Comms.Interaction.new(%{
          request_id: "irq_private_leak",
          kind: :approval,
          agent_id: "agent_private_other",
          user_id: "human_dashboard",
          description: "foreign private approval",
          resource_uri: "arbor://shell/exec/private"
        })

      for _ <- 1..2, do: send(pid, {:dashboard_interaction, interaction})

      send(
        pid,
        {:signal_received,
         %{
           category: :security,
           type: :authorization_pending,
           data: %{principal_id: "agent_private_other"}
         }}
      )

      send(pid, :refresh_approvals)
      html = render(view)

      trace_ref = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^trace_ref}
      refute html =~ "foreign private approval"
      refute has_element?(view, "#approvals-container [phx-click=approve-tool]")
      refute_received {:list_pending_approvals, _}
      refute_received {:trace, ^pid, :call, {Arbor.Security, :grant, _}}
    end

    @tag :fast
    test "security regression: crafted approval events do not answer or grant trust, even with a session",
         %{conn: conn} do
      conn =
        init_test_session(conn, %{"agent_id" => "human_socket", "session_token" => "socket-token"})

      {:ok, view, _} = live(conn, "/chat")

      for event <- [
            "approve-tool",
            "always-allow-tool",
            "deny-tool",
            "approve-interaction",
            "reject-interaction"
          ] do
        html =
          render_click(view, event, %{
            "id" => "irq_private",
            "agent" => "agent_private",
            "resource" => "arbor://shell/exec",
            "caller_id" => "human_forged",
            "session_token" => "forged-token"
          })

        assert html =~ "Approvals are unavailable in this private conversation"
      end

      refute_received {:answer_approval, _, _, _}
      refute_received {:list_pending_approvals, _}
    end

    @tag :fast
    test "security regression: group events cannot join create send or resume through private chat",
         %{conn: conn} do
      watched = [
        {Arbor.Agent.Manager, :create_channel, 2},
        {Arbor.Agent.Manager, :join_channel, 2},
        {Arbor.Agent.Manager, :channel_send, 5},
        {Arbor.Agent.Manager, :resume_agent, 1},
        {Arbor.Agent.Lifecycle, :start, 2}
      ]

      trace_calls_for_new_processes(watched)
      {:ok, view, _} = live(conn, "/chat")
      pid = view.pid

      for event <- [
            "show-group-modal",
            "show-join-groups",
            "toggle-group-agent",
            "update-group-name",
            "confirm-create-group",
            "join-group",
            "leave-group"
          ] do
        html =
          render_click(view, event, %{
            "id" => "group_private",
            "channel-id" => "group_private",
            "agent-id" => "agent_private",
            "value" => "group_private"
          })

        assert html =~ "Group chat is unavailable in this private conversation"
      end

      trace_ref = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^trace_ref}

      for {module, function, _arity} <- watched do
        refute_received {:trace, ^pid, :call, {^module, ^function, _}}
      end
    end
  end

  describe "approval card presentation" do
    @tag :fast
    test "approval card says why it is asking, what is at stake, and withholds Always Allow for one-way actions",
         _context do
      Application.put_env(:arbor_dashboard, :chat_live_pending_approvals, [
        %{
          id: "irq_one_way",
          source: :interaction,
          agent_id: "agent_test_one_way",
          proposer: "agent_test_one_way",
          principal_id: "agent_test_one_way",
          resource_uri: "arbor://shell/exec/rm",
          action: :approval,
          description: "Authorization request for arbor://shell/exec/rm",
          metadata: %{
            gate: :trust_policy,
            reason: :policy_gated,
            target: "rm -rf build/",
            trust: %{
              effective_mode: :ask,
              baseline: :ask,
              matched_rule: %{prefix: "arbor://shell", mode: :ask},
              ceiling_match: %{prefix: "arbor://shell", mode: :ask},
              profile: %{
                uri_prefix: "arbor://shell",
                reversibility: :irreversible,
                blast_radius: :critical,
                effect_class: :process_spawn,
                graduation_threshold: :never
              }
            }
          },
          created_at: DateTime.utc_now()
        }
      ])

      [approval] = Application.fetch_env!(:arbor_dashboard, :chat_live_pending_approvals)

      html =
        render_component(&Arbor.Dashboard.Live.ChatLive.Components.approvals_panel/1, %{
          show_approvals: true,
          approvals_count: 1,
          streams: %{approvals: [{"approval-card", approval}]}
        })

      assert html =~ "Asking because your trust rule for arbor://shell is ask"
      assert html =~ "security ceiling arbor://shell: ask"
      assert html =~ "rm -rf build/"
      assert html =~ "one-way"
      assert html =~ "blast: critical"
      assert html =~ "one-way: confirmed each time"
      refute html =~ "Always Allow"
    end

    @tag :fast
    test "approval card offers Always Allow for reversible actions", _context do
      Application.put_env(:arbor_dashboard, :chat_live_pending_approvals, [
        %{
          id: "irq_reversible",
          source: :interaction,
          agent_id: "agent_test_reversible",
          proposer: "agent_test_reversible",
          principal_id: "agent_test_reversible",
          resource_uri: "arbor://fs/write/report.md",
          action: :approval,
          description: "Authorization request for arbor://fs/write/report.md",
          metadata: %{
            gate: :trust_policy,
            trust: %{profile: %{reversibility: :reversible, blast_radius: :high}}
          },
          created_at: DateTime.utc_now()
        }
      ])

      [approval] = Application.fetch_env!(:arbor_dashboard, :chat_live_pending_approvals)

      html =
        render_component(&Arbor.Dashboard.Live.ChatLive.Components.approvals_panel/1, %{
          show_approvals: true,
          approvals_count: 1,
          streams: %{approvals: [{"approval-card", approval}]}
        })

      assert html =~ "reversible"
      assert html =~ "Always Allow"
      refute html =~ "one-way: confirmed each time"
    end
  end

  describe "authenticated private conversation boundary" do
    @tag :fast
    test "security regression: local console cannot select an engagement or supply browser proof",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/chat?agent_id=agent_private_boundary")
      assert html =~ "Sign in with a valid session"

      html =
        render_submit(view, "send-message", %{
          "message" => "must stay private",
          "command_id" => "browser-proof-attempt",
          "session_token" => "browser-forged-proof",
          "caller_id" => "human_somebody_else",
          "engagement_id" => "eng_11111111111111111111111111111111"
        })

      assert html =~ "Sign in with a valid session"
      refute has_element?(view, "#messages-container", "must stay private")
      refute has_element?(view, "#conversation-delivery")
    end
  end

  defp trace_calls_for_new_processes(patterns) do
    for {module, _function, _arity} = pattern <- patterns do
      Code.ensure_loaded!(module)
      :erlang.trace_pattern(pattern, true, [:local])
    end

    tracer = self()
    :erlang.trace(:new, true, [:call, {:tracer, tracer}])

    on_exit(fn ->
      :erlang.trace(:new, false, [:call])

      for pid <- Process.list() do
        if :erlang.trace_info(pid, :tracer) == {:tracer, tracer},
          do: :erlang.trace(pid, false, [:call])
      end

      for pattern <- patterns, do: :erlang.trace_pattern(pattern, false, [:local])
    end)
  end
end
