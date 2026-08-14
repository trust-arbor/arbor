defmodule Arbor.Commands.KernelMigration.Encode do
  @moduledoc """
  Canonical JSON and domain-separated digests for the PK-K0 gate.

  Nested key order is applied at the byte-representation boundary via
  `Jason.OrderedObject`. Elixir maps do not preserve `Map.keys/1` order.
  Digests are order-independent (entries are sorted) and domain-separated
  per manifest and inventory.
  """

  @finding_domain "arbor.packaging.kernel_migration.finding.v1\0"
  @identity_domain "arbor.packaging.kernel_migration.identity.v1\0"
  @disposition_domain "arbor.packaging.kernel_migration.disposition.v1\0"
  @runtime_domain "arbor.packaging.kernel_migration.runtime.v1\0"
  @mix_task_domain "arbor.packaging.kernel_migration.mix_task.v1\0"
  @boundary_domain "arbor.packaging.kernel_migration.boundary.v1\0"
  @formatter_files_domain "arbor.packaging.kernel_migration.formatter_files.v1\0"
  @formatter_configs_domain "arbor.packaging.kernel_migration.formatter_configs.v1\0"
  @formatter_manifest_domain "arbor.packaging.kernel_migration.formatter.v1\0"

  # Normative checked artifact: no presentation-mode keys.
  @report_key_order [
    "schema",
    "status",
    "identity",
    "policy",
    "provenance",
    "counts",
    "runtime",
    "mix_task",
    "boundary",
    "formatter",
    "dispositions",
    "comparison",
    "errors"
  ]

  @policy_key_order ["version", "k_apps"]

  @provenance_key_order [
    "scan_manifest_digest",
    "object_format",
    "provenance_source",
    "policy_version",
    "k_apps"
  ]

  @counts_key_order [
    "total",
    "runtime",
    "mix_task",
    "boundary",
    "formatter",
    "dispositions"
  ]

  @finding_key_order [
    "finding_id",
    "file",
    "line",
    "occurrence_ordinal",
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
    "declared",
    "collection"
  ]

  @disposition_key_order [
    "finding_id",
    "file",
    "from_module",
    "target",
    "kind",
    "class",
    "occurrence_ordinal",
    "disposition",
    "owner_packet",
    "rationale",
    "blob_oid"
  ]

  @boundary_key_order [
    "current_path",
    "from_module",
    "target",
    "kind",
    "site_line",
    "proof_destination",
    "source",
    "blob_oid"
  ]

  @formatter_file_key_order ["current_path", "proof_destination", "blob_oid"]
  @formatter_config_key_order ["path", "status", "blob_oid"]
  @comparison_key_order ["status", "failures", "failure_count", "truncated"]
  @failure_key_order ["reason", "detail"]

  @spec finding_id(map()) :: String.t()
  def finding_id(finding) when is_map(finding) do
    ordinal = occurrence_ordinal(finding)

    :crypto.hash(:sha256, [
      @finding_domain,
      frame(field(finding, "file")),
      frame(field(finding, "from_module")),
      frame(field(finding, "target")),
      frame(field(finding, "kind")),
      frame(field(finding, "class")),
      <<ordinal::unsigned-big-32>>
    ])
    |> Base.encode16(case: :lower)
  end

  def finding_id(_), do: String.duplicate("0", 64)

  @spec identity(map()) :: String.t()
  def identity(parts) when is_map(parts) do
    :crypto.hash(:sha256, [
      @identity_domain,
      frame(parts["scan_manifest_digest"] || ""),
      frame(parts["disposition_manifest_digest"] || ""),
      frame(parts["boundary_manifest_digest"] || ""),
      frame(parts["formatter_manifest_digest"] || ""),
      frame(parts["policy_version"] || ""),
      frame(Enum.join(List.wrap(parts["k_apps"]), "\n")),
      frame(parts["runtime_digest"] || ""),
      frame(parts["mix_task_digest"] || "")
    ])
    |> Base.encode16(case: :lower)
  end

  def identity(_), do: String.duplicate("0", 64)

  @spec runtime_digest([map()]) :: String.t()
  def runtime_digest(entries) when is_list(entries) do
    digest_maps(entries, @runtime_domain, &inventory_sort/1, @finding_key_order)
  end

  def runtime_digest(_) do
    digest_maps([], @runtime_domain, &inventory_sort/1, @finding_key_order)
  end

  @spec mix_task_digest([map()]) :: String.t()
  def mix_task_digest(entries) when is_list(entries) do
    digest_maps(entries, @mix_task_domain, &inventory_sort/1, @finding_key_order)
  end

  def mix_task_digest(_) do
    digest_maps([], @mix_task_domain, &inventory_sort/1, @finding_key_order)
  end

  @spec inventory_digest([map()]) :: String.t()
  def inventory_digest(entries) when is_list(entries) do
    runtime_digest(entries)
  end

  def inventory_digest(_), do: runtime_digest([])

  @spec disposition_digest([map()]) :: String.t()
  def disposition_digest(entries) when is_list(entries) do
    digest_maps(entries, @disposition_domain, &disposition_sort/1, @disposition_key_order)
  end

  def disposition_digest(_),
    do: digest_maps([], @disposition_domain, &disposition_sort/1, @disposition_key_order)

  @spec boundary_digest([map()]) :: String.t()
  def boundary_digest(entries) when is_list(entries) do
    digest_maps(entries, @boundary_domain, &boundary_sort/1, @boundary_key_order)
  end

  def boundary_digest(_),
    do: digest_maps([], @boundary_domain, &boundary_sort/1, @boundary_key_order)

  @spec formatter_files_digest([map()]) :: String.t()
  def formatter_files_digest(entries) when is_list(entries) do
    digest_maps(entries, @formatter_files_domain, &path_sort/1, @formatter_file_key_order)
  end

  def formatter_files_digest(_),
    do: digest_maps([], @formatter_files_domain, &path_sort/1, @formatter_file_key_order)

  @spec formatter_configs_digest([map()]) :: String.t()
  def formatter_configs_digest(entries) when is_list(entries) do
    digest_maps(entries, @formatter_configs_domain, &config_sort/1, @formatter_config_key_order)
  end

  def formatter_configs_digest(_),
    do: digest_maps([], @formatter_configs_domain, &config_sort/1, @formatter_config_key_order)

  @spec formatter_digest([map()], [map()]) :: String.t()
  def formatter_digest(files, configs) when is_list(files) and is_list(configs) do
    :crypto.hash(:sha256, [
      @formatter_manifest_domain,
      frame(formatter_files_digest(files)),
      frame(formatter_configs_digest(configs))
    ])
    |> Base.encode16(case: :lower)
  end

  def formatter_digest(_, _), do: formatter_digest([], [])

  @doc """
  Drop presentation-only keys so check and write share one byte artifact.
  """
  @spec normative_report(map()) :: map()
  def normative_report(report) when is_map(report) do
    Map.take(report, @report_key_order)
  end

  def normative_report(_), do: %{}

  @spec encode_report(map()) :: {:ok, binary()} | {:error, term()}
  def encode_report(report) when is_map(report) do
    encode_ordered(normative_report(report), @report_key_order)
  end

  def encode_report(_), do: {:error, :invalid_report}

  @spec encode_ordered_map(map(), [String.t()]) :: {:ok, binary()} | {:error, term()}
  def encode_ordered_map(map, key_order) when is_map(map) and is_list(key_order) do
    encode_ordered(map, key_order)
  end

  def encode_ordered_map(_, _), do: {:error, :invalid_map}

  @spec order_finding(map()) :: map()
  def order_finding(finding) when is_map(finding) do
    Map.new(@finding_key_order, fn key ->
      {key, finding_field(finding, key)}
    end)
  end

  def order_finding(_), do: %{}

  @spec order_disposition(map()) :: map()
  def order_disposition(entry) when is_map(entry) do
    take_present(entry, @disposition_key_order)
  end

  def order_disposition(_), do: %{}

  @spec order_boundary(map()) :: map()
  def order_boundary(entry) when is_map(entry) do
    take_present(entry, @boundary_key_order)
  end

  def order_boundary(_), do: %{}

  @spec order_formatter_file(map()) :: map()
  def order_formatter_file(entry) when is_map(entry) do
    take_present(entry, @formatter_file_key_order)
  end

  def order_formatter_file(_), do: %{}

  @spec order_formatter_config(map()) :: map()
  def order_formatter_config(entry) when is_map(entry) do
    take_present(entry, @formatter_config_key_order)
  end

  def order_formatter_config(_), do: %{}

  @spec finding_key_order() :: [String.t()]
  def finding_key_order, do: @finding_key_order

  @spec report_key_order() :: [String.t()]
  def report_key_order, do: @report_key_order

  @spec disposition_key_order() :: [String.t()]
  def disposition_key_order, do: @disposition_key_order

  @spec boundary_key_order() :: [String.t()]
  def boundary_key_order, do: @boundary_key_order

  @spec formatter_file_key_order() :: [String.t()]
  def formatter_file_key_order, do: @formatter_file_key_order

  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @spec git_blob_oid(binary()) :: String.t()
  def git_blob_oid(bytes) when is_binary(bytes) do
    :crypto.hash(:sha, ["blob #{byte_size(bytes)}\0", bytes])
    |> Base.encode16(case: :lower)
  end

  def git_blob_oid(_), do: String.duplicate("0", 40)

  @spec blob_oid_valid?(term()) :: boolean()
  def blob_oid_valid?(oid) when is_binary(oid), do: Regex.match?(@oid_re, oid)
  def blob_oid_valid?(_), do: false

  defp finding_field(finding, "occurrence_ordinal"), do: occurrence_ordinal(finding)
  defp finding_field(finding, "line"), do: line_of(finding)
  defp finding_field(finding, "declared"), do: Map.get(finding, "declared", false)
  defp finding_field(finding, key), do: Map.get(finding, key, default_finding(key))

  defp default_finding("declared"), do: false
  defp default_finding(_), do: ""

  defp occurrence_ordinal(finding) do
    case Map.get(finding, "occurrence_ordinal") || Map.get(finding, :occurrence_ordinal) do
      n when is_integer(n) and n >= 1 -> n
      _ -> 1
    end
  end

  defp line_of(finding) do
    case Map.get(finding, "line") || Map.get(finding, :line) || Map.get(finding, "site_line") do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> value
      {:ok, value} when is_atom(value) -> Atom.to_string(value)
      {:ok, value} when is_integer(value) -> Integer.to_string(value)
      {:ok, value} when is_boolean(value) -> if(value, do: "true", else: "false")
      :error -> ""
      _ -> ""
    end
  end

  defp frame(value) when is_binary(value) do
    [<<byte_size(value)::unsigned-big-32>>, value]
  end

  defp digest_maps(entries, domain, sort_fun, key_order) do
    sorted = Enum.sort_by(entries, sort_fun)

    Enum.reduce(
      sorted,
      :crypto.hash_init(:sha256) |> :crypto.hash_update(domain),
      fn entry, acc ->
        encoded = encode_digest_entry(entry, key_order)
        :crypto.hash_update(acc, [<<byte_size(encoded)::unsigned-big-32>>, encoded])
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp encode_digest_entry(entry, key_order) do
    ordered =
      key_order
      |> Enum.filter(&Map.has_key?(entry, &1))
      |> Enum.map(fn key -> {key, canonicalize(Map.get(entry, key))} end)
      |> Jason.OrderedObject.new()

    Jason.encode!(ordered)
  end

  defp inventory_sort(entry) do
    {
      field(entry, "file"),
      line_of(entry),
      field(entry, "from_module"),
      field(entry, "target"),
      field(entry, "kind"),
      field(entry, "class"),
      occurrence_ordinal(entry)
    }
  end

  defp disposition_sort(entry) do
    {
      field(entry, "file"),
      field(entry, "from_module"),
      field(entry, "target"),
      field(entry, "kind"),
      field(entry, "class"),
      occurrence_ordinal(entry)
    }
  end

  defp boundary_sort(entry) do
    {
      field(entry, "current_path"),
      field(entry, "from_module"),
      field(entry, "target"),
      field(entry, "kind"),
      line_of(entry)
    }
  end

  defp path_sort(entry), do: field(entry, "current_path")
  defp config_sort(entry), do: field(entry, "path")

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
      Map.has_key?(map, "disposition") and Map.has_key?(map, "owner_packet") ->
        @disposition_key_order

      Map.has_key?(map, "collection") and Map.has_key?(map, "finding_id") ->
        @finding_key_order

      Map.has_key?(map, "site_line") and Map.has_key?(map, "current_path") ->
        @boundary_key_order

      Map.has_key?(map, "proof_destination") and Map.has_key?(map, "current_path") ->
        @formatter_file_key_order

      Map.has_key?(map, "status") and Map.has_key?(map, "path") and
          not Map.has_key?(map, "schema") ->
        @formatter_config_key_order

      Map.has_key?(map, "failure_count") and Map.has_key?(map, "failures") ->
        @comparison_key_order

      Map.has_key?(map, "reason") and Map.has_key?(map, "detail") ->
        @failure_key_order

      Map.has_key?(map, "scan_manifest_digest") ->
        @provenance_key_order

      Map.has_key?(map, "mix_task") and Map.has_key?(map, "formatter") and
          is_integer(Map.get(map, "runtime")) ->
        @counts_key_order

      Map.has_key?(map, "version") and Map.has_key?(map, "k_apps") and
          not Map.has_key?(map, "schema") ->
        @policy_key_order

      Map.has_key?(map, "schema") and Map.has_key?(map, "identity") ->
        @report_key_order

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
