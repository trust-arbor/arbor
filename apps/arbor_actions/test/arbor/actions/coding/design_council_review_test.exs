defmodule Arbor.Actions.Coding.DesignCouncilReviewTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.DesignCouncilReview
  alias Arbor.Contracts.Coding.{DesignArtifactDescriptor, WorkPacket}

  @moduletag :fast

  defmodule FakeArtifactStore do
    def read(_root, task_id, _descriptor), do: {:ok, Process.get({:archived_design, task_id})}
  end

  defmodule FakeConsensus do
    def consult(question, opts) do
      send(self(), {:consult, question, opts})
      Process.get(:consult_result)
    end
  end

  setup do
    archived = "Archived design: extract a CRC core and keep the operator checkpoint."
    spoofed = "SPOOFED worker design that must never be consulted."
    sha256 = :crypto.hash(:sha256, archived) |> Base.encode16(case: :lower)
    design_digest = "sha256:" <> sha256

    {:ok, descriptor} =
      DesignArtifactDescriptor.normalize(%{
        "path" => "/tmp/coding-design-attempt-1.txt",
        "sha256" => sha256,
        "byte_size" => byte_size(archived),
        "schema_version" => 1,
        "task_id" => "task-council-1",
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
    now_ms = System.system_time(:millisecond)
    deadline = now_ms + 5_000

    params = %{
      work_packet: packet,
      packet_digest: packet_digest,
      task_id: "task-council-1",
      task: "Add the design council gate",
      design_artifact: descriptor,
      design_digest: design_digest,
      design_attempt: 1,
      run_deadline_unix_ms: deadline
    }

    Process.put({:archived_design, "task-council-1"}, archived)

    context = %{
      design_artifact_source: {FakeArtifactStore, :read, ["/tmp", "task-council-1"]},
      consensus: FakeConsensus,
      now_ms: now_ms,
      design: spoofed
    }

    {:ok,
     archived: archived,
     spoofed: spoofed,
     packet: packet,
     packet_digest: packet_digest,
     params: params,
     context: context}
  end

  test "loads the archived design by digest and ignores a differing context design", ctx do
    Process.put(:consult_result, {:ok, %{evaluations: unanimous_approve(), run_id: "run_ok"}})

    assert {:ok, result} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert result["checkpoint_outcome"] == "approve"
    assert result["note"] == ""
    assert result["design_council_run_id"] == "run_ok"
    assert result["evidence"]["design_council_run_id"] == "run_ok"
    assert result["dispersion"]["approve"] == 13
    assert result["dispersion"]["responded"] == 13

    assert_received {:consult, question, opts}
    assert question =~ ctx.archived
    refute question =~ ctx.spoofed
    assert question =~ "Add the design council gate"
    assert question =~ "core is pure"
    assert Keyword.get(opts, :deadline_unix_ms) == ctx.params.run_deadline_unix_ms
    assert Keyword.get(opts, :context) == %{"evaluation_protocol" => "design_review"}
    refute Keyword.has_key?(opts, :now_ms)
  after
    Process.delete(:consult_result)
  end

  test "packet-digest binding fails closed before any consult", ctx do
    assert {:error, {:design_checkpoint_field_required, "packet_digest"}} =
             DesignCouncilReview.run(Map.delete(ctx.params, :packet_digest), %{
               ctx.context
               | consensus: fn _q, _opts ->
                   send(self(), :consulted)
                   {:ok, %{evaluations: [], run_id: "run"}}
                 end
             })

    refute_received :consulted

    assert {:error, :work_packet_digest_mismatch} =
             DesignCouncilReview.run(%{ctx.params | packet_digest: digest("wrong")}, ctx.context)

    refute_received {:consult, _, _}

    assert {:error, :work_packet_digest_conflict} =
             DesignCouncilReview.run(
               Map.put(ctx.params, :work_packet_digest, digest("other")),
               ctx.context
             )

    refute_received {:consult, _, _}

    assert {:error, :work_packet_digest_conflict} =
             DesignCouncilReview.run(
               ctx.params,
               Map.merge(ctx.context, %{
                 "packet_digest" => digest("alias"),
                 packet_digest: ctx.packet_digest
               })
             )

    refute_received {:consult, _, _}
  end

  test "nil ConsultationLog run id is an error, never an approval", ctx do
    Process.put(:consult_result, {:ok, %{evaluations: unanimous_approve(), run_id: nil}})

    assert {:error, :design_council_run_id_required} =
             DesignCouncilReview.run(ctx.params, ctx.context)
  after
    Process.delete(:consult_result)
  end

  test "maps consult failure to an explicit error, never an approval", ctx do
    Process.put(:consult_result, {:error, :provider_unavailable})

    assert {:error, :design_council_consult_failed} =
             DesignCouncilReview.run(ctx.params, ctx.context)
  after
    Process.delete(:consult_result)
  end

  test "maps consult timeout to an explicit timeout error", ctx do
    Process.put(:consult_result, {:error, :timeout})

    assert {:error, :design_council_timeout} = DesignCouncilReview.run(ctx.params, ctx.context)
  after
    Process.delete(:consult_result)
  end

  test "maps an elapsed deadline to an explicit error without consulting", ctx do
    context = Map.put(ctx.context, :now_ms, ctx.params.run_deadline_unix_ms + 1)

    assert {:error, :design_council_deadline_elapsed} =
             DesignCouncilReview.run(ctx.params, context)

    refute_received {:consult, _, _}
  end

  test "rejects padded, control-containing, and oversized ConsultationLog run ids", ctx do
    for run_id <- [
          " run_ok",
          "run_ok ",
          "run\nid",
          "run" <> <<1>> <> "ok",
          String.duplicate("r", 257)
        ] do
      Process.put(:consult_result, {:ok, %{evaluations: unanimous_approve(), run_id: run_id}})

      assert {:error, {:design_checkpoint_identifier_invalid, "design_council_run_id"}} =
               DesignCouncilReview.run(ctx.params, ctx.context)
    end
  after
    Process.delete(:consult_result)
  end

  test "injected consult raise, throw, and exit become explicit council errors", ctx do
    assert {:error, :design_council_consult_failed} =
             DesignCouncilReview.run(
               ctx.params,
               Map.put(ctx.context, :consensus, fn _q, _opts -> raise "consult boom" end)
             )

    assert {:error, :design_council_consult_failed} =
             DesignCouncilReview.run(
               ctx.params,
               Map.put(ctx.context, :consensus, fn _q, _opts -> throw(:consult_throw) end)
             )

    assert {:error, :design_council_consult_failed} =
             DesignCouncilReview.run(
               ctx.params,
               Map.put(ctx.context, :consensus, fn _q, _opts -> exit(:consult_exit) end)
             )
  end

  test "default reject_threshold reworks at three generic rejects through run/2", ctx do
    two =
      unanimous_approve()
      |> put_vote(:privacy, :reject, ["Name the privacy bound"])
      |> put_vote(:capability, :reject, ["Name the missing grant"])

    three = put_vote(two, :vision, :reject, ["Name the missing success criterion"])

    Process.put(:consult_result, {:ok, %{evaluations: two, run_id: "run_default_two"}})
    assert {:ok, approved} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert approved["checkpoint_outcome"] == "approve"
    assert approved["dispersion"]["reject"] == 2

    Process.put(:consult_result, {:ok, %{evaluations: three, run_id: "run_default_three"}})
    assert {:ok, reworked} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert reworked["checkpoint_outcome"] == "rework"
    assert reworked["dispersion"]["reject"] == 3
  after
    Process.delete(:consult_result)
  end

  test "custom reject_threshold is enforced at the exact boundary through run/2", ctx do
    one_generic = put_vote(unanimous_approve(), :privacy, :reject, ["Name the privacy bound"])
    two_generic = put_vote(one_generic, :capability, :reject, ["Name the missing grant"])

    Process.put(:consult_result, {:ok, %{evaluations: one_generic, run_id: "run_threshold_1"}})

    assert {:ok, approved} =
             DesignCouncilReview.run(Map.put(ctx.params, :reject_threshold, 2), ctx.context)

    assert approved["checkpoint_outcome"] == "approve"
    assert approved["dispersion"]["reject"] == 1

    Process.put(:consult_result, {:ok, %{evaluations: two_generic, run_id: "run_threshold_2"}})

    assert {:ok, reworked} =
             DesignCouncilReview.run(Map.put(ctx.params, :reject_threshold, 2), ctx.context)

    assert reworked["checkpoint_outcome"] == "rework"
    assert reworked["dispersion"]["reject"] == 2
  after
    Process.delete(:consult_result)
  end

  test "custom min_responders is enforced at the exact boundary through run/2", ctx do
    four = responders(4) ++ non_responders(9)
    five = responders(5) ++ non_responders(8)

    Process.put(:consult_result, {:ok, %{evaluations: four, run_id: "run_min_4"}})

    assert {:ok, reworked} =
             DesignCouncilReview.run(Map.put(ctx.params, :min_responders, 5), ctx.context)

    assert reworked["checkpoint_outcome"] == "rework"
    assert reworked["dispersion"]["responded"] == 4

    Process.put(:consult_result, {:ok, %{evaluations: five, run_id: "run_min_5"}})

    assert {:ok, approved} =
             DesignCouncilReview.run(Map.put(ctx.params, :min_responders, 5), ctx.context)

    assert approved["checkpoint_outcome"] == "approve"
    assert approved["dispersion"]["responded"] == 5
  after
    Process.delete(:consult_result)
  end

  test "out-of-protocol abstain/error verdicts convert to rework, never approve", ctx do
    # Three seats answer outside the approve|rework protocol: a structured
    # abstain, a structured error verdict, and an unknown token. Each must
    # be admitted as a rework evaluation carrying the problem as a concern,
    # so together they trip the default reject_threshold.
    out_of_protocol =
      unanimous_approve()
      |> put_vote(:brainstorming, :abstain, [])
      |> put_vote(:user_experience, :error, [])
      |> put_vote(:privacy, "unknown_token", [])

    Process.put(:consult_result, {:ok, %{evaluations: out_of_protocol, run_id: "run_oop"}})

    assert {:ok, reworked} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert reworked["checkpoint_outcome"] == "rework"
    assert reworked["dispersion"]["reject"] == 3
    assert reworked["dispersion"]["abstain"] == 0
  after
    Process.delete(:consult_result)
  end

  test "a malformed concern payload is a seat error, not a rework responder", ctx do
    malformed =
      unanimous_approve()
      |> put_vote(:brainstorming, :approve, [123])

    Process.put(:consult_result, {:ok, %{evaluations: malformed, run_id: "run_malformed_c"}})

    assert {:ok, result} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert result["dispersion"]["error"] == 1
    assert result["dispersion"]["reject"] == 0
    assert result["checkpoint_outcome"] == "approve"
  after
    Process.delete(:consult_result)
  end

  test "end-to-end AdvisoryLLM malformed concerns are action seat errors, not rework votes",
       ctx do
    {:ok, proposal} =
      Arbor.Contracts.Consensus.Proposal.new(%{
        proposer: "human",
        topic: :advisory,
        mode: :advisory,
        description: "Review the design",
        target_layer: 4,
        context: %{"evaluation_protocol" => "design_review"}
      })

    payloads = [
      Jason.encode!(%{"verdict" => "approve", "concerns" => %{"x" => 1}}),
      Jason.encode!(%{"verdict" => "approve", "concerns" => "not-a-list"}),
      Jason.encode!(%{"verdict" => "rework", "concerns" => [1]}),
      Jason.encode!(%{"verdict" => "approve", "concerns" => [%{"nested" => true}]})
    ]

    Enum.with_index(payloads, 1)
    |> Enum.each(fn {payload, index} ->
      llm_fn = fn _system_prompt, _user_prompt -> {:ok, payload} end

      seat =
        Arbor.Consensus.Evaluators.AdvisoryLLM.evaluate(proposal, :security, llm_fn: llm_fn)

      evaluations =
        Enum.map(unanimous_approve(), fn
          {:security, _eval} -> {:security, seat_as_consult_term(seat)}
          other -> other
        end)

      Process.put(
        :consult_result,
        {:ok, %{evaluations: evaluations, run_id: "run_e2e_malformed_#{index}"}}
      )

      assert {:ok, result} = DesignCouncilReview.run(ctx.params, ctx.context)
      assert result["dispersion"]["error"] == 1
      assert result["dispersion"]["reject"] == 0
      assert result["checkpoint_outcome"] == "approve"
    end)

    # Tuple and invalid-UTF-8 cannot survive Jason.decode; they still
    # fail closed at action admission as seat errors, not rework votes.
    Enum.with_index(
      [
        put_vote(unanimous_approve(), :security, :approve, {"tuple", "payload"}),
        put_vote(unanimous_approve(), :security, :approve, [<<0xFF, 0xFE>>])
      ],
      5
    )
    |> Enum.each(fn {evaluations, index} ->
      Process.put(
        :consult_result,
        {:ok, %{evaluations: evaluations, run_id: "run_e2e_malformed_#{index}"}}
      )

      assert {:ok, result} = DesignCouncilReview.run(ctx.params, ctx.context)
      assert result["dispersion"]["error"] == 1
      assert result["dispersion"]["reject"] == 0
      assert result["checkpoint_outcome"] == "approve"
    end)
  after
    Process.delete(:consult_result)
  end

  test "malformed concerns in reasoning-only evaluations are seat errors, not rework votes",
       ctx do
    payloads = [
      Jason.encode!(%{"verdict" => "approve", "concerns" => %{"x" => 1}}),
      Jason.encode!(%{"verdict" => "approve", "concerns" => "not-a-list"}),
      %{"verdict" => "approve", "concerns" => %{"nested" => true}},
      %{"verdict" => "approve", "concerns" => {"tuple", "payload"}},
      %{"verdict" => "approve", "concerns" => [<<0xFF, 0xFE>>]}
    ]

    Enum.with_index(payloads, 1)
    |> Enum.each(fn {payload, index} ->
      evaluations = reasoning_only_security(unanimous_approve(), payload)
      run_id = "run_reasoning_malformed_#{index}"
      Process.put(:consult_result, {:ok, %{evaluations: evaluations, run_id: run_id}})

      assert {:ok, result} = DesignCouncilReview.run(ctx.params, ctx.context)
      assert result["dispersion"]["error"] == 1
      assert result["dispersion"]["reject"] == 0
      assert result["dispersion"]["responded"] == 12
      assert result["checkpoint_outcome"] == "approve"
    end)
  after
    Process.delete(:consult_result)
  end

  test "custom veto_perspectives rework only the configured seats through run/2", ctx do
    privacy_reject = put_vote(unanimous_approve(), :privacy, :reject, ["Privacy bound missing"])

    security_reject =
      put_vote(unanimous_approve(), :security, :reject, ["Capability check missing"])

    Process.put(
      :consult_result,
      {:ok, %{evaluations: privacy_reject, run_id: "run_veto_privacy"}}
    )

    assert {:ok, reworked} =
             DesignCouncilReview.run(
               Map.put(ctx.params, :veto_perspectives, ["privacy"]),
               ctx.context
             )

    assert reworked["checkpoint_outcome"] == "rework"

    Process.put(
      :consult_result,
      {:ok, %{evaluations: security_reject, run_id: "run_veto_security"}}
    )

    assert {:ok, approved} =
             DesignCouncilReview.run(
               Map.put(ctx.params, :veto_perspectives, ["privacy"]),
               ctx.context
             )

    assert approved["checkpoint_outcome"] == "approve"
    assert approved["dispersion"]["reject"] == 1
  after
    Process.delete(:consult_result)
  end

  test "default stability and adversarial vetoes rework through run/2", ctx do
    stability = put_vote(unanimous_approve(), :stability, :reject, ["Name the crash bound"])
    adversarial = put_vote(unanimous_approve(), :adversarial, :reject, ["Name the abuse case"])

    Process.put(:consult_result, {:ok, %{evaluations: stability, run_id: "run_stability"}})
    assert {:ok, stability_result} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert stability_result["checkpoint_outcome"] == "rework"

    Process.put(:consult_result, {:ok, %{evaluations: adversarial, run_id: "run_adversarial"}})
    assert {:ok, adversarial_result} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert adversarial_result["checkpoint_outcome"] == "rework"
  after
    Process.delete(:consult_result)
  end

  test "invalid decision-rule parameters fail closed through run/2", ctx do
    Process.put(
      :consult_result,
      {:ok, %{evaluations: unanimous_approve(), run_id: "run_invalid"}}
    )

    assert {:error, :invalid_design_council_rule} =
             DesignCouncilReview.run(Map.put(ctx.params, :reject_threshold, 0), ctx.context)

    assert {:error, :invalid_design_council_rule} =
             DesignCouncilReview.run(Map.put(ctx.params, :min_responders, -1), ctx.context)

    assert {:error, :invalid_veto_perspectives} =
             DesignCouncilReview.run(
               Map.put(ctx.params, :veto_perspectives, "security"),
               ctx.context
             )

    assert {:error, :invalid_veto_perspectives} =
             DesignCouncilReview.run(Map.put(ctx.params, :veto_perspectives, []), ctx.context)
  after
    Process.delete(:consult_result)
  end

  test "malformed or missing seat verdicts become rework, never approve", ctx do
    missing_vote =
      unanimous_approve()
      |> Enum.map(fn {perspective, eval} ->
        {perspective, Map.drop(eval, [:vote])}
      end)

    Process.put(
      :consult_result,
      {:ok, %{evaluations: missing_vote, run_id: "run_missing_verdict"}}
    )

    assert {:ok, result} = DesignCouncilReview.run(ctx.params, ctx.context)
    assert result["checkpoint_outcome"] == "rework"
    assert result["note"] =~ "malformed design-review verdict"
    refute result["checkpoint_outcome"] == "approve"
  after
    Process.delete(:consult_result)
  end

  test "catalogs the action as pipeline_internal" do
    assert DesignCouncilReview in Arbor.Actions.list_actions()[:coding]
    assert Arbor.Actions.pipeline_internal_action?(DesignCouncilReview)
    assert DesignCouncilReview.effect_class() == :network_egress

    assert Arbor.Actions.canonical_uri_for(DesignCouncilReview, %{}) ==
             "arbor://action/coding/design_council_review"
  end

  defp digest(value) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower)
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

  defp responders(count) do
    perspectives()
    |> Enum.take(count)
    |> Enum.map(fn perspective ->
      {perspective, %{perspective: perspective, vote: :approve, concerns: []}}
    end)
  end

  # Non-responders are seat-level ERRORS (the evaluator failed), not
  # structured abstain verdicts: a seat that answers "abstain" is out of
  # protocol and converts to rework at admission, so only errors remain
  # outside the responded count.
  defp non_responders(count) do
    perspectives()
    |> Enum.drop(length(perspectives()) - count)
    |> Enum.map(fn perspective -> {perspective, {:error, :seat_unavailable}} end)
  end

  defp seat_as_consult_term({:error, reason}), do: {:error, reason}
  defp seat_as_consult_term({:ok, eval}), do: eval

  defp put_vote(evaluations, perspective, vote, concerns) do
    Enum.map(evaluations, fn
      {^perspective, eval} -> {perspective, Map.merge(eval, %{vote: vote, concerns: concerns})}
      other -> other
    end)
  end

  defp reasoning_only_security(evaluations, reasoning) do
    Enum.map(evaluations, fn
      {:security, eval} ->
        {:security, eval |> Map.drop([:vote, "vote"]) |> Map.put(:reasoning, reasoning)}

      other ->
        other
    end)
  end
end
