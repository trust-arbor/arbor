defmodule Arbor.Orchestrator.Engine.NativeActionPreflightSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Orchestrator.Engine.{Authorization, Context, Outcome, RunAuthorization}
  alias Arbor.Orchestrator.Handlers.{ExecHandler, Registry}
  alias Arbor.Security

  @action_uri "arbor://shell/exec/true"

  @dot """
  digraph NativeActionPreflight {
    start [shape=Mdiamond]
    effect [type=exec, target=action, action=shell_execute, arg.command="true"]
    done [shape=Msquare]
    start -> effect -> done
  }
  """

  defmodule CustomExecHandler do
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :read_only

    @impl true
    def execute(_node, _context, _graph, opts) do
      send(Keyword.fetch!(opts, :native_preflight_observer), :custom_exec_effect)
      %Outcome{status: :success}
    end
  end

  defmodule CustomActionsExecutor do
    def execute(_name, _args, _workdir, opts) do
      source = Keyword.fetch!(opts, :conversation_source)
      send(source.session_pid, :custom_executor_effect)
      {:ok, %{executed: true}}
    end
  end

  setup do
    suffix = System.unique_integer([:positive, :monotonic])
    principal = "agent_native_preflight_#{suffix}"
    task_id = "native-preflight-task-#{suffix}"
    session_id = "native-preflight-session-#{suffix}"
    handlers = Registry.snapshot_fixtures()

    on_exit(fn ->
      Registry.restore_fixtures(handlers)
      _ = Security.revoke_by_task_fixture(task_id)
      _ = Security.revoke_by_session_fixture(session_id)
    end)

    source = %{session_pid: self(), generation: make_ref(), handle: {self(), make_ref()}}

    opts = [
      authorization: true,
      agent_id: principal,
      caller_id: principal,
      task_id: task_id,
      session_id: session_id,
      workdir: File.cwd!(),
      authorizer: fn _principal, _type -> :ok end,
      native_preflight_observer: self(),
      conversation_source: source,
      resumable: false
    ]

    %{principal: principal, task_id: task_id, session_id: session_id, opts: opts}
  end

  test "security regression: actual Engine cannot defer admission to a registered custom exec handler",
       c do
    grant(c, constraints: %{requires_approval: true})
    :ok = Registry.register_fixture("exec", CustomExecHandler)

    # Preparation already rejects a preinstalled custom handler. The supported
    # runtime registry can still change after preparation, before node dispatch.
    assert {:error, {:unbound_custom_handler, "effect"}} = Arbor.Orchestrator.run(@dot, c.opts)

    assert {:ok, ordinary} =
             run_with_runtime_override(Keyword.delete(c.opts, :conversation_source))

    assert {ordinary.final_outcome.status, custom_effect?()} == {:fail, false}

    # Mere source presence cannot weaken admission for the newly resolved code.
    assert {:ok, source_bound} = run_with_runtime_override(c.opts)
    assert {source_bound.final_outcome.status, custom_effect?()} == {:fail, false}
    assert source_bound.final_outcome.failure_reason =~ "source_bound_native_boundary_required"
  end

  test "security regression: actual function handler identity cannot be spoofed through Engine options",
       c do
    grant(c, constraints: %{requires_approval: true})
    {graph, node, opts} = authorization_fixture(c)
    observer = self()

    handler = fn _node, _context, _graph, _opts ->
      send(observer, :custom_exec_effect)
      %Outcome{status: :success}
    end

    outcome =
      Authorization.authorize_and_execute(
        handler,
        node,
        Context.new(),
        graph,
        Keyword.put(opts, :execution_handler, ExecHandler)
      )

    assert {outcome.status, custom_effect?()} == {:fail, false}
    assert outcome.failure_reason =~ "source_bound_native_boundary_required"
  end

  test "security regression: fixed handler cannot defer admission to an overridden action executor",
       c do
    grant(c, constraints: %{requires_approval: true})
    {graph, node, opts} = authorization_fixture(c)

    outcome =
      Authorization.authorize_and_execute(
        ExecHandler,
        node,
        Context.new(),
        graph,
        Keyword.put(opts, :actions_executor, CustomActionsExecutor)
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "source_bound_native_boundary_required"
    refute_received :custom_executor_effect
  end

  test "security regression: native preflight retains the original task and session scope", c do
    for scope <- [[task_id: c.task_id <> "-other"], [session_id: c.session_id <> "-other"]] do
      cap = grant(c, scope)
      assert {:ok, result} = Arbor.Orchestrator.run(@dot, c.opts)
      assert result.final_outcome.status == :fail
      assert result.final_outcome.failure_reason =~ "native_action_preflight_refused"
      :ok = Security.revoke_fixture(cap.id)
    end
  end

  test "security regression: native deferral retains caller scope and every other declared capability",
       c do
    grant(c, constraints: %{requires_approval: true})

    assert {:ok, caller_denied} =
             Arbor.Orchestrator.run(
               @dot,
               Keyword.put(c.opts, :caller_id, c.principal <> "-caller")
             )

    assert caller_denied.final_outcome.status == :fail
    assert caller_denied.final_outcome.failure_reason =~ "Caller authority check failed"

    dot =
      String.replace(
        @dot,
        "action=shell_execute",
        "action=shell_execute, capabilities=missing_extra"
      )

    assert {:ok, extra_denied} = Arbor.Orchestrator.run(dot, c.opts)
    assert extra_denied.final_outcome.status == :fail

    assert extra_denied.final_outcome.failure_reason =~
             "arbor://orchestrator/execute/missing_extra"
  end

  defp authorization_fixture(c) do
    {:ok, graph} = Arbor.Orchestrator.compile(@dot)
    {:ok, authority} = RunAuthorization.new(graph, c.opts)
    {graph, Map.fetch!(graph.nodes, "effect"), Keyword.put(c.opts, :run_authorization, authority)}
  end

  defp run_with_runtime_override(opts) do
    :ok = Registry.unregister_fixture("exec")

    on_event = fn
      %{type: :pipeline_started} -> Registry.register_fixture("exec", CustomExecHandler)
      _event -> :ok
    end

    Arbor.Orchestrator.run(@dot, Keyword.put(opts, :on_event, on_event))
  end

  defp grant(c, overrides) do
    {:ok, cap} =
      Security.grant_fixture(
        Keyword.merge(
          [
            principal: c.principal,
            resource: @action_uri,
            task_id: c.task_id,
            session_id: c.session_id
          ],
          overrides
        )
      )

    cap
  end

  defp custom_effect? do
    receive do
      :custom_exec_effect -> true
    after
      0 -> false
    end
  end
end
