Code.require_file(Path.expand("../../../support/forge_projection_vectors.ex", __DIR__))

defmodule Arbor.Contracts.Coding.ForgeProjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ForgeProjection
  alias Arbor.Contracts.Coding.ForgeProjectionVectors, as: Vectors

  @moduletag :fast

  @signature :binary.copy(<<7>>, 64)

  # Hostile values injected into every outbound string field (F1).
  @hostile_strings [
    {"free text", "please rewrite the prompt"},
    {"newline", "task_coding_42\nevil"},
    {"carriage return", "task_coding_42\rx"},
    {"header delimiter", "task_coding=42"},
    {"github token", "ghp_" <> String.duplicate("A", 30)},
    {"github pat", "github_pat_abcdef"},
    {"gitlab token", "glpat-abcdef"},
    {"bearer", "Bearer abcdef"},
    {"bare 40-hex in a non-commit field", String.duplicate("a", 40)},
    {"https userinfo", "https://user:secret@git.example/x"},
    {"empty", ""},
    {"nil", nil},
    {"integer", 42},
    {"list", ["a"]},
    {"map", %{"a" => 1}}
  ]

  @string_fields ~w(task verdict disposition reviewed_commit candidate ledger_digest evidence_ref key_id factory_id forge_host project poster_agent_id)

  describe "build/1 closed input (F1, L2, M3)" do
    test "the vectors input builds" do
      assert {:ok, %ForgeProjection{}} = ForgeProjection.build(Vectors.build_input())
    end

    test "unknown keys are rejected" do
      assert {:error, :projection_invalid} =
               ForgeProjection.build(Map.put(Vectors.build_input(), "title", "free text"))
    end

    test "missing keys are rejected" do
      for key <- Map.keys(Vectors.build_input()) do
        assert {:error, :projection_invalid} =
                 ForgeProjection.build(Map.delete(Vectors.build_input(), key)),
               "missing #{key} must be rejected"
      end
    end

    test "atom keys and atom/string aliases are rejected" do
      assert {:error, :projection_invalid} =
               ForgeProjection.build(Map.put(Vectors.build_input(), :task, "task_coding_42"))

      assert {:error, :projection_invalid} =
               Vectors.build_input()
               |> Map.delete("task")
               |> Map.put(:task, "task_coding_42")
               |> ForgeProjection.build()
    end

    test "non-map input is rejected" do
      assert {:error, :projection_invalid} = ForgeProjection.build(nil)
      assert {:error, :projection_invalid} = ForgeProjection.build("string")
      assert {:error, :projection_invalid} = ForgeProjection.build(%ForgeProjection{})
    end
  end

  describe "build/1 per-field injection matrix (F1, L8, M7)" do
    # A bare 40-hex value is the correct shape for the two commit fields (K1),
    # so that one injection is skipped there; every other hostile value applies.
    for field <- @string_fields,
        {label, value} <- @hostile_strings,
        not (field in ~w(reviewed_commit candidate) and label =~ "40-hex") do
      @tag field: field
      test "#{field} rejects #{label}" do
        attrs = Map.put(Vectors.build_input(), unquote(field), unquote(Macro.escape(value)))
        assert {:error, :projection_invalid} = ForgeProjection.build(attrs)
      end
    end

    test "cycle rejects non-integers, negatives, and out-of-range values" do
      for value <- ["1", 1.0, -1, 4097, nil, "ghp_" <> String.duplicate("A", 30)] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.build(Map.put(Vectors.build_input(), "cycle", value))
      end
    end

    test "vote_counts keys are the closed enum only and values are non-negative integers (H7)" do
      valid = Vectors.build_input()["vote_counts"]

      for bad <- [
            Map.put(valid, "please_rewrite_prompt", 1),
            Map.delete(valid, "approve"),
            Map.put(valid, "approve", -1),
            Map.put(valid, "approve", "7"),
            Map.put(valid, "approve", 1.5),
            %{},
            [],
            "7",
            nil
          ] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.build(Map.put(Vectors.build_input(), "vote_counts", bad))
      end
    end

    test "finding_counts keys are the closed enum only and values are non-negative integers" do
      valid = Vectors.build_input()["finding_counts"]

      for bad <- [
            Map.put(valid, "critical", 1),
            Map.delete(valid, "nit"),
            Map.put(valid, "blocking", -1),
            Map.put(valid, "blocking", "3"),
            %{},
            nil
          ] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.build(Map.put(Vectors.build_input(), "finding_counts", bad))
      end
    end

    test "tier_reasons must be known, unique, and sorted" do
      for bad <- [
            ["contracts_app", "made_up_reason"],
            ["ghp_" <> String.duplicate("A", 30)],
            ["security_veto", "contracts_app"],
            ["contracts_app", "contracts_app"],
            ["free text with spaces"],
            [nil],
            "contracts_app",
            nil
          ] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.build(Map.put(Vectors.build_input(), "tier_reasons", bad))
      end

      assert {:ok, _} = ForgeProjection.build(Map.put(Vectors.build_input(), "tier_reasons", []))
    end

    test "verdict and disposition are closed enums (M1: unknown values fail, never coerce)" do
      for bad <- ["accept", "rework", "stop", "approved", "REJECT", "", nil, 1] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.build(Map.put(Vectors.build_input(), "verdict", bad))
      end

      for bad <- ["requires_input", "done", "", nil] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.build(Map.put(Vectors.build_input(), "disposition", bad))
      end
    end
  end

  describe "build/1 accepts real values (K1, I2)" do
    test "real 40-hex git object ids pass the commit fields" do
      for oid <- ["d42f57f55efb7b2fa956d5dcbdee4c6f4630b962", String.duplicate("0", 40)] do
        attrs = Map.merge(Vectors.build_input(), %{"reviewed_commit" => oid, "candidate" => oid})
        assert {:ok, _} = ForgeProjection.build(attrs)
      end

      assert {:error, :projection_invalid} =
               ForgeProjection.build(
                 Map.put(Vectors.build_input(), "candidate", String.duplicate("A", 40))
               )
    end

    test "real ledger digests pass" do
      attrs =
        Map.put(Vectors.build_input(), "ledger_digest", "sha256:" <> String.duplicate("0", 64))

      assert {:ok, _} = ForgeProjection.build(attrs)

      assert {:error, :projection_invalid} =
               ForgeProjection.build(
                 Map.put(Vectors.build_input(), "ledger_digest", String.duplicate("0", 64))
               )
    end

    test "executor task ids pass: task_coding_<n>, task_<32 hex>, and other task_ ids" do
      for task <- [
            "task_coding_123",
            "task_" <> String.duplicate("ab", 16),
            "task_9b2ad3be.rework-2"
          ] do
        assert {:ok, _} = ForgeProjection.build(Map.put(Vectors.build_input(), "task", task))
      end

      assert {:error, :projection_invalid} =
               ForgeProjection.build(Map.put(Vectors.build_input(), "task", "job_1"))
    end
  end

  describe "committed vectors (M6, M10, N8)" do
    test "body_without_footer bytes match the committed vector byte for byte" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      assert {:ok, body} = ForgeProjection.body_bytes(projection)
      assert body == Vectors.body()
      assert Base.encode16(:crypto.hash(:sha256, body), case: :lower) == Vectors.body_sha256()
    end

    test "canonical_v1 bytes match the committed vector byte for byte" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      assert {:ok, canonical} = ForgeProjection.canonical_v1(projection)
      assert canonical == Vectors.canonical()
    end

    test "canonical_v1 starts with the length-prefixed domain tag and ends with the body sha" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      {:ok, canonical} = ForgeProjection.canonical_v1(projection)
      tag = ForgeProjection.domain_tag()
      size = byte_size(tag)
      assert <<^size::32-big-unsigned-integer, ^tag::binary-size(size), _::binary>> = canonical
      sha = Vectors.body_sha256()
      assert String.ends_with?(canonical, <<64::32-big-unsigned-integer>> <> sha)
    end

    test "canonical JSON is key-sorted regardless of input map order (M9)" do
      reversed =
        Vectors.build_input()
        |> Enum.sort_by(fn {key, _} -> key end, :desc)
        |> Map.new()
        |> Map.update!("vote_counts", &(&1 |> Enum.sort(:desc) |> Map.new()))

      {:ok, a} = ForgeProjection.build(Vectors.build_input())
      {:ok, b} = ForgeProjection.build(reversed)
      assert ForgeProjection.body_bytes(a) == ForgeProjection.body_bytes(b)
      assert ForgeProjection.body_bytes(a) == {:ok, Vectors.body()}
    end
  end

  describe "render/2 and parse (C6, I3, N5)" do
    test "render/parse_document round-trips the signed bytes exactly" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      {:ok, document} = ForgeProjection.render(projection, @signature)

      assert {:ok, parsed} = ForgeProjection.parse_document(document)
      assert parsed.body_without_footer == Vectors.body()
      assert parsed.signature == @signature
      assert parsed.key_id == Vectors.key_id()
      assert parsed.fields["task"] == "task_coding_42"
      assert parsed.fields["cycle"] == 1

      assert document ==
               ForgeProjection.body_without_footer(
                 "arbor-projection: v1 task=task_coding_42 cycle=1 ledger=#{Vectors.ledger_digest()} candidate=#{Vectors.commit()}",
                 Enum.at(String.split(document, "\n"), 1)
               ) <>
                 "\n<!-- arbor-sig v1 key=#{Vectors.key_id()} sig=#{Base.encode64(@signature)} -->"
    end

    test "parse/2 with the signing context reproduces the signed canonical message" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      {:ok, document} = ForgeProjection.render(projection, @signature)

      assert {:ok, parsed} = ForgeProjection.parse(document, Vectors.signing_context())
      assert ForgeProjection.canonical_v1(parsed) == {:ok, Vectors.canonical()}
    end

    test "parse/2 binds the signing context: a different host, project, factory or poster changes the message" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      {:ok, document} = ForgeProjection.render(projection, @signature)

      for {key, value} <- [
            {"forge_host", "evil.example"},
            {"project", "acme/other"},
            {"factory_id", "other-factory"},
            {"poster_agent_id", "agent_" <> String.duplicate("0e", 32)}
          ] do
        context = Map.put(Vectors.signing_context(), key, value)
        assert {:ok, other} = ForgeProjection.parse(document, context)
        assert ForgeProjection.canonical_v1(other) != {:ok, Vectors.canonical()}
      end
    end

    test "parse/2 rejects an incomplete, extended, or hostile signing context" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      {:ok, document} = ForgeProjection.render(projection, @signature)

      assert {:error, :projection_invalid} =
               ForgeProjection.parse(document, Map.delete(Vectors.signing_context(), "project"))

      assert {:error, :projection_invalid} =
               ForgeProjection.parse(document, Map.put(Vectors.signing_context(), "extra", "x"))

      for {label, value} <- @hostile_strings, is_binary(value) do
        assert {:error, :projection_invalid} =
                 ForgeProjection.parse(
                   document,
                   Map.put(Vectors.signing_context(), "forge_host", value)
                 ),
               "forge_host must reject #{label}"
      end
    end

    test "render rejects a signature that is not 64 bytes" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())

      for sig <- [<<>>, :binary.copy(<<7>>, 63), :binary.copy(<<7>>, 65), "not bytes", nil] do
        assert {:error, :projection_invalid} = ForgeProjection.render(projection, sig)
      end
    end
  end

  describe "parse_document/1 fail-closed (F6, L1, L3, N6, N7)" do
    setup do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      {:ok, document} = ForgeProjection.render(projection, @signature)
      [header, json, footer] = String.split(document, "\n")
      %{document: document, header: header, json: json, footer: footer}
    end

    test "header/body mismatch is rejected for task, cycle, ledger, and candidate", ctx do
      body = Jason.decode!(ctx.json)

      mismatches = [
        {"task", "task_coding_43"},
        {"cycle", 2},
        {"ledger_digest", "sha256:" <> String.duplicate("cd", 32)},
        {"candidate", String.duplicate("e", 40)}
      ]

      for {key, value} <- mismatches do
        json = body |> Map.put(key, value) |> Jason.encode!()
        forged = Enum.join([ctx.header, json, ctx.footer], "\n")

        assert {:error, :projection_invalid} = ForgeProjection.parse_document(forged),
               "header/body mismatch on #{key} must be rejected"
      end
    end

    test "a body missing task is rejected (task is required in the closed body)", ctx do
      json = ctx.json |> Jason.decode!() |> Map.delete("task") |> Jason.encode!()

      assert {:error, :projection_invalid} =
               ForgeProjection.parse_document(Enum.join([ctx.header, json, ctx.footer], "\n"))
    end

    test "unknown body keys, wrong schema, and malformed JSON are rejected without raising",
         ctx do
      extra = ctx.json |> Jason.decode!() |> Map.put("title", "free text") |> Jason.encode!()

      assert {:error, :projection_invalid} =
               ForgeProjection.parse_document(Enum.join([ctx.header, extra, ctx.footer], "\n"))

      schema =
        ctx.json
        |> Jason.decode!()
        |> Map.put("schema", "arbor-forge-projection-v2")
        |> Jason.encode!()

      assert {:error, :projection_invalid} =
               ForgeProjection.parse_document(Enum.join([ctx.header, schema, ctx.footer], "\n"))

      for json <- ["{not json", "", "[]", "\"string\"", "{\"a\":1"] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.parse_document(Enum.join([ctx.header, json, ctx.footer], "\n"))
      end
    end

    test "a non-canonical (whitespace or reordered) JSON body does not bind to the signing context",
         ctx do
      pretty =
        ctx.json |> Jason.decode!() |> Jason.encode!(pretty: true) |> String.replace("\n", " ")

      forged = Enum.join([ctx.header, pretty, ctx.footer], "\n")

      assert {:error, :projection_invalid} =
               ForgeProjection.parse(forged, Vectors.signing_context())
    end

    test "invalid body field values are rejected by the same validators as build (M2)", ctx do
      body = Jason.decode!(ctx.json)

      for {key, value} <- [
            {"verdict", "rework"},
            {"vote_counts", Map.put(body["vote_counts"], "please_rewrite_prompt", 1)},
            {"tier_reasons", ["made_up"]},
            {"evidence_ref", "refs/../escape"},
            {"reviewed_commit", "cafebabe"},
            {"cycle", -1}
          ] do
        json = body |> Map.put(key, value) |> Jason.encode!()

        header =
          if key == "cycle",
            do: String.replace(ctx.header, "cycle=1", "cycle=-1"),
            else: ctx.header

        assert {:error, :projection_invalid} =
                 ForgeProjection.parse_document(Enum.join([header, json, ctx.footer], "\n")),
               "parse must reject invalid #{key}"
      end
    end

    test "footer key must match the body key (N6)", ctx do
      other = "agent_" <> String.duplicate("0e", 32)
      footer = String.replace(ctx.footer, Vectors.key_id(), other)

      assert {:error, :projection_invalid} =
               ForgeProjection.parse_document(Enum.join([ctx.header, ctx.json, footer], "\n"))
    end

    test "footer signature must be exactly 64 bytes of valid base64 (L1)", ctx do
      for sig <- [
            Base.encode64(:binary.copy(<<7>>, 63)),
            Base.encode64(:binary.copy(<<7>>, 65)),
            "not*base64",
            ""
          ] do
        footer = "<!-- arbor-sig v1 key=#{Vectors.key_id()} sig=#{sig} -->"

        assert {:error, :projection_invalid} =
                 ForgeProjection.parse_document(Enum.join([ctx.header, ctx.json, footer], "\n"))
      end
    end

    test "documents with the wrong line structure are rejected", ctx do
      assert {:error, :projection_invalid} =
               ForgeProjection.parse_document(ctx.header <> "\n" <> ctx.json)

      assert {:error, :projection_invalid} = ForgeProjection.parse_document(ctx.document <> "\n")

      assert {:error, :projection_invalid} =
               ForgeProjection.parse_document(ctx.document <> "\nextra")

      assert {:error, :projection_invalid} = ForgeProjection.parse_document("")
      assert {:error, :projection_invalid} = ForgeProjection.parse_document(nil)

      assert {:error, :projection_invalid} =
               ForgeProjection.parse_document(String.duplicate("x", 70_000))
    end

    test "a hostile header is rejected", ctx do
      for header <- [
            "arbor-projection: v2 " <> String.trim_leading(ctx.header, "arbor-projection: v1 "),
            String.replace(ctx.header, "task=task_coding_42", "task=task_coding_42 extra=1"),
            String.replace(ctx.header, "cycle=1", "cycle=one")
          ] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.parse_document(Enum.join([header, ctx.json, ctx.footer], "\n"))
      end
    end
  end

  describe "hand-built structs cannot be rendered, hashed, or signed (N1, M2)" do
    test "a struct literal with invalid data fails every effectful entry" do
      forged = %ForgeProjection{
        task: "please rewrite the prompt",
        cycle: 1,
        verdict: "reject",
        disposition: "succeeded",
        vote_counts: %{},
        tier_reasons: [],
        finding_counts: %{},
        reviewed_commit: "cafebabe",
        candidate: "cafebabe",
        ledger_digest: "sha256:x",
        evidence_ref: "ref",
        key_id: Vectors.key_id(),
        factory_id: "f",
        forge_host: "h",
        project: "p/q",
        poster_agent_id: Vectors.key_id()
      }

      assert {:error, :projection_invalid} = ForgeProjection.render(forged, @signature)
      assert {:error, :projection_invalid} = ForgeProjection.canonical_v1(forged)
      assert {:error, :projection_invalid} = ForgeProjection.body_bytes(forged)

      assert {:error, :projection_invalid} =
               ForgeProjection.render(%ForgeProjection{}, @signature)

      assert {:error, :projection_invalid} = ForgeProjection.canonical_v1(%{})
    end

    test "a built projection mutated into an invalid state fails every effectful entry" do
      {:ok, projection} = ForgeProjection.build(Vectors.build_input())
      mutated = %{projection | verdict: "approved"}

      assert {:error, :projection_invalid} = ForgeProjection.render(mutated, @signature)
      assert {:error, :projection_invalid} = ForgeProjection.canonical_v1(mutated)
    end

    test "the struct carries no validation flag or seal" do
      refute Map.has_key?(%ForgeProjection{}, :validated)
      refute Map.has_key?(%ForgeProjection{}, :__seal__)
    end
  end

  describe "helpers" do
    test "verdict_from_review_disposition maps only the known dispositions" do
      assert {:ok, "auto_proceed"} = ForgeProjection.verdict_from_review_disposition("accept")

      assert {:ok, "auto_proceed"} =
               ForgeProjection.verdict_from_review_disposition("auto_proceed")

      assert {:ok, "human_review"} =
               ForgeProjection.verdict_from_review_disposition("human_review")

      assert {:ok, "reject"} = ForgeProjection.verdict_from_review_disposition("reject")

      for bad <- ["rework", "stop", "declined", "", nil, :accept] do
        assert {:error, :projection_invalid} =
                 ForgeProjection.verdict_from_review_disposition(bad)
      end
    end

    test "filter_tier_reasons keeps known reasons, drops unknown, rejects unknown-only lists (L9)" do
      assert {:ok, ["contracts_app", "security_veto"]} =
               ForgeProjection.filter_tier_reasons([
                 "security_veto",
                 "made_up",
                 "contracts_app",
                 "security_veto"
               ])

      assert {:ok, []} = ForgeProjection.filter_tier_reasons([])
      assert {:error, :projection_invalid} = ForgeProjection.filter_tier_reasons(["made_up"])
      assert {:error, :projection_invalid} = ForgeProjection.filter_tier_reasons("contracts_app")
    end

    test "public enum accessors are closed and stable" do
      assert ForgeProjection.vote_keys() == ~w(approve reject abstain failed reported)
      assert ForgeProjection.finding_keys() == ~w(blocking major minor nit)
      assert ForgeProjection.verdicts() == ~w(auto_proceed human_review reject)
      assert ForgeProjection.dispositions() == ~w(succeeded failed cancelled)
      assert "human_review_required" in ForgeProjection.tier_reasons()
      assert ForgeProjection.body_keys() == Enum.sort(ForgeProjection.body_keys())
      assert ForgeProjection.schema() == "arbor-forge-projection-v1"
      assert ForgeProjection.domain_tag() == "arbor-forge-projection-v1"
    end
  end
end
