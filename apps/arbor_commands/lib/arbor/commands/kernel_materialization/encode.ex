defmodule Arbor.Commands.KernelMaterialization.Encode do
  @moduledoc """
  Canonical JSON and domain-separated digests for the K4A plan.

  Nested key order is applied at the byte-representation boundary via
  `Jason.OrderedObject`. Elixir maps do not preserve `Map.keys/1` order.
  """

  @plan_domain "arbor.packaging.kernel_materialization.plan.v1\0"
  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @plan_key_order [
    "schema",
    "version",
    "policy_version",
    "base_commit",
    "object_format",
    "split",
    "counts",
    "entries",
    "retained_targets",
    "collision_groups",
    "entries_digest"
  ]

  @split_key_order ["passive_owner", "active_owner", "source_map"]

  @counts_key_order [
    "source_entries",
    "exact_moves",
    "transform_inputs",
    "collision_destinations",
    "retained_targets"
  ]

  @entry_key_order [
    "source_path",
    "source_mode",
    "source_oid",
    "destination_path",
    "disposition",
    "target_precondition",
    "collision_group"
  ]

  @retained_key_order ["path", "mode", "oid", "disposition"]
  @group_key_order ["destination_path", "source_paths", "preexisting_paths"]

  @report_key_order [
    "schema",
    "mode",
    "phase",
    "status",
    "output",
    "plan_digest",
    "object_format",
    "counts",
    "comparison",
    "errors"
  ]

  @evidence_key_order ["schema", "version", "plan_digest", "entries"]
  @evidence_entry_key_order ["destination_path", "kind", "mode", "oid"]
  @comparison_key_order ["status", "failures", "failure_count", "truncated"]
  @failure_key_order ["reason", "detail"]

  @spec git_blob_oid(binary(), String.t()) :: String.t()
  def git_blob_oid(bytes, "sha1") when is_binary(bytes), do: hash_blob_oid(:sha, bytes)
  def git_blob_oid(bytes, "sha256") when is_binary(bytes), do: hash_blob_oid(:sha256, bytes)
  def git_blob_oid(_, _), do: ""

  @spec blob_oid_valid?(term()) :: boolean()
  def blob_oid_valid?(oid) when is_binary(oid), do: Regex.match?(@oid_re, oid)
  def blob_oid_valid?(_), do: false

  @spec oid_matches_format?(term(), String.t()) :: boolean()
  def oid_matches_format?(oid, "sha1") when is_binary(oid), do: byte_size(oid) == 40
  def oid_matches_format?(oid, "sha256") when is_binary(oid), do: byte_size(oid) == 64
  def oid_matches_format?(_, _), do: false

  @spec plan_digest(map()) :: String.t()
  def plan_digest(plan) when is_map(plan) do
    :crypto.hash(:sha256, [
      @plan_domain,
      frame(canonical_json(plan["policy_version"] || "")),
      frame(canonical_json(plan["base_commit"] || "")),
      frame(canonical_json(plan["object_format"] || "")),
      frame(canonical_json(plan["split"] || %{})),
      frame(canonical_json(plan["counts"] || %{})),
      frame(canonical_json(plan["entries"] || [])),
      frame(canonical_json(plan["retained_targets"] || [])),
      frame(canonical_json(plan["collision_groups"] || []))
    ])
    |> Base.encode16(case: :lower)
  end

  def plan_digest(_), do: String.duplicate("0", 64)

  @spec encode_plan(map()) :: {:ok, binary()} | {:error, term()}
  def encode_plan(plan) when is_map(plan) do
    encode_ordered(Map.take(plan, @plan_key_order), @plan_key_order)
  end

  def encode_plan(_), do: {:error, :invalid_plan}

  @spec encode_report(map()) :: {:ok, binary()} | {:error, term()}
  def encode_report(report) when is_map(report) do
    encode_ordered(Map.take(report, @report_key_order), @report_key_order)
  end

  def encode_report(_), do: {:error, :invalid_report}

  @spec encode_evidence(map()) :: {:ok, binary()} | {:error, term()}
  def encode_evidence(evidence) when is_map(evidence) do
    encode_ordered(Map.take(evidence, @evidence_key_order), @evidence_key_order)
  end

  def encode_evidence(_), do: {:error, :invalid_evidence}

  @spec order_entry(map()) :: map()
  def order_entry(entry) when is_map(entry), do: take_present(entry, @entry_key_order)
  def order_entry(_), do: %{}

  @spec order_retained(map()) :: map()
  def order_retained(entry) when is_map(entry), do: take_present(entry, @retained_key_order)
  def order_retained(_), do: %{}

  @spec order_group(map()) :: map()
  def order_group(entry) when is_map(entry), do: take_present(entry, @group_key_order)
  def order_group(_), do: %{}

  @spec order_evidence_entry(map()) :: map()
  def order_evidence_entry(entry) when is_map(entry),
    do: take_present(entry, @evidence_entry_key_order)

  def order_evidence_entry(_), do: %{}

  defp hash_blob_oid(algo, bytes) do
    :crypto.hash(algo, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes])
    |> Base.encode16(case: :lower)
  end

  defp frame(value) when is_binary(value) do
    [<<byte_size(value)::unsigned-big-32>>, value]
  end

  defp canonical_json(value) do
    Jason.encode!(canonicalize(value))
  end

  defp encode_ordered(map, key_order) do
    ordered =
      Jason.OrderedObject.new(
        Enum.map(key_order, fn key ->
          {key, canonicalize(Map.get(map, key))}
        end)
      )

    {:ok, Jason.encode!(ordered)}
  rescue
    _ -> {:error, :encode_failed}
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    order = key_order_for(map)

    order
    |> Enum.filter(&Map.has_key?(map, &1))
    |> Enum.map(fn key -> {key, canonicalize(Map.get(map, key))} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(%Jason.OrderedObject{} = o), do: o
  defp canonicalize(other), do: other

  defp key_order_for(map) do
    cond do
      Map.has_key?(map, "source_path") and Map.has_key?(map, "source_oid") ->
        @entry_key_order

      Map.has_key?(map, "disposition") and Map.has_key?(map, "oid") and
          Map.has_key?(map, "path") ->
        @retained_key_order

      Map.has_key?(map, "source_paths") and Map.has_key?(map, "destination_path") ->
        @group_key_order

      Map.has_key?(map, "kind") and Map.has_key?(map, "destination_path") ->
        @evidence_entry_key_order

      Map.has_key?(map, "failure_count") and Map.has_key?(map, "failures") ->
        @comparison_key_order

      Map.has_key?(map, "reason") and Map.has_key?(map, "detail") ->
        @failure_key_order

      Map.has_key?(map, "passive_owner") and Map.has_key?(map, "source_map") ->
        @split_key_order

      Map.has_key?(map, "exact_moves") and Map.has_key?(map, "transform_inputs") ->
        @counts_key_order

      Map.has_key?(map, "schema") and Map.has_key?(map, "entries_digest") ->
        @plan_key_order

      Map.has_key?(map, "schema") and Map.has_key?(map, "plan_digest") and
          Map.has_key?(map, "phase") ->
        @report_key_order

      Map.has_key?(map, "schema") and Map.has_key?(map, "plan_digest") ->
        @evidence_key_order

      true ->
        map
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.sort()
    end
  end

  defp take_present(entry, order) do
    Enum.reduce(order, %{}, fn key, acc ->
      case Map.fetch(entry, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end
end
