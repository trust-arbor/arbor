defmodule Arbor.Orchestrator.Handlers.ExecHandlerExecutionIdTest do
  @moduledoc """
  L3B B3: ExecHandler forwards the owner-issued effect execution_id from
  process-local Engine handler opts into ActionsExecutor opts only when present.

  The ID is never read from DOT attrs, Engine Context, or action params, and is
  never injected into action params / Outcome context updates.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ExecHandler

  @moduletag :fast
  @owner_id "exec_" <> String.duplicate("b", 32)

  defmodule StubExecutor do
    def execute(name, args, workdir, opts) do
      send(self(), {:stub_execute, name, args, workdir, opts})
      {:ok, ~s({"ok":true})}
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
end
