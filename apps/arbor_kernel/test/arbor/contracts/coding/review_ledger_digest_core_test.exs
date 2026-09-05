defmodule Arbor.Contracts.Coding.ReviewLedgerDigestCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ReviewLedgerDigestCore

  @moduletag :fast

  @oid40_a String.duplicate("a", 40)

  @committed_digest "sha256:c1158ffa3482f3ce65b7c0737d5cfefed360e078142888a36870fc5c5bc9342b"

  @terminal_vector %{
    "commit" => @oid40_a,
    "review" => %{
      "review_cycle" => 1,
      "review_disposition" => "accept",
      "blocking_ids" => ["finding-1"],
      "reviewer_outcomes" => %{
        "correctness" => %{
          "perspective" => "correctness",
          "status" => "completed",
          "provider" => "codex",
          "model" => "gpt-5"
        }
      },
      "consolidated_findings" => [
        %{
          "id" => "finding-1",
          "severity" => "major",
          "state" => "open",
          "owner" => "correctness"
        }
      ]
    }
  }

  test "pins the committed terminal digest vector" do
    assert {:ok, @committed_digest} = ReviewLedgerDigestCore.digest(@terminal_vector)
  end

  test "canonical JSON is invariant to review subset key order" do
    reordered =
      Map.put(@terminal_vector, "review", %{
        "consolidated_findings" => [
          %{
            "owner" => "correctness",
            "state" => "open",
            "severity" => "major",
            "id" => "finding-1"
          }
        ],
        "reviewer_outcomes" => %{
          "correctness" => %{
            "model" => "gpt-5",
            "provider" => "codex",
            "status" => "completed",
            "perspective" => "correctness"
          }
        },
        "blocking_ids" => ["finding-1"],
        "review_disposition" => "accept",
        "review_cycle" => 1
      })

    assert ReviewLedgerDigestCore.digest(@terminal_vector) ==
             ReviewLedgerDigestCore.digest(reordered)
  end

  test "rejects missing review fields and malformed terminal shapes" do
    assert {:error, :projection_invalid} =
             ReviewLedgerDigestCore.digest(Map.delete(@terminal_vector, "commit"))

    assert {:error, :projection_invalid} =
             ReviewLedgerDigestCore.digest(
               put_in(@terminal_vector, ["review", "review_cycle"], "1")
             )

    assert {:error, :projection_invalid} =
             ReviewLedgerDigestCore.digest(
               put_in(@terminal_vector, ["review", "review_disposition"], " ")
             )

    assert {:error, :projection_invalid} =
             ReviewLedgerDigestCore.digest(
               put_in(@terminal_vector, ["review", "blocking_ids"], "finding-1")
             )

    assert {:error, :projection_invalid} =
             ReviewLedgerDigestCore.digest(
               put_in(@terminal_vector, ["review", "reviewer_outcomes"], [])
             )

    assert {:error, :projection_invalid} =
             ReviewLedgerDigestCore.digest(
               put_in(@terminal_vector, ["review", "consolidated_findings"], %{})
             )
  end

  test "rejects commit_hash-only terminals and never substitutes commit" do
    assert {:error, :projection_invalid} =
             ReviewLedgerDigestCore.digest(%{
               "commit_hash" => @oid40_a,
               "review" => @terminal_vector["review"]
             })
  end

  test "title and evidence fields are immaterial to the digest" do
    noisy =
      @terminal_vector
      |> put_in(["review", "title"], "Council summary")
      |> put_in(["review", "required_action"], "fix blocking findings")
      |> put_in(
        ["review", "consolidated_findings", Access.at(0), "title"],
        "Missing nil guard"
      )
      |> put_in(
        ["review", "consolidated_findings", Access.at(0), "evidence"],
        "apps/example/lib/example.ex:42"
      )
      |> Map.put("title", "terminal envelope title")

    assert ReviewLedgerDigestCore.digest(@terminal_vector) ==
             ReviewLedgerDigestCore.digest(noisy)
  end

  describe "blank reviewer and finding fields" do
    @reviewer_fields ~w(perspective status provider model)
    @finding_fields ~w(id severity owner)

    for field <- @reviewer_fields do
      test "rejects blank reviewer_outcomes.#{field}" do
        terminal =
          put_in(
            @terminal_vector,
            ["review", "reviewer_outcomes", "correctness", unquote(field)],
            ""
          )

        assert {:error, :projection_invalid} = ReviewLedgerDigestCore.digest(terminal)

        terminal =
          put_in(
            @terminal_vector,
            ["review", "reviewer_outcomes", "correctness", unquote(field)],
            " "
          )

        assert {:error, :projection_invalid} = ReviewLedgerDigestCore.digest(terminal)
      end
    end

    for field <- @finding_fields do
      test "rejects blank consolidated_findings.#{field}" do
        terminal =
          put_in(
            @terminal_vector,
            ["review", "consolidated_findings", Access.at(0), unquote(field)],
            ""
          )

        assert {:error, :projection_invalid} = ReviewLedgerDigestCore.digest(terminal)

        terminal =
          put_in(
            @terminal_vector,
            ["review", "consolidated_findings", Access.at(0), unquote(field)],
            " "
          )

        assert {:error, :projection_invalid} = ReviewLedgerDigestCore.digest(terminal)
      end
    end

    test "rejects blank issue_key findings" do
      finding = %{
        "issue_key" => "",
        "severity" => "major",
        "owner" => "correctness"
      }

      terminal =
        put_in(@terminal_vector, ["review", "consolidated_findings"], [finding])

      assert {:error, :projection_invalid} = ReviewLedgerDigestCore.digest(terminal)
    end

    test "rejects perspective keys that disagree with reviewer_outcomes map keys" do
      terminal =
        put_in(
          @terminal_vector,
          ["review", "reviewer_outcomes", "correctness", "perspective"],
          "security"
        )

      assert {:error, :projection_invalid} = ReviewLedgerDigestCore.digest(terminal)
    end
  end
end
