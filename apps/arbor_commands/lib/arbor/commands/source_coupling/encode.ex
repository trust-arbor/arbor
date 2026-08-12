defmodule Arbor.Commands.SourceCoupling.Encode do
  @moduledoc """
  Canonical ordered JSON and domain-separated digests for source-coupling census.
  Pure: no filesystem or process access.
  """

  @scan_manifest_domain "arbor.packaging.source_coupling.scan_manifest.v1\0"
  @baseline_entries_domain "arbor.packaging.source_coupling.baseline_entries.v1\0"
  @unresolved_expr_domain "arbor.packaging.source_coupling.unresolved_expr.v1\0"

  @report_key_order [
    "schema",
    "mode",
    "status",
    "output",
    "provenance",
    "summaries",
    "undeclared",
    "unresolved",
    "baseline",
    "provisional_delta",
    "compatibility",
    "errors"
  ]

  @baseline_key_order [
    "schema",
    "version",
    "provenance",
    "policy",
    "counts",
    "entries",
    "unresolved_entries",
    "entries_digest"
  ]

  @entry_key_order [
    "file",
    "from_module",
    "target",
    "kind",
    "class",
    "from_app",
    "to_app",
    "from_band",
    "to_band",
    "fate",
    "level_direction",
    "occurrence_count"
  ]

  @unresolved_entry_key_order [
    "file",
    "from_module",
    "reason",
    "kind",
    "expression_digest",
    "normalized_expression",
    "occurrence_count",
    "disposition",
    "rationale"
  ]

  @doc "Domain-separated scan manifest digest over sorted {path, blob_oid}."
  @spec scan_manifest_digest([{String.t(), String.t()}]) :: String.t()
  def scan_manifest_digest(pairs) when is_list(pairs) do
    sorted =
      Enum.sort_by(pairs, fn
        {path, _oid} -> path
        %{"path" => path} -> path
      end)

    Enum.reduce(
      sorted,
      :crypto.hash_init(:sha256) |> :crypto.hash_update(@scan_manifest_domain),
      fn
        {path, oid}, acc when is_binary(path) and is_binary(oid) ->
          :crypto.hash_update(acc, [
            <<byte_size(path)::unsigned-big-32>>,
            path,
            <<byte_size(oid)::unsigned-big-32>>,
            oid
          ])

        %{"path" => path, "blob_oid" => oid}, acc when is_binary(path) and is_binary(oid) ->
          :crypto.hash_update(acc, [
            <<byte_size(path)::unsigned-big-32>>,
            path,
            <<byte_size(oid)::unsigned-big-32>>,
            oid
          ])
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "Digest of a normalized unresolved expression string."
  @spec expression_digest(String.t()) :: String.t()
  def expression_digest(normalized) when is_binary(normalized) do
    :crypto.hash(:sha256, [@unresolved_expr_domain, normalized])
    |> Base.encode16(case: :lower)
  end

  @doc "Domain-separated digest of sorted baseline occurrence entries (no tree_oid)."
  @spec entries_digest([map()]) :: String.t()
  def entries_digest(entries) when is_list(entries) do
    sorted = Enum.sort_by(entries, &entry_sort_key/1)

    Enum.reduce(
      sorted,
      :crypto.hash_init(:sha256) |> :crypto.hash_update(@baseline_entries_domain),
      fn entry, acc ->
        framed =
          Enum.map(@entry_key_order, fn key ->
            value = entry_field(entry, key)
            encoded = encode_field(value)

            [
              <<byte_size(key)::unsigned-big-32>>,
              key,
              <<byte_size(encoded)::unsigned-big-32>>,
              encoded
            ]
          end)

        :crypto.hash_update(acc, framed)
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc "Encode a report map as deterministic JSON bytes."
  @spec encode_report(map()) :: {:ok, binary()} | {:error, term()}
  def encode_report(report) when is_map(report) do
    encode_ordered(report, @report_key_order)
  end

  def encode_report(_), do: {:error, :invalid_report}

  @doc "Encode a baseline map as deterministic JSON bytes."
  @spec encode_baseline(map()) :: {:ok, binary()} | {:error, term()}
  def encode_baseline(baseline) when is_map(baseline) do
    encode_ordered(baseline, @baseline_key_order)
  end

  def encode_baseline(_), do: {:error, :invalid_baseline}

  @doc "Order a baseline entry map with fixed keys."
  @spec order_entry(map()) :: map()
  def order_entry(entry) when is_map(entry) do
    Map.new(@entry_key_order, fn key -> {key, entry_field(entry, key)} end)
  end

  @doc "Order an unresolved baseline entry map with fixed keys."
  @spec order_unresolved_entry(map()) :: map()
  def order_unresolved_entry(entry) when is_map(entry) do
    Map.new(@unresolved_entry_key_order, fn key -> {key, entry_field(entry, key)} end)
  end

  @spec entry_key_order() :: [String.t()]
  def entry_key_order, do: @entry_key_order

  @spec unresolved_entry_key_order() :: [String.t()]
  def unresolved_entry_key_order, do: @unresolved_entry_key_order

  @doc "Digest for an empty entries list (domain tag only)."
  @spec empty_entries_digest() :: String.t()
  def empty_entries_digest, do: entries_digest([])

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
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(%Jason.OrderedObject{} = o), do: o
  defp canonicalize(other), do: other

  defp entry_sort_key(entry) do
    {
      entry_field(entry, "file"),
      entry_field(entry, "from_module"),
      entry_field(entry, "target"),
      entry_field(entry, "kind"),
      entry_field(entry, "class")
    }
  end

  defp entry_field(entry, key) when is_map(entry) do
    case Map.fetch(entry, key) do
      {:ok, value} -> value
      :error -> default_field(key)
    end
  end

  defp default_field("occurrence_count"), do: 0
  defp default_field(_), do: ""

  defp encode_field(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_field(v) when is_binary(v), do: v
  defp encode_field(v) when is_atom(v), do: Atom.to_string(v)
  defp encode_field(v), do: inspect(v, limit: 100)
end
