defmodule Arbor.Contracts.Comms.ApprovalAnswerTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Comms.ApprovalAnswer

  describe "validate_request_id/1" do
    test "accepts closed ASCII opaque ids without mutation" do
      id = "irq_deadbeefcafebabe"
      assert {:ok, ^id} = ApprovalAnswer.validate_request_id(id)

      prop = "proposal-01:ab_cd.ef"
      assert {:ok, ^prop} = ApprovalAnswer.validate_request_id(prop)
    end

    test "rejects oversized ids without truncating" do
      huge = String.duplicate("a", ApprovalAnswer.max_request_id_bytes() + 1)
      assert {:error, :request_id_too_large} = ApprovalAnswer.validate_request_id(huge)
    end

    test "rejects empty, non-ASCII grammar, controls, and whitespace (no trim)" do
      assert {:error, :empty_request_id} = ApprovalAnswer.validate_request_id("")
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id(" irq_abc")
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id("irq_abc ")
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id("irq abc")
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id("irq\n_abc")
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id("irq\x00abc")
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id("irq_α")
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id(<<0xFF, 0xFE>>)
      assert {:error, :invalid_request_id} = ApprovalAnswer.validate_request_id(123)
    end
  end

  describe "validate_note/2" do
    test "rejects oversized notes by default (MCP fail-closed)" do
      long = String.duplicate("a", ApprovalAnswer.max_note_bytes() + 1)
      assert {:error, :note_too_large} = ApprovalAnswer.validate_note(long)
    end

    test "byte_size is checked before UTF-8 work for huge binaries" do
      # Invalid UTF-8 that is also oversized must report size first.
      huge_invalid = :binary.copy(<<0xFF>>, ApprovalAnswer.max_note_bytes() + 10)
      assert {:error, :note_too_large} = ApprovalAnswer.validate_note(huge_invalid)
    end

    test "truncates only when truncate: true" do
      long = String.duplicate("a", ApprovalAnswer.max_note_bytes() + 50)
      assert {:ok, note} = ApprovalAnswer.validate_note(long, truncate: true)
      assert byte_size(note) == ApprovalAnswer.max_note_bytes()
    end

    test "rejects control characters unless drop_invalid" do
      assert {:error, :invalid_note_control} = ApprovalAnswer.validate_note("bad\x00note")
      assert {:ok, ""} = ApprovalAnswer.validate_note("bad\x00note", drop_invalid: true)
      # tab/lf/cr allowed
      assert {:ok, "ok\tline\n"} = ApprovalAnswer.validate_note("ok\tline\n")
    end

    test "rejects invalid UTF-8 unless drop_invalid" do
      assert {:error, :invalid_note_utf8} = ApprovalAnswer.validate_note(<<0xFF, 0xFE>>)
      assert {:ok, ""} = ApprovalAnswer.validate_note(<<0xFF, 0xFE>>, drop_invalid: true)
    end
  end

  describe "normalize/2" do
    test "treats consensus requested_decision rework distinctly from deny" do
      assert {:ok, :rework, "fix api"} =
               ApprovalAnswer.normalize_consensus_decision(%{
                 decision: :rejected,
                 requested_decision: :rework,
                 note: "fix api"
               })

      assert {:ok, :deny, "no"} =
               ApprovalAnswer.normalize_consensus_decision(%{
                 decision: :rejected,
                 requested_decision: :deny,
                 note: "no"
               })
    end

    test "bounds projected notes linearly" do
      long = String.duplicate("x", ApprovalAnswer.max_note_bytes() + 100)

      assert {:ok, :deny, note} =
               ApprovalAnswer.normalize(:rejected, %{decision: :deny, note: long})

      assert byte_size(note) == ApprovalAnswer.max_note_bytes()
    end
  end
end
