defmodule Arbor.Orchestrator.Handlers.ExecHandlerInteractionControlTest do
  @moduledoc """
  Security regression: generic ExecHandler must never project denial/rework into
  success via author-controlled attributes.

  Exact parent proof against 9b64d019: that parent projected `{:control, map}`
  into a successful Outcome for `git_commit` + `project_interaction_control`.
  Asserting only on `coding_reviewed_commit` is not a proof — 9b64 already
  failed closed for non-git_commit actions. The git_commit opt-in path is the
  regression that must fail on the bad parent and pass on HEAD.
  """
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Graph.Node
  alias Arbor.Orchestrator.Handlers.ExecHandler

  defmodule ControlExecutor do
    @moduledoc false
    def execute(_name, _args, _workdir, _opts) do
      {:control,
       %{
         "interaction_outcome" => "denied",
         "request_id" => "irq_git_control",
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

  test "security regression: git_commit control opt-in is no longer projected (fails 9b64d019)" do
    # On 9b64d019 this exact shape returned status: :success with branchable
    # commit.interaction_outcome. HEAD must treat it as an ordinary failure.
    node = %Node{
      id: "commit_change",
      attrs: %{
        "target" => "action",
        "action" => "git_commit",
        "project_interaction_control" => "true",
        "output_prefix" => "commit"
      }
    }

    outcome =
      ExecHandler.execute(node, empty_context(), %{},
        actions_executor: ControlExecutor,
        workdir: File.cwd!()
      )

    assert %Outcome{status: :fail} = outcome
    refute outcome.status == :success
    refute Map.has_key?(outcome.context_updates || %{}, "commit.interaction_outcome")
    assert is_binary(outcome.failure_reason)

    assert outcome.failure_reason =~ "control" or outcome.failure_reason =~ "denied" or
             outcome.failure_reason =~ "irq_git_control"
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
        actions_executor: ControlExecutor,
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
