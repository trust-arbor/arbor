defmodule Arbor.Contracts.Coding.ValidationCapacityHandoffTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  test "live schema is v3 and maximum compact batch cardinality remains bounded" do
    assert ValidationCapacityHandoff.schema_version() == 3
    batches = max_batches()
    assert length(batches) == 343

    assert {:ok, ordered_plan_sha256} =
             ValidationCapacityHandoff.ordered_plan_digest(batches)

    attrs = valid_v3_structural_attrs(batches, ordered_plan_sha256)

    assert {:ok, descriptor} = ValidationCapacityHandoff.new(attrs)
    encoded = Jason.encode!(ValidationCapacityHandoff.to_map(descriptor))
    assert byte_size(encoded) < 1_048_576
    assert byte_size(encoded) <= 256_000
    refute encoded =~ "\"paths\""
    refute Map.has_key?(ValidationCapacityHandoff.to_map(descriptor), "required_budget_ms")
    assert descriptor.available_budget_ms == 0
    assert descriptor.interrupted_batch == nil
  end

  test "valid interrupted-middle and interrupted-final v3 shapes" do
    [b1, b2, b3] = three_batches()

    # Middle: completed 0, interrupted b1, unstarted [b2,b3]
    middle_subject = [b1, b2, b3]
    {:ok, middle_digest} = ValidationCapacityHandoff.ordered_plan_digest(middle_subject)

    middle = %{
      "schema_version" => 3,
      "phase" => "runtime",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 2,
      "unstarted_file_count" => b2["count"] + b3["count"],
      "total_batch_count" => 3,
      "total_file_count" => b1["count"] + b2["count"] + b3["count"],
      "ordered_plan_sha256" => middle_digest,
      "interrupted_batch" => b1,
      "unstarted_batches" => [b2, b3]
    }

    assert {:ok, mid} = ValidationCapacityHandoff.new(middle)
    assert mid.interrupted_batch.index == 1
    assert length(mid.unstarted_batches) == 2

    # Final: completed 2, interrupted b3, unstarted []
    {:ok, final_digest} = ValidationCapacityHandoff.ordered_plan_digest([b3])

    final = %{
      "schema_version" => 3,
      "phase" => "runtime",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => 1_200_000,
      "completed_batch_count" => 2,
      "completed_file_count" => b1["count"] + b2["count"],
      "unstarted_batch_count" => 0,
      "unstarted_file_count" => 0,
      "total_batch_count" => 3,
      "total_file_count" => b1["count"] + b2["count"] + b3["count"],
      "ordered_plan_sha256" => final_digest,
      "interrupted_batch" => b3,
      "unstarted_batches" => []
    }

    assert {:ok, fin} = ValidationCapacityHandoff.new(final)
    assert fin.interrupted_batch.index == 3
    assert fin.unstarted_batches == []
  end

  test "tampered, unknown, and inconsistent v3 descriptors fail closed" do
    batches = max_batches()
    {:ok, ordered_plan_sha256} = ValidationCapacityHandoff.ordered_plan_digest(batches)
    attrs = valid_v3_structural_attrs(batches, ordered_plan_sha256)
    [b1, b2 | _] = three_batches()
    ib1 = batch(1, 2, b1["count"], b1["inventory_sha256"])
    ib2 = batch(2, 2, b2["count"], b2["inventory_sha256"])
    {:ok, ib_digest} = ValidationCapacityHandoff.ordered_plan_digest([ib1, ib2])

    interrupted_base = %{
      "schema_version" => 3,
      "phase" => "runtime",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 1,
      "unstarted_file_count" => ib2["count"],
      "total_batch_count" => 2,
      "total_file_count" => ib1["count"] + ib2["count"],
      "ordered_plan_sha256" => ib_digest,
      "interrupted_batch" => ib1,
      "unstarted_batches" => [ib2]
    }

    assert {:ok, _} = ValidationCapacityHandoff.new(interrupted_base)

    bad_index =
      Map.merge(ib1, %{
        "index" => 2,
        "label" => "batch-2-of-2-n#{ib1["count"]}-#{ib1["inventory_sha256"]}"
      })

    invalid = [
      Map.put(attrs, "unknown", true),
      put_in(attrs, ["unstarted_batches", Access.at(0), "count"], 2),
      put_in(attrs, ["unstarted_batches", Access.at(0), "index"], 2),
      put_in(attrs, ["unstarted_batches", Access.at(0), "label"], "tampered"),
      put_in(
        attrs,
        ["unstarted_batches", Access.at(0), "inventory_sha256"],
        String.duplicate("b", 64)
      ),
      Map.put(attrs, "ordered_plan_sha256", String.duplicate("0", 64)),
      Map.put(attrs, "available_budget_ms", 1),
      Map.put(attrs, "completed_file_count", 1),
      Map.put(attrs, "required_budget_ms", 1),
      Map.put(attrs, "interrupted_batch", ib1),
      Map.put(interrupted_base, "ordered_plan_sha256", String.duplicate("0", 64)),
      Map.put(interrupted_base, "interrupted_batch", bad_index),
      Map.put(interrupted_base, "completed_batch_count", 1),
      Map.put(interrupted_base, "phase", "structural"),
      put_in(interrupted_base, ["interrupted_batch", "paths"], ["apps/x/test/a_test.exs"])
    ]

    assert Enum.all?(invalid, &match?({:error, _}, ValidationCapacityHandoff.new(&1)))
  end

  test "live normalize rejects well-formed historical schema-v1 and schema-v2 evidence" do
    batches = max_batches()
    {:ok, ordered_plan_sha256} = ValidationCapacityHandoff.ordered_plan_digest(batches)
    v1 = valid_v1_attrs(batches, ordered_plan_sha256)
    v2 = valid_v2_attrs(batches, ordered_plan_sha256)

    assert {:error, _} = ValidationCapacityHandoff.normalize(v1)

    assert {:error, _} = ValidationCapacityHandoff.normalize(v2)

    refute ValidationCapacityHandoff.valid?(v1)
    refute ValidationCapacityHandoff.valid?(v2)
  end

  test "archive-only APIs accept valid historical schema-v1 and schema-v2 and reject tamper" do
    batches = max_batches()
    {:ok, ordered_plan_sha256} = ValidationCapacityHandoff.ordered_plan_digest(batches)
    v1 = valid_v1_attrs(batches, ordered_plan_sha256)
    v2 = valid_v2_attrs(batches, ordered_plan_sha256)

    assert {:ok, normalized_v1} = ValidationCapacityHandoff.normalize_archived_v1(v1)
    assert normalized_v1["schema_version"] == 1
    assert normalized_v1["required_budget_ms"] == 343 * 1_200_000
    assert ValidationCapacityHandoff.valid_archived_v1?(v1)

    assert {:ok, normalized_v2} = ValidationCapacityHandoff.normalize_archived_v2(v2)
    assert normalized_v2["schema_version"] == 2
    refute Map.has_key?(normalized_v2, "interrupted_batch")
    assert ValidationCapacityHandoff.valid_archived_v2?(v2)

    assert {:error, _} =
             ValidationCapacityHandoff.normalize_archived_v1(Map.put(v1, "required_budget_ms", 1))

    assert {:error, _} =
             ValidationCapacityHandoff.normalize_archived_v2(
               Map.put(v2, "available_budget_ms", 1)
             )

    refute ValidationCapacityHandoff.valid_archived_v1?(Map.put(v1, "required_budget_ms", 1))
    refute ValidationCapacityHandoff.valid_archived_v2?(Map.put(v2, "available_budget_ms", 1))
  end

  defp valid_v3_structural_attrs(batches, ordered_plan_sha256) do
    %{
      "schema_version" => 3,
      "phase" => "structural",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 343,
      "unstarted_file_count" => 2_000,
      "total_batch_count" => 343,
      "total_file_count" => 2_000,
      "ordered_plan_sha256" => ordered_plan_sha256,
      "interrupted_batch" => nil,
      "unstarted_batches" => batches
    }
  end

  defp valid_v2_attrs(batches, ordered_plan_sha256) do
    %{
      "schema_version" => 2,
      "phase" => "structural",
      "available_budget_ms" => 0,
      "per_batch_budget_ms" => 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 343,
      "unstarted_file_count" => 2_000,
      "total_batch_count" => 343,
      "total_file_count" => 2_000,
      "ordered_plan_sha256" => ordered_plan_sha256,
      "unstarted_batches" => batches
    }
  end

  defp valid_v1_attrs(batches, ordered_plan_sha256) do
    %{
      "schema_version" => 1,
      "phase" => "structural",
      "available_budget_ms" => 1_000,
      "per_batch_budget_ms" => 1_200_000,
      "required_budget_ms" => 343 * 1_200_000,
      "completed_batch_count" => 0,
      "completed_file_count" => 0,
      "unstarted_batch_count" => 343,
      "unstarted_file_count" => 2_000,
      "total_batch_count" => 343,
      "total_file_count" => 2_000,
      "ordered_plan_sha256" => ordered_plan_sha256,
      "unstarted_batches" => batches
    }
  end

  defp three_batches do
    [
      batch(1, 3, 1, String.duplicate("a", 64)),
      batch(2, 3, 2, String.duplicate("b", 64)),
      batch(3, 3, 1, String.duplicate("c", 64))
    ]
  end

  defp batch(index, total, count, inventory_sha256) do
    %{
      "index" => index,
      "total" => total,
      "count" => count,
      "label" => "batch-#{index}-of-#{total}-n#{count}-#{inventory_sha256}",
      "inventory_sha256" => inventory_sha256
    }
  end

  defp max_batches do
    Enum.map(1..343, fn index ->
      count =
        cond do
          index <= 255 -> 1
          index <= 342 -> 20
          true -> 5
        end

      inventory_sha256 =
        :crypto.hash(:sha256, "inventory-#{index}")
        |> Base.encode16(case: :lower)

      batch(index, 343, count, inventory_sha256)
    end)
  end
end
