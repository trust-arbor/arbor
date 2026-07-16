defmodule Arbor.Orchestrator.Handlers.ExecHandlerExecutionIdTest do
  @moduledoc """
  L3B B3: ExecHandler forwards the owner-issued effect execution_id from
  process-local Engine handler opts into ActionsExecutor opts only when present.

  The ID is never read from DOT attrs, Engine Context, or action params, and is
  never injected into action params / Outcome context updates.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ExecHandler

  @moduletag :fast
  @owner_id "exec_" <> String.duplicate("b", 32)

  defmodule StubExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:stub_execute, name, args, workdir, opts})

      result =
        if name == "acp_send_message" do
          %{"text" => "done", "transcript" => descriptor()}
        else
          %{"ok" => true}
        end

      {:ok, Jason.encode!(result)}
    end

    def descriptor do
      %{
        "path" => "/tmp/task/acp-transcript.json",
        "sha256" => String.duplicate("a", 64),
        "byte_size" => 128,
        "turns_retained" => 1,
        "turns_seen" => 1,
        "turns_omitted" => 0,
        "turns_truncated" => false,
        "aggregate_truncated" => false,
        "schema_version" => 1,
        "task_id" => "task-1"
      }
    end
  end

  defp action_node(attrs) do
    %Node{id: "n_exec", attrs: Map.merge(%{"target" => "action"}, attrs)}
  end

  defp graph, do: %Graph{}

  defp base_opts(extra \\ []) do
    Keyword.merge([agent_id: "agent_test", actions_executor: StubExecutor], extra)
  end

  test "forwards the exact process-local execution_id to ActionsExecutor opts" do
    node =
      action_node(%{
        "action" => "file.read",
        "arg.path" => "mix.exs"
      })

    outcome =
      ExecHandler.execute(node, Context.new(), graph(), base_opts(execution_id: @owner_id))

    assert outcome.status == :success

    assert_received {:stub_execute, "file.read", args, _workdir, executor_opts}

    assert Keyword.fetch!(executor_opts, :execution_id) === @owner_id
    refute Map.has_key?(args, "execution_id")
    refute Map.has_key?(args, :execution_id)
    refute Map.has_key?(outcome.context_updates, "execution_id")
    refute Map.has_key?(outcome.context_updates, "exec.n_exec.execution_id")
  end

  test "forwards a trusted MFA sink only as process-local executor opts" do
    sink = {Arbor.Orchestrator.CodingPlan.ArtifactStore, :append_transcript_turn, ["/tmp", "t"]}

    node =
      action_node(%{
        "action" => "acp_send_message",
        "arg.worker_session_id" => "acp_worker_test",
        "arg.prompt" => "continue"
      })

    outcome =
      ExecHandler.execute(
        node,
        Context.new(),
        graph(),
        base_opts(execution_id: @owner_id, transcript_sink: sink)
      )

    assert outcome.status == :success
    assert_received {:stub_execute, "acp_send_message", args, _workdir, executor_opts}
    assert Keyword.fetch!(executor_opts, :transcript_sink) == sink
    refute Map.has_key?(args, "transcript_sink")
    refute Map.has_key?(outcome.context_updates, "transcript_sink")
    assert outcome.context_updates["exec.n_exec.transcript"] == StubExecutor.descriptor()
    refute Map.has_key?(outcome.context_updates["exec.n_exec.transcript"], "turns")
    assert {:ok, _json} = Jason.encode(outcome.context_updates)
  end

  test "malformed transcript sink becomes a bounded process-local rejection sentinel" do
    malformed_sink = %{callback: fn -> :unsafe end, payload: Integer.pow(10, 100)}

    node =
      action_node(%{
        "action" => "acp_send_message",
        "arg.worker_session_id" => "acp_worker_test",
        "arg.prompt" => "continue"
      })

    outcome =
      ExecHandler.execute(
        node,
        Context.new(),
        graph(),
        base_opts(execution_id: @owner_id, transcript_sink: malformed_sink)
      )

    assert outcome.status == :success
    assert_received {:stub_execute, "acp_send_message", args, _workdir, executor_opts}

    assert Keyword.fetch!(executor_opts, :transcript_capture_error) ==
             :invalid_trusted_transcript_capture

    refute Keyword.has_key?(executor_opts, :transcript_sink)
    refute Map.has_key?(args, "transcript_sink")
    refute Map.has_key?(args, "transcript_capture_error")
    refute Map.has_key?(outcome.context_updates, "transcript_sink")
    refute Map.has_key?(outcome.context_updates, "transcript_capture_error")
    refute inspect(outcome.context_updates) =~ "callback"
    assert {:ok, _json} = Jason.encode(outcome.context_updates)
  end

  test "security regression: malformed sink fails through ExecHandler and ActionsExecutor" do
    for module <- [
          Arbor.Security.Identity.Registry,
          Arbor.Security.Identity.NonceCache,
          Arbor.Security.SystemAuthority,
          Arbor.Security.CapabilityStore,
          Arbor.Trust.EventStore,
          Arbor.Trust.Store
        ] do
      ensure_started(module)
    end

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )

    agent_id = "agent_exec_transcript_#{System.unique_integer([:positive])}"

    assert {:ok, capability} =
             Arbor.Security.grant(principal: agent_id, resource: "arbor://acp/tool")

    assert {:ok, _profile} =
             Arbor.Trust.ensure_trust_profile(agent_id,
               baseline: :block,
               rules: %{"arbor://acp/tool" => :allow}
             )

    assert {:ok, _capability} =
             Arbor.Security.CapabilityStore.find_authorizing(agent_id, "arbor://acp/tool")

    assert {:ok, :authorized} =
             Arbor.Trust.authorize(agent_id, "arbor://acp/tool", :execute,
               effect_class: :network_egress,
               egress_tier: :external_peer
             )

    on_exit(fn ->
      Arbor.Security.revoke(capability.id)
      Arbor.Trust.delete_trust_profile(agent_id)
    end)

    node =
      action_node(%{
        "action" => "acp_send_message",
        "arg.worker_session_id" => "acp_worker_must_not_run",
        "arg.prompt" => "continue"
      })

    outcome =
      ExecHandler.execute(
        node,
        %Context{values: %{"session.agent_id" => agent_id}},
        graph(),
        base_opts(
          actions_executor: Arbor.Orchestrator.ActionsExecutor,
          execution_id: @owner_id,
          transcript_sink: %{callback: fn -> :unsafe end}
        )
      )

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "invalid_trusted_transcript_capture"
    refute outcome.failure_reason =~ "callback"
    refute inspect(outcome.context_updates) =~ "callback"
    assert {:ok, _json} = Jason.encode(outcome.context_updates)
  end

  test "omits execution_id when Engine did not supply an owner ID" do
    node =
      action_node(%{
        "action" => "file.read",
        "arg.path" => "mix.exs"
      })

    outcome = ExecHandler.execute(node, Context.new(), graph(), base_opts())

    assert outcome.status == :success
    assert_received {:stub_execute, "file.read", _args, _workdir, executor_opts}
    refute Keyword.has_key?(executor_opts, :execution_id)
  end

  test "attrs and context cannot override the process-local execution_id or turn it into a param" do
    spoof_attr = "spoofed_from_attr"
    spoof_context = "spoofed_from_context"

    node =
      action_node(%{
        "action" => "file.read",
        "arg.path" => "mix.exs",
        # Bare attr and param-prefixed forms must not become the owner ID path.
        "execution_id" => spoof_attr,
        "param.execution_id" => spoof_attr,
        "context_keys" => "execution_id"
      })

    context = %Context{values: %{"execution_id" => spoof_context, "path" => "mix.exs"}}

    outcome =
      ExecHandler.execute(
        node,
        context,
        graph(),
        base_opts(execution_id: @owner_id)
      )

    assert outcome.status == :success

    assert_received {:stub_execute, "file.read", args, _workdir, executor_opts}

    # Process-local opts win; attrs/context never select the owner ID.
    assert Keyword.fetch!(executor_opts, :execution_id) === @owner_id
    refute Keyword.get(executor_opts, :execution_id) == spoof_attr
    refute Keyword.get(executor_opts, :execution_id) == spoof_context

    # The Engine Context value wins normal action-argument merging, but remains
    # ordinary input and cannot replace the process-local owner control value.
    assert args["execution_id"] === spoof_context
    refute args["execution_id"] === @owner_id

    refute Map.has_key?(outcome.context_updates, "execution_id")
  end

  test "spoofed attrs/context alone never invent an owner execution_id" do
    node =
      action_node(%{
        "action" => "file.read",
        "arg.path" => "mix.exs",
        "execution_id" => "spoofed_attr_only",
        "param.execution_id" => "spoofed_param_only",
        "context_keys" => "execution_id"
      })

    context = %Context{values: %{"execution_id" => "spoofed_context_only"}}

    outcome = ExecHandler.execute(node, context, graph(), base_opts())

    assert outcome.status == :success
    assert_received {:stub_execute, "file.read", args, _workdir, executor_opts}
    assert args["execution_id"] === "spoofed_context_only"
    refute Keyword.has_key?(executor_opts, :execution_id)
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module), do: :already_running, else: start_supervised!({module, opts})
  end
end
