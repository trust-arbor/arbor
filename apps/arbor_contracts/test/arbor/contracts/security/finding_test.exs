defmodule Arbor.Contracts.Security.FindingTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.Finding

  describe "new/1" do
    test "builds a finding with required fields and defaults" do
      f =
        Finding.new(
          category: :fail_open_authz,
          title: "authorize/4 rescues to :ok"
        )

      assert f.category == :fail_open_authz
      assert f.status == :open
      assert f.schema_version == "1.0"
      assert %DateTime{} = f.detected_at
      assert String.starts_with?(f.id, "sec-finding_")
    end

    test "raises without category or title" do
      assert_raise KeyError, fn -> Finding.new(title: "x") end
      assert_raise KeyError, fn -> Finding.new(category: :other) end
    end
  end

  describe "dedup_key/1 stability" do
    test "same category+location+invariant produce the same id" do
      opts = [
        category: :fail_open_authz,
        title: "t",
        invariant_violated: "authorize must fail closed",
        location: %{
          file: "apps/arbor_security/lib/arbor/security/auth_decision.ex",
          function: "trust_profile_gates?"
        }
      ]

      assert Finding.new(opts).id == Finding.new(opts).id
    end

    test "id is stable across absolute vs apps-relative paths" do
      a =
        Finding.new(
          category: :fail_open_authz,
          title: "t",
          location: %{file: "/Users/x/code/arbor/apps/arbor_security/lib/a.ex"}
        )

      b =
        Finding.new(
          category: :fail_open_authz,
          title: "t",
          location: %{file: "apps/arbor_security/lib/a.ex"}
        )

      assert a.id == b.id
    end

    test "different categories produce different ids" do
      loc = %{file: "apps/x/lib/a.ex"}
      a = Finding.new(category: :fail_open_authz, title: "t", location: loc)
      b = Finding.new(category: :crypto_weakness, title: "t", location: loc)
      refute a.id == b.id
    end
  end

  describe "status transitions" do
    test "update_status accepts valid statuses" do
      f = Finding.new(category: :other, title: "t")
      assert {:ok, %Finding{status: :triaged}} = Finding.update_status(f, :triaged)
    end

    test "update_status fails closed on garbage" do
      f = Finding.new(category: :other, title: "t")
      assert {:error, :invalid_status} = Finding.update_status(f, :totally_made_up)
    end

    test "mark_false_positive records the verdict and note" do
      f = Finding.new(category: :other, title: "t")
      f = Finding.mark_false_positive(f, "matched a test fixture")
      assert f.status == :false_positive
      assert f.human_feedback.verdict == :false_positive
      assert f.human_feedback.note == "matched a test fixture"
    end

    test "terminal?/1 reflects terminal states" do
      f = Finding.new(category: :other, title: "t")
      refute Finding.terminal?(f)
      {:ok, fixed} = Finding.update_status(f, :fixed)
      assert Finding.terminal?(fixed)
    end
  end

  describe "high_risk_location?/1 (the hard cap)" do
    test "true for arbor_security paths" do
      f =
        Finding.new(
          category: :fail_open_authz,
          title: "t",
          location: %{file: "apps/arbor_security/lib/arbor/security.ex"}
        )

      assert Finding.high_risk_location?(f)
    end

    test "false for an ordinary app path" do
      f =
        Finding.new(
          category: :other,
          title: "t",
          location: %{file: "apps/arbor_web/lib/page.ex"}
        )

      refute Finding.high_risk_location?(f)
    end
  end

  describe "projection + encoding" do
    test "to_markdown renders the key fields" do
      f =
        Finding.new(
          category: :fail_open_authz,
          title: "authorize/4 rescues to :ok",
          severity: %{level: :high},
          location: %{file: "apps/arbor_security/lib/a.ex", line: 42, function: "authorize/4"},
          invariant_violated: "authorize must fail closed",
          recommendation: %{approach: "Return {:error, reason} from the rescue."}
        )

      md = Finding.to_markdown(f)
      assert md =~ "authorize/4 rescues to :ok"
      assert md =~ "apps/arbor_security/lib/a.ex:42"
      assert md =~ "authorize must fail closed"
      assert md =~ "Return {:error, reason}"
    end

    test "Jason-encodes with an ISO8601 timestamp" do
      f = Finding.new(category: :other, title: "t")
      json = Jason.encode!(f)
      assert json =~ "\"category\":\"other\""
      assert json =~ "\"status\":\"open\""
      # detected_at serialized as a string, not a struct
      assert {:ok, decoded} = Jason.decode(json)
      assert is_binary(decoded["detected_at"])
    end
  end

  describe "gating_from_markdown/1 (verify-pending selector)" do
    test "round-trips layer + confidence from to_markdown frontmatter" do
      f =
        Finding.new(
          category: :fail_open_authz,
          title: "L1 diff finding",
          detector: %{layer: "L1", name: "diff_review"},
          confidence: %{score: 0.5, rationale: "llm"}
        )

      gating = Finding.gating_from_markdown(Finding.to_markdown(f))
      assert gating.layer == "L1"
      assert gating.confidence == 0.5
    end

    test "tolerates missing fields" do
      gating = Finding.gating_from_markdown("no frontmatter here")
      assert gating.layer == nil
      assert gating.confidence == nil
    end

    test "parses an L0 deterministic finding's high confidence" do
      f =
        Finding.new(
          category: :other,
          title: "L0 finding",
          detector: %{layer: "L0", name: "auth_smells"},
          confidence: %{score: 0.9, rationale: "ast"}
        )

      gating = Finding.gating_from_markdown(Finding.to_markdown(f))
      assert gating.layer == "L0"
      assert gating.confidence == 0.9
    end
  end
end
