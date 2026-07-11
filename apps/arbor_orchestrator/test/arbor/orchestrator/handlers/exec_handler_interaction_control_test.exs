defmodule Arbor.Orchestrator.Handlers.ExecHandlerInteractionControlTest do
  @moduledoc """
  ExecHandler may project ActionsExecutor `{:control, map}` into a successful
  branchable Outcome only for the reviewed git_commit opt-in.
  """
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Graph
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ExecHandler

  @moduletag :fast

  defmodule ControlExecutor do
    def execute(_name, _args, _workdir, _opts) do
      {:control,
       %{
         "interaction_outcome" => "rework",
         "request_id" => "irq_test_1",
         "note" => "fix it"
       }}
    end
  end

  defmodule DenyControlExecutor do
    def execute(_name, _args, _workdir, _opts) do
      {:control,
       %{
         "interaction_outcome" => "denied",
         "request_id" => "irq_deny_1",
         "note" => "no"
       }}
    end
  end

  defmodule SuccessExecutor do
    def execute(_name, _args, _workdir, _opts) do
      {:ok, Jason.encode!(%{"commit_hash" => "abc123", "message" => "ok"})}
    end
  end

  defp action_node(attrs) do
    %Node{id: "commit_change", attrs: Map.merge(%{"target" => "action"}, attrs)}
  end

  defp graph, do: %Graph{}

  defp opts(executor), do: [agent_id: "agent_test", actions_executor: executor]

  test "reviewed git_commit opt-in projects rework control into success Outcome" do
    node =
      action_node(%{
        "action" => "git_commit",
        "output_prefix" => "commit",
        "project_interaction_control" => "true"
      })

    outcome = ExecHandler.execute(node, Context.new(), graph(), opts(ControlExecutor))

    assert outcome.status == :success
    assert outcome.context_updates["commit.interaction_outcome"] == "rework"
    assert outcome.context_updates["commit.request_id"] == "irq_test_1"
    assert outcome.context_updates["commit.note"] == "fix it"
  end

  test "reviewed git_commit opt-in projects denied control into success Outcome" do
    node =
      action_node(%{
        "action" => "git_commit",
        "output_prefix" => "commit",
        "project_interaction_control" => "true"
      })

    outcome = ExecHandler.execute(node, Context.new(), graph(), opts(DenyControlExecutor))

    assert outcome.status == :success
    assert outcome.context_updates["commit.interaction_outcome"] == "denied"
    assert outcome.context_updates["commit.request_id"] == "irq_deny_1"
  end

  test "absent opt-in fails control as ordinary action failure" do
    node =
      action_node(%{
        "action" => "git_commit",
        "output_prefix" => "commit"
      })

    outcome = ExecHandler.execute(node, Context.new(), graph(), opts(ControlExecutor))

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "rework"
    assert outcome.failure_reason =~ "irq_test_1"
  end

  test "wrong action with opt-in fails control closed" do
    node =
      action_node(%{
        "action" => "mix_compile",
        "output_prefix" => "validation",
        "project_interaction_control" => "true"
      })

    outcome = ExecHandler.execute(node, Context.new(), graph(), opts(ControlExecutor))

    assert outcome.status == :fail
    assert outcome.failure_reason =~ "rework"
    refute Map.has_key?(outcome.context_updates || %{}, "validation.interaction_outcome")
  end

  test "successful git_commit with opt-in clears prior interaction control keys" do
    node =
      action_node(%{
        "action" => "git_commit",
        "output_prefix" => "commit",
        "project_interaction_control" => "true"
      })

    outcome = ExecHandler.execute(node, Context.new(), graph(), opts(SuccessExecutor))

    assert outcome.status == :success
    assert outcome.context_updates["commit.commit_hash"] == "abc123"
    assert outcome.context_updates["commit.interaction_outcome"] == ""
    assert outcome.context_updates["commit.request_id"] == ""
    assert outcome.context_updates["commit.note"] == ""
  end
end
