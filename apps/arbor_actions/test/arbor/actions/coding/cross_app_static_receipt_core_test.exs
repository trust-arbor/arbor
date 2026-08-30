defmodule Arbor.Actions.Coding.CrossApp.StaticReceiptCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CrossApp.EvidenceCore
  alias Arbor.Actions.Coding.CrossApp.StaticReceiptCore
  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  @hex String.duplicate("c", 64)
  @base_oid String.duplicate("1", 40)
  @base_tree_oid String.duplicate("2", 40)
  @candidate_tree_oid String.duplicate("3", 40)
  @inv1 String.duplicate("a", 64)

  test "static receipt is non-circular, closed JSON, and digest-stable" do
    identities = identities()
    checks = successful_checks()
    assert {:ok, receipt, digest} = StaticReceiptCore.new_static_stage_receipt(identities, checks)

    assert receipt["schema_version"] == 1
    assert receipt["continuation_id"] =~ ~r/\Axappc_[0-9a-f]{64}\z/
    assert receipt["identities"] == identities
    assert Enum.sort(Map.keys(receipt)) == ~w(checks continuation_id identities schema_version)
    assert Enum.sort(Map.keys(receipt["checks"])) == ~w(compile test_compile xref)
    refute Map.has_key?(receipt, "digest")
    refute Map.has_key?(receipt, "static_stage_receipt_digest")
    assert {:ok, encoded} = Jason.encode(receipt)
    refute encoded =~ "fence_token"
    refute encoded =~ "authority"

    assert {:ok, ^receipt} = StaticReceiptCore.admit_static_stage_receipt(receipt)
    assert {:ok, ^digest} = StaticReceiptCore.static_receipt_digest(receipt)
    assert {:ok, from_evidence} = EvidenceCore.digest(receipt)
    assert digest == from_evidence

    assert {:ok, ^receipt, ^digest} =
             Actions.coding_cross_app_static_receipt_new(identities, checks)

    assert {:ok, ^receipt} = Actions.coding_cross_app_static_receipt_admit(receipt)
    assert {:ok, ^digest} = Actions.coding_cross_app_static_receipt_digest(receipt)
    assert Actions.coding_cross_app_static_receipt_schema_version() == 1
    assert Actions.coding_cross_app_static_receipt_limits() == StaticReceiptCore.limits()
  end

  test "static receipt admits 2000-byte excerpts and rejects 2001" do
    heavy = String.duplicate(<<0, ?\n, ?", ?\\>>, 500)
    assert byte_size(heavy) == 2_000

    assert {:ok, receipt, _digest} =
             StaticReceiptCore.new_static_stage_receipt(
               identities(),
               successful_checks(heavy)
             )

    assert receipt["checks"]["compile"]["stdout_excerpt"] == heavy
    assert {:ok, _} = StaticReceiptCore.admit_static_stage_receipt(receipt)

    too_long = heavy <> <<0>>

    assert {:error, :malformed_envelope} =
             StaticReceiptCore.new_static_stage_receipt(
               identities(),
               successful_checks(too_long)
             )
  end

  test "static receipt rejects failed, mixed, and malformed checks" do
    identities = identities()
    checks = successful_checks()

    failed = put_in(checks, ["compile", "passed"], false)

    assert {:error, :malformed_envelope} =
             StaticReceiptCore.new_static_stage_receipt(identities, failed)

    extra = Map.put(checks, "test", hd_check())

    assert {:error, :malformed_envelope} =
             StaticReceiptCore.new_static_stage_receipt(identities, extra)

    assert {:error, :malformed_state} =
             StaticReceiptCore.new_static_stage_receipt(%{task_id: "atom"}, checks)

    assert {:error, :malformed_envelope} =
             StaticReceiptCore.admit_static_stage_receipt(DateTime.utc_now())
  end

  test "limits publish static-receipt JSON ceilings" do
    limits = StaticReceiptCore.limits()
    assert limits["max_excerpt_raw_bytes"] == 2_000
    assert limits["max_excerpt_json_bytes"] == 2 + 6 * 2_000
    assert limits["max_static_receipt_json_bytes"] > 76_000
    assert is_integer(limits["max_continuation_id_raw_bytes"])
  end

  test "production static receipt core contains no side-effect calls" do
    source =
      Path.expand(
        "../../../../lib/arbor/actions/coding/cross_app_static_receipt_core.ex",
        __DIR__
      )
      |> File.read!()

    for forbidden <- [
          "File.",
          "System.",
          "Application.",
          "Registry.",
          "GenServer.",
          "Process.",
          ":ets.",
          "DateTime.utc_now",
          "make_ref",
          "strong_rand_bytes",
          "String.to_atom"
        ] do
      refute source =~ forbidden, "static receipt core must not call #{forbidden}"
    end
  end

  defp identities do
    plan = [
      %{
        "index" => 1,
        "total" => 1,
        "count" => 1,
        "label" => "batch-1-of-1-n1-#{@inv1}",
        "inventory_sha256" => @inv1
      }
    ]

    {:ok, digest} = ValidationCapacityHandoff.ordered_plan_digest(plan)

    %{
      "task_id" => "task_static_receipt",
      "work_packet_digest" => "sha256:" <> @hex,
      "base_commit" => @base_oid,
      "base_tree_oid" => @base_tree_oid,
      "candidate_head" => @base_oid,
      "candidate_tree_oid" => @candidate_tree_oid,
      "validation_plan_digest" => digest,
      "toolchain_digest" => String.duplicate("3", 64),
      "dependency_baseline_digest" => String.duplicate("4", 64),
      "wrapper_digest" => String.duplicate("5", 64),
      "validator_id" => "coding_cross_app_validate",
      "principal_id" => "agent_principal",
      "configuration_digest" => String.duplicate("6", 64)
    }
  end

  defp successful_checks(excerpt \\ "") do
    check = hd_check(excerpt)
    %{"compile" => check, "xref" => check, "test_compile" => check}
  end

  defp hd_check(excerpt \\ "") do
    %{
      "status" => "completed",
      "passed" => true,
      "exit_code" => 0,
      "reason" => nil,
      "stdout_excerpt" => excerpt,
      "stderr_excerpt" => excerpt,
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "stdout_sha256" => String.duplicate("a", 64),
      "stderr_sha256" => String.duplicate("b", 64)
    }
  end
end
