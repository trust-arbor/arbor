defmodule Arbor.Actions.Coding.DesignCheckpointTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Actions.Coding.DesignCheckpoint.{Await, Open}
  alias Arbor.Contracts.Coding.WorkPacket

  @moduletag :fast

  defmodule FakeComms do
    def durable_ready?, do: Process.get(:durable_ready, true)

    def operator_for_agent(agent_id) do
      send(self(), {:operator_for_agent, agent_id})
      "operator-1"
    end

    def request_interaction(interaction, opts) do
      send(self(), {:request_interaction, interaction, opts})
      {:ok, interaction.request_id}
    end

    def await_interaction_response(request_id, agent_id, opts) do
      send(self(), {:await_interaction_response, request_id, agent_id, opts})
      Process.get(:await_result, {:error, :timeout})
    end
  end

  setup do
    packet = %{
      "version" => 1,
      "success_criteria" => ["focused tests pass"],
      "non_goals" => ["execution authority"],
      "constraints" => ["touch only owned files"],
      "architecture_refs" => ["apps/arbor_actions"],
      "required_evidence" => ["action and template tests"],
      "checkpoint_policy" => "design_required"
    }

    {:ok, packet_digest} = WorkPacket.digest(packet)
    design = "Plan the smallest change, then validate the exact owned files."
    design_digest = digest(design)

    params = %{
      work_packet: packet,
      packet_digest: packet_digest,
      task_id: "task-123",
      task: "Implement the durable design checkpoint actions",
      plan_fingerprint: String.duplicate("a", 64),
      workspace_id: "workspace-123",
      worker_session_id: "acp_worker_123",
      worker_provider_session_id: "provider-session-123",
      design_attempt: 1,
      design: design,
      design_digest: design_digest,
      agent_id: "agent_123"
    }

    context = %{
      comms_boundary: FakeComms,
      agent_id: "agent_123",
      run_deadline_unix_ms: System.system_time(:millisecond) + 600_000
    }

    {:ok, params: params, context: context}
  end

  test "binds deterministic evidence and opens node-restart durable interaction", ctx do
    assert {:ok, first} = Open.run(ctx.params, ctx.context)
    assert {:ok, second} = Open.run(ctx.params, ctx.context)
    assert first == second
    assert String.match?(first["request_id"], ~r/^irq_design_[0-9a-f]{64}$/)

    assert_received {:operator_for_agent, "agent_123"}
    assert_received {:request_interaction, interaction, [durability: :node_restart]}
    assert interaction.request_id == first["request_id"]
    assert interaction.kind == :approval
    assert interaction.user_id == "operator-1"
    assert interaction.metadata["work_packet"] == ctx.params.work_packet
    assert interaction.metadata["task"] == ctx.params.task
    assert interaction.metadata["plan_fingerprint"] == ctx.params.plan_fingerprint
    assert interaction.metadata["design"] == ctx.params.design
    {:ok, canonical_packet} = WorkPacket.canonical_bytes(ctx.params.work_packet)
    assert interaction.description =~ canonical_packet
    assert interaction.description =~ ctx.params.task
    assert interaction.description =~ ctx.params.plan_fingerprint
    assert interaction.description =~ ctx.params.design
    assert first["evidence"]["request_id"] == first["request_id"]
    assert first["evidence"]["task"] == ctx.params.task
    assert first["evidence"]["plan_fingerprint"] == ctx.params.plan_fingerprint
  end

  test "rejects packet, digest, and policy tampering", ctx do
    tampered_packet = Map.put(ctx.params.work_packet, "success_criteria", ["tampered"])

    assert {:error, :work_packet_digest_mismatch} =
             Open.run(%{ctx.params | work_packet: tampered_packet}, ctx.context)

    assert {:error, :work_packet_digest_mismatch} =
             Open.run(%{ctx.params | packet_digest: digest("wrong")}, ctx.context)

    assert {:error, :design_digest_mismatch} =
             Open.run(%{ctx.params | design_digest: digest("wrong")}, ctx.context)

    direct_packet = Map.put(ctx.params.work_packet, "checkpoint_policy", "direct")
    {:ok, direct_digest} = WorkPacket.digest(direct_packet)

    assert {:error, :design_checkpoint_policy_required} =
             Open.run(
               %{ctx.params | work_packet: direct_packet, packet_digest: direct_digest},
               ctx.context
             )
  end

  test "fails closed when exact design evidence cannot fit durable bounds", ctx do
    design = String.duplicate("x", DesignCheckpoint.max_design_bytes())
    params = %{ctx.params | design: design, design_digest: digest(design)}

    assert {:error, :design_checkpoint_description_too_large} = Open.run(params, ctx.context)
    refute_received {:request_interaction, _, _}
  end

  test "await independently rejects a tampered request id", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)

    assert {:error, :design_checkpoint_request_id_mismatch} =
             Await.run(Map.put(ctx.params, :request_id, opened["request_id"] <> "x"), ctx.context)

    refute_received {:await_interaction_response, _, _, _}
  end

  test "security regression: task and plan fingerprint tampering changes the authority id", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)

    assert {:ok, task_tampered} =
             Open.run(%{ctx.params | task: "Implement a different task"}, ctx.context)

    assert task_tampered["request_id"] != opened["request_id"]

    assert {:ok, fingerprint_tampered} =
             Open.run(
               %{ctx.params | plan_fingerprint: String.duplicate("b", 64)},
               ctx.context
             )

    assert fingerprint_tampered["request_id"] != opened["request_id"]

    assert {:error, :design_checkpoint_request_id_mismatch} =
             Await.run(
               ctx.params
               |> Map.put(:request_id, opened["request_id"])
               |> Map.put(:task, "Tampered task"),
               ctx.context
             )

    assert {:error, :design_checkpoint_request_id_mismatch} =
             Await.run(
               ctx.params
               |> Map.put(:request_id, opened["request_id"])
               |> Map.put(:plan_fingerprint, String.duplicate("b", 64)),
               ctx.context
             )

    refute_received {:await_interaction_response, _, _, _}
  end

  test "requires bounded task and valid compiled plan fingerprint", ctx do
    assert {:error, :design_checkpoint_task_required} =
             Open.run(Map.delete(ctx.params, :task), ctx.context)

    assert {:error, :design_checkpoint_plan_fingerprint_required} =
             Open.run(Map.delete(ctx.params, :plan_fingerprint), ctx.context)

    assert {:error, :design_checkpoint_task_control_character} =
             Open.run(%{ctx.params | task: "bad\u0000task"}, ctx.context)

    assert {:error, :design_checkpoint_plan_fingerprint_invalid} =
             Open.run(
               %{ctx.params | plan_fingerprint: String.duplicate("A", 64)},
               ctx.context
             )

    assert {:error, :design_checkpoint_plan_fingerprint_invalid_utf8} =
             Open.run(
               %{ctx.params | plan_fingerprint: <<0xFF, String.duplicate("a", 63)::binary>>},
               ctx.context
             )

    assert {:error, :design_checkpoint_plan_fingerprint_control_character} =
             Open.run(
               %{ctx.params | plan_fingerprint: <<0, String.duplicate("a", 63)::binary>>},
               ctx.context
             )

    alias_context = Map.put(ctx.context, :coding_plan_fingerprint, ctx.params.plan_fingerprint)

    assert {:ok, aliased} =
             Open.run(Map.delete(ctx.params, :plan_fingerprint), alias_context)

    assert aliased["evidence"]["plan_fingerprint"] == ctx.params.plan_fingerprint
  end

  test "normalizes approve, rework, and deny into JSON-clean branches", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)

    for {response, expected, note} <- [
          {{:approved, %{}}, "approve", ""},
          {{:rejected, %{decision: :rework, note: "Please add the rollback test."}}, "rework",
           "Please add the rollback test."},
          {{:rejected, %{decision: :deny, note: "Scope is too broad."}}, "deny",
           "Scope is too broad."}
        ] do
      {response_value, response_metadata} = response
      Process.put(:await_result, {:ok, response_value, response_metadata})

      assert {:ok, result} =
               Await.run(Map.put(ctx.params, :request_id, opened["request_id"]), ctx.context)

      assert result["checkpoint_outcome"] == expected
      assert result["note"] == note
      assert result["request_id"] == opened["request_id"]
      assert result["evidence"]["design_digest"] == ctx.params.design_digest
    end
  after
    Process.delete(:await_result)
  end

  test "returns timeout as a structured checkpoint outcome", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    Process.put(:await_result, {:error, :timeout})

    assert {:ok, result} =
             Await.run(Map.put(ctx.params, :request_id, opened["request_id"]), ctx.context)

    assert result["checkpoint_outcome"] == "timeout"
    assert result["note"] == ""
  after
    Process.delete(:await_result)
  end

  test "await uses the minimum of static timeout and positive deadline remainder", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    request_params = Map.put(ctx.params, :request_id, opened["request_id"])

    static_params = Map.put(request_params, :timeout, 1_234)

    assert {:ok, _result} = Await.run(static_params, ctx.context)

    assert_received {:await_interaction_response, _, "agent_123", [timeout: 1_234]}

    deadline_unix_ms = System.system_time(:millisecond) + 10_000
    deadline_params = Map.put(request_params, :timeout, 20_000)
    deadline_context = Map.put(ctx.context, :run_deadline_unix_ms, deadline_unix_ms)

    assert {:ok, _result} = Await.run(deadline_params, deadline_context)

    assert_received {:await_interaction_response, _, "agent_123", [timeout: bounded_timeout]}
    assert bounded_timeout in 9_000..10_000
  end

  test "exact numeric static DOT timeout remains authoritative under a later deadline", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)

    params =
      ctx.params
      |> Map.put(:request_id, opened["request_id"])
      |> Map.put(:timeout, 300_000)

    assert {:ok, _result} = Await.run(params, ctx.context)

    assert_received {:await_interaction_response, _, "agent_123", [timeout: 300_000]}
  end

  test "elapsed owner deadline returns structured timeout without consulting Comms", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)

    params = Map.put(ctx.params, :request_id, opened["request_id"])

    context =
      Map.put(
        ctx.context,
        :run_deadline_unix_ms,
        System.system_time(:millisecond) - 1
      )

    assert {:ok, result} = Await.run(params, context)
    assert result["checkpoint_outcome"] == "timeout"
    assert result["note"] == ""
    refute_received {:await_interaction_response, _, _, _}
  end

  test "missing and malformed owner deadlines fail closed before Comms", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    params = Map.put(ctx.params, :request_id, opened["request_id"])

    assert {:error, :design_checkpoint_run_deadline_required} =
             Await.run(params, Map.delete(ctx.context, :run_deadline_unix_ms))

    assert {:error, :invalid_design_checkpoint_run_deadline} =
             Await.run(params, Map.put(ctx.context, :run_deadline_unix_ms, "later"))

    refute_received {:await_interaction_response, _, _, _}
  end

  test "far-future caller param cannot override a shorter owner context deadline", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)

    owner_deadline_unix_ms = System.system_time(:millisecond) + 3_000

    params =
      ctx.params
      |> Map.put(:request_id, opened["request_id"])
      |> Map.put(:timeout, 20_000)
      |> Map.put(:run_deadline_unix_ms, System.system_time(:millisecond) + 86_400_000)

    context = Map.put(ctx.context, :run_deadline_unix_ms, owner_deadline_unix_ms)

    assert {:ok, _result} = Await.run(params, context)

    assert_received {:await_interaction_response, _, "agent_123", [timeout: bounded_timeout]}
    assert bounded_timeout in 2_000..3_000
  end

  test "fails closed when durable interactions are unavailable", ctx do
    Process.put(:durable_ready, false)

    assert {:error, :durable_interaction_unavailable} = Open.run(ctx.params, ctx.context)
    refute_received {:request_interaction, _, _}
  after
    Process.delete(:durable_ready)
  end

  test "rejects malformed or mismatched authority evidence", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    Process.put(:await_result, {:ok, :approved, %{"request_id" => "irq_design_wrong"}})

    assert {:error, {:design_checkpoint_authority_mismatch, "request_id"}} =
             Await.run(Map.put(ctx.params, :request_id, opened["request_id"]), ctx.context)

    Process.put(:await_result, {:ok, :approved, %{"evidence" => "not-a-map"}})

    assert {:error, :malformed_design_checkpoint_authority_evidence} =
             Await.run(Map.put(ctx.params, :request_id, opened["request_id"]), ctx.context)
  after
    Process.delete(:await_result)
  end

  test "catalogs both actions and keeps them pipeline-internal" do
    assert Open in Arbor.Actions.list_actions()[:coding]
    assert Await in Arbor.Actions.list_actions()[:coding]
    assert Arbor.Actions.pipeline_internal_action?(Open)
    assert Arbor.Actions.pipeline_internal_action?(Await)

    assert Arbor.Actions.canonical_uri_for(Open, %{}) ==
             "arbor://action/coding/design_checkpoint/open"

    assert Arbor.Actions.canonical_uri_for(Await, %{}) ==
             "arbor://action/coding/design_checkpoint/await"

    refute Open in Arbor.Actions.exposed_actions()
    refute Await in Arbor.Actions.exposed_actions()
  end

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
end
