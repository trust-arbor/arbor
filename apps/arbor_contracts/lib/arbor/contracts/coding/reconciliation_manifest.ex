defmodule Arbor.Contracts.Coding.ReconciliationManifest do
  @moduledoc "Versioned, bounded manifest for dry-run coding-resource reconciliation."

  use TypedStruct

  alias Arbor.Contracts.Coding.ReconciliationDecision

  @schema_version 1
  @fields [:schema_version, :observed_at, :scope, :observation_digest, :decisions, :counts]
  @scope_fields [:task_id, :principal_id, :agent_id, :state]
  @digest_fields [:task_inventory_sha256, :resource_inventory_sha256, :source_sha256]
  @count_fields [:resources, :keep, :retry, :settle, :quarantine, :remove]
  @max_decisions 1_000
  @max_json_bytes 256_000
  @max_timestamp_bytes 64

  typedstruct enforce: true do
    @typedoc "A bounded reconciliation manifest without cleanup authority."

    field(:schema_version, pos_integer())
    field(:observed_at, String.t())
    field(:scope, map())
    field(:observation_digest, map())
    field(:decisions, [map()])
    field(:counts, map())
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Construct and validate a canonical reconciliation manifest."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, attrs} <- normalize_object(attrs, @fields, :invalid_reconciliation_manifest),
         :ok <- require_fields(attrs),
         :ok <- exact_version(attrs.schema_version),
         {:ok, observed_at} <- timestamp(attrs.observed_at),
         {:ok, scope} <- normalize_scope(attrs.scope),
         {:ok, observation_digest} <- normalize_digest(attrs.observation_digest),
         {:ok, decisions} <- normalize_decisions(attrs.decisions),
         {:ok, counts} <- normalize_counts(attrs.counts),
         :ok <- validate_counts(counts, decisions),
         manifest = %__MODULE__{
           schema_version: @schema_version,
           observed_at: observed_at,
           scope: scope,
           observation_digest: observation_digest,
           decisions: decisions,
           counts: counts
         },
         :ok <- size_ok(manifest) do
      {:ok, manifest}
    end
  rescue
    _ -> {:error, {:invalid_reconciliation_manifest, :malformed}}
  catch
    _, _ -> {:error, {:invalid_reconciliation_manifest, :malformed}}
  end

  @doc "Return the canonical string-keyed JSON representation."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    %{
      "schema_version" => manifest.schema_version,
      "observed_at" => manifest.observed_at,
      "scope" => manifest.scope,
      "observation_digest" => manifest.observation_digest,
      "decisions" => manifest.decisions,
      "counts" => manifest.counts
    }
  end

  @doc "Normalize a manifest directly to its canonical JSON map."
  @spec normalize(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize(attrs) do
    with {:ok, manifest} <- new(attrs), do: {:ok, to_map(manifest)}
  end

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{} = manifest), do: match?({:ok, _}, new(to_map(manifest)))
  def valid?(attrs) when is_map(attrs) or is_list(attrs), do: match?({:ok, _}, new(attrs))
  def valid?(_attrs), do: false

  @doc "Digest a valid manifest using sorted-key canonical JSON."
  @spec digest(t() | map()) :: {:ok, String.t()} | {:error, term()}
  def digest(%__MODULE__{} = manifest), do: digest(to_map(manifest))

  def digest(attrs) when is_map(attrs) do
    with {:ok, manifest} <- new(attrs) do
      {:ok, sha256(canonical_json(to_map(manifest)))}
    end
  rescue
    _ -> {:error, {:invalid_reconciliation_manifest, :malformed}}
  end

  def digest(_attrs), do: {:error, {:invalid_reconciliation_manifest, :malformed}}

  defp normalize_decisions(value) when is_list(value) do
    entries = Enum.take(value, @max_decisions + 1)

    if length(entries) > @max_decisions do
      {:error, {:invalid_reconciliation_manifest, :too_many_decisions}}
    else
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        case ReconciliationDecision.new(entry) do
          {:ok, decision} -> {:cont, {:ok, [ReconciliationDecision.to_map(decision) | acc]}}
          {:error, _} -> {:halt, {:error, {:invalid_reconciliation_manifest, :decision}}}
        end
      end)
      |> reverse_ok()
    end
  end

  defp normalize_decisions(_value), do: {:error, {:invalid_reconciliation_manifest, :decisions}}

  defp normalize_scope(value) when is_map(value) and not is_struct(value) do
    with {:ok, attrs} <- normalize_object(value, @scope_fields, :invalid_scope),
         {:ok, task_id} <- optional_text(attrs.task_id),
         {:ok, principal_id} <- optional_text(attrs.principal_id),
         {:ok, agent_id} <- optional_text(attrs.agent_id),
         {:ok, state} <-
           optional_enum(attrs.state, ~w(running waiting_approval done failed cancelled)) do
      {:ok,
       %{
         "task_id" => task_id,
         "principal_id" => principal_id,
         "agent_id" => agent_id,
         "state" => state
       }}
    end
  end

  defp normalize_scope(_value), do: {:error, {:invalid_reconciliation_manifest, :scope}}

  defp normalize_digest(value) when is_map(value) and not is_struct(value) do
    with {:ok, attrs} <- normalize_object(value, @digest_fields, :invalid_observation_digest),
         :ok <- require_exact(attrs, @digest_fields),
         {:ok, task} <- digest_value(attrs.task_inventory_sha256),
         {:ok, resource} <- digest_value(attrs.resource_inventory_sha256),
         {:ok, source} <- digest_value(attrs.source_sha256) do
      {:ok,
       %{
         "task_inventory_sha256" => task,
         "resource_inventory_sha256" => resource,
         "source_sha256" => source
       }}
    end
  end

  defp normalize_digest(_value),
    do: {:error, {:invalid_reconciliation_manifest, :observation_digest}}

  defp normalize_counts(value) when is_map(value) and not is_struct(value) do
    with {:ok, attrs} <- normalize_object(value, @count_fields, :invalid_counts),
         :ok <- require_exact(attrs, @count_fields),
         {:ok, resources} <- count(attrs.resources),
         {:ok, keep} <- count(attrs.keep),
         {:ok, retry} <- count(attrs.retry),
         {:ok, settle} <- count(attrs.settle),
         {:ok, quarantine} <- count(attrs.quarantine),
         {:ok, remove} <- count(attrs.remove) do
      {:ok,
       %{
         "resources" => resources,
         "keep" => keep,
         "retry" => retry,
         "settle" => settle,
         "quarantine" => quarantine,
         "remove" => remove
       }}
    end
  end

  defp normalize_counts(_value), do: {:error, {:invalid_reconciliation_manifest, :counts}}

  defp validate_counts(counts, decisions) do
    expected = Enum.frequencies_by(decisions, & &1["decision"])

    if counts["resources"] == length(decisions) and
         Enum.all?(
           ~w(keep retry settle quarantine remove),
           &(counts[&1] == Map.get(expected, &1, 0))
         ),
       do: :ok,
       else: {:error, {:invalid_reconciliation_manifest, :count_mismatch}}
  end

  defp size_ok(manifest) do
    if :erlang.iolist_size(canonical_json(to_map(manifest))) <= @max_json_bytes,
      do: :ok,
      else: {:error, {:invalid_reconciliation_manifest, :too_large}}
  end

  defp normalize_object(attrs, allowed, tag) when is_map(attrs) do
    cond do
      is_struct(attrs) -> {:error, {tag, :struct_not_allowed}}
      map_size(attrs) > length(allowed) -> {:error, {tag, :object_too_large}}
      true -> normalize_entries(Map.to_list(attrs), allowed, tag)
    end
  end

  defp normalize_object(attrs, allowed, tag) when is_list(attrs) do
    entries = Enum.take(attrs, length(allowed) + 1)

    cond do
      length(entries) > length(allowed) -> {:error, {tag, :object_too_large}}
      Enum.all?(entries, &match?({_, _}, &1)) -> normalize_entries(entries, allowed, tag)
      true -> {:error, {tag, :object_required}}
    end
  end

  defp normalize_object(_attrs, _allowed, tag), do: {:error, {tag, :object_required}}

  defp normalize_entries(entries, allowed, tag) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      case canonical_key(key, allowed) do
        {:ok, canonical} when not is_map_key(normalized, canonical) ->
          {:cont, {:ok, Map.put(normalized, canonical, value)}}

        {:ok, canonical} ->
          {:halt, {:error, {:duplicate_field, Atom.to_string(canonical)}}}

        :error ->
          {:halt, {:error, {tag, :unknown_field}}}
      end
    end)
  end

  defp canonical_key(key, allowed) when is_atom(key) do
    if Enum.member?(allowed, key), do: {:ok, key}, else: :error
  end

  defp canonical_key(key, allowed) when is_binary(key) do
    Enum.find_value(allowed, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  defp canonical_key(_key, _allowed), do: :error

  defp require_fields(attrs), do: require_exact(attrs, @fields)

  defp require_exact(attrs, fields) do
    if Map.keys(attrs) |> Enum.sort() == fields |> Enum.sort(),
      do: :ok,
      else: {:error, :field_set}
  end

  defp exact_version(@schema_version), do: :ok
  defp exact_version(_), do: {:error, {:invalid_field, "schema_version"}}

  defp timestamp(value) when is_binary(value) and byte_size(value) <= @max_timestamp_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, DateTime.to_iso8601(DateTime.shift_zone!(datetime, "Etc/UTC"))}

      _ ->
        {:error, {:invalid_field, "observed_at"}}
    end
  end

  defp timestamp(_value), do: {:error, {:invalid_field, "observed_at"}}

  defp optional_text(nil), do: {:ok, nil}

  defp optional_text(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= 256 do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, :invalid_text}
  end

  defp optional_text(_value), do: {:error, :invalid_text}

  defp optional_enum(nil, _allowed), do: {:ok, nil}

  defp optional_enum(value, allowed),
    do: if(value in allowed, do: {:ok, value}, else: {:error, :invalid_enum})

  defp digest_value(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: {:ok, value},
      else: {:error, :invalid_digest}
  end

  defp digest_value(_value), do: {:error, :invalid_digest}

  defp count(value) when is_integer(value) and value >= 0 and value <= @max_decisions,
    do: {:ok, value}

  defp count(_value), do: {:error, :invalid_count}

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, nested} -> [Jason.encode!(key), ":", canonical_json(nested)] end)
    |> then(&["{", Enum.intersperse(&1, ","), "}"])
  end

  defp canonical_json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &canonical_json/1), ","), "]"]

  defp canonical_json(value), do: Jason.encode!(value)
end
