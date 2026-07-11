defmodule Arbor.Actions.Coding.ReviewedCommitTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Actions.Coding.ReviewedCommit
  alias Arbor.Contracts.Comms.ApprovalAnswer

  test "pipeline-internal tool name and tags" do
    assert ReviewedCommit.name() == "coding_reviewed_commit"
    assert "pipeline_internal" in Enum.map(ReviewedCommit.tags(), &to_string/1)
  end

  test "canonical URI is coding reviewed_commit" do
    assert Arbor.Actions.canonical_uri_for(ReviewedCommit, %{}) ==
             "arbor://action/coding/reviewed_commit"
  end

  test "ApprovalAnswer bounds notes linearly and rejects oversized ids" do
    long = String.duplicate("a", 2_000)
    assert {:ok, note} = ApprovalAnswer.validate_note(long)
    assert byte_size(note) == ApprovalAnswer.max_note_bytes()

    huge_id = String.duplicate("x", ApprovalAnswer.max_request_id_bytes() + 1)
    assert {:error, :request_id_too_large} = ApprovalAnswer.validate_request_id(huge_id)
    assert {:error, :invalid_request_id_utf8} = ApprovalAnswer.validate_request_id(<<0xFF, 0xFE>>)
  end

  test "normalize treats consensus requested_decision rework distinctly from deny" do
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
end
