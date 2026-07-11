defmodule Arbor.Contracts.Consensus.CodeReviewRequestTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts
  alias Arbor.Contracts.Consensus.CodeReviewRequest

  @valid_attrs %{
    diff: "diff --git a/lib/a.ex b/lib/a.ex\n+def ok, do: :ok",
    files: ["lib/a.ex", "test/a_test.exs"],
    branch: "agent/review-loop",
    base_ref: "main",
    candidate_commit: String.duplicate("a", 40),
    intent: "Add a review loop",
    agent_id: "agent_123"
  }

  describe "new/1" do
    test "creates a request with valid attributes" do
      assert {:ok, %CodeReviewRequest{} = request} = CodeReviewRequest.new(@valid_attrs)
      assert request.diff == @valid_attrs.diff
      assert request.files == @valid_attrs.files
      assert request.branch == "agent/review-loop"
      assert request.base_ref == "main"
      assert request.candidate_commit == String.duplicate("a", 40)
      assert request.review_snapshot_id == nil
      assert request.intent == "Add a review loop"
      assert request.agent_id == "agent_123"
    end

    test "accepts string-keyed attrs from JSON boundaries" do
      attrs =
        Map.new(@valid_attrs, fn {key, value} ->
          {Atom.to_string(key), value}
        end)

      assert {:ok, request} = CodeReviewRequest.new(attrs)
      assert request.branch == "agent/review-loop"
      assert request.files == ["lib/a.ex", "test/a_test.exs"]
    end

    test "accepts keyword attrs and defaults optional values" do
      attrs = [
        diff: @valid_attrs.diff,
        files: @valid_attrs.files,
        branch: @valid_attrs.branch
      ]

      assert {:ok, request} = CodeReviewRequest.new(attrs)
      assert request.base_ref == nil
      assert request.candidate_commit == nil
      assert request.review_snapshot_id == nil
      assert request.intent == ""
      assert request.agent_id == nil
    end

    test "rejects missing required fields" do
      for field <- [:diff, :files, :branch] do
        attrs = Map.delete(@valid_attrs, field)
        assert {:error, {:missing_required_field, ^field}} = CodeReviewRequest.new(attrs)
      end
    end

    test "rejects empty diff and branch" do
      assert {:error, {:invalid_field, :diff, :empty}} =
               CodeReviewRequest.new(%{@valid_attrs | diff: "  "})

      assert {:error, {:invalid_field, :branch, :empty}} =
               CodeReviewRequest.new(%{@valid_attrs | branch: ""})
    end

    test "rejects empty or invalid file lists" do
      assert {:error, {:invalid_field, :files, :empty}} =
               CodeReviewRequest.new(%{@valid_attrs | files: []})

      assert {:error, {:invalid_field, :files, {:invalid_path, ""}}} =
               CodeReviewRequest.new(%{@valid_attrs | files: ["lib/a.ex", ""]})

      assert {:error, {:invalid_field, :files, {:expected_list, "lib/a.ex"}}} =
               CodeReviewRequest.new(%{@valid_attrs | files: "lib/a.ex"})
    end
  end

  describe "bind_review_snapshot/2" do
    test "binds only a matching candidate/base snapshot" do
      {:ok, request} = CodeReviewRequest.new(@valid_attrs)

      snapshot = %{
        review_snapshot_id: "review_snap_123",
        candidate_commit: @valid_attrs.candidate_commit,
        base_commit: @valid_attrs.base_ref
      }

      assert {:ok, bound} = CodeReviewRequest.bind_review_snapshot(request, snapshot)
      assert bound.review_snapshot_id == "review_snap_123"
      assert bound.candidate_commit == @valid_attrs.candidate_commit

      assert {:error, {:review_commit_mismatch, :candidate}} =
               CodeReviewRequest.bind_review_snapshot(request, %{
                 snapshot
                 | candidate_commit: String.duplicate("b", 40)
               })
    end
  end

  describe "to_context/1" do
    test "returns a JSON-clean Engine context map" do
      {:ok, request} = CodeReviewRequest.new(@valid_attrs)
      context = CodeReviewRequest.to_context(request)

      assert context["review.request"] == %{
               "diff" => @valid_attrs.diff,
               "files" => @valid_attrs.files,
               "branch" => "agent/review-loop",
               "base_ref" => "main",
               "candidate_commit" => String.duplicate("a", 40),
               "review_snapshot_id" => nil,
               "intent" => "Add a review loop",
               "agent_id" => "agent_123"
             }

      assert context["review.diff"] == @valid_attrs.diff
      assert context["review.files"] == @valid_attrs.files
      assert context["review.branch"] == "agent/review-loop"
      assert context["diff"] == @valid_attrs.diff
      assert context["files"] == @valid_attrs.files
      assert context["intent"] == "Add a review loop"

      assert context["council.question"] ==
               "Should branch agent/review-loop be accepted for human review?"

      assert {:ok, _json} = Jason.encode(context)
      refute inspect(context) =~ "%CodeReviewRequest"
    end

    test "includes diff, files, branch, and intent in the reviewer prompt" do
      {:ok, request} = CodeReviewRequest.new(@valid_attrs)
      prompt = CodeReviewRequest.to_context(request)["review.prompt"]

      assert prompt =~ "Branch: agent/review-loop"
      assert prompt =~ "Candidate commit: #{String.duplicate("a", 40)}"
      assert prompt =~ "Review snapshot id: unavailable"
      assert prompt =~ "Intent:\nAdd a review loop"
      assert prompt =~ "- lib/a.ex"
      assert prompt =~ "```diff"
      assert prompt =~ @valid_attrs.diff
    end
  end

  test "is listed by the contracts facade" do
    assert CodeReviewRequest in Contracts.list_contracts()
  end
end
