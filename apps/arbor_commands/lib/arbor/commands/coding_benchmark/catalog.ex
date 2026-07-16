defmodule Arbor.Commands.CodingBenchmark.Catalog do
  @moduledoc """
  Pure validation and normalization for the closed coding-benchmark catalog v1.

  Catalogs are data-only: they pin fixture identity, Git OIDs, task input, and a
  verifier selector. They never name modules, functions, commands, or other
  executable surfaces.
  """

  @schema "arbor.coding_benchmark.catalog.v1"
  @publication_schema "arbor.coding_benchmark.publication.v1"
  @target_evidence_schema "arbor.coding_benchmark.target_evidence.v1"
  @max_catalog_bytes 1_048_576
  @max_fixtures 20
  @max_seed 2_147_483_647
  @max_objective_bytes 32_000
  @max_criterion_bytes 4_000
  @max_criteria 100
  @oid_pattern ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @id_pattern ~r/\A[a-z0-9][a-z0-9._-]{0,63}\z/
  @source_id_pattern ~r/\A[a-z0-9][a-z0-9._-]{0,63}(?:\/[a-z0-9][a-z0-9._-]{0,63})?\z/

  @type json_map :: %{optional(String.t()) => term()}

  @doc "Return the accepted catalog schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Return the maximum canonical catalog size accepted by v1."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_catalog_bytes

  @doc "Validate and normalize a closed coding-benchmark catalog."
  @spec validate(term()) :: {:ok, json_map()} | {:error, json_map()}
  def validate(catalog) when is_map(catalog) and not is_struct(catalog) do
    with :ok <-
           closed_map(
             catalog,
             ~w(schema seed source_repository_label fixtures),
             ~w(schema seed source_repository_label fixtures),
             "catalog"
           ),
         :ok <- exact_value(catalog["schema"], @schema, "catalog.schema"),
         {:ok, seed} <- bounded_integer(catalog["seed"], 0, @max_seed, "catalog.seed"),
         {:ok, source_repository_label} <-
           source_repository_label(
             catalog["source_repository_label"],
             "catalog.source_repository_label"
           ),
         {:ok, fixtures} <- fixtures(catalog["fixtures"]),
         :ok <- unique_fixture_ids(fixtures),
         :ok <- unique_transitions(fixtures),
         normalized = %{
           "fixtures" => fixtures,
           "schema" => @schema,
           "seed" => seed,
           "source_repository_label" => source_repository_label
         },
         :ok <- bounded_catalog_size(normalized) do
      {:ok, normalized}
    end
  end

  def validate(_catalog), do: invalid("catalog", "expected_object")

  @doc "SHA-256 digest of the canonical JSON encoding of a normalized catalog."
  @spec digest(json_map()) :: String.t()
  def digest(catalog) when is_map(catalog), do: canonical_digest(catalog)

  @doc false
  @spec canonical_digest(term()) :: String.t()
  def canonical_digest(value) do
    value
    |> canonical_encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec canonical_encode(term()) :: binary()
  def canonical_encode(value) do
    value
    |> canonical_json()
    |> IO.iodata_to_binary()
  end

  @doc "Validate the closed publication sidecars against their manifest."
  @spec validate_publication(json_map(), json_map(), json_map(), json_map()) ::
          :ok | {:error, json_map()}
  def validate_publication(manifest, normalized_manifest, target_evidence, publication)
      when is_map(manifest) and not is_struct(manifest) and is_map(normalized_manifest) and
             not is_struct(normalized_manifest) and is_map(target_evidence) and
             not is_struct(target_evidence) and is_map(publication) and
             not is_struct(publication) do
    with :ok <-
           publication_closed_map(
             publication,
             ~w(schema catalog_digest manifest_digest target_evidence_digest),
             "publication"
           ),
         :ok <-
           publication_exact_value(
             publication["schema"],
             @publication_schema,
             "publication.schema"
           ),
         :ok <- publication_digest(publication["catalog_digest"], "publication.catalog_digest"),
         :ok <-
           publication_digest(publication["manifest_digest"], "publication.manifest_digest"),
         :ok <-
           publication_digest(
             publication["target_evidence_digest"],
             "publication.target_evidence_digest"
           ),
         :ok <-
           publication_closed_map(
             target_evidence,
             ~w(schema catalog_digest manifest_digest source_repository_label fixtures),
             "target_evidence"
           ),
         :ok <-
           publication_exact_value(
             target_evidence["schema"],
             @target_evidence_schema,
             "target_evidence.schema"
           ),
         :ok <-
           publication_digest(
             target_evidence["catalog_digest"],
             "target_evidence.catalog_digest"
           ),
         :ok <-
           publication_digest(
             target_evidence["manifest_digest"],
             "target_evidence.manifest_digest"
           ),
         :ok <-
           publication_source_label(
             target_evidence["source_repository_label"],
             "target_evidence.source_repository_label"
           ),
         :ok <-
           publication_fixtures(
             target_evidence["fixtures"],
             normalized_manifest["fixtures"]
           ),
         :ok <-
           publication_matches(
             publication["manifest_digest"],
             canonical_digest(manifest),
             "publication.manifest_digest"
           ),
         :ok <-
           publication_matches(
             publication["target_evidence_digest"],
             canonical_digest(target_evidence),
             "publication.target_evidence_digest"
           ),
         :ok <-
           publication_matches(
             publication["catalog_digest"],
             target_evidence["catalog_digest"],
             "publication.catalog_digest"
           ),
         :ok <-
           publication_matches(
             publication["manifest_digest"],
             target_evidence["manifest_digest"],
             "target_evidence.manifest_digest"
           ) do
      :ok
    end
  end

  def validate_publication(_manifest, _normalized_manifest, _target_evidence, _publication),
    do: invalid_publication("publication", "expected_objects")

  defp fixtures([]), do: invalid("catalog.fixtures", "empty_list")
  defp fixtures([_head | _tail] = fixtures), do: collect_fixtures(fixtures, 0, [])
  defp fixtures(_fixtures), do: invalid("catalog.fixtures", "expected_list")

  defp collect_fixtures([], _index, acc) do
    {:ok, acc |> Enum.reverse() |> Enum.sort_by(& &1["fixture_id"])}
  end

  defp collect_fixtures([_head | _tail], @max_fixtures, _acc),
    do: invalid("catalog.fixtures", "too_many_items")

  defp collect_fixtures([fixture | tail], index, acc) do
    case fixture(fixture, index) do
      {:ok, normalized} -> collect_fixtures(tail, index + 1, [normalized | acc])
      {:error, _reason} = error -> error
    end
  end

  defp collect_fixtures(_improper_tail, _index, _acc),
    do: invalid("catalog.fixtures", "expected_list")

  defp fixture(fixture, index) when is_map(fixture) and not is_struct(fixture) do
    field = "catalog.fixtures[#{index}]"

    with :ok <-
           closed_map(
             fixture,
             ~w(fixture_id base_commit_oid base_tree_oid target_commit_oid target_tree_oid input verifier_id),
             ~w(fixture_id base_commit_oid base_tree_oid target_commit_oid target_tree_oid input verifier_id),
             field
           ),
         {:ok, fixture_id} <- identifier(fixture["fixture_id"], "#{field}.fixture_id"),
         {:ok, base_commit_oid} <- oid(fixture["base_commit_oid"], "#{field}.base_commit_oid"),
         {:ok, base_tree_oid} <- oid(fixture["base_tree_oid"], "#{field}.base_tree_oid"),
         {:ok, target_commit_oid} <-
           oid(fixture["target_commit_oid"], "#{field}.target_commit_oid"),
         {:ok, target_tree_oid} <- oid(fixture["target_tree_oid"], "#{field}.target_tree_oid"),
         :ok <-
           same_object_format(
             [base_commit_oid, base_tree_oid, target_commit_oid, target_tree_oid],
             field
           ),
         :ok <-
           distinct_oids(
             base_commit_oid,
             target_commit_oid,
             "#{field}.target_commit_oid",
             "base_and_target_commit_identical"
           ),
         :ok <-
           distinct_oids(
             base_tree_oid,
             target_tree_oid,
             "#{field}.target_tree_oid",
             "base_and_target_tree_identical"
           ),
         {:ok, input} <- input(fixture["input"], "#{field}.input"),
         {:ok, verifier_id} <- identifier(fixture["verifier_id"], "#{field}.verifier_id") do
      {:ok,
       %{
         "base_commit_oid" => base_commit_oid,
         "base_tree_oid" => base_tree_oid,
         "fixture_id" => fixture_id,
         "input" => input,
         "target_commit_oid" => target_commit_oid,
         "target_tree_oid" => target_tree_oid,
         "verifier_id" => verifier_id
       }}
    end
  end

  defp fixture(_fixture, index), do: invalid("catalog.fixtures[#{index}]", "expected_object")

  defp input(input, field) when is_map(input) and not is_struct(input) do
    with :ok <-
           closed_map(
             input,
             ~w(objective acceptance_criteria),
             ~w(objective acceptance_criteria),
             field
           ),
         {:ok, objective} <-
           normalized_text(input["objective"], 1, @max_objective_bytes, "#{field}.objective"),
         {:ok, criteria} <-
           criteria(input["acceptance_criteria"], "#{field}.acceptance_criteria") do
      {:ok, %{"acceptance_criteria" => criteria, "objective" => objective}}
    end
  end

  defp input(_input, field), do: invalid(field, "expected_object")

  defp criteria([], field), do: invalid(field, "empty_list")

  defp criteria([_head | _tail] = criteria, field) do
    with {:ok, normalized} <- collect_criteria(criteria, field, 0, []),
         :ok <- unique_criteria(normalized, field) do
      {:ok, normalized}
    end
  end

  defp criteria(_criteria, field), do: invalid(field, "invalid_list")

  defp collect_criteria([], _field, _index, acc), do: {:ok, Enum.reverse(acc)}

  defp collect_criteria([_head | _tail], field, @max_criteria, _acc),
    do: invalid(field, "too_many_items")

  defp collect_criteria([criterion | tail], field, index, acc) do
    case normalized_text(criterion, 1, @max_criterion_bytes, "#{field}[#{index}]") do
      {:ok, normalized} -> collect_criteria(tail, field, index + 1, [normalized | acc])
      {:error, _reason} = error -> error
    end
  end

  defp collect_criteria(_improper_tail, field, _index, _acc), do: invalid(field, "invalid_list")

  defp distinct_oids(left, right, _field, _reason) when left != right, do: :ok
  defp distinct_oids(_left, _right, field, reason), do: invalid(field, reason)

  defp same_object_format(oids, field) do
    case oids |> Enum.map(&byte_size/1) |> Enum.uniq() do
      [_one_size] -> :ok
      _mixed -> invalid(field, "mixed_object_formats")
    end
  end

  defp unique_criteria(criteria, field) do
    if length(criteria) == length(Enum.uniq(criteria)),
      do: :ok,
      else: invalid(field, "duplicate_criterion")
  end

  defp unique_fixture_ids(fixtures) do
    ids = Enum.map(fixtures, & &1["fixture_id"])

    if length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: invalid("catalog.fixtures", "duplicate_fixture_id")
  end

  defp unique_transitions(fixtures) do
    transitions = Enum.map(fixtures, &{&1["base_commit_oid"], &1["target_commit_oid"]})

    if length(transitions) == length(Enum.uniq(transitions)),
      do: :ok,
      else: invalid("catalog.fixtures", "duplicate_transition")
  end

  defp source_repository_label(value, field) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) and
         Regex.match?(@source_id_pattern, value),
       do: {:ok, value},
       else: invalid(field, "invalid_id")
  end

  defp source_repository_label(_value, field), do: invalid(field, "expected_string")

  defp identifier(value, field) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) and
         Regex.match?(@id_pattern, value),
       do: {:ok, value},
       else: invalid(field, "invalid_id")
  end

  defp identifier(_value, field), do: invalid(field, "expected_string")

  defp oid(value, field) when is_binary(value) do
    if byte_size(value) <= 66 and String.valid?(value) and not String.contains?(value, <<0>>) do
      normalized = value |> String.trim() |> String.downcase()

      if Regex.match?(@oid_pattern, normalized),
        do: {:ok, normalized},
        else: invalid(field, "invalid_oid")
    else
      invalid(field, "invalid_oid")
    end
  end

  defp oid(_value, field), do: invalid(field, "expected_oid")

  defp normalized_text(value, min, max, field) when is_binary(value) do
    if byte_size(value) <= max * 2 and String.valid?(value) and
         not String.contains?(value, <<0>>) do
      normalized = value |> String.replace("\r\n", "\n") |> String.trim()

      if byte_size(normalized) in min..max,
        do: {:ok, normalized},
        else: invalid(field, "invalid_text")
    else
      invalid(field, "invalid_text")
    end
  end

  defp normalized_text(_value, _min, _max, field), do: invalid(field, "expected_string")

  defp bounded_integer(value, min, max, _field)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp bounded_integer(_value, _min, _max, field), do: invalid(field, "out_of_bounds")

  defp bounded_catalog_size(catalog) do
    if catalog |> canonical_json() |> :erlang.iolist_size() <= @max_catalog_bytes,
      do: :ok,
      else: invalid("catalog", "too_large")
  end

  defp closed_map(map, allowed, required, field) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        invalid(field, "non_string_key")

      Enum.any?(keys, &(&1 not in allowed)) ->
        invalid(field, "unknown_field")

      Enum.any?(required, &(not Map.has_key?(map, &1))) ->
        invalid(field, "missing_field")

      true ->
        :ok
    end
  end

  defp exact_value(value, value, _field), do: :ok
  defp exact_value(_actual, _expected, field), do: invalid(field, "unsupported_schema")

  defp invalid(field, reason) do
    {:error,
     %{
       "error" => "invalid_coding_benchmark_catalog",
       "field" => field,
       "reason" => reason
     }}
  end

  defp publication_fixtures(evidence, normalized_fixtures)
       when is_map(evidence) and not is_struct(evidence) and is_list(normalized_fixtures) do
    expected =
      Map.new(normalized_fixtures, fn fixture ->
        {fixture["fixture_id"],
         %{
           "base_tree_oid" => fixture["base_tree_oid"],
           "normalized_input_hash" => fixture["normalized_input_hash"]
         }}
      end)

    evidence_ids = evidence |> Map.keys() |> Enum.sort()
    expected_ids = expected |> Map.keys() |> Enum.sort()

    if evidence_ids == expected_ids do
      Enum.reduce_while(evidence, :ok, fn {fixture_id, fixture}, :ok ->
        case publication_fixture(fixture_id, fixture, Map.fetch!(expected, fixture_id)) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    else
      invalid_publication("target_evidence.fixtures", "fixture_set_mismatch")
    end
  rescue
    _exception -> invalid_publication("target_evidence.fixtures", "invalid_manifest_fixtures")
  end

  defp publication_fixtures(_evidence, _normalized_fixtures),
    do: invalid_publication("target_evidence.fixtures", "expected_object")

  defp publication_fixture(fixture_id, fixture, expected)
       when is_binary(fixture_id) and is_map(fixture) and not is_struct(fixture) do
    field = "target_evidence.fixtures.#{fixture_id}"

    with :ok <-
           publication_closed_map(
             fixture,
             ~w(base_commit_oid base_tree_oid normalized_input_hash target_commit_oid target_tree_oid),
             field
           ),
         :ok <- publication_oid(fixture["base_commit_oid"], "#{field}.base_commit_oid"),
         :ok <- publication_oid(fixture["base_tree_oid"], "#{field}.base_tree_oid"),
         :ok <-
           publication_digest(
             fixture["normalized_input_hash"],
             "#{field}.normalized_input_hash"
           ),
         :ok <- publication_oid(fixture["target_commit_oid"], "#{field}.target_commit_oid"),
         :ok <- publication_oid(fixture["target_tree_oid"], "#{field}.target_tree_oid"),
         :ok <-
           publication_same_object_format(
             [
               fixture["base_commit_oid"],
               fixture["base_tree_oid"],
               fixture["target_commit_oid"],
               fixture["target_tree_oid"]
             ],
             field
           ),
         :ok <-
           publication_distinct(
             fixture["base_commit_oid"],
             fixture["target_commit_oid"],
             "#{field}.target_commit_oid"
           ),
         :ok <-
           publication_distinct(
             fixture["base_tree_oid"],
             fixture["target_tree_oid"],
             "#{field}.target_tree_oid"
           ),
         :ok <-
           publication_matches(
             fixture["base_tree_oid"],
             expected["base_tree_oid"],
             "#{field}.base_tree_oid"
           ),
         :ok <-
           publication_matches(
             fixture["normalized_input_hash"],
             expected["normalized_input_hash"],
             "#{field}.normalized_input_hash"
           ) do
      :ok
    end
  end

  defp publication_fixture(fixture_id, _fixture, _expected),
    do: invalid_publication("target_evidence.fixtures.#{fixture_id}", "expected_object")

  defp publication_closed_map(map, keys, field) do
    actual_keys = Map.keys(map)

    cond do
      Enum.any?(actual_keys, &(not is_binary(&1))) ->
        invalid_publication(field, "non_string_key")

      Enum.sort(actual_keys) != Enum.sort(keys) ->
        invalid_publication(field, "closed_schema_mismatch")

      true ->
        :ok
    end
  end

  defp publication_exact_value(value, value, _field), do: :ok

  defp publication_exact_value(_actual, _expected, field),
    do: invalid_publication(field, "unsupported_schema")

  defp publication_digest(value, field) when is_binary(value) do
    if Regex.match?(@digest_pattern, value),
      do: :ok,
      else: invalid_publication(field, "invalid_digest")
  end

  defp publication_digest(_value, field), do: invalid_publication(field, "invalid_digest")

  defp publication_oid(value, field) when is_binary(value) do
    if Regex.match?(@oid_pattern, value),
      do: :ok,
      else: invalid_publication(field, "invalid_oid")
  end

  defp publication_oid(_value, field), do: invalid_publication(field, "invalid_oid")

  defp publication_same_object_format(oids, field) do
    case oids |> Enum.map(&byte_size/1) |> Enum.uniq() do
      [_one_size] -> :ok
      _mixed -> invalid_publication(field, "mixed_object_formats")
    end
  end

  defp publication_distinct(left, right, _field) when left != right, do: :ok

  defp publication_distinct(_left, _right, field),
    do: invalid_publication(field, "base_and_target_identical")

  defp publication_source_label(value, field) when is_binary(value) do
    if Regex.match?(@source_id_pattern, value),
      do: :ok,
      else: invalid_publication(field, "invalid_id")
  end

  defp publication_source_label(_value, field), do: invalid_publication(field, "invalid_id")

  defp publication_matches(value, value, _field), do: :ok

  defp publication_matches(_actual, _expected, field),
    do: invalid_publication(field, "digest_or_binding_mismatch")

  defp invalid_publication(field, reason) do
    {:error,
     %{
       "error" => "invalid_coding_benchmark_publication",
       "field" => field,
       "reason" => reason
     }}
  end

  defp canonical_json(nil), do: "null"
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(value) when is_binary(value), do: Jason.encode_to_iodata!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: Jason.encode_to_iodata!(value)

  defp canonical_json(value) when is_list(value) do
    ["[", value |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, item} -> [Jason.encode_to_iodata!(key), ":", canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end
end
