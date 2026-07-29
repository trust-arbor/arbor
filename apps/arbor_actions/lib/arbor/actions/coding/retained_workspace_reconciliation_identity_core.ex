defmodule Arbor.Actions.Coding.RetainedWorkspaceReconciliationIdentityCore do
  @moduledoc """
  Pure retained-workspace reconciliation identity and proof construction.

  Raw paths, filesystem identity, registration details, and repository identity
  are admitted only as digest inputs. Only closed status values, object IDs,
  and domain-separated SHA-256 digests cross the reconciliation boundary.
  """

  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: RetentionJournal
  alias Arbor.Contracts.Coding.RetainedWorkspaceIdentity

  @workspace_domain "arbor.retained-workspace-reconciliation.workspace.v2"
  @marker_domain "arbor.retained-workspace-reconciliation.marker.v2"
  @repository_domain "arbor.retained-workspace-reconciliation.repository.v2"

  @spec complete(
          map(),
          map(),
          String.t(),
          map() | nil,
          map(),
          {:present, String.t()} | :absent,
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def complete(
        legacy_identity,
        retained,
        marker_source,
        durable_record,
        repository_identity,
        branch_observation,
        runtime_id
      )
      when is_map(legacy_identity) and is_map(retained) and
             marker_source in ["durable", "disabled"] and is_map(repository_identity) and
             is_binary(runtime_id) do
    with {:ok, marker_record} <- durable_marker_record(retained, runtime_id),
         :ok <- require_marker_match(marker_source, marker_record, durable_record),
         {:ok, branch} <- normalize_branch_observation(branch_observation),
         identity <-
           legacy_identity
           |> Map.merge(%{
             "identity_version" => RetainedWorkspaceIdentity.identity_version(),
             "proof_status" => "complete",
             "marker_source" => marker_source,
             "workspace_digest" =>
               digest(
                 @workspace_domain,
                 workspace_subject(legacy_identity, retained, marker_record)
               ),
             "marker_digest" =>
               if(marker_source == "durable",
                 do: digest(@marker_domain, marker_record),
                 else: nil
               ),
             "repository_digest" => digest(@repository_domain, repository_identity),
             "branch_observation" => branch,
             "discard_phase" => Map.get(marker_record, :discard_phase),
             "settlement_tip" => Map.get(marker_record, :settlement_tip)
           }),
         {:ok, normalized} <- RetainedWorkspaceIdentity.normalize(identity) do
      {:ok, normalized}
    end
  end

  def complete(
        _legacy_identity,
        _retained,
        _marker_source,
        _durable_record,
        _repository_identity,
        _branch_observation,
        _runtime_id
      ),
      do: {:error, :retained_identity_unavailable}

  @spec unavailable(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def unavailable(legacy_identity, marker_source)
      when is_map(legacy_identity) and marker_source in ["durable", "disabled", "unavailable"] do
    legacy_identity
    |> Map.merge(%{
      "identity_version" => RetainedWorkspaceIdentity.identity_version(),
      "proof_status" => "unavailable",
      "marker_source" => marker_source,
      "workspace_digest" => nil,
      "marker_digest" => nil,
      "repository_digest" => nil,
      "branch_observation" => %{"status" => "unavailable", "oid" => nil},
      "discard_phase" => nil,
      "settlement_tip" => nil
    })
    |> RetainedWorkspaceIdentity.normalize()
  end

  @doc "Build the exact normalized durable marker semantics for hot retained state."
  @spec durable_marker_record(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def durable_marker_record(retained, runtime_id)
      when is_map(retained) and is_binary(runtime_id) do
    lifecycle =
      Map.get(retained, :durable_lifecycle) ||
        case Map.get(retained, :lifecycle, :retained) do
          :active_orphaned -> "active"
          :retained -> "retained"
          :discarding -> "discarding"
          :creating -> "creating"
          "active" -> "active"
          "retained" -> "retained"
          "discarding" -> "discarding"
          "creating" -> "creating"
          _ -> "retained"
        end

    input = %{
      workspace_id: Map.get(retained, :workspace_id),
      task_id: Map.get(retained, :task_id),
      principal_id: Map.get(retained, :principal_id),
      repo_path: Map.get(retained, :repo_path),
      worktree_path: Map.get(retained, :worktree_path),
      display_worktree_path:
        Map.get(retained, :display_worktree_path, Map.get(retained, :worktree_path)),
      branch: Map.get(retained, :branch),
      base_commit: Map.get(retained, :base_commit),
      ownership: Map.get(retained, :ownership, :owned),
      lifecycle: lifecycle,
      runtime_id: Map.get(retained, :runtime_id) || runtime_id,
      lstat_identity: Map.get(retained, :lstat_identity),
      worktree_registration: Map.get(retained, :worktree_registration),
      expires_at: Map.get(retained, :expires_at),
      retry_count: Map.get(retained, :retry_count, 0),
      branch_provenance: Map.get(retained, :branch_provenance, :unknown)
    }

    input
    |> maybe_put(:settlement_tip, Map.get(retained, :settlement_tip))
    |> maybe_put(:discard_phase, Map.get(retained, :discard_phase))
    |> RetentionJournal.encode_record()
  end

  def durable_marker_record(_retained, _runtime_id),
    do: {:error, :invalid_retained_identity_source}

  defp require_marker_match("durable", marker_record, marker_record), do: :ok
  defp require_marker_match("disabled", _marker_record, nil), do: :ok
  defp require_marker_match(_source, _expected, _actual), do: {:error, :retention_marker_drift}

  defp normalize_branch_observation({:present, oid}) when is_binary(oid),
    do: {:ok, %{"status" => "present", "oid" => String.downcase(oid)}}

  defp normalize_branch_observation(:absent),
    do: {:ok, %{"status" => "absent", "oid" => nil}}

  defp normalize_branch_observation(_observation),
    do: {:error, :invalid_branch_observation}

  defp workspace_subject(legacy_identity, retained, marker_record) do
    %{
      "legacy_identity" => legacy_identity,
      "marker_record" => marker_record,
      "expires_at_ms" => Map.get(retained, :expires_at_ms)
    }
  end

  defp digest(domain, value) do
    :crypto.hash(:sha256, [domain, <<0>>, canonical_json(value)])
    |> Base.encode16(case: :lower)
  end

  defp canonical_json(value), do: IO.iodata_to_binary(do_canonical_json(value))

  defp do_canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, item} -> [Jason.encode!(key), ":", do_canonical_json(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp do_canonical_json(value) when is_list(value),
    do: ["[", Enum.intersperse(Enum.map(value, &do_canonical_json/1), ","), "]"]

  defp do_canonical_json(value) when is_atom(value) and value not in [nil, true, false],
    do: Jason.encode!(Atom.to_string(value))

  defp do_canonical_json(value), do: Jason.encode!(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
