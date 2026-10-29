defmodule Arbor.Contracts.Coding.BranchLifecycleDescriptor do
  @moduledoc """
  Closed, authority-free evidence for the lifecycle of a coding branch.

  This descriptor deliberately contains no workspace, task, principal,
  filesystem, callback, command, replay, or mutation authority.
  """

  use TypedStruct

  @branch_statuses ~w(preserved retired pending)
  @cleanup_statuses ~w(complete retrying dormant)
  @discard_phases ~w(archive worktree branch)
  @fields [
    :branch_status,
    :cleanup_status,
    :branch_preserved_reason,
    :cleanup_retry_count,
    :cleanup_retry_limit,
    :cleanup_failure_category,
    :discard_phase,
    :evidence_ref,
    :published_commit
  ]
  @max_fields length(@fields)
  @max_text_bytes 256
  @max_retry_count 32
  @max_retry_limit 32
  @oid_regex ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  typedstruct enforce: true do
    @typedoc "Bounded branch lifecycle evidence without execution authority."

    field(:branch_status, String.t())
    field(:cleanup_status, String.t())
    field(:branch_preserved_reason, String.t() | nil, default: nil)
    field(:cleanup_retry_count, non_neg_integer() | nil, default: nil)
    field(:cleanup_retry_limit, pos_integer() | nil, default: nil)
    field(:cleanup_failure_category, String.t() | nil, default: nil)
    field(:discard_phase, String.t() | nil, default: nil)
    field(:evidence_ref, String.t() | nil, default: nil)
    field(:published_commit, String.t() | nil, default: nil)
  end

  @doc "Construct and validate a closed branch lifecycle descriptor."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs),
         {:ok, branch_status} <- required_enum(attrs, :branch_status, @branch_statuses),
         {:ok, cleanup_status} <- required_enum(attrs, :cleanup_status, @cleanup_statuses),
         {:ok, branch_preserved_reason} <- optional_text(attrs, :branch_preserved_reason),
         {:ok, retry_count} <- optional_integer(attrs, :cleanup_retry_count, @max_retry_count),
         {:ok, retry_limit} <-
           optional_positive_integer(attrs, :cleanup_retry_limit, @max_retry_limit),
         {:ok, cleanup_failure_category} <-
           optional_category(attrs, :cleanup_failure_category),
         {:ok, discard_phase} <- optional_enum(attrs, :discard_phase, @discard_phases),
         {:ok, evidence_ref} <- optional_evidence_ref(attrs),
         {:ok, published_commit} <- optional_oid(attrs, :published_commit),
         :ok <-
           validate_invariants(
             branch_status,
             cleanup_status,
             branch_preserved_reason,
             retry_count,
             retry_limit,
             cleanup_failure_category,
             discard_phase
           ) do
      {:ok,
       %__MODULE__{
         branch_status: branch_status,
         cleanup_status: cleanup_status,
         branch_preserved_reason: branch_preserved_reason,
         cleanup_retry_count: retry_count,
         cleanup_retry_limit: retry_limit,
         cleanup_failure_category: cleanup_failure_category,
         discard_phase: discard_phase,
         evidence_ref: evidence_ref,
         published_commit: published_commit
       }}
    end
  rescue
    _ -> {:error, {:invalid_branch_lifecycle_descriptor, :malformed}}
  catch
    _, _ -> {:error, {:invalid_branch_lifecycle_descriptor, :malformed}}
  end

  @doc "Return the canonical closed string-keyed JSON representation."
  @spec to_map(t()) :: %{required(String.t()) => term()}
  def to_map(%__MODULE__{} = descriptor) do
    %{
      "branch_status" => descriptor.branch_status,
      "cleanup_status" => descriptor.cleanup_status
    }
    |> maybe_put("branch_preserved_reason", descriptor.branch_preserved_reason)
    |> maybe_put("cleanup_retry_count", descriptor.cleanup_retry_count)
    |> maybe_put("cleanup_retry_limit", descriptor.cleanup_retry_limit)
    |> maybe_put("cleanup_failure_category", descriptor.cleanup_failure_category)
    |> maybe_put("discard_phase", descriptor.discard_phase)
    |> maybe_put("evidence_ref", descriptor.evidence_ref)
    |> maybe_put("published_commit", descriptor.published_commit)
  end

  @doc "Normalize a descriptor object directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, descriptor} <- new(attrs), do: {:ok, to_map(descriptor)}
  end

  @doc "Return true only for a complete valid descriptor or struct."
  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = descriptor), do: match?({:ok, _}, new(to_map(descriptor)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  defp normalize_object(attrs) when is_map(attrs) do
    if map_size(attrs) <= @max_fields, do: normalize_entries(attrs), else: too_large()
  end

  defp normalize_object(attrs) when is_list(attrs) do
    entries = Enum.take(attrs, @max_fields + 1)

    cond do
      length(entries) > @max_fields -> too_large()
      Enum.all?(entries, &match?({_, _}, &1)) -> normalize_entries(entries)
      true -> {:error, {:invalid_branch_lifecycle_descriptor, :object_required}}
    end
  end

  defp normalize_object(_), do: {:error, {:invalid_branch_lifecycle_descriptor, :object_required}}

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case normalize_key(key) do
        {:ok, canonical} ->
          if Map.has_key?(normalized, canonical) do
            {:halt, {:error, {:duplicate_field, Atom.to_string(canonical)}}}
          else
            {:cont, {:ok, Map.put(normalized, canonical, value)}}
          end

        :error ->
          {:halt, {:error, {:unknown_field, printable_key(key)}}}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: if(key in @fields, do: {:ok, key}, else: :error)

  defp normalize_key(key) when is_binary(key) do
    Enum.find_value(@fields, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp normalize_key(_), do: :error

  defp required_enum(attrs, field, allowed) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> normalize_enum(value, field, allowed)
      :error -> {:error, {:missing_field, Atom.to_string(field)}}
    end
  end

  defp optional_enum(attrs, field, allowed) do
    case Map.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> normalize_enum(value, field, allowed)
    end
  end

  defp normalize_enum(value, field, allowed) when is_atom(value),
    do: normalize_enum(Atom.to_string(value), field, allowed)

  defp normalize_enum(value, field, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, value}, else: {:error, {:invalid_field, field_name(field)}}
  end

  defp normalize_enum(_value, field, _allowed), do: {:error, {:invalid_field, field_name(field)}}

  defp optional_text(attrs, field) do
    case Map.fetch(attrs, field) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if safe_text?(value),
          do: {:ok, value},
          else: {:error, {:invalid_field, field_name(field)}}

      {:ok, _} ->
        {:error, {:invalid_field, field_name(field)}}
    end
  end

  defp optional_category(attrs, field) do
    with {:ok, value} <- optional_text(attrs, field) do
      if is_nil(value) or Regex.match?(~r/\A[a-z][a-z0-9_]{0,63}\z/, value),
        do: {:ok, value},
        else: {:error, {:invalid_field, field_name(field)}}
    end
  end

  defp optional_integer(attrs, field, maximum) do
    case Map.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value >= 0 and value <= maximum -> {:ok, value}
      {:ok, _} -> {:error, {:invalid_field, field_name(field)}}
    end
  end

  defp optional_positive_integer(attrs, field, maximum) do
    case Map.fetch(attrs, field) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_integer(value) and value > 0 and value <= maximum -> {:ok, value}
      {:ok, _} -> {:error, {:invalid_field, field_name(field)}}
    end
  end

  defp optional_evidence_ref(attrs) do
    case Map.fetch(attrs, :evidence_ref) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        valid = safe_text?(value) and String.starts_with?(value, "refs/arbor/evidence/")
        if valid, do: {:ok, value}, else: {:error, {:invalid_field, "evidence_ref"}}

      {:ok, _} ->
        {:error, {:invalid_field, "evidence_ref"}}
    end
  end

  defp optional_oid(attrs, field) do
    case Map.fetch(attrs, field) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.downcase(value)

        if String.valid?(value) and Regex.match?(@oid_regex, value),
          do: {:ok, value},
          else: {:error, {:invalid_field, field_name(field)}}

      {:ok, _} ->
        {:error, {:invalid_field, field_name(field)}}
    end
  end

  defp validate_invariants("retired", "complete", nil, nil, nil, nil, nil), do: :ok
  defp validate_invariants("preserved", "complete", nil, nil, nil, nil, nil), do: :ok

  defp validate_invariants("preserved", "complete", reason, nil, nil, nil, nil)
       when is_binary(reason), do: :ok

  defp validate_invariants("pending", "retrying", _reason, count, limit, failure, phase)
       when is_integer(count) and is_integer(limit) and count < limit and is_binary(failure) and
              is_binary(phase),
       do: :ok

  defp validate_invariants("pending", "dormant", _reason, count, limit, failure, phase)
       when is_integer(count) and is_integer(limit) and count >= limit and is_binary(failure) and
              is_binary(phase),
       do: :ok

  defp validate_invariants(_, _, _, _, _, _, _),
    do: {:error, {:invalid_branch_lifecycle_descriptor, :inconsistent_fields}}

  defp safe_text?(value) do
    String.valid?(value) and byte_size(value) > 0 and byte_size(value) <= @max_text_bytes and
      String.trim(value) != "" and not String.contains?(value, <<0>>) and
      not String.match?(value, ~r/[\x00-\x1F\x7F]/)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp too_large, do: {:error, {:invalid_branch_lifecycle_descriptor, :object_too_large}}
  defp field_name(nil), do: "field"
  defp field_name(field), do: Atom.to_string(field)
  defp printable_key(key) when is_binary(key), do: key
  defp printable_key(key) when is_atom(key), do: Atom.to_string(key)
  defp printable_key(_), do: "<non-string-key>"
end
