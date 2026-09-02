defmodule Arbor.Actions.Coding.DesignCouncilReviewSecurityRegressionTest do
  @moduledoc """
  Security regression: a design-council veto seat classified as a provider
  error must fail closed with `:design_council_veto_unavailable` and must
  not approve or consume design-rework budget as `checkpoint_outcome=rework`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Arbor.Actions.Coding.DesignCouncilReview
  alias Arbor.Consensus.Evaluators.AdvisoryLLM
  alias Arbor.Contracts.Coding.{DesignArtifactDescriptor, WorkPacket}
  alias Arbor.Contracts.Consensus.Proposal

  @moduletag :fast
  @moduletag :security_regression

  @default_veto_perspectives [:adversarial, :security, :stability]

  defmodule FakeArtifactStore do
    def read(_root, task_id, _descriptor), do: {:ok, Process.get({:archived_design, task_id})}
  end

  defmodule FakeConsensus do
    def consult(question, opts) do
      send(self(), {:consult, question, opts})
      Process.get(:consult_result)
    end
  end

  defmodule RecordingConsultationLog do
    def log_single(question, perspective, eval, llm_meta, opts) do
      send(self(), {:log_single, question, perspective, eval, llm_meta, opts})
      :ok
    end
  end

  setup do
    archived = "Archived design: extract a CRC core and keep the operator checkpoint."
    sha256 = :crypto.hash(:sha256, archived) |> Base.encode16(case: :lower)
    design_digest = "sha256:" <> sha256

    {:ok, descriptor} =
      DesignArtifactDescriptor.normalize(%{
        "path" => "/tmp/coding-design-attempt-1.txt",
        "sha256" => sha256,
        "byte_size" => byte_size(archived),
        "schema_version" => 1,
        "task_id" => "task-council-sec-1",
        "design_attempt" => 1
      })

    packet = %{
      "version" => 1,
      "success_criteria" => ["core is pure"],
      "non_goals" => ["do not merge"],
      "constraints" => ["no worker shell"],
      "architecture_refs" => ["apps/arbor_actions"],
      "required_evidence" => ["focused tests"],
      "checkpoint_policy" => "design_required"
    }

    {:ok, packet_digest} = WorkPacket.digest(packet)
    plan_fingerprint = String.duplicate("a", 64)

    plan_review_context_json =
      ~s({"budgets":{"wall_clock_ms":28800000},"plan_fingerprint":"#{plan_fingerprint}"})

    now_ms = System.system_time(:millisecond)
    deadline = now_ms + 5_000

    params = %{
      work_packet: packet,
      packet_digest: packet_digest,
      task_id: "task-council-sec-1",
      task: "Add the design council gate",
      plan_review_context_json: plan_review_context_json,
      plan_fingerprint: plan_fingerprint,
      design_artifact: descriptor,
      design_digest: design_digest,
      design_attempt: 1,
      run_deadline_unix_ms: deadline
    }

    Process.put({:archived_design, "task-council-sec-1"}, archived)

    context = %{
      design_artifact_source: {FakeArtifactStore, :read, ["/tmp", "task-council-sec-1"]},
      consensus: FakeConsensus,
      now_ms: now_ms
    }

    {:ok, params: params, context: context}
  end

  test "security regression: each default veto provider error fails closed at run/2", ctx do
    for perspective <- @default_veto_perspectives do
      evaluations = put_error(unanimous_approve(), perspective, :api_error)

      Process.put(
        :consult_result,
        {:ok, %{evaluations: evaluations, run_id: "run_sec_veto_#{perspective}"}}
      )

      log =
        capture_log(fn ->
          assert {:error, :design_council_veto_unavailable} =
                   DesignCouncilReview.run(ctx.params, ctx.context)
        end)

      assert log =~ "veto perspective unavailable"
      refute log =~ "api_error"
    end
  after
    Process.delete(:consult_result)
  end

  test "security regression: a non-veto provider error remains nonblocking when quorum holds",
       ctx do
    evaluations = put_error(unanimous_approve(), :brainstorming, :api_error)

    Process.put(
      :consult_result,
      {:ok, %{evaluations: evaluations, run_id: "run_sec_non_veto"}}
    )

    assert {:ok, result} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert result["checkpoint_outcome"] == "approve"
    assert result["dispersion"]["error"] == 1
    assert result["dispersion"]["approve"] == 12
    assert result["dispersion"]["responded"] == 12
  after
    Process.delete(:consult_result)
  end

  test "security regression: action boundary returns the bounded atom, not a checkpoint map",
       ctx do
    evaluations = put_error(unanimous_approve(), :security, :api_error)

    Process.put(
      :consult_result,
      {:ok, %{evaluations: evaluations, run_id: "run_sec_boundary"}}
    )

    assert {:error, :design_council_veto_unavailable} =
             DesignCouncilReview.run(ctx.params, ctx.context)
  after
    Process.delete(:consult_result)
  end

  test "security regression: provider error logs synthetic abstain evidence then fails closed",
       ctx do
    {:ok, proposal} =
      Proposal.new(%{
        proposer: "human",
        topic: :advisory,
        mode: :advisory,
        description: "Review the design",
        target_layer: 4,
        context: %{"evaluation_protocol" => "design_review"}
      })

    llm_fn = fn _system_prompt, _user_prompt -> {:error, :api_error} end

    assert {:error, :api_error} =
             AdvisoryLLM.evaluate(proposal, :security,
               llm_fn: llm_fn,
               consultation_id: "run_sec_obs",
               consultation_log: RecordingConsultationLog
             )

    assert_received {:log_single, _question, :security, eval, _llm_meta, opts}
    assert eval.vote == :abstain
    assert eval.sealed == true
    assert Keyword.get(opts, :run_id) == "run_sec_obs"

    evaluations = put_error(unanimous_approve(), :security, :api_error)

    Process.put(
      :consult_result,
      {:ok, %{evaluations: evaluations, run_id: "run_sec_obs_action"}}
    )

    log =
      capture_log(fn ->
        assert {:error, :design_council_veto_unavailable} =
                 DesignCouncilReview.run(ctx.params, ctx.context)
      end)

    assert log =~ "veto perspective unavailable"
  after
    Process.delete(:consult_result)
  end

  defp perspectives do
    [
      :brainstorming,
      :user_experience,
      :security,
      :privacy,
      :stability,
      :capability,
      :emergence,
      :vision,
      :performance,
      :generalization,
      :resource_usage,
      :consistency,
      :adversarial
    ]
  end

  defp unanimous_approve do
    Enum.map(perspectives(), fn perspective ->
      {perspective, %{perspective: perspective, vote: :approve, concerns: [], reasoning: ""}}
    end)
  end

  defp put_error(evaluations, perspective, reason) do
    Enum.map(evaluations, fn
      {^perspective, _eval} -> {perspective, {:error, reason}}
      other -> other
    end)
  end
end
