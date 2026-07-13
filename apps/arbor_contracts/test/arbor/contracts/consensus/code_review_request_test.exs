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
      assert request.review_cycle == 1
      assert request.prior_candidate_commit == nil
      assert request.delta_diff == ""
      assert request.delta_files == []
      assert request.finding_ledger == %{}
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
      assert request.review_cycle == 1
      assert request.prior_candidate_commit == nil
      assert request.delta_diff == ""
      assert request.delta_files == []
      assert request.finding_ledger == %{}
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

    test "accepts string-keyed review-cycle fields and rejects malformed values" do
      attrs = %{
        "diff" => @valid_attrs.diff,
        "files" => @valid_attrs.files,
        "branch" => @valid_attrs.branch,
        "review_cycle" => 2,
        "prior_candidate_commit" => String.duplicate("b", 40),
        "delta_diff" => "@@ -1 +1 @@",
        "delta_files" => ["lib/a.ex"],
        "finding_ledger" => %{"findings" => []}
      }

      assert {:ok, request} = CodeReviewRequest.new(attrs)
      assert request.review_cycle == 2
      assert request.prior_candidate_commit == String.duplicate("b", 40)
      assert request.delta_files == ["lib/a.ex"]

      assert {:error, {:invalid_field, :review_cycle, _}} =
               CodeReviewRequest.new(Map.put(@valid_attrs, :review_cycle, 0))

      assert {:error, {:invalid_field, :delta_files, {:invalid_path, "../secret.ex"}}} =
               CodeReviewRequest.new(Map.put(@valid_attrs, :delta_files, ["../secret.ex"]))

      assert {:error, {:invalid_field, :delta_files, :duplicate}} =
               CodeReviewRequest.new(
                 Map.put(@valid_attrs, :delta_files, ["lib/a.ex", "lib/a.ex"])
               )

      assert {:error, {:invalid_field, :delta_files, :too_many}} =
               CodeReviewRequest.new(
                 Map.put(@valid_attrs, :delta_files, List.duplicate("lib/a.ex", 129))
               )

      assert {:error, {:invalid_field, :delta_files, {:invalid_path, _}}} =
               CodeReviewRequest.new(
                 Map.put(@valid_attrs, :delta_files, [String.duplicate("a", 1_025)])
               )

      assert {:error, {:invalid_field, :delta_diff, :invalid_utf8}} =
               CodeReviewRequest.new(Map.put(@valid_attrs, :delta_diff, <<195>>))

      assert {:error, {:invalid_field, :prior_candidate_commit, :invalid_utf8}} =
               CodeReviewRequest.new(Map.put(@valid_attrs, :prior_candidate_commit, <<195>>))

      assert {:error, {:invalid_field, :finding_ledger, _}} =
               CodeReviewRequest.new(Map.put(@valid_attrs, :finding_ledger, %{bad: :atom}))

      assert {:error, {:invalid_field, :finding_ledger, :invalid_json_or_size}} =
               CodeReviewRequest.new(
                 Map.put(@valid_attrs, :finding_ledger, %{
                   "large" => String.duplicate("x", 131_073)
                 })
               )
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

      assert bound.review_cycle == request.review_cycle
      assert bound.prior_candidate_commit == request.prior_candidate_commit
      assert bound.delta_diff == request.delta_diff
      assert bound.delta_files == request.delta_files
      assert bound.finding_ledger == request.finding_ledger

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
               "agent_id" => "agent_123",
               "review_cycle" => 1,
               "prior_candidate_commit" => nil,
               "delta_diff" => "",
               "delta_files" => [],
               "finding_ledger" => %{}
             }

      assert context["review.diff"] == @valid_attrs.diff
      assert context["review.files"] == @valid_attrs.files
      assert context["review.branch"] == "agent/review-loop"
      assert context["diff"] == @valid_attrs.diff
      assert context["files"] == @valid_attrs.files
      assert context["intent"] == "Add a review loop"
      assert context["review.cycle"] == 1
      assert context["review.finding_ledger"] == %{}

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
      assert prompt =~ "Review cycle: 1"
      assert prompt =~ "Recheck: initial review"
      assert prompt =~ "Delta files:\n- none supplied"
      assert prompt =~ "Finding ledger (bounded JSON):"
      assert prompt =~ "Review charter:\nCycle 1: review the stated intent and full diff."
      assert prompt =~ "Intent:\nAdd a review loop"
      assert prompt =~ "- lib/a.ex"
      assert prompt =~ "```diff"
      assert prompt =~ @valid_attrs.diff
      assert Jason.decode!(extract_ledger_json(prompt)) == %{}
    end

    test "keeps multibyte prompt truncation valid and context JSON-clean" do
      attrs =
        @valid_attrs
        |> Map.put(:review_cycle, 2)
        |> Map.put(:delta_diff, String.duplicate("é", 20_000))
        |> Map.put(:delta_files, ["lib/a.ex"])
        |> Map.put(:finding_ledger, %{"z" => String.duplicate("é", 20_000), "a" => "first"})

      assert {:ok, request} = CodeReviewRequest.new(attrs)
      context = CodeReviewRequest.to_context(request)
      prompt = context["review.prompt"]

      assert {:ok, _encoded} = Jason.encode(context)
      assert String.valid?(prompt)
      assert prompt =~ "Cycle >1: verify owned open findings"
      assert prompt =~ "pre-existing or out-of-delta issues as nonblocking/out-of-scope"
      assert prompt =~ "[truncated]"

      ledger_json = extract_ledger_json(prompt)
      bounded = Jason.decode!(ledger_json)
      assert byte_size(ledger_json) <= 32_768
      assert bounded["truncated"] == true
      assert bounded["original_bytes"] > 32_768
      assert is_binary(bounded["preview"])
      assert String.valid?(bounded["preview"])
    end
  end

  test "is listed by the contracts facade" do
    assert CodeReviewRequest in Contracts.list_contracts()
  end

  defp extract_ledger_json(prompt) do
    [_, json] =
      Regex.run(~r/Finding ledger \(bounded JSON\):\n```json\n(.*?)\n```/s, prompt)

    json
  end
end
