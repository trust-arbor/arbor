defmodule Arbor.Orchestrator.Handlers.ExecHandlerInteractionControlTest do
  @moduledoc """
  Security regression: generic ExecHandler must never project denial/rework into
  success via author-controlled attributes. Branchable approval outcomes live
  only in the coding_reviewed_commit action result map.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ExecHandler

  defmodule DenyAsOkExecutor do
    @moduledoc false
    def execute(_name, _args, _workdir, _opts) do
      # Even if an executor tried to return a legacy control tuple, ExecHandler
      # must treat unknown returns as failures (no control protocol).
      {:control,
       %{
         "interaction_outcome" => "denied",
         "request_id" => "irq_x",
         "note" => "nope"
       }}
    end
  end

  defmodule ReviewedCommitExecutor do
    @moduledoc false
    def execute("coding_reviewed_commit", _args, _workdir, _opts) do
      {:ok,
       Jason.encode!(%{
         "interaction_outcome" => "denied",
         "request_id" => "irq_gate",
         "note" => "denied by operator",
         "commit_hash" => ""
       })}
    end

    def execute(name, _args, _workdir, _opts), do: {:error, "unexpected #{name}"}
  end

  defp empty_context do
    Context.new(%{"session.agent_id" => "agent_test", "workdir" => File.cwd!()})
  end

  test "security regression: no author attribute can turn control tuples into success" do
    node = %Node{
      id: "commit_change",
      attrs: %{
        "target" => "action",
        "action" => "coding_reviewed_commit",
        "project_interaction_control" => "true",
        "output_prefix" => "commit"
      }
    }

    outcome =
      ExecHandler.execute(node, empty_context(), %{},
        actions_executor: DenyAsOkExecutor,
        workdir: File.cwd!()
      )

    assert %Outcome{status: :fail} = outcome
    refute outcome.status == :success
  end

  test "coding_reviewed_commit success payload is branchable without control protocol" do
    node = %Node{
      id: "commit_change",
      attrs: %{
        "target" => "action",
        "action" => "coding_reviewed_commit",
        "output_prefix" => "commit"
      }
    }

    outcome =
      ExecHandler.execute(node, empty_context(), %{},
        actions_executor: ReviewedCommitExecutor,
        workdir: File.cwd!()
      )

    assert %Outcome{status: :success} = outcome
    assert outcome.context_updates["commit.interaction_outcome"] == "denied"
    assert outcome.context_updates["commit.request_id"] == "irq_gate"
  end
end
