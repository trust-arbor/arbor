Code.require_file(Path.expand("../../../support/forge_projection_vectors.ex", __DIR__))

defmodule Arbor.Contracts.Coding.ForgeProjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ForgeProjection
  alias Arbor.Contracts.Coding.ForgeProjectionVectors, as: Vectors

  @moduletag :fast

  @signature :crypto.strong_rand_bytes(64)

  test "build rejects hostile and incomplete field sets" do
    valid = Vectors.build_input()

    for {field, value} <- [
          {"task", nil},
          {"task", "task with spaces"},
          {"task", "task=bad"},
          {"task", String.duplicate("a", 40)},
          {"cycle", -1},
          {"cycle", 4097},
          {"cycle", "1"},
          {"verdict", "accept"},
          {"verdict", nil},
          {"disposition", "accept"},
          {"disposition", nil},
          {"vote_counts", %{"approve" => 1}},
          {"finding_counts", %{"major" => 1}},
          {"reviewed_commit", "not-hex"},
          {"candidate", String.duplicate("z", 39)},
          {"ledger_digest", "sha256:deadbeef"},
          {"evidence_ref", "../escape"},
          {"evidence_ref", ""},
          {"factory_id", ""},
          {"forge_host", "Bearer secret"},
          {"project", ""},
          {"poster_agent_id", "not-an-agent-id"},
          {"key_id", "not-an-agent-id"}
        ] do
      assert {:error, :projection_invalid} =
               ForgeProjection.build(Map.put(valid, field, value))
    end

    assert {:error, :projection_invalid} = ForgeProjection.build("not-a-map")
  end

  test "round-trips a rendered projection through parse/1" do
    assert {:ok, document} = Vectors.render_document()
    assert {:ok, parsed} = ForgeProjection.parse(document)
    assert parsed.task == "task-001"
    assert parsed.cycle == 1
    assert parsed.ledger_digest == Vectors.ledger_digest()
    assert parsed.candidate == Vectors.candidate_oid()
    assert parsed.key_id == Vectors.key_id()
  end

  test "rejects header mismatches against the JSON body" do
    assert {:ok, document} = Vectors.render_document()
    [header, rest] = String.split(document, "\n", parts: 2)

    tampered_header =
      String.replace(header, "cycle=1", "cycle=2")

    assert {:error, :projection_invalid} =
             ForgeProjection.parse(tampered_header <> "\n" <> rest)

    tampered_ledger =
      String.replace(header, Vectors.ledger_digest(), "sha256:" <> String.duplicate("0", 64))

    assert {:error, :projection_invalid} =
             ForgeProjection.parse(tampered_ledger <> "\n" <> rest)

    tampered_candidate =
      String.replace(header, Vectors.candidate_oid(), String.duplicate("d", 40))

    assert {:error, :projection_invalid} =
             ForgeProjection.parse(tampered_candidate <> "\n" <> rest)
  end

  test "rejects footer key mismatches and forged structs" do
    assert {:ok, document} = Vectors.render_document()

    mismatched_footer =
      String.replace(
        document,
        "key=#{Vectors.key_id()}",
        "key=agent_other1234567890abcdef"
      )

    assert {:error, :projection_invalid} = ForgeProjection.parse(mismatched_footer)

    assert {:ok, projection} = ForgeProjection.build(Vectors.build_input())
    forged = %{projection | verdict: "reject"}

    assert {:error, :projection_invalid} = ForgeProjection.render(forged, @signature)
    assert {:error, :projection_invalid} = ForgeProjection.canonical_v1(forged)
  end

  test "pins committed canonical, body sha256, and body hex vectors" do
    assert {:ok, sha} = Vectors.body_sha256()
    assert sha == Vectors.committed_body_sha256()

    assert {:ok, hex} = Vectors.body_hex()
    assert hex == Vectors.committed_body_hex()

    assert {:ok, canonical} = Vectors.canonical_hex()
    assert canonical == Vectors.committed_canonical_hex()
  end

  test "rejects malformed JSON bodies and closed-schema drift" do
    assert {:ok, document} = Vectors.render_document()
    [header, rest] = String.split(document, "\n", parts: 2)

    assert {:error, :projection_invalid} =
             ForgeProjection.parse(header <> "\n" <> "{not json")

    extra_field =
      rest
      |> String.replace("<!--", ~s(,"unexpected":"field"<!--))

    assert {:error, :projection_invalid} = ForgeProjection.parse(header <> "\n" <> extra_field)

    wrong_schema =
      String.replace(rest, "arbor-forge-projection-v1", "arbor-forge-projection-v2")

    assert {:error, :projection_invalid} =
             ForgeProjection.parse(header <> "\n" <> wrong_schema)
  end

  test "verdict_from_review_disposition maps review dispositions without accepting them as verdicts" do
    assert {:ok, "auto_proceed"} = ForgeProjection.verdict_from_review_disposition("accept")
    assert {:ok, "human_review"} = ForgeProjection.verdict_from_review_disposition("rework")
    assert {:ok, "reject"} = ForgeProjection.verdict_from_review_disposition("declined")

    assert {:error, :projection_invalid} =
             ForgeProjection.verdict_from_review_disposition("acceptance")

    assert {:error, :projection_invalid} =
             ForgeProjection.build(Map.put(Vectors.build_input(), "verdict", "accept"))
  end
end
