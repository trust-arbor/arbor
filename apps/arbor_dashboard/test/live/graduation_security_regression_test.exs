Code.require_file(
  Path.expand("../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Dashboard.Live.GraduationSecurityRegressionTest do
  @moduledoc """
  Browser-event authority regressions at the current public-input boundary.
  Fixtures admit local requests without external delivery; real Comms winning
  answers, Security human proofs and Trust persistence own all decisions.
  """
  use Arbor.Dashboard.ConnCase, async: false

  alias Arbor.Agent.Orchestration
  alias Arbor.Comms
  alias Arbor.Comms.InteractionRegistry
  alias Arbor.Contracts.Comms.Interaction
  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Fixture
  alias Arbor.Signals
  alias Arbor.Trust
  alias Arbor.Trust.{ConfirmationTracker, PolicyHost, Store}

  @moduletag :fast
  @moduletag :integration
  @prefix "arbor://memory/read"

  defmodule Backend do
    def put(key, record, _opts) do
      Agent.get_and_update(__MODULE__, fn state ->
        if state.fail do
          {{:error, :test_storage_failure}, state}
        else
          {:ok, put_in(state.rows[key], record)}
        end
      end)
    end

    def get(key, _opts) do
      Agent.get(__MODULE__, fn state ->
        case Map.fetch(state.rows, key) do
          {:ok, row} -> {:ok, row}
          :error -> {:error, :not_found}
        end
      end)
    end

    def list(_opts), do: Agent.get(__MODULE__, &{:ok, Map.keys(&1.rows)})
  end

  setup do
    ctx = Fixture.setup!()

    if :ets.whereis(:arbor_agent_registry) == :undefined,
      do: :ets.new(:arbor_agent_registry, [:named_table, :set, :public])

    for module <- [PolicyHost, Arbor.Signals.Store, Arbor.Signals.Bus] do
      if Process.whereis(module) == nil, do: start_supervised!(module)
    end

    if Process.whereis(Comms.PubSub) == nil,
      do: start_supervised!({Phoenix.PubSub, name: Comms.PubSub})

    if Process.whereis(InteractionRegistry) == nil, do: start_supervised!(InteractionRegistry)

    start_supervised!({Agent, fn -> %{rows: %{}, fail: false} end}, id: Backend)
    |> Process.register(Backend)

    start_supervised!({Store, persistence: :durable, durable_backend: Backend})
    start_supervised!(ConfirmationTracker)

    for {app, key, value} <- [
          {:arbor_trust, :approval_evidence_provider, Arbor.Agent.ApprovalEvidence},
          {:arbor_trust, :graduation_thresholds, %{}},
          {:arbor_dashboard, :chat_orchestration, Orchestration}
        ] do
      previous = Application.fetch_env(app, key)
      Application.put_env(app, key, value)
      on_exit(fn -> restore(app, key, previous) end)
    end

    {:ok, profile} = Profile.new(ctx.agent_id)
    assert :ok = Store.store_profile(%{profile | rules: %{@prefix => :ask}})
    Fixture.grant!(ctx.human_id, "arbor://approval/read")
    Fixture.grant!(ctx.human_id, "arbor://approval/answer/#{ctx.agent_id}")
    Fixture.grant!(ctx.human_id, "arbor://trust/read/#{ctx.agent_id}")
    cap = Fixture.grant!(ctx.human_id, "arbor://trust/auto_promote/#{ctx.agent_id}")
    Map.put(ctx, :promotion_cap, cap)
  end

  test "verified evidence is visible and only an explicit authenticated acceptance saves the rule",
       ctx do
    observe!(ctx)
    {:ok, view, _} = live(authenticated_conn(ctx), "/agents")
    html = render_click(view, "select-agent", %{"id" => ctx.agent_id})
    assert html =~ "Verified human approvals"
    assert html =~ "Current human streak"
    assert html =~ "System ceiling"
    assert html =~ "Evidence revision"
    assert has_element?(view, "[phx-click='graduation:accept']")
    assert_mode(ctx, :ask)
    refute html =~ ctx.token

    html = view |> element("[phx-click='graduation:accept']") |> render_click()
    assert html =~ "The automatic-execution rule was saved"
    assert html =~ "Current policy already permits automatic execution"
    refute has_element?(view, "[phx-click='graduation:accept']")
    assert_mode(ctx, :auto)
  end

  test "security regression: stale suggestions are refused and explicit decline locks the scope",
       ctx do
    observe!(ctx)
    {:ok, old} = Trust.graduation_status(ctx.agent_id, @prefix, proof(ctx))
    {:ok, view, _} = live(authenticated_conn(ctx), "/agents")
    render_click(view, "select-agent", %{"id" => ctx.agent_id})
    observe!(ctx)

    html =
      render_click(view, "graduation:accept", %{
        "prefix" => @prefix,
        "suggestion_id" => old.suggestion_id
      })

    assert html =~ "This suggestion is stale"
    assert_mode(ctx, :ask)
    html = view |> element("[phx-click='graduation:decline']") |> render_click()
    assert html =~ "This scope is locked against graduation"
    refute has_element?(view, "[phx-click='graduation:accept']")
    assert {:ok, status} = Trust.graduation_status(ctx.agent_id, @prefix, proof(ctx))
    assert status.locked
    assert_mode(ctx, :ask)
  end

  test "security regression: event parameters and local dev flag cannot supply missing socket authority",
       ctx do
    observe!(ctx)
    {:ok, status} = Trust.graduation_status(ctx.agent_id, @prefix, proof(ctx))
    conn = init_test_session(ctx.conn, %{"local_dev_operator" => true})
    {:ok, view, _} = live(conn, "/agents")
    html = render_click(view, "select-agent", %{"id" => ctx.agent_id})
    assert html =~ "unavailable without a current authenticated human session"
    refute html =~ status.suggestion_id

    html =
      render_click(view, "graduation:accept", %{
        "prefix" => @prefix,
        "suggestion_id" => status.suggestion_id,
        "caller_id" => ctx.human_id,
        "session_token" => ctx.token,
        "agent_id" => ctx.agent_id
      })

    assert html =~ "unavailable without a current authenticated human session"
    assert_mode(ctx, :ask)
  end

  test "security regression: current revoked authority denies an already rendered accept button",
       ctx do
    observe!(ctx)
    {:ok, view, _} = live(authenticated_conn(ctx), "/agents")
    render_click(view, "select-agent", %{"id" => ctx.agent_id})
    assert :ok = Security.revoke(ctx.promotion_cap.id)
    html = view |> element("[phx-click='graduation:accept']") |> render_click()
    assert html =~ "unavailable without a current authenticated human session"
    assert has_element?(view, "[phx-click='graduation:accept']")
    assert_mode(ctx, :ask)
  end

  test "trust signals refresh current evidence and cannot reopen a deselected agent", ctx do
    {:ok, view, _} = live(authenticated_conn(ctx), "/agents")
    render_click(view, "select-agent", %{"id" => ctx.agent_id})
    assert has_element?(view, "#graduation-empty")
    observe!(ctx)
    eventually(fn -> assert has_element?(view, "[phx-click='graduation:accept']") end)
    render_click(view, "close-detail")
    assert :ok = Signals.emit(:trust, :confirmation_recorded, %{agent_id: ctx.agent_id})
    refute has_element?(view, "#graduation-review")
    html = render_click(view, "select-agent", %{"id" => ctx.agent_id <> "_other"})
    assert html =~ "unavailable without a current authenticated human session"
    refute has_element?(view, "[data-graduation-scope]")
  end

  test "acknowledged persistence failure keeps pending evidence visible and permits retry", ctx do
    observe!(ctx)
    {:ok, view, _} = live(authenticated_conn(ctx), "/agents")
    render_click(view, "select-agent", %{"id" => ctx.agent_id})
    Agent.update(Backend, &%{&1 | fail: true})
    html = view |> element("[phx-click='graduation:accept']") |> render_click()
    assert html =~ "The rule could not be saved"
    assert has_element?(view, "[phx-click='graduation:accept']")
    assert_mode(ctx, :ask)
    Agent.update(Backend, &%{&1 | fail: false})
    html = view |> element("[phx-click='graduation:accept']") |> render_click()
    assert html =~ "The automatic-execution rule was saved"
    assert_mode(ctx, :auto)
  end

  test "ChatLive passes Nav human proof into the actual winning answer and Trust evidence", ctx do
    request = request!(ctx)
    {:ok, view, _} = live(authenticated_conn(ctx), "/chat")

    render_click(view, "approve-tool", %{
      "id" => request.request_id,
      "caller_id" => "human_forged"
    })

    assert {:ok, evidence} = Comms.get_answered_approval(request.request_id)
    assert evidence.verified_human_id == ctx.human_id
    assert {:ok, status} = Trust.graduation_status(ctx.agent_id, @prefix, proof(ctx))
    assert status.verified_human_approvals == 1
    assert status.unknown_approvals == 0
    assert status.pending
  end

  test "security regression: ChatLive cannot downgrade a missing socket token into a legacy answer",
       ctx do
    request = request!(ctx)
    conn = init_test_session(ctx.conn, %{"agent_id" => ctx.human_id})
    {:ok, view, _} = live(conn, "/chat")

    render_click(view, "approve-tool", %{
      "id" => request.request_id,
      "session_token" => ctx.token,
      "caller_id" => ctx.human_id
    })

    assert :not_found = Comms.get_answered_approval(request.request_id)
    assert Enum.any?(Comms.pending_interactions(), &(&1.request_id == request.request_id))
    assert {:ok, status} = Trust.graduation_status(ctx.agent_id, @prefix, proof(ctx))
    assert status.verified_human_approvals == 0
    assert status.unknown_approvals == 0
  end

  defp request!(ctx) do
    {:ok, request} =
      Interaction.new(%{
        kind: :approval,
        agent_id: ctx.agent_id,
        user_id: ctx.human_id,
        resource_uri: @prefix <> "/exact",
        description: "Review local memory read"
      })

    assert {:ok, _} = InteractionRegistry.put(request)
    request
  end

  defp observe!(ctx) do
    request = request!(ctx)
    assert :ok = Orchestration.answer_approval(request.request_id, :approve, proof(ctx))
    request
  end

  defp authenticated_conn(ctx),
    do: init_test_session(ctx.conn, %{"agent_id" => ctx.human_id, "session_token" => ctx.token})

  defp proof(ctx), do: [caller_id: ctx.human_id, session_token: ctx.token]

  defp assert_mode(ctx, mode) do
    assert {:ok, profile} = Store.get_profile(ctx.agent_id)
    assert profile.rules[@prefix] == mode
  end

  defp eventually(assertion, attempts \\ 100)
  defp eventually(assertion, 0), do: assertion.()

  defp eventually(assertion, attempts) do
    assertion.()
  rescue
    ExUnit.AssertionError ->
      receive do
      after
        20 -> eventually(assertion, attempts - 1)
      end
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
