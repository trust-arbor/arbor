defmodule Arbor.Commands.PlatformInventory.Encode do
  @moduledoc """
  Strict canonical JSON and domain-separated digests for the platform
  inventory report.

  Every validator rejects missing, extra, duplicate, malformed, unbounded,
  or non-JSON-safe fields — it never fills a silent default and never
  falls back to `inspect/1` to encode an unexpected value. Pure: no
  filesystem or process access.
  """

  @scan_manifest_domain "arbor.packaging.platform_inventory.scan_manifest.v1\0"
  @entries_domain "arbor.packaging.platform_inventory.entries.v1\0"
  @review_domain "arbor.packaging.platform_inventory.review.v1\0"
  @comparison_domain "arbor.packaging.platform_inventory.comparison.v1\0"
  @comparison_failures_domain "arbor.packaging.platform_inventory.comparison.failures.v1\0"
  @report_schema "arbor.packaging.platform_inventory.v1"

  @oid_re ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @digest_re ~r/\A[0-9a-f]{64}\z/

  @accepted_modes MapSet.new(["100644", "100755"])

  @component_classes MapSet.new([
                       "k_primitive",
                       "trusted_host",
                       "system_extension",
                       "optional_extension",
                       "third_party_extension"
                     ])

  @platform_apps MapSet.new([
                   "arbor_cartographer",
                   "arbor_llm",
                   "arbor_security",
                   "arbor_persistence",
                   "arbor_persistence_ecto",
                   "arbor_shell",
                   "arbor_sandbox",
                   "arbor_historian",
                   "arbor_trust"
                 ])

  @comparison_statuses MapSet.new(["match", "mismatch", "unreviewed"])
  @report_modes MapSet.new(["report", "check"])
  @report_outputs MapSet.new(["human", "json"])

  @max_path_bytes 4096
  @max_short_bytes 256
  @max_rationale_bytes 4000
  @max_detail_bytes @max_path_bytes + 160
  @max_byte_size 1_048_576
  @max_field_list_items 64
  @max_report_list_items 5000

  @entry_key_order [
    "path",
    "blob_oid",
    "mode",
    "byte_size",
    "app",
    "modules",
    "otp_roles",
    "configuration",
    "ownership",
    "registry",
    "process",
    "native",
    "network",
    "filesystem_scan",
    "dynamic_code",
    "telemetry"
  ]

  @classification_key_order ["path", "blob_oid", "class", "rationale"]

  @failure_key_order ["reason", "detail"]

  @counts_key_order ["total_files", "reviewed_files", "unreviewed_files", "by_app", "by_class"]

  @provenance_key_order [
    "head_tree_oid",
    "index_manifest_digest",
    "entries_digest",
    "review_digest",
    "comparison_digest"
  ]

  @entry_field_specs [
    {"path", &__MODULE__.valid_path?/1},
    {"blob_oid", &__MODULE__.valid_oid?/1},
    {"mode", &__MODULE__.valid_mode?/1},
    {"byte_size", &__MODULE__.valid_byte_size?/1},
    {"app", &__MODULE__.valid_platform_app?/1},
    {"modules", &__MODULE__.valid_string_list?/1},
    {"otp_roles", &__MODULE__.valid_string_list?/1},
    {"configuration", &__MODULE__.valid_boolean?/1},
    {"ownership", &__MODULE__.valid_boolean?/1},
    {"registry", &__MODULE__.valid_boolean?/1},
    {"process", &__MODULE__.valid_boolean?/1},
    {"native", &__MODULE__.valid_boolean?/1},
    {"network", &__MODULE__.valid_boolean?/1},
    {"filesystem_scan", &__MODULE__.valid_boolean?/1},
    {"dynamic_code", &__MODULE__.valid_boolean?/1},
    {"telemetry", &__MODULE__.valid_boolean?/1}
  ]

  @classification_field_specs [
    {"path", &__MODULE__.valid_path?/1},
    {"blob_oid", &__MODULE__.valid_oid?/1},
    {"class", &__MODULE__.valid_component_class?/1},
    {"rationale", &__MODULE__.valid_rationale?/1}
  ]

  @failure_field_specs [
    {"reason", &__MODULE__.valid_short_string?/1},
    {"detail", &__MODULE__.valid_detail_string?/1}
  ]

  @type validation_error :: {:error, term()}

  @spec entry_key_order() :: [String.t()]
  def entry_key_order, do: @entry_key_order

  @spec classification_key_order() :: [String.t()]
  def classification_key_order, do: @classification_key_order

  @spec component_classes() :: MapSet.t(String.t())
  def component_classes, do: @component_classes

  @spec platform_apps() :: MapSet.t(String.t())
  def platform_apps, do: @platform_apps

  @doc "Domain-separated digest over sorted, deduplicated {path, mode, blob_oid} triples."
  @spec scan_manifest_digest([{String.t(), String.t(), String.t()}]) ::
          {:ok, String.t()} | validation_error()
  def scan_manifest_digest(triples) when is_list(triples) do
    with {:ok, admitted} <- admit_manifest_triples(triples) do
      digest =
        admitted
        |> Enum.sort_by(&elem(&1, 0))
        |> hash_framed_triples(@scan_manifest_domain)

      {:ok, digest}
    end
  end

  def scan_manifest_digest(_), do: {:error, :invalid_manifest_pairs}

  @doc "Strictly validate then domain-separate digest sorted inventory entries."
  @spec entries_digest([map()]) :: {:ok, String.t()} | validation_error()
  def entries_digest(entries) do
    with {:ok, entries} <- validate_entry_list(entries) do
      digest =
        entries
        |> Enum.sort_by(&Map.fetch!(&1, "path"))
        |> hash_ordered_maps(@entries_domain, @entry_key_order)

      {:ok, digest}
    end
  rescue
    _ -> {:error, :incomparable_values}
  end

  @doc "Strictly validate then domain-separate digest sorted reviewed classifications."
  @spec review_digest([map()]) :: {:ok, String.t()} | validation_error()
  def review_digest(classifications) do
    with {:ok, classifications} <- validate_classification_list(classifications) do
      digest =
        classifications
        |> Enum.sort_by(&Map.fetch!(&1, "path"))
        |> hash_ordered_maps(@review_domain, @classification_key_order)

      {:ok, digest}
    end
  rescue
    _ -> {:error, :incomparable_values}
  end

  @doc "Strictly validate then domain-separate digest of a comparison result."
  @spec comparison_digest(map()) :: {:ok, String.t()} | validation_error()
  def comparison_digest(comparison) do
    case validate_comparison(comparison) do
      {:ok, comparison} -> hash_comparison(comparison)
      other -> other
    end
  end

  @doc "Strictly validate and canonically encode sorted inventory entries as JSON."
  @spec encode_entries([map()]) :: {:ok, binary()} | validation_error()
  def encode_entries(entries) do
    with {:ok, entries} <- validate_entry_list(entries) do
      ordered =
        entries
        |> Enum.sort_by(&Map.fetch!(&1, "path"))
        |> Enum.map(&order_fields(&1, @entry_key_order))

      {:ok, Jason.encode!(ordered)}
    end
  rescue
    _ -> {:error, :encode_failed}
  end

  @doc "Strictly validate and canonically encode sorted classifications as JSON."
  @spec encode_classifications([map()]) :: {:ok, binary()} | validation_error()
  def encode_classifications(classifications) do
    with {:ok, classifications} <- validate_classification_list(classifications) do
      ordered =
        classifications
        |> Enum.sort_by(&Map.fetch!(&1, "path"))
        |> Enum.map(&order_fields(&1, @classification_key_order))

      {:ok, Jason.encode!(ordered)}
    end
  rescue
    _ -> {:error, :encode_failed}
  end

  @doc "Strictly validate the full report structure and canonically encode it as JSON."
  @spec encode_report(map()) :: {:ok, binary()} | validation_error()
  def encode_report(report) when is_map(report) do
    with :ok <- validate_report(report) do
      ordered =
        Jason.OrderedObject.new([
          {"schema", Map.fetch!(report, "schema")},
          {"mode", Map.fetch!(report, "mode")},
          {"status", Map.fetch!(report, "status")},
          {"output", Map.fetch!(report, "output")},
          {"platform_apps", Enum.sort(Map.fetch!(report, "platform_apps"))},
          {"component_classes", Enum.sort(Map.fetch!(report, "component_classes"))},
          {"counts", order_counts(Map.fetch!(report, "counts"))},
          {"entries", ordered_entries(Map.fetch!(report, "entries"))},
          {"classifications", ordered_classifications(Map.fetch!(report, "classifications"))},
          {"comparison", order_comparison(Map.fetch!(report, "comparison"))},
          {"provenance", order_fields(Map.fetch!(report, "provenance"), @provenance_key_order)}
        ])

      {:ok, Jason.encode!(ordered)}
    end
  rescue
    _ -> {:error, :encode_failed}
  end

  def encode_report(_), do: {:error, :invalid_report}

  ## -- validation entry points --------------------------------------------

  @spec validate_entry(map()) :: :ok | validation_error()
  def validate_entry(entry), do: validate_fields(entry, @entry_field_specs)

  @spec validate_classification(map()) :: :ok | validation_error()
  def validate_classification(entry), do: validate_fields(entry, @classification_field_specs)

  @spec validate_failure(map()) :: :ok | validation_error()
  def validate_failure(entry), do: validate_fields(entry, @failure_field_specs)

  @spec validate_comparison(map()) :: {:ok, map()} | validation_error()
  def validate_comparison(comparison) when is_map(comparison) do
    with :ok <- validate_fields(comparison, comparison_field_specs()) do
      failures = Map.fetch!(comparison, "failures")
      count = Map.fetch!(comparison, "failure_count")

      cond do
        not is_list(failures) ->
          {:error, {:invalid_field, "failures", :not_a_list}}

        length(failures) > @max_report_list_items ->
          {:error, {:invalid_field, "failures", :unbounded}}

        not Enum.all?(failures, &(validate_failure(&1) == :ok)) ->
          {:error, {:invalid_field, "failures", :malformed_failure}}

        duplicate_by?(failures, &failure_sort_key/1) ->
          {:error, {:invalid_field, "failures", :duplicate_failures}}

        count != length(failures) ->
          {:error, {:invalid_field, "failure_count", :mismatched_count}}

        not consistent_comparison_status?(Map.fetch!(comparison, "status"), count) ->
          {:error, {:invalid_field, "status", :inconsistent_status}}

        true ->
          {:ok, comparison}
      end
    end
  end

  def validate_comparison(_), do: {:error, :invalid_comparison}

  @spec validate_report(map()) :: :ok | validation_error()
  def validate_report(report) when is_map(report) do
    with :ok <- validate_fields(report, report_field_specs()),
         {:ok, entries} <- validate_entry_list(Map.fetch!(report, "entries")),
         {:ok, classifications} <-
           validate_classification_list(Map.fetch!(report, "classifications")),
         {:ok, comparison} <- validate_comparison(Map.fetch!(report, "comparison")),
         :ok <- validate_fields(Map.fetch!(report, "provenance"), provenance_field_specs()),
         :ok <- validate_fields(Map.fetch!(report, "counts"), counts_field_specs()) do
      validate_report_semantics(report, entries, classifications, comparison)
    end
  end

  def validate_report(_), do: {:error, :invalid_report}

  ## -- field validators (public: referenced by @..._field_specs) ---------

  @doc false
  def valid_path?(path) when is_binary(path) do
    cond do
      path == "" -> {:error, :blank}
      not String.valid?(path) -> {:error, :invalid_utf8}
      byte_size(path) > @max_path_bytes -> {:error, :unbounded}
      String.contains?(path, <<0>>) -> {:error, :nul_byte}
      String.starts_with?(path, "/") -> {:error, :absolute}
      String.contains?(path, "\\") -> {:error, :backslash}
      traversal_segment?(path) -> {:error, :traversal}
      true -> :ok
    end
  end

  def valid_path?(_), do: {:error, :not_a_string}

  @doc false
  def valid_oid?(oid) when is_binary(oid) do
    if Regex.match?(@oid_re, oid), do: :ok, else: {:error, :invalid_oid}
  end

  def valid_oid?(_), do: {:error, :not_a_string}

  @doc false
  def valid_mode?(mode) when is_binary(mode) do
    if MapSet.member?(@accepted_modes, mode), do: :ok, else: {:error, :invalid_mode}
  end

  def valid_mode?(_), do: {:error, :not_a_string}

  @doc false
  def valid_byte_size?(size) when is_integer(size) do
    cond do
      size < 0 -> {:error, :negative}
      size > @max_byte_size -> {:error, :unbounded}
      true -> :ok
    end
  end

  def valid_byte_size?(_), do: {:error, :not_an_integer}

  @doc false
  def valid_platform_app?(app) when is_binary(app) do
    if MapSet.member?(@platform_apps, app), do: :ok, else: {:error, :unknown_app}
  end

  def valid_platform_app?(_), do: {:error, :not_a_string}

  @doc false
  def valid_component_class?(class) when is_binary(class) do
    if MapSet.member?(@component_classes, class), do: :ok, else: {:error, :unknown_class}
  end

  def valid_component_class?(_), do: {:error, :not_a_string}

  @doc false
  def valid_string_list?(list) when is_list(list) do
    cond do
      length(list) > @max_field_list_items ->
        {:error, :unbounded}

      not Enum.all?(list, &is_binary/1) ->
        {:error, :non_string_item}

      Enum.any?(list, &bounded_string_error/1) ->
        {:error, :malformed_item}

      length(list) != length(Enum.uniq(list)) ->
        {:error, :duplicate_items}

      true ->
        :ok
    end
  end

  def valid_string_list?(_), do: {:error, :not_a_list}

  @doc false
  def valid_boolean?(v) when is_boolean(v), do: :ok
  def valid_boolean?(_), do: {:error, :not_a_boolean}

  @doc false
  def valid_rationale?(v) when is_binary(v) do
    bounded_nonblank_string(v, @max_rationale_bytes)
  end

  def valid_rationale?(_), do: {:error, :not_a_string}

  @doc false
  def valid_short_string?(v) when is_binary(v) do
    bounded_nonblank_string(v, @max_short_bytes)
  end

  def valid_short_string?(_), do: {:error, :not_a_string}

  @doc false
  def valid_detail_string?(v) when is_binary(v) do
    bounded_nonblank_string(v, @max_detail_bytes)
  end

  def valid_detail_string?(_), do: {:error, :not_a_string}

  ## -- private ---------------------------------------------------------

  defp comparison_field_specs do
    [
      {"status", fn v -> member_or_error(v, @comparison_statuses, :invalid_status) end},
      {"failures", &valid_report_list?/1},
      {"failure_count", &valid_nonneg_int?/1}
    ]
  end

  defp report_field_specs do
    [
      {"schema", &valid_schema?/1},
      {"mode", fn v -> member_or_error(v, @report_modes, :invalid_mode) end},
      {"status", fn v -> member_or_error(v, @comparison_statuses, :invalid_status) end},
      {"output", fn v -> member_or_error(v, @report_outputs, :invalid_output) end},
      {"platform_apps", &valid_platform_apps_field?/1},
      {"component_classes", &valid_component_classes_field?/1},
      {"counts", &valid_map?/1},
      {"entries", &valid_report_list?/1},
      {"classifications", &valid_report_list?/1},
      {"comparison", &valid_map?/1},
      {"provenance", &valid_map?/1}
    ]
  end

  defp counts_field_specs do
    [
      {"total_files", &valid_nonneg_int?/1},
      {"reviewed_files", &valid_nonneg_int?/1},
      {"unreviewed_files", &valid_nonneg_int?/1},
      {"by_app", &valid_app_count_map?/1},
      {"by_class", &valid_class_count_map?/1}
    ]
  end

  defp provenance_field_specs do
    [
      {"head_tree_oid", &valid_oid?/1},
      {"index_manifest_digest", &valid_digest?/1},
      {"entries_digest", &valid_digest?/1},
      {"review_digest", &valid_digest?/1},
      {"comparison_digest", &valid_digest?/1}
    ]
  end

  defp valid_digest?(v) when is_binary(v) do
    if Regex.match?(@digest_re, v), do: :ok, else: {:error, :invalid_digest}
  end

  defp valid_digest?(_), do: {:error, :not_a_string}

  defp valid_schema?(v) when is_binary(v) do
    if v == @report_schema, do: :ok, else: {:error, :invalid_schema}
  end

  defp valid_schema?(_), do: {:error, :not_a_string}

  defp consistent_comparison_status?("mismatch", count) when count > 0, do: true
  defp consistent_comparison_status?("match", 0), do: true
  defp consistent_comparison_status?("unreviewed", 0), do: true
  defp consistent_comparison_status?(_, _), do: false

  defp valid_nonneg_int?(v) when is_integer(v) and v >= 0 do
    if v > @max_report_list_items, do: {:error, :unbounded}, else: :ok
  end

  defp valid_nonneg_int?(_), do: {:error, :not_a_nonneg_integer}

  defp valid_map?(v) when is_map(v) and not is_struct(v), do: :ok
  defp valid_map?(_), do: {:error, :not_a_map}

  defp valid_report_list?(v) when is_list(v) do
    if length(v) > @max_report_list_items, do: {:error, :unbounded}, else: :ok
  end

  defp valid_report_list?(_), do: {:error, :not_a_list}

  defp valid_platform_apps_field?(v) when is_list(v) do
    if Enum.all?(v, &is_binary/1) and MapSet.new(v) == @platform_apps and
         length(v) == MapSet.size(@platform_apps) do
      :ok
    else
      {:error, :invalid_platform_apps}
    end
  end

  defp valid_platform_apps_field?(_), do: {:error, :not_a_list}

  defp valid_component_classes_field?(v) when is_list(v) do
    if Enum.all?(v, &is_binary/1) and MapSet.new(v) == @component_classes and
         length(v) == MapSet.size(@component_classes) do
      :ok
    else
      {:error, :invalid_component_classes}
    end
  end

  defp valid_component_classes_field?(_), do: {:error, :not_a_list}

  defp valid_app_count_map?(v) when is_map(v) and not is_struct(v) do
    exact_count_map?(v, @platform_apps)
  end

  defp valid_app_count_map?(_), do: {:error, :not_a_map}

  defp valid_class_count_map?(v) when is_map(v) and not is_struct(v) do
    exact_count_map?(v, @component_classes)
  end

  defp valid_class_count_map?(_), do: {:error, :not_a_map}

  defp exact_count_map?(map, allowed) do
    keys = Map.keys(map)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, :non_string_keys}

      MapSet.new(keys) != allowed ->
        {:error, :key_mismatch}

      not Enum.all?(Map.values(map), &(is_integer(&1) and &1 >= 0)) ->
        {:error, :invalid_count_value}

      true ->
        :ok
    end
  end

  defp member_or_error(v, set, tag) when is_binary(v) do
    if MapSet.member?(set, v), do: :ok, else: {:error, tag}
  end

  defp member_or_error(_, _, _), do: {:error, :not_a_string}

  defp bounded_string_error(v) do
    case bounded_nonblank_string(v, @max_short_bytes) do
      :ok -> false
      {:error, _} -> true
    end
  end

  defp bounded_nonblank_string(v, max_bytes) do
    cond do
      v == "" -> {:error, :blank}
      not String.valid?(v) -> {:error, :invalid_utf8}
      byte_size(v) > max_bytes -> {:error, :unbounded}
      String.contains?(v, <<0>>) -> {:error, :nul_byte}
      true -> :ok
    end
  end

  defp traversal_segment?(path) do
    path
    |> String.split("/")
    |> Enum.any?(&(&1 in ["..", "", "."]))
  end

  @doc "Strictly validate a list of inventory entries (exact fields, no duplicate paths)."
  @spec validate_entry_list([map()]) :: {:ok, [map()]} | validation_error()
  def validate_entry_list(entries) when is_list(entries) do
    cond do
      length(entries) > @max_report_list_items ->
        {:error, :unbounded}

      not Enum.all?(entries, &(is_map(&1) and not is_struct(&1))) ->
        {:error, :invalid_entries}

      (err = first_field_error(entries, &validate_entry/1)) != nil ->
        err

      duplicate_by?(entries, &Map.fetch!(&1, "path")) ->
        {:error, :duplicate_entries}

      mixed_oid_format?(entries) ->
        {:error, :mixed_object_format}

      true ->
        {:ok, entries}
    end
  end

  def validate_entry_list(_), do: {:error, :invalid_entries}

  @doc "Strictly validate a list of reviewed classifications (exact fields, no duplicate paths)."
  @spec validate_classification_list([map()]) :: {:ok, [map()]} | validation_error()
  def validate_classification_list(classifications) when is_list(classifications) do
    cond do
      length(classifications) > @max_report_list_items ->
        {:error, :unbounded}

      not Enum.all?(classifications, &(is_map(&1) and not is_struct(&1))) ->
        {:error, :invalid_classifications}

      (err = first_field_error(classifications, &validate_classification/1)) != nil ->
        err

      duplicate_by?(classifications, &Map.fetch!(&1, "path")) ->
        {:error, :duplicate_classifications}

      mixed_oid_format?(classifications) ->
        {:error, :mixed_object_format}

      true ->
        {:ok, classifications}
    end
  end

  def validate_classification_list(_), do: {:error, :invalid_classifications}

  defp first_field_error(list, validator) do
    Enum.find_value(list, fn item ->
      case validator.(item) do
        :ok -> nil
        {:error, _} = err -> err
      end
    end)
  end

  defp duplicate_by?(list, fun) do
    keys = Enum.map(list, fun)
    length(keys) != length(Enum.uniq(keys))
  end

  defp admit_manifest_triples(triples) do
    if length(triples) > @max_report_list_items do
      {:error, :unbounded}
    else
      Enum.reduce_while(triples, {:ok, []}, fn triple, {:ok, acc} ->
        case admit_manifest_triple(triple) do
          {:ok, admitted} -> {:cont, {:ok, [admitted | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, acc} -> finish_manifest_triples(Enum.reverse(acc))
        err -> err
      end
    end
  end

  defp finish_manifest_triples(admitted) do
    cond do
      duplicate_by?(admitted, &elem(&1, 0)) ->
        {:error, :duplicate_manifest_pairs}

      mixed_triple_oid_format?(admitted) ->
        {:error, :mixed_object_format}

      true ->
        {:ok, admitted}
    end
  end

  defp admit_manifest_triple({path, mode, oid}) do
    with :ok <- valid_path?(path),
         :ok <- valid_mode?(mode),
         :ok <- valid_oid?(oid) do
      {:ok, {path, mode, oid}}
    else
      {:error, _} -> {:error, :invalid_manifest_pairs}
    end
  end

  defp admit_manifest_triple(_), do: {:error, :invalid_manifest_pairs}

  defp mixed_triple_oid_format?(triples) do
    triples
    |> Enum.map(fn {_, _, oid} -> byte_size(oid) end)
    |> Enum.uniq()
    |> then(&(&1 not in [[], [40], [64]]))
  end

  defp mixed_oid_format?(maps) do
    maps
    |> Enum.map(&byte_size(Map.fetch!(&1, "blob_oid")))
    |> Enum.uniq()
    |> then(&(&1 not in [[], [40], [64]]))
  end

  defp validate_fields(map, specs) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)
    expected_keys = Enum.map(specs, &elem(&1, 0))

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, :non_string_keys}

      MapSet.new(keys) != MapSet.new(expected_keys) ->
        {:error,
         {:field_mismatch, %{missing: expected_keys -- keys, extra: keys -- expected_keys}}}

      true ->
        Enum.reduce_while(specs, :ok, fn {key, validator}, :ok ->
          case validator.(Map.fetch!(map, key)) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:invalid_field, key, reason}}}
          end
        end)
    end
  end

  defp validate_fields(_, _), do: {:error, :invalid_map}

  defp order_fields(map, key_order) do
    Jason.OrderedObject.new(
      Enum.map(key_order, fn key ->
        {key, canonicalize_value(Map.fetch!(map, key))}
      end)
    )
  end

  defp canonicalize_value(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1) do
      Enum.sort(list)
    else
      list
    end
  end

  defp canonicalize_value(other), do: other

  defp ordered_entries(entries) do
    entries
    |> Enum.sort_by(&Map.fetch!(&1, "path"))
    |> Enum.map(&order_fields(&1, @entry_key_order))
  end

  defp ordered_classifications(classifications) do
    classifications
    |> Enum.sort_by(&Map.fetch!(&1, "path"))
    |> Enum.map(&order_fields(&1, @classification_key_order))
  end

  defp order_comparison(comparison) do
    {:ok, failures} = sort_failures(Map.fetch!(comparison, "failures"))

    Jason.OrderedObject.new([
      {"status", Map.fetch!(comparison, "status")},
      {"failures", Enum.map(failures, &order_fields(&1, @failure_key_order))},
      {"failure_count", Map.fetch!(comparison, "failure_count")}
    ])
  end

  defp sort_failures(failures) do
    {:ok, Enum.sort_by(failures, &failure_sort_key/1)}
  rescue
    _ -> {:error, :incomparable_failures}
  end

  defp failure_sort_key(failure) when is_map(failure) and not is_struct(failure) do
    {Map.fetch!(failure, "reason"), Map.fetch!(failure, "detail")}
  end

  defp validate_report_semantics(report, entries, classifications, comparison) do
    with :ok <- validate_entry_scope(entries),
         :ok <- validate_status_alignment(report, comparison, classifications),
         :ok <- validate_comparison_alignment(entries, classifications, comparison),
         :ok <- validate_counts(Map.fetch!(report, "counts"), entries, classifications),
         :ok <- validate_oid_format_alignment(report, entries, classifications) do
      validate_bound_digests(report, entries, classifications, comparison)
    end
  end

  defp validate_entry_scope(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      path = Map.fetch!(entry, "path")
      reported_app = Map.fetch!(entry, "app")

      case platform_source_app(path) do
        {:ok, ^reported_app} ->
          {:cont, :ok}

        {:ok, _path_app} ->
          {:halt, {:error, {:invalid_field, "app", :path_app_mismatch}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_field, "path", reason}}}
      end
    end)
  end

  defp platform_source_app(path) do
    case String.split(path, "/") do
      ["apps", app, "lib" | rest] when rest != [] ->
        cond do
          not MapSet.member?(@platform_apps, app) ->
            {:error, :outside_platform_scope}

          not String.ends_with?(List.last(rest), ".ex") ->
            {:error, :not_elixir_source}

          true ->
            {:ok, app}
        end

      _ ->
        {:error, :outside_platform_scope}
    end
  end

  defp validate_comparison_alignment(entries, classifications, comparison) do
    expected = expected_comparison(entries, classifications)

    with {:ok, failures} <- sort_failures(Map.fetch!(comparison, "failures")) do
      actual = %{comparison | "failures" => failures}

      if actual == expected do
        :ok
      else
        {:error, {:invalid_field, "comparison", :semantic_mismatch}}
      end
    end
  end

  defp expected_comparison(_entries, []) do
    %{"status" => "unreviewed", "failures" => [], "failure_count" => 0}
  end

  defp expected_comparison(entries, classifications) do
    entries_by_path = Map.new(entries, &{Map.fetch!(&1, "path"), &1})
    classifications_by_path = Map.new(classifications, &{Map.fetch!(&1, "path"), &1})

    missing =
      entries
      |> Enum.reject(&Map.has_key?(classifications_by_path, Map.fetch!(&1, "path")))
      |> Enum.map(&comparison_failure("missing_review", Map.fetch!(&1, "path")))

    extra =
      classifications
      |> Enum.reject(&Map.has_key?(entries_by_path, Map.fetch!(&1, "path")))
      |> Enum.map(&comparison_failure("extra_review", Map.fetch!(&1, "path")))

    stale =
      classifications
      |> stale_classifications(entries_by_path)
      |> Enum.map(&stale_review_failure(&1, entries_by_path))

    failures = Enum.sort_by(missing ++ extra ++ stale, &failure_sort_key/1)
    status = if failures == [], do: "match", else: "mismatch"

    %{"status" => status, "failures" => failures, "failure_count" => length(failures)}
  end

  defp stale_classifications(classifications, entries_by_path) do
    Enum.filter(classifications, fn classification ->
      path = Map.fetch!(classification, "path")

      Map.has_key?(entries_by_path, path) and
        Map.fetch!(entries_by_path, path)["blob_oid"] != Map.fetch!(classification, "blob_oid")
    end)
  end

  defp stale_review_failure(classification, entries_by_path) do
    path = Map.fetch!(classification, "path")
    expected = entries_by_path |> Map.fetch!(path) |> Map.fetch!("blob_oid")
    actual = Map.fetch!(classification, "blob_oid")
    comparison_failure("stale_blob", "#{path} expected=#{expected} actual=#{actual}")
  end

  defp comparison_failure(reason, detail), do: %{"reason" => reason, "detail" => detail}

  defp validate_status_alignment(report, comparison, classifications) do
    report_status = Map.fetch!(report, "status")
    comparison_status = Map.fetch!(comparison, "status")
    failure_count = Map.fetch!(comparison, "failure_count")

    cond do
      report_status != comparison_status ->
        {:error, {:invalid_field, "status", :status_mismatch}}

      classifications == [] and comparison_status != "unreviewed" ->
        {:error, {:invalid_field, "status", :inconsistent_status}}

      classifications != [] and failure_count == 0 and comparison_status != "match" ->
        {:error, {:invalid_field, "status", :inconsistent_status}}

      failure_count > 0 and comparison_status != "mismatch" ->
        {:error, {:invalid_field, "status", :inconsistent_status}}

      true ->
        :ok
    end
  end

  defp validate_counts(counts, entries, classifications) do
    expected = expected_counts(entries, classifications)

    cond do
      Map.fetch!(counts, "total_files") != expected.total_files ->
        {:error, {:invalid_field, "counts", :inconsistent_total_files}}

      Map.fetch!(counts, "reviewed_files") != expected.reviewed_files ->
        {:error, {:invalid_field, "counts", :inconsistent_reviewed_files}}

      Map.fetch!(counts, "unreviewed_files") != expected.unreviewed_files ->
        {:error, {:invalid_field, "counts", :inconsistent_unreviewed_files}}

      Map.fetch!(counts, "by_app") != expected.by_app ->
        {:error, {:invalid_field, "counts", :inconsistent_by_app}}

      Map.fetch!(counts, "by_class") != expected.by_class ->
        {:error, {:invalid_field, "counts", :inconsistent_by_class}}

      true ->
        :ok
    end
  end

  defp expected_counts(entries, classifications) do
    by_app = Enum.frequencies_by(entries, &Map.fetch!(&1, "app"))
    by_app_full = Map.new(@platform_apps, fn app -> {app, Map.get(by_app, app, 0)} end)
    by_class = Enum.frequencies_by(classifications, &Map.fetch!(&1, "class"))

    by_class_full =
      Map.new(@component_classes, fn class -> {class, Map.get(by_class, class, 0)} end)

    entry_paths = MapSet.new(entries, &Map.fetch!(&1, "path"))
    reviewed_paths = MapSet.new(classifications, &Map.fetch!(&1, "path"))
    reviewed_files = MapSet.size(MapSet.intersection(entry_paths, reviewed_paths))

    %{
      total_files: length(entries),
      reviewed_files: reviewed_files,
      unreviewed_files: length(entries) - reviewed_files,
      by_app: by_app_full,
      by_class: by_class_full
    }
  end

  defp validate_oid_format_alignment(report, entries, classifications) do
    head_tree_oid = report |> Map.fetch!("provenance") |> Map.fetch!("head_tree_oid")

    lengths =
      [byte_size(head_tree_oid)]
      |> Kernel.++(Enum.map(entries, &byte_size(Map.fetch!(&1, "blob_oid"))))
      |> Kernel.++(Enum.map(classifications, &byte_size(Map.fetch!(&1, "blob_oid"))))
      |> Enum.uniq()

    if lengths in [[40], [64]] do
      :ok
    else
      {:error, {:invalid_field, "head_tree_oid", :oid_format_mismatch}}
    end
  end

  defp validate_bound_digests(report, entries, classifications, comparison) do
    provenance = Map.fetch!(report, "provenance")
    triples = Enum.map(entries, &{&1["path"], &1["mode"], &1["blob_oid"]})

    with {:ok, index_digest} <- scan_manifest_digest(triples),
         {:ok, entries_digest} <- entries_digest(entries),
         {:ok, review_digest} <- review_digest(classifications),
         {:ok, comparison_digest} <- comparison_digest(comparison) do
      cond do
        provenance["index_manifest_digest"] != index_digest ->
          {:error, {:invalid_field, "index_manifest_digest", :digest_mismatch}}

        provenance["entries_digest"] != entries_digest ->
          {:error, {:invalid_field, "entries_digest", :digest_mismatch}}

        provenance["review_digest"] != review_digest ->
          {:error, {:invalid_field, "review_digest", :digest_mismatch}}

        provenance["comparison_digest"] != comparison_digest ->
          {:error, {:invalid_field, "comparison_digest", :digest_mismatch}}

        true ->
          :ok
      end
    end
  end

  defp order_counts(counts) do
    Jason.OrderedObject.new(
      Enum.map(@counts_key_order, fn
        key when key in ["by_app", "by_class"] ->
          {key, sorted_count_map(Map.fetch!(counts, key))}

        key ->
          {key, Map.fetch!(counts, key)}
      end)
    )
  end

  defp sorted_count_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Jason.OrderedObject.new()
  end

  defp hash_framed_triples(triples, domain) do
    Enum.reduce(
      triples,
      :crypto.hash_init(:sha256) |> :crypto.hash_update(domain),
      fn {path, mode, oid}, acc ->
        :crypto.hash_update(acc, [
          <<byte_size(path)::unsigned-big-32>>,
          path,
          <<byte_size(mode)::unsigned-big-32>>,
          mode,
          <<byte_size(oid)::unsigned-big-32>>,
          oid
        ])
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp hash_ordered_maps(entries, domain, key_order) do
    Enum.reduce(
      entries,
      :crypto.hash_init(:sha256) |> :crypto.hash_update(domain),
      fn entry, acc ->
        framed =
          Enum.map(key_order, fn key ->
            frame_field(key, encode_field(Map.fetch!(entry, key)))
          end)

        :crypto.hash_update(acc, framed)
      end
    )
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp hash_comparison(comparison) do
    with {:ok, failures} <- sort_failures(Map.fetch!(comparison, "failures")) do
      failures_digest =
        hash_ordered_maps(failures, @comparison_failures_domain, @failure_key_order)

      digest =
        :crypto.hash_init(:sha256)
        |> :crypto.hash_update(@comparison_domain)
        |> :crypto.hash_update([
          frame_field("status", encode_field(Map.fetch!(comparison, "status"))),
          frame_field(
            "failure_count",
            encode_field(Map.fetch!(comparison, "failure_count"))
          ),
          frame_field("failures_digest", failures_digest)
        ])
        |> :crypto.hash_final()
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  defp frame_field(key, encoded) do
    [
      <<byte_size(key)::unsigned-big-32>>,
      key,
      <<byte_size(encoded)::unsigned-big-32>>,
      encoded
    ]
  end

  # Only ever called with pre-validated primitive types (string / integer /
  # boolean / list-of-strings). No catch-all clause: an unexpected shape is
  # an internal defect and must crash loudly rather than silently render via
  # `inspect/1` into a persisted digest.
  defp encode_field(v) when is_binary(v), do: v
  defp encode_field(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_field(v) when is_boolean(v), do: if(v, do: "true", else: "false")

  defp encode_field(list) when is_list(list) do
    list
    |> Enum.sort()
    |> Enum.map_join("\0", &encode_field/1)
  end
end
