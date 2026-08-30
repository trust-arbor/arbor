defmodule Arbor.Actions.Coding.CrossApp.EvidenceCore do
  @moduledoc """
  Neutral identity admission and canonical digest for CrossApp evidence.

  Closed identities bind task, work-packet (`sha256:` digest), base_commit/
  base_tree_oid, candidate_head/candidate_tree_oid, validation-plan, toolchain,
  dependency-baseline, wrapper, validator implementation, principal, and
  configuration. CrossApp is pre-commit: candidate_head MUST equal base_commit.
  candidate_tree_oid is independently bound and MUST NOT be required to equal
  base_tree_oid.

  `lineage_key_for_identities/1` still emits the historical `xappc_` prefix so
  stored static-receipt `continuation_id` values remain admit-compatible.

  CRC: no filesystem, process, registry, clock, randomness, or Application env.
  """

  @max_identities_json_bytes 4_096
  @max_id_bytes 256
  @digest_regex ~r/\A[0-9a-f]{64}\z/
  @work_packet_digest_regex ~r/\Asha256:[0-9a-f]{64}\z/
  @oid_regex ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/

  @identity_keys Enum.sort(~w(
    task_id
    work_packet_digest
    base_commit
    base_tree_oid
    candidate_head
    candidate_tree_oid
    validation_plan_digest
    toolchain_digest
    dependency_baseline_digest
    wrapper_digest
    validator_id
    principal_id
    configuration_digest
  ))

  @oid_keys ~w(base_commit base_tree_oid candidate_head candidate_tree_oid)
  @hex_identity_keys ~w(
    validation_plan_digest
    toolchain_digest
    dependency_baseline_digest
    wrapper_digest
    configuration_digest
  )
  @id_keys ~w(task_id validator_id principal_id)

  @type error :: :malformed_state | :oversized_state | :identity_drift

  @doc "Derived JSON ceilings for identity maps."
  @spec limits() :: %{required(String.t()) => pos_integer()}
  def limits do
    %{
      "max_identities_json_bytes" => @max_identities_json_bytes,
      "max_id_bytes" => @max_id_bytes
    }
  end

  @doc """
  Admit a closed identities map.

  Execution and static-receipt envelopes derive stored `continuation_id` from
  identities alone so a static receipt cannot circularly include its own digest.
  """
  @spec admit_identities(term()) :: {:ok, map()} | {:error, error()}
  def admit_identities(identities) do
    parse_identities(identities)
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc """
  Deterministic stored lineage key from an admitted identities map.

  `xappc_` plus lowercase hex SHA-256 of canonical JSON over the closed
  identities map. Canonical JSON recursively sorts string keys. The `xappc_`
  prefix is historical stored-schema identity, not live continuation authority.
  """
  @spec lineage_key_for_identities(term()) :: {:ok, String.t()} | {:error, error()}
  def lineage_key_for_identities(identities) do
    with {:ok, admitted} <- admit_identities(identities) do
      {:ok, "xappc_" <> sha256_hex(canonical_json(admitted))}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  @doc "Lowercase hex SHA-256 of canonical JSON for a JSON-clean value."
  @spec digest(term()) :: {:ok, String.t()} | {:error, error()}
  def digest(value) do
    with :ok <- require_json_clean_value(value) do
      {:ok, sha256_hex(canonical_json(value))}
    end
  rescue
    _ -> {:error, :malformed_state}
  catch
    _, _ -> {:error, :malformed_state}
  end

  defp parse_identities(identities) do
    with :ok <- require_json_object(identities),
         :ok <- bound_json(identities, @max_identities_json_bytes, :oversized_state),
         :ok <- require_allowed_keys(identities, @identity_keys),
         :ok <- require_keys(identities, @identity_keys),
         :ok <- validate_identity_fields(identities) do
      {:ok, Map.take(identities, @identity_keys)}
    end
  end

  defp validate_identity_fields(identities) do
    with :ok <- require_all(@id_keys, identities, &parse_id/1),
         :ok <- require_work_packet_digest(identities["work_packet_digest"]),
         :ok <- require_all(@oid_keys, identities, &parse_oid/1),
         :ok <- require_all(@hex_identity_keys, identities, &parse_hex/1),
         :ok <- require_precommit_head(identities) do
      :ok
    else
      {:error, _reason} = error -> error
      {:ok, _value} -> :ok
    end
  end

  defp require_precommit_head(identities) do
    if identities["candidate_head"] === identities["base_commit"],
      do: :ok,
      else: {:error, :identity_drift}
  end

  defp require_all([], _map, _fun), do: :ok

  defp require_all([key | rest], map, fun) do
    case fun.(map[key]) do
      {:ok, _} -> require_all(rest, map, fun)
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_work_packet_digest(value) when is_binary(value) do
    if Regex.match?(@work_packet_digest_regex, value),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_work_packet_digest(_value), do: {:error, :malformed_state}

  defp parse_id(value) when is_binary(value) do
    if valid_id?(value), do: {:ok, value}, else: {:error, :malformed_state}
  end

  defp parse_id(_value), do: {:error, :malformed_state}

  defp valid_id?(value) do
    byte_size(value) > 0 and byte_size(value) <= @max_id_bytes and String.valid?(value) and
      printable?(value) and not String.contains?(value, <<0>>)
  end

  defp parse_oid(value) when is_binary(value) do
    if Regex.match?(@oid_regex, value), do: {:ok, value}, else: {:error, :malformed_state}
  end

  defp parse_oid(_value), do: {:error, :malformed_state}

  defp parse_hex(value) when is_binary(value) do
    if Regex.match?(@digest_regex, value), do: {:ok, value}, else: {:error, :malformed_state}
  end

  defp parse_hex(_value), do: {:error, :malformed_state}

  defp require_json_object(value) when is_map(value) and not is_struct(value) do
    if json_clean?(value), do: :ok, else: {:error, :malformed_state}
  end

  defp require_json_object(_value), do: {:error, :malformed_state}

  defp json_clean?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn
      {key, nested} when is_binary(key) -> json_clean?(nested)
      _ -> false
    end)
  end

  defp json_clean?(value) when is_list(value),
    do: proper_list?(value) and Enum.all?(value, &json_clean?/1)

  defp json_clean?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp json_clean?(_value), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_tail), do: false

  defp require_allowed_keys(map, allowed) do
    allowed_set = MapSet.new(allowed)

    if Enum.all?(Map.keys(map), &MapSet.member?(allowed_set, &1)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp require_keys(map, keys) do
    if Enum.all?(keys, &Map.has_key?(map, &1)),
      do: :ok,
      else: {:error, :malformed_state}
  end

  defp printable?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F))
  end

  defp require_json_clean_value(value) do
    if json_clean?(value), do: :ok, else: {:error, :malformed_state}
  end

  defp bound_json(value, max, error) do
    if json_size(value) <= max, do: :ok, else: {:error, error}
  end

  defp json_size(value), do: byte_size(Jason.encode!(value))

  defp sha256_hex(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp canonical_json(value) when is_map(value) and not is_struct(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, item} ->
        [Jason.encode!(key), ":", canonical_json(item)]
      end)

    :erlang.iolist_to_binary(["{", Enum.intersperse(entries, ","), "}"])
  end

  defp canonical_json(value) when is_list(value) do
    :erlang.iolist_to_binary([
      "[",
      Enum.intersperse(Enum.map(value, &canonical_json/1), ","),
      "]"
    ])
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
