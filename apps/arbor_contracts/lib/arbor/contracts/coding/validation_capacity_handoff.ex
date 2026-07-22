defmodule Arbor.Contracts.Coding.ValidationCapacityHandoff do
  @moduledoc """
  Closed, bounded evidence for a coding-validation capacity handoff.

  The handoff binds the exact ordered unstarted inventory through per-batch
  path digests and a recomputable ordered-plan digest. Filenames remain in the
  retained workspace and authorized inventory; they are intentionally absent
  from terminal evidence.
  """

  use TypedStruct

  @schema_version 1
  @phases ~w(structural runtime)
  @fields [
    :schema_version,
    :phase,
    :available_budget_ms,
    :per_batch_budget_ms,
    :required_budget_ms,
    :completed_batch_count,
    :completed_file_count,
    :unstarted_batch_count,
    :unstarted_file_count,
    :total_batch_count,
    :total_file_count,
    :ordered_plan_sha256,
    :unstarted_batches
  ]
  @batch_fields [:index, :total, :count, :label, :inventory_sha256]
  # These bounds mirror CrossApp's closed maxima without introducing a
  # contracts -> actions dependency. With 2,000 files, 256 app test roots, and
  # at most 20 files per batch, the worst distribution is 255 singleton roots
  # plus 1,745 files in one root: 255 + ceil(1,745 / 20) = 343 batches.
  @max_file_count 2_000
  @max_test_roots 256
  @max_batch_files 20
  @max_batch_count @max_test_roots + div(@max_file_count - @max_test_roots - 1, @max_batch_files)
  @max_operation_timeout_ms 1_200_000
  @max_budget_ms @max_batch_count * @max_operation_timeout_ms
  @max_label_bytes 256
  @max_json_bytes 256_000
  @sha256_regex ~r/\A[0-9a-f]{64}\z/

  typedstruct enforce: true do
    @typedoc "Bounded, authority-free validation capacity evidence."

    field(:schema_version, pos_integer())
    field(:phase, String.t())
    field(:available_budget_ms, non_neg_integer())
    field(:per_batch_budget_ms, pos_integer())
    field(:required_budget_ms, pos_integer())
    field(:completed_batch_count, non_neg_integer())
    field(:completed_file_count, non_neg_integer())
    field(:unstarted_batch_count, pos_integer())
    field(:unstarted_file_count, pos_integer())
    field(:total_batch_count, pos_integer())
    field(:total_file_count, pos_integer())
    field(:ordered_plan_sha256, String.t())
    field(:unstarted_batches, [map()])
  end

  @doc "Return the accepted capacity-handoff schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Construct and validate a closed capacity handoff descriptor."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @fields, :invalid_capacity_handoff),
         :ok <- require_all_fields(attrs, @fields),
         :ok <- validate_schema_version(attrs.schema_version),
         {:ok, phase} <- enum(attrs.phase, @phases, :phase),
         {:ok, available} <-
           bounded_integer(attrs.available_budget_ms, :available_budget_ms, @max_budget_ms),
         {:ok, per_batch} <-
           bounded_positive_integer(
             attrs.per_batch_budget_ms,
             :per_batch_budget_ms,
             @max_operation_timeout_ms
           ),
         {:ok, required} <-
           bounded_positive_integer(attrs.required_budget_ms, :required_budget_ms, @max_budget_ms),
         {:ok, completed_batches} <-
           bounded_integer(attrs.completed_batch_count, :completed_batch_count, @max_batch_count),
         {:ok, completed_files} <-
           bounded_integer(attrs.completed_file_count, :completed_file_count, @max_file_count),
         {:ok, unstarted_batch_count} <-
           bounded_positive_integer(
             attrs.unstarted_batch_count,
             :unstarted_batch_count,
             @max_batch_count
           ),
         {:ok, unstarted_file_count} <-
           bounded_positive_integer(
             attrs.unstarted_file_count,
             :unstarted_file_count,
             @max_file_count
           ),
         {:ok, total_batch_count} <-
           bounded_positive_integer(attrs.total_batch_count, :total_batch_count, @max_batch_count),
         {:ok, total_file_count} <-
           bounded_positive_integer(attrs.total_file_count, :total_file_count, @max_file_count),
         {:ok, ordered_plan_sha256} <- digest(attrs.ordered_plan_sha256, :ordered_plan_sha256),
         {:ok, batches} <- normalize_batches(attrs.unstarted_batches),
         :ok <-
           validate_invariants(
             phase,
             available,
             per_batch,
             required,
             completed_batches,
             completed_files,
             unstarted_batch_count,
             unstarted_file_count,
             total_batch_count,
             total_file_count,
             batches
           ),
         true <- ordered_plan_sha256 == digest_for_normalized_batches(batches) do
      descriptor = %__MODULE__{
        schema_version: @schema_version,
        phase: phase,
        available_budget_ms: available,
        per_batch_budget_ms: per_batch,
        required_budget_ms: required,
        completed_batch_count: completed_batches,
        completed_file_count: completed_files,
        unstarted_batch_count: unstarted_batch_count,
        unstarted_file_count: unstarted_file_count,
        total_batch_count: total_batch_count,
        total_file_count: total_file_count,
        ordered_plan_sha256: ordered_plan_sha256,
        unstarted_batches: batches
      }

      if byte_size(Jason.encode!(to_map(descriptor))) <= @max_json_bytes do
        {:ok, descriptor}
      else
        {:error, {:invalid_capacity_handoff, :too_large}}
      end
    else
      false -> {:error, {:invalid_capacity_handoff, :ordered_plan_digest_mismatch}}
      {:error, _reason} = error -> error
    end
  rescue
    _ -> {:error, {:invalid_capacity_handoff, :malformed}}
  catch
    _, _ -> {:error, {:invalid_capacity_handoff, :malformed}}
  end

  @doc "Return the canonical closed string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = descriptor) do
    %{
      "schema_version" => descriptor.schema_version,
      "phase" => descriptor.phase,
      "available_budget_ms" => descriptor.available_budget_ms,
      "per_batch_budget_ms" => descriptor.per_batch_budget_ms,
      "required_budget_ms" => descriptor.required_budget_ms,
      "completed_batch_count" => descriptor.completed_batch_count,
      "completed_file_count" => descriptor.completed_file_count,
      "unstarted_batch_count" => descriptor.unstarted_batch_count,
      "unstarted_file_count" => descriptor.unstarted_file_count,
      "total_batch_count" => descriptor.total_batch_count,
      "total_file_count" => descriptor.total_file_count,
      "ordered_plan_sha256" => descriptor.ordered_plan_sha256,
      "unstarted_batches" => Enum.map(descriptor.unstarted_batches, &batch_to_map/1)
    }
  end

  @doc "Normalize a capacity handoff directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, descriptor} <- new(attrs), do: {:ok, to_map(descriptor)}
  end

  @doc "Return true only for a complete, valid capacity handoff."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = descriptor), do: match?({:ok, _}, new(to_map(descriptor)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @doc "Compute the canonical ordered-plan digest for compact batch descriptors."
  @spec ordered_plan_digest([map()]) :: {:ok, String.t()} | {:error, term()}
  def ordered_plan_digest(batches) when is_list(batches) do
    with {:ok, normalized} <- normalize_batches(batches) do
      {:ok, digest_for_normalized_batches(normalized)}
    end
  rescue
    _ -> {:error, {:invalid_capacity_handoff, :malformed_batches}}
  end

  def ordered_plan_digest(_batches),
    do: {:error, {:invalid_capacity_handoff, :malformed_batches}}

  defp validate_invariants(
         phase,
         available,
         per_batch,
         required,
         completed_batches,
         completed_files,
         unstarted_batch_count,
         unstarted_file_count,
         total_batch_count,
         total_file_count,
         batches
       ) do
    batch_counts = Enum.map(batches, & &1.count)

    cond do
      required <= available ->
        {:error, {:invalid_capacity_handoff, :capacity_not_exceeded}}

      phase == "structural" and (completed_batches != 0 or completed_files != 0) ->
        {:error, {:invalid_capacity_handoff, :structural_completed_counts}}

      required != unstarted_batch_count * per_batch ->
        {:error, {:invalid_capacity_handoff, :required_budget_mismatch}}

      completed_batches + unstarted_batch_count != total_batch_count ->
        {:error, {:invalid_capacity_handoff, :batch_count_mismatch}}

      completed_files + unstarted_file_count != total_file_count ->
        {:error, {:invalid_capacity_handoff, :file_count_mismatch}}

      length(batches) != unstarted_batch_count ->
        {:error, {:invalid_capacity_handoff, :unstarted_batch_count_mismatch}}

      Enum.sum(batch_counts) != unstarted_file_count ->
        {:error, {:invalid_capacity_handoff, :unstarted_file_count_mismatch}}

      Enum.any?(batches, &(&1.total != total_batch_count)) ->
        {:error, {:invalid_capacity_handoff, :batch_total_mismatch}}

      not contiguous_suffix?(batches, completed_batches, total_batch_count) ->
        {:error, {:invalid_capacity_handoff, :batch_index_mismatch}}

      true ->
        :ok
    end
  end

  defp contiguous_suffix?([first | rest], completed_count, total) do
    first.index == completed_count + 1 and
      Enum.with_index([first | rest], 0)
      |> Enum.all?(fn {batch, offset} -> batch.index == completed_count + 1 + offset end) and
      first.index + length(rest) == total
  end

  defp contiguous_suffix?(_, _, _), do: false

  defp normalize_batches(batches) when is_list(batches) do
    entries = Enum.take(batches, @max_batch_count + 1)

    if length(entries) > @max_batch_count or not proper_list?(batches) do
      {:error, {:invalid_capacity_handoff, :too_many_batches}}
    else
      Enum.reduce_while(entries, {:ok, []}, fn batch, {:ok, acc} ->
        case normalize_batch(batch) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize_batches(_batches),
    do: {:error, {:invalid_capacity_handoff, :batches_required}}

  defp normalize_batch(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @batch_fields, :invalid_capacity_batch),
         :ok <- require_all_fields(attrs, @batch_fields),
         {:ok, index} <- bounded_positive_integer(attrs.index, :index, @max_batch_count),
         {:ok, total} <- bounded_positive_integer(attrs.total, :total, @max_batch_count),
         {:ok, count} <- bounded_positive_integer(attrs.count, :count, @max_batch_files),
         {:ok, label} <- bounded_text(attrs.label, :label),
         {:ok, inventory_sha256} <- digest(attrs.inventory_sha256, :inventory_sha256),
         true <- label == expected_label(index, total, count, inventory_sha256) do
      {:ok,
       %{
         index: index,
         total: total,
         count: count,
         label: label,
         inventory_sha256: inventory_sha256
       }}
    else
      false -> {:error, {:invalid_capacity_batch, :label_mismatch}}
      {:error, _reason} = error -> error
    end
  end

  defp batch_to_map(batch) do
    %{
      "index" => batch.index,
      "total" => batch.total,
      "count" => batch.count,
      "label" => batch.label,
      "inventory_sha256" => batch.inventory_sha256
    }
  end

  defp expected_label(index, total, count, inventory_sha256),
    do: "batch-#{index}-of-#{total}-n#{count}-#{inventory_sha256}"

  defp digest_for_normalized_batches(batches) do
    batches
    |> Enum.map(&batch_to_map/1)
    |> canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value), do: Jason.encode!(canonicalize(value))

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {key, canonicalize(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(value), do: value

  defp normalize_object(attrs, fields, error_tag) when is_map(attrs) do
    if map_size(attrs) <= length(fields),
      do: normalize_entries(attrs, fields, error_tag),
      else: {:error, {error_tag, :unknown_key}}
  end

  defp normalize_object(attrs, fields, error_tag) when is_list(attrs) do
    entries = Enum.take(attrs, length(fields) + 1)

    cond do
      not proper_list?(attrs) -> {:error, {error_tag, :malformed}}
      length(entries) > length(fields) -> {:error, {error_tag, :unknown_key}}
      Enum.all?(entries, &match?({_, _}, &1)) -> normalize_entries(entries, fields, error_tag)
      true -> {:error, {error_tag, :object_required}}
    end
  end

  defp normalize_object(_attrs, _fields, error_tag),
    do: {:error, {error_tag, :object_required}}

  defp normalize_entries(entries, fields, error_tag) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case normalize_key(key, fields) do
        {:ok, canonical} when not is_map_key(normalized, canonical) ->
          {:cont, {:ok, Map.put(normalized, canonical, value)}}

        {:ok, _canonical} ->
          {:halt, {:error, {error_tag, :duplicate_key}}}

        :error ->
          {:halt, {:error, {error_tag, :unknown_key}}}
      end
    end)
  end

  defp normalize_key(key, fields) when is_atom(key) do
    if key in fields, do: {:ok, key}, else: :error
  end

  defp normalize_key(key, fields) when is_binary(key) do
    Enum.find_value(fields, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp normalize_key(_key, _fields), do: :error

  defp require_all_fields(attrs, fields) do
    case Enum.find(fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:invalid_capacity_handoff, {:missing_field, Atom.to_string(field)}}}
    end
  end

  defp validate_schema_version(@schema_version), do: :ok
  defp validate_schema_version(_), do: {:error, {:invalid_capacity_handoff, :schema_version}}

  defp enum(value, allowed, field) when is_atom(value),
    do: enum(Atom.to_string(value), allowed, field)

  defp enum(value, allowed, field) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_capacity_handoff, field}}
  end

  defp bounded_integer(value, _field, max)
       when is_integer(value) and not is_boolean(value) and value >= 0 and value <= max,
       do: {:ok, value}

  defp bounded_integer(_value, field, _max),
    do: {:error, {:invalid_capacity_handoff, field}}

  defp bounded_positive_integer(value, _field, max)
       when is_integer(value) and not is_boolean(value) and value > 0 and value <= max,
       do: {:ok, value}

  defp bounded_positive_integer(_value, field, _max),
    do: {:error, {:invalid_capacity_handoff, field}}

  defp bounded_text(value, _field)
       when is_binary(value) and byte_size(value) <= @max_label_bytes and value != "" do
    if String.valid?(value), do: {:ok, value}, else: {:error, {:invalid_capacity_handoff, :label}}
  end

  defp bounded_text(_value, field), do: {:error, {:invalid_capacity_handoff, field}}

  defp digest(value, field) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@sha256_regex, value),
      do: {:ok, value},
      else: {:error, {:invalid_capacity_handoff, field}}
  end

  defp digest(_value, field), do: {:error, {:invalid_capacity_handoff, field}}

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false
end
