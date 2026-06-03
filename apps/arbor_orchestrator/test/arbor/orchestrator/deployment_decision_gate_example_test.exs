defmodule Arbor.Orchestrator.DeploymentDecisionGateExampleTest do
  @moduledoc """
  Demo runner for `specs/pipelines/examples/deployment-decision-gate.dot`.
  Drives the same pipeline three times with three different reviewer
  answers and asserts each run routes to the matching branch and
  writes only that branch's output file.

  Exercises HITL surface area:
    * `wait.human` handler with three distinct outgoing edges
    * `CallbackInterviewer` returning different answers per run
    * Engine's adherence to `outcome.suggested_next_ids` for routing
    * `transform=template` substitution for branch-specific content
    * Multi-branch convergence to a single terminal

  No LLM calls — runs in the :fast test suite. The HITL story is
  about routing semantics; the LLM story is everywhere else.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Orchestrator.Human.Answer
  alias Arbor.Orchestrator.Human.CallbackInterviewer

  @dot_path Path.expand("../../../specs/pipelines/examples/deployment-decision-gate.dot", __DIR__)
  # Tests run as agent_decision_test; the pipeline calls file_write which
  # enforces its own capability check at the Action layer (Orchestrator.run's
  # authorization: false only bypasses engine-level checks, not action ones).
  @principal_id "agent_decision_test"

  setup_all do
    # File.Write is auth'd via Arbor.Security.authorize — needs the agent's
    # principal granted arbor://fs/write or a wildcard. Grant once for the
    # whole module to avoid per-test setup churn.
    {:ok, cap} =
      Arbor.Contracts.Security.Capability.new(
        resource_uri: "arbor://fs/**",
        principal_id: @principal_id,
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true}
      )

    Arbor.Security.CapabilityStore.put(cap)
    :ok
  end

  setup do
    workdir = Path.join(System.tmp_dir!(), "arbor_decision_#{System.unique_integer([:positive])}")
    File.mkdir_p!(workdir)

    on_exit(fn -> File.rm_rf(workdir) end)

    spec_path = "spec.json"
    approve_path = Path.join(workdir, "approved.txt")
    modify_path = Path.join(workdir, "needs_modification.txt")
    reject_path = Path.join(workdir, "rejected.txt")

    spec = %{
      "proposal" => "Deploy v1.2.3 to staging",
      "approve_output_path" => approve_path,
      "modify_output_path" => modify_path,
      "reject_output_path" => reject_path
    }

    File.write!(Path.join(workdir, spec_path), Jason.encode!(spec, pretty: true))

    logs_root =
      Path.join(System.tmp_dir!(), "arbor_decision_logs_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(logs_root) end)

    {:ok,
     workdir: workdir,
     spec_path: spec_path,
     approve_path: approve_path,
     modify_path: modify_path,
     reject_path: reject_path,
     logs_root: logs_root}
  end

  describe "decision routing" do
    test "Approve answer writes only the approve file", ctx do
      run_with_answer(ctx, "Approve")

      assert File.exists?(ctx.approve_path)
      refute File.exists?(ctx.modify_path)
      refute File.exists?(ctx.reject_path)

      assert File.read!(ctx.approve_path) == "APPROVED: Deploy v1.2.3 to staging"
    end

    test "Modify answer writes only the modify file", ctx do
      run_with_answer(ctx, "Modify")

      assert File.exists?(ctx.modify_path)
      refute File.exists?(ctx.approve_path)
      refute File.exists?(ctx.reject_path)

      assert File.read!(ctx.modify_path) == "NEEDS MODIFICATION: Deploy v1.2.3 to staging"
    end

    test "Reject answer writes only the reject file", ctx do
      run_with_answer(ctx, "Reject")

      assert File.exists?(ctx.reject_path)
      refute File.exists?(ctx.approve_path)
      refute File.exists?(ctx.modify_path)

      assert File.read!(ctx.reject_path) == "REJECTED: Deploy v1.2.3 to staging"
    end

    test "completed_nodes contains only the chosen branch's transforms + write", ctx do
      result = run_with_answer(ctx, "Modify")

      # Only the modify branch's nodes should be in completed_nodes.
      assert "build_modify_content" in result.completed_nodes
      assert "write_modify" in result.completed_nodes
      refute "write_approve" in result.completed_nodes
      refute "write_reject" in result.completed_nodes

      # The shared prefix and the decision node both ran.
      assert "decision" in result.completed_nodes
      assert "read_spec" in result.completed_nodes
    end
  end

  describe "interview event stream" do
    test "emits interview_started and interview_completed with the chosen branch", ctx do
      events = collect_events(ctx, "Approve")

      interview_started = Enum.find(events, &(&1[:type] == :interview_started))
      assert interview_started, "expected an interview_started event"
      assert interview_started.stage == "decision"

      interview_completed = Enum.find(events, &(&1[:type] == :interview_completed))
      assert interview_completed, "expected an interview_completed event"
      assert interview_completed.selected == "build_approve_content"
      assert interview_completed.answer == "Approve"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp run_with_answer(ctx, answer_label) do
    initial_values = %{
      "spec_path" => ctx.spec_path,
      "workdir" => ctx.workdir,
      "session.agent_id" => @principal_id
    }

    interviewer = {CallbackInterviewer, [callback: fn _q -> %Answer{value: answer_label} end]}

    assert {:ok, result} =
             Arbor.Orchestrator.run_file(@dot_path,
               initial_values: initial_values,
               logs_root: ctx.logs_root,
               interviewer: interviewer,
               # No identity/capability bootstrap needed — the pipeline does
               # only local I/O and the test runs in a sandbox.
               authorization: false
             )

    assert result.final_outcome.status == :success,
           "pipeline failed: #{inspect(result.final_outcome.failure_reason)}"

    result
  end

  defp collect_events(ctx, answer_label) do
    test_pid = self()

    initial_values = %{
      "spec_path" => ctx.spec_path,
      "workdir" => ctx.workdir,
      "session.agent_id" => @principal_id
    }

    interviewer = {CallbackInterviewer, [callback: fn _q -> %Answer{value: answer_label} end]}

    {:ok, _result} =
      Arbor.Orchestrator.run_file(@dot_path,
        initial_values: initial_values,
        logs_root: ctx.logs_root,
        interviewer: interviewer,
        authorization: false,
        on_event: fn event -> send(test_pid, {:event, event}) end
      )

    drain_events([])
  end

  defp drain_events(acc) do
    receive do
      {:event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
