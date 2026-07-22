defmodule Arbor.Contracts.Coding.ValidationCapacityHandoffTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Coding.ValidationCapacityHandoff

  @moduletag :fast

  test "maximum compact batch cardinality remains bounded and JSON-clean" do
    batches = max_batches()
    assert length(batches) == 343

    assert {:ok, ordered_plan_sha256} =
             ValidationCapacityHandoff.ordered_plan_digest(batches)

    attrs = %{
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

    assert {:ok, descriptor} = ValidationCapacityHandoff.new(attrs)
    encoded = Jason.encode!(ValidationCapacityHandoff.to_map(descriptor))
    assert byte_size(encoded) < 1_048_576
    assert byte_size(encoded) <= 256_000
    refute encoded =~ "\"paths\""
  end

  test "tampered, unknown, and inconsistent descriptors fail closed" do
    batches = max_batches()
    {:ok, ordered_plan_sha256} = ValidationCapacityHandoff.ordered_plan_digest(batches)
    attrs = valid_attrs(batches, ordered_plan_sha256)

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
      Map.put(attrs, "required_budget_ms", 1),
      Map.put(attrs, "completed_file_count", 1)
    ]

    assert Enum.all?(invalid, &match?({:error, _}, ValidationCapacityHandoff.new(&1)))
  end

  defp valid_attrs(batches, ordered_plan_sha256) do
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

      %{
        "index" => index,
        "total" => 343,
        "count" => count,
        "label" => "batch-#{index}-of-343-n#{count}-#{inventory_sha256}",
        "inventory_sha256" => inventory_sha256
      }
    end)
  end
end
