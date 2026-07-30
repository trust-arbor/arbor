defmodule Arbor.Actions.Coding.DesignCheckpointTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.DesignCheckpoint
  alias Arbor.Actions.Coding.DesignCheckpoint.{Await, Open, Parse}
  alias Arbor.Contracts.Coding.WorkPacket

  @moduletag :fast

  defmodule FakeComms do
    def durable_ready?, do: Process.get(:durable_ready, true)

    def operator_for_agent(agent_id) do
      send(self(), {:operator_for_agent, agent_id})
      "operator-1"
    end

    def request_durable_interaction(interaction, opts) do
      send(self(), {:request_durable_interaction, interaction, opts})

      receipt =
        Process.get(:durable_receipt, %{
          request_id: interaction.request_id,
          operation_id: "op_#{interaction.request_id}",
          owner_deadline_unix_ms: Keyword.fetch!(opts, :owner_deadline_unix_ms)
        })

      Process.put(:persisted_durable_receipt, receipt)
      {:ok, receipt}
    end

    def await_durable_interaction_response(request_id, agent_id, opts) do
      send(self(), {:await_durable_interaction_response, request_id, agent_id, opts})

      with %{
             request_id: ^request_id,
             operation_id: operation_id,
             owner_deadline_unix_ms: deadline
           } <- Process.get(:persisted_durable_receipt),
           ^operation_id <- Keyword.get(opts, :operation_id),
           ^deadline <- Keyword.get(opts, :owner_deadline_unix_ms) do
        Process.get(:await_result, {:error, :timeout})
      else
        _ -> {:error, :durable_identity_mismatch}
      end
    end

    # These legacy mutating APIs must remain unused by the design checkpoint.
    def request_interaction(_interaction, _opts) do
      send(self(), :legacy_request_interaction_called)
      {:error, :legacy_api_used}
    end

    def await_interaction_response(_request_id, _agent_id, _opts) do
      send(self(), :legacy_await_interaction_response_called)
      {:error, :legacy_api_used}
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
      agent_id: "agent_123",
      timeout: 60_000
    }

    context = %{
      comms_boundary: FakeComms,
      agent_id: "agent_123",
      run_deadline_unix_ms: System.system_time(:millisecond) + 600_000
    }

    {:ok, params: params, context: context}
  end

  test "timeout admits the exact maximum and fails closed above it" do
    max = DesignCheckpoint.max_timeout_ms()

    assert max == 3_600_000
    assert max == Arbor.Actions.coding_design_checkpoint_max_timeout_ms()
    assert DesignCheckpoint.timeout(%{}, %{timeout: max}) == {:ok, max}
    assert DesignCheckpoint.timeout(%{}, %{"timeout" => max}) == {:ok, max}

    assert DesignCheckpoint.timeout(%{}, %{timeout: max + 1}) ==
             {:error, :invalid_design_checkpoint_timeout}

    assert DesignCheckpoint.timeout(%{}, %{timeout: 0}) ==
             {:error, :invalid_design_checkpoint_timeout}

    assert DesignCheckpoint.timeout(%{}, %{timeout: -1}) ==
             {:error, :invalid_design_checkpoint_timeout}

    assert DesignCheckpoint.timeout(%{}, %{timeout: "3600000"}) ==
             {:error, :invalid_design_checkpoint_timeout}
  end

  test "Open persists the atomic deadline-bound receipt and accepts an earlier duplicate deadline",
       ctx do
    earlier_deadline = System.system_time(:millisecond) + 1_000

    Process.put(:durable_receipt, %{
      request_id: "ignored until interaction is built",
      operation_id: "op_persisted_1",
      owner_deadline_unix_ms: earlier_deadline
    })

    # FakeComms needs the exact deterministic request id, which is independent
    # of the receipt and available from the shared binding helper.
    assert {:ok, binding} = DesignCheckpoint.build_binding(ctx.params, ctx.context)

    Process.put(:durable_receipt, %{
      request_id: binding.request_id,
      operation_id: "op_persisted_1",
      owner_deadline_unix_ms: earlier_deadline
    })

    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    assert opened["request_id"] == binding.request_id
    assert opened["operation_id"] == "op_persisted_1"
    assert opened["owner_deadline_unix_ms"] == earlier_deadline
    assert opened["evidence"] == binding.evidence

    assert_received {:operator_for_agent, "agent_123"}

    assert_received {:request_durable_interaction, interaction,
                     [owner_deadline_unix_ms: requested_deadline]}

    assert interaction.request_id == binding.request_id
    assert interaction.kind == :approval
    assert interaction.agent_id == "agent_123"
    assert interaction.user_id == "operator-1"
    assert interaction.metadata["work_packet"] == ctx.params.work_packet
    assert interaction.metadata["task"] == ctx.params.task
    assert interaction.metadata["plan_fingerprint"] == ctx.params.plan_fingerprint
    assert interaction.metadata["design"] == ctx.params.design
    assert interaction.metadata["packet_digest"] == ctx.params.packet_digest
    assert interaction.metadata["design_digest"] == ctx.params.design_digest

    # Description is short operator prose; exact evidence stays in metadata.
    assert interaction.description =~ "Design checkpoint for task task-123"
    assert interaction.description =~ ctx.params.packet_digest
    assert interaction.description =~ ctx.params.design_digest
    refute interaction.description =~ ctx.params.task
    refute interaction.description =~ ctx.params.design
    {:ok, canonical_packet} = WorkPacket.canonical_bytes(ctx.params.work_packet)
    refute interaction.description =~ canonical_packet
    assert byte_size(interaction.description) < 1_024
    assert :ok = Arbor.Comms.validate_durable_interaction_payload(interaction)

    assert opened["evidence"]["request_id"] == opened["request_id"]
    assert opened["evidence"]["task"] == ctx.params.task
    assert opened["evidence"]["plan_fingerprint"] == ctx.params.plan_fingerprint
    assert requested_deadline <= ctx.context.run_deadline_unix_ms
    assert requested_deadline > earlier_deadline
    refute_received :legacy_request_interaction_called
  after
    Process.delete(:durable_receipt)
    Process.delete(:persisted_durable_receipt)
  end

  test "Parse extracts progress-wrapped adjacent identical terminal envelopes", ctx do
    envelope = %{
      "design" => ctx.params.design <> ~s(\nPreserve map syntax like %{"key" => "{value}"}.),
      "design_digest" =>
        digest(ctx.params.design <> ~s(\nPreserve map syntax like %{"key" => "{value}"}.))
    }

    encoded = Jason.encode!(envelope)

    text = """
    I am checking the owned files first.
    {"event":"progress","message":"unrelated JSON is not the terminal envelope"}
    The final design follows:
    #{encoded}#{encoded}
    """

    assert {:ok, ^envelope} = Parse.run(%{text: text}, %{})
  end

  test "Parse admits a server-owned one-field envelope and computes the digest", ctx do
    encoded = Jason.encode!(%{"design" => ctx.params.design})

    assert {:ok, envelope} = Parse.run(%{text: encoded}, %{})
    assert envelope["design"] == ctx.params.design
    assert envelope["design_digest"] == ctx.params.design_digest
  end

  test "Parse rejects a lone design_digest field and any other envelope shape", ctx do
    lone_digest = Jason.encode!(%{"design_digest" => ctx.params.design_digest})

    assert {:error, :invalid_design_envelope_fields} = Parse.run(%{text: lone_digest}, %{})

    duplicate_design_only =
      ~s({"design":#{Jason.encode!(ctx.params.design)},"design":#{Jason.encode!(ctx.params.design)}})

    assert {:error, :invalid_design_envelope_fields} =
             Parse.run(%{text: duplicate_design_only}, %{})
  end

  test "Parse rejects invalid or oversized designs in a one-field envelope" do
    for invalid_design <- [" \n\t ", "invalid\u0000control"] do
      encoded = Jason.encode!(%{"design" => invalid_design})

      assert {:error, reason} = Parse.run(%{text: encoded}, %{})

      assert reason in [
               :design_checkpoint_design_blank,
               :design_checkpoint_design_control_character
             ]
    end

    oversized = String.duplicate("x", DesignCheckpoint.max_design_bytes() + 1)

    assert {:error, :design_checkpoint_design_too_large} =
             Parse.run(%{text: Jason.encode!(%{"design" => oversized})}, %{})
  end

  test "Parse rejects conflicting valid terminal envelopes", ctx do
    first = design_envelope(ctx.params.design)
    second = design_envelope(ctx.params.design <> " Use a different implementation.")

    assert {:error, :conflicting_design_envelopes} =
             Parse.run(%{text: Jason.encode!(first) <> Jason.encode!(second)}, %{})
  end

  test "Parse never extracts an envelope from inside malformed outer JSON", ctx do
    encoded = Jason.encode!(design_envelope(ctx.params.design))

    for wrapped <- ["{malformed:" <> encoded <> "}", "[malformed," <> encoded <> "]"] do
      assert {:error, :design_envelope_not_found} = Parse.run(%{text: wrapped}, %{})
    end

    assert {:error, :design_envelope_unbalanced_json} =
             Parse.run(%{text: "{malformed:" <> encoded}, %{})
  end

  test "Parse skips a whole rejected prose composite before a valid envelope", ctx do
    envelope = design_envelope(ctx.params.design)

    assert {:ok, ^envelope} =
             Parse.run(%{text: "Example syntax: {not-json}\n" <> Jason.encode!(envelope)}, %{})
  end

  test "Parse rejects candidate-like objects with extra or duplicate fields", ctx do
    extra = Jason.encode!(Map.put(design_envelope(ctx.params.design), "commentary", "done"))

    duplicate =
      ~s({"design":#{Jason.encode!(ctx.params.design)},"design":#{Jason.encode!(ctx.params.design)},"design_digest":#{Jason.encode!(ctx.params.design_digest)}})

    for candidate <- [extra, duplicate] do
      assert {:error, :invalid_design_envelope_fields} = Parse.run(%{text: candidate}, %{})
    end
  end

  test "Parse rejects digest mismatch and invalid or oversized designs", ctx do
    wrong_digest =
      Jason.encode!(%{
        "design" => ctx.params.design,
        "design_digest" => digest("different design")
      })

    assert {:error, :design_digest_mismatch} = Parse.run(%{text: wrong_digest}, %{})

    for invalid_design <- [" \n\t ", "invalid\u0000control"] do
      encoded = Jason.encode!(design_envelope(invalid_design))

      assert {:error, reason} = Parse.run(%{text: encoded}, %{})

      assert reason in [
               :design_checkpoint_design_blank,
               :design_checkpoint_design_control_character
             ]
    end

    oversized = String.duplicate("x", DesignCheckpoint.max_design_bytes() + 1)

    assert {:error, :design_checkpoint_design_too_large} =
             Parse.run(%{text: Jason.encode!(design_envelope(oversized))}, %{})
  end

  test "Parse bounds response bytes and JSON scanning attempts" do
    oversized_response =
      String.duplicate("x", DesignCheckpoint.max_terminal_response_bytes() + 1)

    assert {:error, :design_envelope_response_too_large} =
             Parse.run(%{text: oversized_response}, %{})

    excessive_candidates = String.duplicate("{}", DesignCheckpoint.max_json_scan_attempts() + 1)

    assert {:error, :design_envelope_scan_limit_exceeded} =
             Parse.run(%{text: excessive_candidates}, %{})
  end

  test "Open rejects work-packet, digest, design-digest, and policy tampering", ctx do
    tampered_packet = Map.put(ctx.params.work_packet, "success_criteria", ["tampered"])

    assert {:error, :work_packet_digest_mismatch} =
             Open.run(%{ctx.params | work_packet: tampered_packet}, ctx.context)

    assert {:error, :work_packet_digest_mismatch} =
             Open.run(%{ctx.params | packet_digest: digest("wrong")}, ctx.context)

    assert {:error, :design_digest_mismatch} =
             Open.run(%{ctx.params | design_digest: digest("wrong")}, ctx.context)

    assert {:error, :design_digest_mismatch} =
             Open.run(%{ctx.params | design: ctx.params.design <> " Tampered."}, ctx.context)

    direct_packet = Map.put(ctx.params.work_packet, "checkpoint_policy", "direct")
    {:ok, direct_digest} = WorkPacket.digest(direct_packet)

    assert {:error, :design_checkpoint_policy_required} =
             Open.run(
               %{ctx.params | work_packet: direct_packet, packet_digest: direct_digest},
               ctx.context
             )

    refute_received {:request_durable_interaction, _, _}
  end

  test "Open fails closed when exact design evidence exceeds its field bound", ctx do
    oversized_design = String.duplicate("x", DesignCheckpoint.max_design_bytes() + 1)

    assert {:error, :design_checkpoint_design_too_large} =
             Open.run(
               %{
                 ctx.params
                 | design: oversized_design,
                   design_digest: digest(oversized_design)
               },
               ctx.context
             )

    refute_received {:request_durable_interaction, _, _}
  end

  test "Open admits the measured Phase F work-packet and design shape under durable ceilings",
       ctx do
    # Measured failed Phase F shape: ~4.8 KiB work packet + ~12.7 KiB design.
    # Description must stay short operator prose; exact evidence is metadata-only.
    text_chunk = String.duplicate("phase-f-work-packet-intent-", 36)
    path_chunk = "docs/" <> String.duplicate("phase-f-arch-ref-", 55) <> "guide.md"
    assert byte_size(text_chunk) <= WorkPacket.max_text_bytes()
    assert byte_size(path_chunk) <= WorkPacket.max_architecture_ref_bytes()

    phase_f_packet = %{
      ctx.params.work_packet
      | "success_criteria" => [text_chunk],
        "non_goals" => [text_chunk],
        "constraints" => [text_chunk],
        "architecture_refs" => [path_chunk],
        "required_evidence" => [text_chunk]
    }

    {:ok, packet_bytes} = WorkPacket.canonical_bytes(phase_f_packet)
    # Keep the packet near the measured 4.8 KiB without exceeding WorkPacket bounds.
    assert_in_delta byte_size(packet_bytes), 4_900, 400

    {:ok, packet_digest} = WorkPacket.digest(phase_f_packet)
    phase_f_design = String.duplicate("d", 12_700)
    assert byte_size(phase_f_design) == 12_700

    assert {:ok, opened} =
             Open.run(
               %{
                 ctx.params
                 | work_packet: phase_f_packet,
                   packet_digest: packet_digest,
                   design: phase_f_design,
                   design_digest: digest(phase_f_design)
               },
               ctx.context
             )

    assert opened["checkpoint_outcome"] == "pending"
    assert_received {:request_durable_interaction, interaction, _opts}

    assert interaction.description =~ "Design checkpoint for task task-123"
    assert interaction.description =~ packet_digest
    assert interaction.description =~ digest(phase_f_design)
    refute interaction.description =~ phase_f_design
    refute interaction.description =~ text_chunk
    assert byte_size(interaction.description) < 1_024

    assert interaction.metadata["work_packet"] == phase_f_packet
    assert interaction.metadata["design"] == phase_f_design
    assert interaction.metadata["task"] == ctx.params.task
    assert interaction.metadata["packet_digest"] == packet_digest
    assert interaction.metadata["design_digest"] == digest(phase_f_design)

    assert {:ok, _encoded_metadata} = Jason.encode(interaction.metadata)
    assert :ok = Arbor.Comms.validate_durable_interaction_payload(interaction)
  end

  test "Open rejects aggregate metadata over durable ceilings via the public Comms validator",
       ctx do
    # Individually admitted task/design field bounds still exceed the durable
    # metadata aggregate ceiling when combined. Aggregate authority is only the
    # public Comms validator — not an action-local size copy.
    bounded_design = String.duplicate("x", DesignCheckpoint.max_task_bytes())
    bounded_task = String.duplicate("t", DesignCheckpoint.max_task_bytes())

    assert {:error, {:invalid_durable_interaction, :json_value_too_large}} =
             Open.run(
               %{
                 ctx.params
                 | task: bounded_task,
                   design: bounded_design,
                   design_digest: digest(bounded_design)
               },
               ctx.context
             )

    refute_received {:request_durable_interaction, _, _}
  end

  test "Open rejects worst-case metadata JSON expansion via the public Comms validator", ctx do
    max_text = String.duplicate("p", WorkPacket.max_text_bytes())

    large_packet = %{
      ctx.params.work_packet
      | "success_criteria" => List.duplicate(max_text, WorkPacket.max_list_items()),
        "non_goals" => List.duplicate(max_text, 16)
    }

    {:ok, large_packet_digest} = WorkPacket.digest(large_packet)
    escaped_task = String.duplicate(<<1>>, DesignCheckpoint.max_task_bytes())
    escaped_design = String.duplicate(<<1>>, DesignCheckpoint.max_task_bytes())

    assert {:error, {:invalid_durable_interaction, :json_value_too_large}} =
             Open.run(
               %{
                 ctx.params
                 | work_packet: large_packet,
                   packet_digest: large_packet_digest,
                   task: escaped_task,
                   design: escaped_design,
                   design_digest: digest(escaped_design)
               },
               ctx.context
             )

    refute_received {:request_durable_interaction, _, _}
  end

  test "Open requires a bounded task and a strict compiled plan fingerprint", ctx do
    assert {:error, :design_checkpoint_task_required} =
             Open.run(Map.delete(ctx.params, :task), ctx.context)

    assert {:error, :design_checkpoint_task_blank} =
             Open.run(%{ctx.params | task: " \n\t "}, ctx.context)

    assert {:error, :design_checkpoint_task_invalid_utf8} =
             Open.run(%{ctx.params | task: <<0xFF>>}, ctx.context)

    assert {:error, :design_checkpoint_task_control_character} =
             Open.run(%{ctx.params | task: "bad\u0000task"}, ctx.context)

    assert {:error, :design_checkpoint_task_too_large} =
             Open.run(%{ctx.params | task: String.duplicate("x", 16_385)}, ctx.context)

    assert {:error, :design_checkpoint_plan_fingerprint_required} =
             Open.run(Map.delete(ctx.params, :plan_fingerprint), ctx.context)

    assert {:error, :design_checkpoint_plan_fingerprint_invalid} =
             Open.run(
               %{ctx.params | plan_fingerprint: String.duplicate("a", 63)},
               ctx.context
             )

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

    assert {:error, :design_checkpoint_plan_fingerprint_mismatch} =
             Open.run(
               Map.put(ctx.params, :coding_plan_fingerprint, String.duplicate("b", 64)),
               ctx.context
             )
  after
    Process.delete(:persisted_durable_receipt)
  end

  test "Open derives deterministic authority ids that bind task and plan fingerprint", ctx do
    assert {:ok, first} = Open.run(ctx.params, ctx.context)
    assert {:ok, repeated} = Open.run(ctx.params, ctx.context)
    assert first["request_id"] == repeated["request_id"]
    assert String.match?(first["request_id"], ~r/^irq_design_[0-9a-f]{64}$/)

    assert {:ok, task_changed} =
             Open.run(%{ctx.params | task: "Implement a different task"}, ctx.context)

    assert task_changed["request_id"] != first["request_id"]

    assert {:ok, fingerprint_changed} =
             Open.run(
               %{ctx.params | plan_fingerprint: String.duplicate("b", 64)},
               ctx.context
             )

    assert fingerprint_changed["request_id"] != first["request_id"]
    assert fingerprint_changed["request_id"] != task_changed["request_id"]
  after
    Process.delete(:persisted_durable_receipt)
  end

  test "Open rejects widened and malformed durable receipts", ctx do
    assert {:ok, binding} = DesignCheckpoint.build_binding(ctx.params, ctx.context)

    base_receipt = %{
      request_id: binding.request_id,
      operation_id: "op_receipt_1",
      owner_deadline_unix_ms: 1
    }

    Process.put(:durable_receipt, %{base_receipt | request_id: "irq_design_wrong"})

    assert {:error, :design_checkpoint_request_id_mismatch} =
             Open.run(ctx.params, ctx.context)

    Process.put(:durable_receipt, %{base_receipt | operation_id: 123})

    assert {:error, :design_checkpoint_operation_id_required} =
             Open.run(ctx.params, ctx.context)

    Process.put(:durable_receipt, %{base_receipt | operation_id: ""})

    assert {:error, {:design_checkpoint_identifier_invalid, "operation_id"}} =
             Open.run(ctx.params, ctx.context)

    Process.put(:durable_receipt, %{base_receipt | owner_deadline_unix_ms: "later"})

    assert {:error, :invalid_design_checkpoint_persisted_deadline} =
             Open.run(ctx.params, ctx.context)

    Process.put(:durable_receipt, %{base_receipt | owner_deadline_unix_ms: 0})

    assert {:error, :invalid_design_checkpoint_persisted_deadline} =
             Open.run(ctx.params, ctx.context)

    Process.put(:durable_receipt, %{
      base_receipt
      | owner_deadline_unix_ms: ctx.context.run_deadline_unix_ms + 1
    })

    assert {:error, :design_checkpoint_durable_deadline_extended} =
             Open.run(ctx.params, ctx.context)

    Process.put(:durable_receipt, "not-a-receipt")

    assert {:error, :invalid_design_checkpoint_durable_receipt} =
             Open.run(ctx.params, ctx.context)
  after
    Process.delete(:durable_receipt)
    Process.delete(:persisted_durable_receipt)
  end

  test "Open rejects missing and conflicting durable receipt fields", ctx do
    assert {:ok, binding} = DesignCheckpoint.build_binding(ctx.params, ctx.context)

    receipt = %{
      request_id: binding.request_id,
      operation_id: "op_receipt_1",
      owner_deadline_unix_ms: 1
    }

    for key <- [:request_id, :operation_id, :owner_deadline_unix_ms] do
      Process.put(:durable_receipt, Map.delete(receipt, key))

      assert {:error, {:design_checkpoint_durable_receipt_missing, ^key}} =
               Open.run(ctx.params, ctx.context)
    end

    conflicts = %{
      request_id: "irq_design_conflict",
      operation_id: "op_receipt_conflict",
      owner_deadline_unix_ms: 2
    }

    for {key, conflicting_value} <- conflicts do
      Process.put(
        :durable_receipt,
        Map.put(receipt, Atom.to_string(key), conflicting_value)
      )

      assert {:error, {:design_checkpoint_durable_receipt_conflict, ^key}} =
               Open.run(ctx.params, ctx.context)
    end
  after
    Process.delete(:durable_receipt)
    Process.delete(:persisted_durable_receipt)
  end

  test "Open rejects expired and malformed owner deadlines before Comms", ctx do
    assert {:error, :design_checkpoint_run_deadline_elapsed} =
             Open.run(ctx.params, %{
               ctx.context
               | run_deadline_unix_ms: System.system_time(:millisecond) - 1
             })

    assert {:error, :invalid_design_checkpoint_run_deadline} =
             Open.run(ctx.params, %{ctx.context | run_deadline_unix_ms: "tomorrow"})

    refute_received {:request_durable_interaction, _, _}
  end

  test "Open fails closed when durable interactions are unavailable", ctx do
    Process.put(:durable_ready, false)

    assert {:error, :durable_interaction_unavailable} = Open.run(ctx.params, ctx.context)
    refute_received {:operator_for_agent, _}
    refute_received {:request_durable_interaction, _, _}
  after
    Process.delete(:durable_ready)
  end

  test "Await observes the exact durable identity and never calls a legacy mutating await", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    Process.put(:await_result, {:ok, :approved, authority_metadata(opened)})

    assert {:ok, result} = Await.run(await_params(ctx.params, opened), ctx.context)
    assert result["checkpoint_outcome"] == "approve"
    assert result["request_id"] == opened["request_id"]
    assert result["evidence"] == opened["evidence"]

    assert_received {:await_durable_interaction_response, request_id, "agent_123", opts}
    assert request_id == opened["request_id"]

    assert opts == [
             operation_id: opened["operation_id"],
             owner_deadline_unix_ms: opened["owner_deadline_unix_ms"]
           ]

    refute_received :legacy_await_interaction_response_called
  after
    Process.delete(:await_result)
    Process.delete(:persisted_durable_receipt)
  end

  test "Await normalizes approve, rework, deny, and timeout outcomes", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    params = await_params(ctx.params, opened)

    for {await_result, expected_outcome, expected_note} <- [
          {{:ok, :approved, authority_metadata(opened)}, "approve", ""},
          {{:ok, :rejected,
            Map.merge(authority_metadata(opened), %{
              decision: :rework,
              note: "Please add the rollback test."
            })}, "rework", "Please add the rollback test."},
          {{:ok, :rejected,
            Map.merge(authority_metadata(opened), %{
              decision: :deny,
              note: "Scope is too broad."
            })}, "deny", "Scope is too broad."}
        ] do
      Process.put(:await_result, await_result)

      assert {:ok, result} = Await.run(params, ctx.context)
      assert result["checkpoint_outcome"] == expected_outcome
      assert result["note"] == expected_note
      assert result["request_id"] == opened["request_id"]
      assert result["evidence"] == opened["evidence"]
    end

    Process.put(:await_result, {:error, :timeout})

    assert {:ok, timeout} = Await.run(params, ctx.context)
    assert timeout["checkpoint_outcome"] == "timeout"
    assert timeout["note"] == ""
    assert timeout["request_id"] == opened["request_id"]
    assert timeout["evidence"] == opened["evidence"]
  after
    Process.delete(:await_result)
    Process.delete(:persisted_durable_receipt)
  end

  test "Await rejects mismatched request evidence and persisted deadline before Comms", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    params = await_params(ctx.params, opened)

    assert {:error, :design_checkpoint_request_id_mismatch} =
             Await.run(%{params | request_id: opened["request_id"] <> "x"}, ctx.context)

    assert {:error, :design_checkpoint_evidence_mismatch} =
             Await.run(%{params | evidence: %{"tampered" => true}}, ctx.context)

    assert {:error, :design_checkpoint_owner_deadline_exceeds_run_deadline} =
             Await.run(
               %{params | owner_deadline_unix_ms: ctx.context.run_deadline_unix_ms + 1},
               ctx.context
             )

    refute_received {:await_durable_interaction_response, _, _, _}
  after
    Process.delete(:persisted_durable_receipt)
  end

  test "Await forwards an operation mismatch only to the durable observer", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)

    assert {:error, :durable_identity_mismatch} =
             Await.run(
               %{await_params(ctx.params, opened) | operation_id: "op_wrong"},
               ctx.context
             )

    assert_received {:await_durable_interaction_response, _, _, opts}
    assert opts[:operation_id] == "op_wrong"
    refute_received :legacy_await_interaction_response_called
  after
    Process.delete(:persisted_durable_receipt)
  end

  test "Await rejects task and fingerprint changes under an existing authority id", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    params = await_params(ctx.params, opened)

    assert {:error, :design_checkpoint_request_id_mismatch} =
             Await.run(%{params | task: "tampered"}, ctx.context)

    assert {:error, :design_checkpoint_request_id_mismatch} =
             Await.run(
               %{params | plan_fingerprint: String.duplicate("b", 64)},
               ctx.context
             )

    refute_received {:await_durable_interaction_response, _, _, _}
  after
    Process.delete(:persisted_durable_receipt)
  end

  test "Await rejects malformed or mismatched terminal authority evidence", ctx do
    assert {:ok, opened} = Open.run(ctx.params, ctx.context)
    params = await_params(ctx.params, opened)

    Process.put(:await_result, {:ok, :approved, %{"request_id" => "irq_design_wrong"}})

    assert {:error, {:design_checkpoint_authority_mismatch, "request_id"}} =
             Await.run(params, ctx.context)

    Process.put(:await_result, {:ok, :approved, %{"task" => "tampered"}})

    assert {:error, {:design_checkpoint_authority_mismatch, "task"}} =
             Await.run(params, ctx.context)

    Process.put(:await_result, {:ok, :approved, %{"evidence" => "not-a-map"}})

    assert {:error, :malformed_design_checkpoint_authority_evidence} =
             Await.run(params, ctx.context)

    Process.put(
      :await_result,
      {:ok, :approved, %{"evidence" => Map.put(opened["evidence"], "task", "tampered")}}
    )

    assert {:error, :design_checkpoint_authority_mismatch} =
             Await.run(params, ctx.context)

    Process.put(:await_result, {:ok, :approved, "not-metadata"})

    assert {:error, :malformed_design_checkpoint_authority_evidence} =
             Await.run(params, ctx.context)
  after
    Process.delete(:await_result)
    Process.delete(:persisted_durable_receipt)
  end

  test "catalogs canonical internal actions without exposing them" do
    alias Arbor.Actions.Coding.DesignCheckpoint.{Capture, Load}

    assert Parse in Arbor.Actions.list_actions()[:coding]
    assert Capture in Arbor.Actions.list_actions()[:coding]
    assert Open in Arbor.Actions.list_actions()[:coding]
    assert Await in Arbor.Actions.list_actions()[:coding]
    assert Load in Arbor.Actions.list_actions()[:coding]
    assert Parse.effect_class() == :read
    assert Parse.execution_idempotency() == :read_only
    assert Open.effect_class() == :network_egress
    assert Await.effect_class() == :read
    assert Await.execution_idempotency() == :read_only
    assert Arbor.Actions.pipeline_internal_action?(Parse)
    assert Arbor.Actions.pipeline_internal_action?(Capture)
    assert Arbor.Actions.pipeline_internal_action?(Open)
    assert Arbor.Actions.pipeline_internal_action?(Await)
    assert Arbor.Actions.pipeline_internal_action?(Load)

    assert Arbor.Actions.canonical_uri_for(Parse, %{}) ==
             "arbor://action/coding/design_checkpoint/parse"

    assert Arbor.Actions.canonical_uri_for(Capture, %{}) ==
             "arbor://action/coding/design_checkpoint/capture"

    assert Arbor.Actions.canonical_uri_for(Open, %{}) ==
             "arbor://action/coding/design_checkpoint/open"

    assert Arbor.Actions.canonical_uri_for(Await, %{}) ==
             "arbor://action/coding/design_checkpoint/await"

    assert Arbor.Actions.canonical_uri_for(Load, %{}) ==
             "arbor://action/coding/design_checkpoint/load"

    refute Parse in Arbor.Actions.exposed_actions()
    refute Capture in Arbor.Actions.exposed_actions()
    refute Open in Arbor.Actions.exposed_actions()
    refute Await in Arbor.Actions.exposed_actions()
    refute Load in Arbor.Actions.exposed_actions()
  end

  test "max_design_bytes is the contract sole authority and admits 17585 bytes" do
    alias Arbor.Contracts.Coding.DesignArtifactDescriptor

    assert DesignCheckpoint.max_design_bytes() == DesignArtifactDescriptor.max_bytes()
    assert DesignCheckpoint.max_design_bytes() == 32_768

    large = String.duplicate("d", 17_585)
    assert {:ok, envelope} = Parse.run(%{text: Jason.encode!(%{"design" => large})}, %{})
    assert byte_size(envelope["design"]) == 17_585
    assert envelope["design_digest"] == digest(large)
  end

  test "legacy inline request_id stays stable when design_artifact is absent", ctx do
    assert {:ok, binding} = DesignCheckpoint.build_binding(ctx.params, ctx.context)
    assert {:ok, again} = DesignCheckpoint.build_binding(ctx.params, ctx.context)
    assert binding.request_id == again.request_id

    assert binding.request_id ==
             "irq_design_b57c153c2738dc97c00f95d90f9d8ee8d5119156e7091af3f9a062525ff6d45e"

    assert Map.has_key?(binding.evidence, "design")
    refute Map.has_key?(binding.evidence, "design_artifact")
  end

  test "artifact path Open metadata has descriptor and digest but not design text", ctx do
    alias Arbor.Actions.Coding.DesignCheckpoint.{Capture, Load}
    root = tmp_root()
    task_id = ctx.params.task_id
    design = ctx.params.design
    design_digest = ctx.params.design_digest

    context =
      Map.merge(ctx.context, %{
        design_artifact_sink: {__MODULE__.FakeArtifactStore, :archive, [root, task_id]},
        design_artifact_source: {__MODULE__.FakeArtifactStore, :read, [root, task_id]}
      })

    assert {:ok, captured} =
             Capture.run(
               %{
                 design: design,
                 design_digest: design_digest,
                 task_id: task_id,
                 design_attempt: 1
               },
               context
             )

    descriptor = captured["design_artifact"]
    refute is_nil(descriptor)

    open_params =
      ctx.params
      |> Map.delete(:design)
      |> Map.put(:design_artifact, descriptor)
      |> Map.put(:design_digest, design_digest)

    assert {:ok, opened} = Open.run(open_params, context)
    assert opened["evidence"]["design_artifact"] == descriptor
    assert opened["evidence"]["design_digest"] == design_digest
    refute Map.has_key?(opened["evidence"], "design")

    assert_received {:request_durable_interaction, interaction, _}
    assert interaction.metadata["design_artifact"] == descriptor
    assert interaction.metadata["design_digest"] == design_digest
    refute Map.has_key?(interaction.metadata, "design")
    refute Jason.encode!(interaction.metadata) =~ design
    assert :ok = Arbor.Comms.validate_durable_interaction_payload(interaction)

    Process.put(:await_result, {:ok, :approved, %{}})

    assert {:ok, awaited} =
             Await.run(await_params(open_params, opened), context)

    assert awaited["checkpoint_outcome"] == "approve"

    assert {:ok, loaded} =
             Load.run(
               %{
                 design_artifact: descriptor,
                 design_digest: design_digest,
                 task_id: task_id,
                 design_attempt: 1
               },
               context
             )

    assert loaded["design"] == design
  after
    Process.delete(:await_result)
    Process.delete(:persisted_durable_receipt)
  end

  test "Await fail-closed never returns terminal outcomes for bad artifacts", ctx do
    alias Arbor.Actions.Coding.DesignCheckpoint.Capture
    root = tmp_root()
    task_id = ctx.params.task_id
    design = ctx.params.design
    design_digest = ctx.params.design_digest

    context =
      Map.merge(ctx.context, %{
        design_artifact_sink: {__MODULE__.FakeArtifactStore, :archive, [root, task_id]},
        design_artifact_source: {__MODULE__.FakeArtifactStore, :read, [root, task_id]}
      })

    assert {:ok, captured} =
             Capture.run(
               %{
                 design: design,
                 design_digest: design_digest,
                 task_id: task_id,
                 design_attempt: 1
               },
               context
             )

    descriptor = captured["design_artifact"]

    open_params =
      ctx.params
      |> Map.delete(:design)
      |> Map.put(:design_artifact, descriptor)
      |> Map.put(:design_digest, design_digest)

    assert {:ok, opened} = Open.run(open_params, context)
    base = await_params(open_params, opened)

    # Missing artifact
    File.rm!(descriptor["path"])
    Process.put(:await_result, {:ok, :approved, %{}})

    assert {:error, _reason} = Await.run(base, context)
    refute_received {:await_durable_interaction_response, _, _, _}

    # Re-archive then tamper bytes
    assert {:ok, _} =
             Capture.run(
               %{
                 design: design,
                 design_digest: design_digest,
                 task_id: task_id,
                 design_attempt: 1
               },
               context
             )

    File.chmod!(descriptor["path"], 0o600)
    File.write!(descriptor["path"], design <> "tampered")
    # immutable write may reject overwrite; force replace for tamper simulation
    File.rm!(descriptor["path"])
    File.write!(descriptor["path"], design <> "tampered")
    File.chmod!(descriptor["path"], 0o600)

    for await_result <- [
          {:ok, :approved, %{}},
          {:ok, {:rework, "note"}, %{}},
          {:ok, {:deny, "no"}, %{}},
          {:error, :timeout}
        ] do
      Process.put(:await_result, await_result)
      assert {:error, _reason} = Await.run(base, context)
    end

    refute_received {:await_durable_interaction_response, _, _, _}

    # Wrong task_id in binding vs fixed source
    wrong_task_context =
      Map.put(
        context,
        :design_artifact_source,
        {__MODULE__.FakeArtifactStore, :read, [root, "other-task"]}
      )

    assert {:error, :design_artifact_task_id_mismatch} =
             Await.run(base, wrong_task_context)

    # Path escape
    escaped = Map.put(descriptor, "path", "/etc/passwd")

    assert {:error, _} =
             DesignCheckpoint.verify_design_artifact(
               context,
               %{task_id: task_id, design_attempt: 1},
               escaped,
               design_digest
             )

    assert {:error, :design_artifact_task_id_mismatch} =
             DesignCheckpoint.verify_design_artifact(
               context,
               %{design_attempt: 1},
               descriptor,
               design_digest
             )
  after
    Process.delete(:await_result)
    Process.delete(:persisted_durable_receipt)
  end

  test "Capture rejects task_id that disagrees with executor-fixed identity", ctx do
    alias Arbor.Actions.Coding.DesignCheckpoint.Capture
    root = tmp_root()

    context =
      Map.merge(ctx.context, %{
        design_artifact_sink: {__MODULE__.FakeArtifactStore, :archive, [root, ctx.params.task_id]}
      })

    assert {:error, :design_artifact_task_id_mismatch} =
             Capture.run(
               %{
                 design: ctx.params.design,
                 design_digest: ctx.params.design_digest,
                 task_id: "attacker-task",
                 design_attempt: 1
               },
               context
             )
  end

  defmodule FakeArtifactStore do
    alias Arbor.Contracts.Coding.DesignArtifactDescriptor

    def archive(root, task_id, design_attempt, design) do
      File.mkdir_p!(root)
      path = Path.join(root, "coding-design-attempt-#{design_attempt}.txt")
      tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

      case File.open(tmp, [:write, :binary, :exclusive], fn device ->
             with :ok <- File.chmod(tmp, 0o600),
                  :ok <- IO.binwrite(device, design) do
               :ok
             end
           end) do
        {:ok, :ok} ->
          case File.ln(tmp, path) do
            :ok ->
              File.rm(tmp)
              build_descriptor(path, task_id, design_attempt, design)

            {:error, :eexist} ->
              File.rm(tmp)

              case File.read(path) do
                {:ok, ^design} -> build_descriptor(path, task_id, design_attempt, design)
                {:ok, _} -> {:error, :design_artifact_conflict}
                {:error, reason} -> {:error, reason}
              end

            {:error, reason} ->
              File.rm(tmp)
              {:error, reason}
          end

        {:ok, {:error, reason}} ->
          File.rm(tmp)
          {:error, reason}

        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    end

    def read(root, task_id, descriptor) do
      with {:ok, normalized} <- DesignArtifactDescriptor.normalize(descriptor),
           true <- normalized["task_id"] == task_id,
           path = normalized["path"],
           true <- Path.dirname(path) == Path.expand(root),
           {:ok, %File.Stat{type: :regular, mode: mode}} <- File.lstat(path),
           true <- Bitwise.band(mode, 0o777) == 0o600,
           {:ok, body} <- File.read(path),
           true <- byte_size(body) == normalized["byte_size"],
           true <-
             Base.encode16(:crypto.hash(:sha256, body), case: :lower) == normalized["sha256"] do
        {:ok, body}
      else
        _ -> {:error, :design_artifact_unavailable}
      end
    end

    defp build_descriptor(path, task_id, design_attempt, design) do
      DesignArtifactDescriptor.normalize(%{
        "path" => Path.expand(path),
        "sha256" => Base.encode16(:crypto.hash(:sha256, design), case: :lower),
        "byte_size" => byte_size(design),
        "schema_version" => 1,
        "task_id" => task_id,
        "design_attempt" => design_attempt
      })
    end
  end

  defp tmp_root do
    path =
      Path.join(
        System.tmp_dir!(),
        "design_checkpoint_artifact_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    Path.expand(path)
  end

  defp await_params(params, opened) do
    params
    |> Map.put(:request_id, opened["request_id"])
    |> Map.put(:operation_id, opened["operation_id"])
    |> Map.put(:owner_deadline_unix_ms, opened["owner_deadline_unix_ms"])
    |> Map.put(:evidence, opened["evidence"])
  end

  defp authority_metadata(opened),
    do: %{"request_id" => opened["request_id"], "evidence" => opened["evidence"]}

  defp digest(value),
    do: "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))

  defp design_envelope(design),
    do: %{"design" => design, "design_digest" => digest(design)}
end
