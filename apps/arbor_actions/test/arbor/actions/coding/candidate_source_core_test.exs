defmodule Arbor.Actions.Coding.CandidateSourceCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Coding.CandidateSourceCore, as: Core

  @moduletag :fast

  @base "0123456789abcdef0123456789abcdef01234567"
  @candidate "fedcba9876543210fedcba9876543210fedcba98"

  describe "admit/1" do
    test "omitted keys default to workspace_branch" do
      assert Core.admit(%{}) == {:ok, :workspace_branch}
      assert Core.admit([]) == {:ok, :workspace_branch}
    end

    test "accepts atom and string aliases for both closed sources" do
      assert Core.admit(%{candidate_source: :workspace_branch}) == {:ok, :workspace_branch}
      assert Core.admit(%{candidate_source: :immutable_object}) == {:ok, :immutable_object}

      assert Core.admit(%{"candidate_source" => "workspace_branch"}) ==
               {:ok, :workspace_branch}

      assert Core.admit(%{"candidate_source" => "immutable_object"}) ==
               {:ok, :immutable_object}

      assert Core.admit(candidate_source: :workspace_branch) == {:ok, :workspace_branch}
      assert Core.admit(candidate_source: :immutable_object) == {:ok, :immutable_object}

      assert Core.admit([{"candidate_source", "workspace_branch"}]) ==
               {:ok, :workspace_branch}

      assert Core.admit([{"candidate_source", "immutable_object"}]) ==
               {:ok, :immutable_object}

      assert Core.admit([{"candidate_source", :immutable_object}]) ==
               {:ok, :immutable_object}

      assert Core.admit(%{"candidate_source" => :workspace_branch}) ==
               {:ok, :workspace_branch}
    end

    test "rejects mixed atom and string keys as ambiguous even when values match" do
      mixed_map =
        %{candidate_source: :immutable_object}
        |> Map.put("candidate_source", "immutable_object")

      mixed_keyword = [
        {:candidate_source, :workspace_branch},
        {"candidate_source", "workspace_branch"}
      ]

      assert Core.admit(mixed_map) == {:error, :ambiguous_candidate_source}
      assert Core.admit(mixed_keyword) == {:error, :ambiguous_candidate_source}
    end

    test "rejects unknown and malformed values and non-opts terms" do
      assert Core.admit(%{candidate_source: "immutable"}) ==
               {:error, :invalid_candidate_source}

      assert Core.admit(%{candidate_source: :immutable}) ==
               {:error, :invalid_candidate_source}

      assert Core.admit(%{candidate_source: ""}) == {:error, :invalid_candidate_source}
      assert Core.admit(%{candidate_source: nil}) == {:error, :invalid_candidate_source}
      assert Core.admit(%{candidate_source: 1}) == {:error, :invalid_candidate_source}
      assert Core.admit(%{candidate_source: []}) == {:error, :invalid_candidate_source}
      assert Core.admit(nil) == {:error, :invalid_candidate_source}
      assert Core.admit("workspace_branch") == {:error, :invalid_candidate_source}
      assert Core.admit(1) == {:error, :invalid_candidate_source}
    end
  end

  describe "review head and evidence" do
    test "workspace_branch reviews the candidate; immutable_object reviews the base" do
      assert Core.review_expected_head(:workspace_branch, @base, @candidate) == @candidate
      assert Core.review_expected_head(:immutable_object, @base, @candidate) == @base
    end

    test "only immutable_object requires pinned evidence" do
      assert Core.review_requires_pinned_evidence?(:immutable_object) == true
      assert Core.review_requires_pinned_evidence?(:workspace_branch) == false
    end
  end

  describe "publication and adoption modes" do
    test "workspace_branch archives from the branch; immutable_object verifies existing" do
      assert Core.publish_evidence_mode(:workspace_branch) == :archive_from_branch
      assert Core.publish_evidence_mode(:immutable_object) == :verify_existing
      assert Core.adoption_evidence_mode(:workspace_branch) == :archive_from_branch
      assert Core.adoption_evidence_mode(:immutable_object) == :verify_existing
    end

    test "adoption evidence mode matches publication evidence mode" do
      assert Core.adoption_evidence_mode(:workspace_branch) ==
               Core.publish_evidence_mode(:workspace_branch)

      assert Core.adoption_evidence_mode(:immutable_object) ==
               Core.publish_evidence_mode(:immutable_object)
    end
  end

  describe "branch retirement" do
    test "created sources compare-delete at the source-specific expected oid" do
      assert Core.branch_retirement_expected_oid(
               :immutable_object,
               :created,
               @base,
               @candidate
             ) == {:compare_delete, @base}

      assert Core.branch_retirement_expected_oid(
               :immutable_object,
               "created",
               @base,
               @candidate
             ) == {:compare_delete, @base}

      assert Core.branch_retirement_expected_oid(
               :workspace_branch,
               :created,
               @base,
               @candidate
             ) == {:compare_delete, @candidate}

      assert Core.branch_retirement_expected_oid(
               :workspace_branch,
               "created",
               @base,
               @candidate
             ) == {:compare_delete, @candidate}
    end

    test "reused, unknown, and garbage provenance preserve the branch" do
      for provenance <- [:reused, "reused", :unknown, "unknown", "bogus", nil] do
        assert Core.branch_retirement_expected_oid(
                 :workspace_branch,
                 provenance,
                 @base,
                 @candidate
               ) == :preserve

        assert Core.branch_retirement_expected_oid(
                 :immutable_object,
                 provenance,
                 @base,
                 @candidate
               ) == :preserve
      end
    end
  end

  describe "impossible-base detection" do
    test "true only for workspace_branch still at a distinct base oid" do
      assert Core.workspace_branch_still_at_impossible_base?(
               :workspace_branch,
               @base,
               @base,
               @candidate
             )

      refute Core.workspace_branch_still_at_impossible_base?(
               :workspace_branch,
               @candidate,
               @base,
               @candidate
             )

      refute Core.workspace_branch_still_at_impossible_base?(
               :workspace_branch,
               @base,
               @base,
               @base
             )

      refute Core.workspace_branch_still_at_impossible_base?(
               :immutable_object,
               @base,
               @base,
               @candidate
             )

      refute Core.workspace_branch_still_at_impossible_base?(
               :workspace_branch,
               nil,
               @base,
               @candidate
             )
    end

    test "normalizes oid case and surrounding whitespace" do
      observed = " " <> String.upcase(@base) <> " "

      assert Core.workspace_branch_still_at_impossible_base?(
               :workspace_branch,
               observed,
               @base,
               @candidate
             )
    end
  end
end
