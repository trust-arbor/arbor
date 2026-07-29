defmodule Arbor.Contracts.Coding.RetainedWorkspaceIdentity do
  @moduledoc """
  Closed retained-workspace reconciliation identity.

  Legacy identities without `identity_version` remain readable for archived
  manifest audit. Version 2 adds exact, redacted source proof and is the only
  version eligible for retained settlement.
  """

  @identity_version 2
  @legacy_fields ~w(
    resource_type resource_id task_id principal_id lifecycle active ownership
    branch_provenance cleanup_armed dormant retry_count retry_limit expires_at
  )
  @proof_fields @legacy_fields ++
                  ~w(
                    identity_version proof_status marker_source workspace_digest marker_digest
                    repository_digest branch_observation discard_phase settlement_tip
                  )
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @oid ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/
  @max_id_bytes 256
  @max_timestamp_bytes 64

  @spec identity_version() :: pos_integer()
  def identity_version, do: @identity_version

  @doc "Normalize a legacy audit identity or a version 2 retained proof."
  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(value) when is_map(value) and not is_struct(value) do
    if has_key?(value, "identity_version") do
      normalize_v2(value)
    else
      normalize_legacy(value)
    end
  rescue
    _ -> {:error, :invalid_retained_workspace_identity}
  catch
    _, _ -> {:error, :invalid_retained_workspace_identity}
  end

  def normalize(_value), do: {:error, :invalid_retained_workspace_identity}

  @doc "Whether an identity carries complete version 2 settlement proof."
  @spec settlement_ready?(term()) :: boolean()
  def settlement_ready?(value) do
    case normalize(value) do
      {:ok,
       %{
         "identity_version" => @identity_version,
         "proof_status" => "complete"
       }} ->
        true

      _ ->
        false
    end
  end

  defp normalize_legacy(value) do
    with {:ok, normalized} <- normalize_object(value, @legacy_fields),
         :ok <- exact_fields(normalized, @legacy_fields),
         {:ok, legacy} <- normalize_legacy_fields(normalized, :legacy) do
      {:ok, legacy}
    end
  end

  defp normalize_v2(value) do
    with {:ok, normalized} <- normalize_object(value, @proof_fields),
         :ok <- exact_fields(normalized, @proof_fields),
         true <- normalized["identity_version"] == @identity_version,
         {:ok, legacy} <- normalize_legacy_fields(normalized, :v2),
         {:ok, proof_status} <- enum(normalized["proof_status"], ~w(complete unavailable)),
         {:ok, marker_source} <-
           enum(normalized["marker_source"], ~w(durable disabled unavailable)),
         {:ok, workspace_digest} <- optional_digest(normalized["workspace_digest"]),
         {:ok, marker_digest} <- optional_digest(normalized["marker_digest"]),
         {:ok, repository_digest} <- optional_digest(normalized["repository_digest"]),
         {:ok, branch_observation} <-
           normalize_branch_observation(normalized["branch_observation"]),
         {:ok, discard_phase} <-
           optional_enum(normalized["discard_phase"], ~w(archive worktree branch)),
         {:ok, settlement_tip} <- optional_oid(normalized["settlement_tip"]),
         :ok <-
           validate_proof_shape(
             proof_status,
             marker_source,
             workspace_digest,
             marker_digest,
             repository_digest,
             branch_observation
           ) do
      {:ok,
       legacy
       |> Map.merge(%{
         "identity_version" => @identity_version,
         "proof_status" => proof_status,
         "marker_source" => marker_source,
         "workspace_digest" => workspace_digest,
         "marker_digest" => marker_digest,
         "repository_digest" => repository_digest,
         "branch_observation" => branch_observation,
         "discard_phase" => discard_phase,
         "settlement_tip" => settlement_tip
       })}
    else
      false -> {:error, :invalid_retained_workspace_identity}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_retained_workspace_identity}
    end
  end

  defp normalize_legacy_fields(value, mode) do
    with true <- value["resource_type"] == "retained_workspace_record",
         {:ok, resource_id} <- bounded_id(value["resource_id"]),
         {:ok, task_id} <- optional_id(value["task_id"]),
         {:ok, principal_id} <- optional_id(value["principal_id"]),
         {:ok, lifecycle} <- legacy_text(value["lifecycle"], mode, :lifecycle),
         {:ok, active} <- boolean(value["active"]),
         {:ok, ownership} <- legacy_text(value["ownership"], mode, :ownership),
         {:ok, branch_provenance} <-
           legacy_text(value["branch_provenance"], mode, :branch_provenance),
         {:ok, cleanup_armed} <- boolean(value["cleanup_armed"]),
         {:ok, dormant} <- boolean(value["dormant"]),
         {:ok, retry_count} <- bounded_integer(value["retry_count"]),
         {:ok, retry_limit} <- bounded_integer(value["retry_limit"]),
         {:ok, expires_at} <- optional_timestamp(value["expires_at"]) do
      {:ok,
       %{
         "resource_type" => "retained_workspace_record",
         "resource_id" => resource_id,
         "task_id" => task_id,
         "principal_id" => principal_id,
         "lifecycle" => lifecycle,
         "active" => active,
         "ownership" => ownership,
         "branch_provenance" => branch_provenance,
         "cleanup_armed" => cleanup_armed,
         "dormant" => dormant,
         "retry_count" => retry_count,
         "retry_limit" => retry_limit,
         "expires_at" => expires_at
       }}
    else
      false -> {:error, :invalid_retained_workspace_identity}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_retained_workspace_identity}
    end
  end

  defp legacy_text(value, :legacy, _field), do: optional_id(value)

  defp legacy_text(value, :v2, :lifecycle),
    do: optional_enum(value, ~w(active retained active_orphaned discarding creating))

  defp legacy_text(value, :v2, :ownership),
    do: optional_enum(value, ~w(owned reused pending))

  defp legacy_text(value, :v2, :branch_provenance),
    do: optional_enum(value, ~w(created reused unknown))

  defp normalize_branch_observation(value)
       when is_map(value) and not is_struct(value) do
    with {:ok, normalized} <- normalize_object(value, ~w(status oid)),
         :ok <- exact_fields(normalized, ~w(status oid)),
         {:ok, status} <- enum(normalized["status"], ~w(present absent unavailable)),
         {:ok, oid} <- optional_oid(normalized["oid"]),
         :ok <- valid_branch_observation(status, oid) do
      {:ok, %{"status" => status, "oid" => oid}}
    end
  end

  defp normalize_branch_observation(_value),
    do: {:error, :invalid_retained_workspace_identity}

  defp valid_branch_observation("present", oid) when is_binary(oid), do: :ok
  defp valid_branch_observation(status, nil) when status in ~w(absent unavailable), do: :ok
  defp valid_branch_observation(_status, _oid), do: {:error, :invalid_retained_workspace_identity}

  defp validate_proof_shape(
         "complete",
         marker_source,
         workspace_digest,
         marker_digest,
         repository_digest,
         %{"status" => branch_status}
       )
       when marker_source in ~w(durable disabled) and is_binary(workspace_digest) and
              is_binary(repository_digest) and branch_status in ~w(present absent) do
    cond do
      marker_source == "durable" and is_binary(marker_digest) -> :ok
      marker_source == "disabled" and is_nil(marker_digest) -> :ok
      true -> {:error, :invalid_retained_workspace_identity}
    end
  end

  defp validate_proof_shape(
         "unavailable",
         marker_source,
         nil,
         nil,
         nil,
         %{"status" => "unavailable", "oid" => nil}
       )
       when marker_source in ~w(durable disabled unavailable),
       do: :ok

  defp validate_proof_shape(
         _proof_status,
         _marker_source,
         _workspace_digest,
         _marker_digest,
         _repository_digest,
         _branch_observation
       ),
       do: {:error, :invalid_retained_workspace_identity}

  defp normalize_object(value, allowed) do
    if map_size(value) <= length(allowed) do
      Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
        with {:ok, canonical} <- canonical_key(key, allowed),
             false <- Map.has_key?(acc, canonical) do
          {:cont, {:ok, Map.put(acc, canonical, item)}}
        else
          _ -> {:halt, {:error, :invalid_retained_workspace_identity}}
        end
      end)
    else
      {:error, :invalid_retained_workspace_identity}
    end
  end

  defp exact_fields(value, fields) do
    if Enum.sort(Map.keys(value)) == Enum.sort(fields),
      do: :ok,
      else: {:error, :invalid_retained_workspace_identity}
  end

  defp canonical_key(key, allowed) when is_binary(key) do
    if key in allowed, do: {:ok, key}, else: {:error, :unknown_field}
  end

  defp canonical_key(key, allowed) when is_atom(key),
    do: canonical_key(Atom.to_string(key), allowed)

  defp canonical_key(_key, _allowed), do: {:error, :unknown_field}

  defp has_key?(value, key),
    do: Map.has_key?(value, key) or Map.has_key?(value, String.to_existing_atom(key))

  defp bounded_id(value)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_id_bytes do
    if String.valid?(value) and String.trim(value) != "" and not String.contains?(value, <<0>>),
      do: {:ok, value},
      else: {:error, :invalid_retained_workspace_identity}
  end

  defp bounded_id(_value), do: {:error, :invalid_retained_workspace_identity}

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(value), do: bounded_id(value)

  defp enum(value, allowed) when is_atom(value), do: enum(Atom.to_string(value), allowed)

  defp enum(value, allowed) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, :invalid_retained_workspace_identity}
  end

  defp optional_enum(nil, _allowed), do: {:ok, nil}
  defp optional_enum(value, allowed), do: enum(value, allowed)

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :invalid_retained_workspace_identity}

  defp bounded_integer(value) when is_integer(value) and value >= 0 and value <= 1_000_000,
    do: {:ok, value}

  defp bounded_integer(_value), do: {:error, :invalid_retained_workspace_identity}

  defp optional_digest(nil), do: {:ok, nil}

  defp optional_digest(value) when is_binary(value) do
    if Regex.match?(@sha256, value),
      do: {:ok, value},
      else: {:error, :invalid_retained_workspace_identity}
  end

  defp optional_digest(_value), do: {:error, :invalid_retained_workspace_identity}

  defp optional_oid(nil), do: {:ok, nil}

  defp optional_oid(value) when is_binary(value) do
    if Regex.match?(@oid, value),
      do: {:ok, value},
      else: {:error, :invalid_retained_workspace_identity}
  end

  defp optional_oid(_value), do: {:error, :invalid_retained_workspace_identity}

  defp optional_timestamp(nil), do: {:ok, nil}

  defp optional_timestamp(value)
       when is_binary(value) and byte_size(value) <= @max_timestamp_bytes do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.to_iso8601(datetime)}
      _ -> {:error, :invalid_retained_workspace_identity}
    end
  end

  defp optional_timestamp(_value), do: {:error, :invalid_retained_workspace_identity}
end
