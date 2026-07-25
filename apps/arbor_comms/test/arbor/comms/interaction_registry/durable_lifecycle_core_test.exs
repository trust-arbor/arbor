defmodule Arbor.Comms.InteractionRegistry.DurableLifecycleCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Comms.InteractionRegistry.DurableLifecycleCore
  alias Arbor.Contracts.Comms.Interaction

  @now 1_700_000_000_000

  describe "construction and strict JSON schema" do
    test "constructs a closed JSON-clean pending record and reconstructs the interaction" do
      interaction = interaction()

      assert {:ok, record} =
               DurableLifecycleCore.new(interaction, "op-1", "node-a", "epoch-1", @now)

      assert Map.keys(record) |> Enum.sort() == [
               "admitted_at_unix_ms",
               "authority_epoch",
               "authority_node",
               "interaction",
               "operation_id",
               "owner_deadline_unix_ms",
               "request_id",
               "schema_version",
               "status",
               "terminal",
               "updated_at_unix_ms"
             ]

      assert {:ok, decoded} = Jason.encode(record)
      assert {:ok, ^record} = Jason.decode(decoded)
      assert {:ok, ^interaction} = DurableLifecycleCore.project_interaction(record)
      assert {:ok, ^record} = DurableLifecycleCore.decode(record)
    end

    test "rejects unknown fields, malformed interaction fields, and non-JSON metadata" do
      {:ok, record} = DurableLifecycleCore.new(interaction(), "op-1", "node-a", "epoch-1", @now)

      assert {:error, {:unknown_fields, :record}} =
               DurableLifecycleCore.decode(Map.put(record, "unexpected", true))

      malformed = put_in(record["interaction"]["kind"], "made-up")
      assert {:error, {:invalid, :kind}} = DurableLifecycleCore.decode(malformed)

      atom_key_metadata = put_in(record["interaction"]["metadata"], %{resource: "example"})
      assert {:error, :non_string_json_key} = DurableLifecycleCore.decode(atom_key_metadata)

      bad_metadata = %{interaction() | metadata: %{"pid" => self()}}

      assert {:error, :non_json_value} =
               DurableLifecycleCore.new(bad_metadata, "op-1", "node-a", "epoch-1", @now)
    end

    test "rejects invalid UTF-8 identifiers" do
      invalid = <<0xFF>>

      assert {:error, :invalid_utf8} =
               DurableLifecycleCore.new(interaction(), invalid, "node-a", "epoch-1", @now)

      assert {:error, :invalid_utf8} =
               DurableLifecycleCore.new(interaction(), "op-1", "node-a", invalid, @now)
    end

    test "rejects oversized metadata and unsupported response terms" do
      oversized = %{
        interaction()
        | metadata: %{
            "a" => String.duplicate("x", 10_000),
            "b" => String.duplicate("x", 10_000),
            "c" => String.duplicate("x", 10_000),
            "d" => String.duplicate("x", 10_000)
          }
      }

      assert {:error, :json_value_too_large} =
               DurableLifecycleCore.new(oversized, "op-1", "node-a", "epoch-1", @now)

      {:ok, record} = DurableLifecycleCore.new(interaction(), "op-1", "node-a", "epoch-1", @now)

      assert {:error, :non_json_response} =
               DurableLifecycleCore.respond(
                 record,
                 {:unexpected, self()},
                 %{},
                 "node-a",
                 "epoch-1",
                 @now + 1
               )
    end
  end

  describe "authority epochs and deadlines" do
    setup do
      {:ok, record} = DurableLifecycleCore.new(interaction(), "op-1", "node-a", "epoch-1", @now)
      %{record: record}
    end

    test "operation and request IDs are immutable across lifecycle operations", %{record: record} do
      {:ok, armed} = DurableLifecycleCore.arm_deadline(record, @now + 10_000, @now + 1)
      assert {:ok, ^armed} = DurableLifecycleCore.decode(armed)

      {:ok, claimed} = DurableLifecycleCore.claim_epoch(armed, "node-a", "epoch-2", @now + 2)
      assert {:ok, ^claimed} = DurableLifecycleCore.decode(claimed)

      {:ok, terminal} =
        DurableLifecycleCore.abandon(claimed, :owner_timeout, "node-a", "epoch-2", @now + 3)

      assert {:ok, ^terminal} = DurableLifecycleCore.decode(terminal)

      assert terminal["operation_id"] == "op-1"
      assert terminal["request_id"] == record["request_id"]
      assert terminal["interaction"] == record["interaction"]
    end

    test "claims a same-node epoch and rejects wrong-node and stale claims", %{record: record} do
      assert {:error, :wrong_authority_node} =
               DurableLifecycleCore.claim_epoch(record, "node-b", "epoch-2", @now + 1)

      assert {:ok, claimed} =
               DurableLifecycleCore.claim_epoch(record, "node-a", "epoch-2", @now + 1)

      assert {:error, :stale_authority_epoch} =
               DurableLifecycleCore.claim_epoch(claimed, "node-a", "epoch-1", "epoch-3", @now + 2)

      assert {:ok, claimed_again} =
               DurableLifecycleCore.claim_epoch(claimed, "node-a", "epoch-2", "epoch-3", @now + 2)

      assert claimed_again["authority_epoch"] == "epoch-3"
    end

    test "does not allow injected time to move updated_at before admission", %{record: record} do
      assert {:error, :time_before_admission} =
               DurableLifecycleCore.arm_deadline(record, @now + 50, @now - 1)

      assert {:error, :time_before_admission} =
               DurableLifecycleCore.claim_epoch(record, "node-a", "epoch-2", @now - 1)

      assert {:error, :time_before_admission} =
               DurableLifecycleCore.respond(record, :approved, %{}, "node-a", "epoch-1", @now - 1)
    end

    test "deadline arm is earliest and never extends a pending record", %{record: record} do
      assert {:ok, first} = DurableLifecycleCore.arm_deadline(record, @now + 500, @now + 1)
      assert {:ok, second} = DurableLifecycleCore.arm_deadline(first, @now + 900, @now + 2)
      assert second["owner_deadline_unix_ms"] == @now + 500

      assert {:ok, earlier} = DurableLifecycleCore.arm_deadline(second, @now + 100, @now + 3)
      assert earlier["owner_deadline_unix_ms"] == @now + 100
      refute DurableLifecycleCore.deadline_due?(earlier, @now + 99)
      assert DurableLifecycleCore.deadline_due?(earlier, @now + 100)
    end

    test "due helpers distinguish expiry and owner deadline", %{record: record} do
      assert DurableLifecycleCore.due_decision(record, @now) == :not_due

      {:ok, armed} = DurableLifecycleCore.arm_deadline(record, @now + 50, @now + 1)
      assert DurableLifecycleCore.due_decision(armed, @now + 50) == {:due, :abandoned}

      expired_interaction = %{
        interaction()
        | expires_at: DateTime.from_unix!(@now - 1, :millisecond)
      }

      {:ok, expiring} =
        DurableLifecycleCore.new(expired_interaction, "op-2", "node-a", "epoch-1", @now)

      assert DurableLifecycleCore.expiry_due?(expiring, @now)
      assert DurableLifecycleCore.due_decision(expiring, @now) == {:due, :expired}
    end
  end

  describe "terminal transitions" do
    test "response and timeout have one first-terminal winner" do
      {:ok, record} = DurableLifecycleCore.new(interaction(), "op-1", "node-a", "epoch-1", @now)

      {:ok, responded} =
        DurableLifecycleCore.respond(
          record,
          :approved,
          %{"channel" => "dashboard"},
          "node-a",
          "epoch-1",
          @now + 1
        )

      assert responded["status"] == "responded"

      assert {:error, {:terminal_conflict, "responded"}} =
               DurableLifecycleCore.abandon(
                 responded,
                 :await_timeout,
                 "node-a",
                 "epoch-1",
                 @now + 2
               )

      assert {:ok, same} =
               DurableLifecycleCore.transition(
                 responded,
                 responded["terminal"],
                 "node-a",
                 "epoch-1",
                 @now + 2
               )

      assert same == responded
    end

    test "stale epoch cannot terminalize after a same-node claim" do
      {:ok, record} = DurableLifecycleCore.new(interaction(), "op-1", "node-a", "epoch-1", @now)
      {:ok, claimed} = DurableLifecycleCore.claim_epoch(record, "node-a", "epoch-2", @now + 1)

      assert {:error, :stale_authority_epoch} =
               DurableLifecycleCore.respond(
                 claimed,
                 :approved,
                 %{},
                 "node-a",
                 "epoch-1",
                 @now + 2
               )
    end

    test "approval and text response shapes round-trip with terminal projection" do
      {:ok, approval_record} =
        DurableLifecycleCore.new(interaction(), "op-1", "node-a", "epoch-1", @now)

      {:ok, approved} =
        DurableLifecycleCore.respond(
          approval_record,
          :approved,
          %{},
          "node-a",
          "epoch-1",
          @now + 1
        )

      assert {:ok, %{status: :responded, decision: :approved, response: :approved}} =
               DurableLifecycleCore.project_terminal(approved)

      text_interaction = %{interaction() | kind: :clarification}

      {:ok, text_record} =
        DurableLifecycleCore.new(text_interaction, "op-2", "node-a", "epoch-1", @now)

      {:ok, answered} =
        DurableLifecycleCore.respond(
          text_record,
          {:text, "The answer is durable."},
          %{"source" => "operator"},
          "node-a",
          "epoch-1",
          @now + 1
        )

      assert {:ok, terminal} = DurableLifecycleCore.project_terminal(answered)
      assert terminal.status == :responded
      assert terminal.decision == nil
      assert terminal.response == {:text, "The answer is durable."}
      assert terminal.metadata == %{"source" => "operator"}
      assert is_binary(terminal.authority_node)
    end
  end

  defp interaction(overrides \\ %{}) do
    {:ok, interaction} =
      Interaction.new(
        Map.merge(
          %{
            request_id: "irq-1",
            kind: :approval,
            agent_id: "agent-1",
            user_id: "user-1",
            description: "Approve the operation",
            metadata: %{"resource" => "arbor://example"},
            resource_uri: "arbor://example",
            urgency: :normal,
            expires_at: DateTime.from_unix!(@now + 10_000, :millisecond),
            response_topic: "interaction:agent:agent-1",
            submitted_at: DateTime.from_unix!(@now, :millisecond)
          },
          overrides
        )
      )

    interaction
  end
end
