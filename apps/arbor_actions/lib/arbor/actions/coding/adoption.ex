defmodule Arbor.Actions.Coding.Adoption do
  @moduledoc false

  alias Arbor.Actions.Coding.CandidateSourceCore
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git

  @candidate_keys MapSet.new(~w(
    base_commit
    branch
    branch_provenance
    candidate_commit
    evidence_ref
    principal_id
    repo_path
    task_id
    workspace_id
  ))

  @oid_regex ~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/

  @spec prove(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prove(candidate, destination_ref) when is_map(candidate) and is_binary(destination_ref) do
    with {:ok, candidate} <- validate_candidate(candidate),
         :ok <- validate_destination(candidate, destination_ref),
         {:ok, proof} <-
           Git.compute_adoption_proof(
             candidate["repo_path"],
             candidate["base_commit"],
             candidate["candidate_commit"],
             destination_ref
           ),
         {:ok, proof} <- json_string_map(proof),
         :ok <- validate_destination(candidate, proof["destination_ref"]) do
      {:ok, proof}
    end
  end

  def prove(_candidate, _destination_ref), do: {:error, :invalid_adoption_request}

  @spec settle(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def settle(candidate, proof, opts \\ [])

  def settle(candidate, proof, opts)
      when is_map(candidate) and is_map(proof) and is_list(opts) do
    with {:ok, candidate} <- validate_candidate(candidate),
         :ok <- proof_matches_candidate(candidate, proof),
         :ok <- validate_destination(candidate, map_value(proof, "destination_ref")),
         :ok <- Git.verify_adoption_proof(candidate["repo_path"], proof),
         {:ok, %{hidden_ref: hidden_ref}} <- archive_candidate(candidate),
         :ok <- require_expected_evidence_ref(candidate, hidden_ref),
         {:ok, _release} <- release_candidate_workspace(candidate, opts),
         {:ok, settlement} <- settle_candidate_branch(candidate) do
      {:ok,
       settlement
       |> Map.put("status", "adopted")
       |> Map.put("evidence_ref", hidden_ref)}
    end
  end

  def settle(_candidate, _proof, _opts), do: {:error, :invalid_adoption_request}

  defp validate_candidate(candidate) when is_map(candidate) do
    with {:ok, source} <- CandidateSourceCore.admit(candidate),
         {:ok, candidate} <- json_string_map(candidate),
         :ok <- require_candidate_key_set(candidate),
         :ok <- require_nonblank_fields(candidate),
         true <- Regex.match?(@oid_regex, candidate["base_commit"]),
         true <- Regex.match?(@oid_regex, candidate["candidate_commit"]),
         true <- byte_size(candidate["base_commit"]) == byte_size(candidate["candidate_commit"]),
         true <- candidate["branch_provenance"] in ["created", "reused", "unknown"],
         true <- String.starts_with?(candidate["evidence_ref"], "refs/arbor/evidence/") do
      {:ok, Map.put(candidate, "candidate_source", source_string(source))}
    else
      {:error, :ambiguous_candidate_source} = error -> error
      {:error, :invalid_candidate_source} = error -> error
      _other -> {:error, :invalid_adoption_candidate}
    end
  end

  defp validate_candidate(_candidate), do: {:error, :invalid_adoption_candidate}

  defp require_candidate_key_set(candidate) do
    keys = candidate |> Map.keys() |> MapSet.new()

    cond do
      MapSet.equal?(keys, @candidate_keys) ->
        :ok

      MapSet.equal?(keys, MapSet.put(@candidate_keys, "candidate_source")) and
          candidate["candidate_source"] in ["workspace_branch", "immutable_object"] ->
        :ok

      true ->
        {:error, :invalid_adoption_candidate}
    end
  end

  defp source_string(:immutable_object), do: "immutable_object"
  defp source_string(:workspace_branch), do: "workspace_branch"

  defp candidate_source(candidate) do
    case Map.get(candidate, "candidate_source") do
      "immutable_object" -> :immutable_object
      _other -> :workspace_branch
    end
  end

  defp require_nonblank_fields(candidate) do
    if Enum.all?(@candidate_keys, fn key ->
         value = Map.get(candidate, key)

         is_binary(value) and String.valid?(value) and String.trim(value) != "" and
           not String.contains?(value, <<0>>)
       end) do
      :ok
    else
      {:error, :invalid_adoption_candidate}
    end
  end

  defp proof_matches_candidate(candidate, proof) do
    base = map_value(proof, "base_commit")
    commit = map_value(proof, "candidate_commit")

    if base == candidate["base_commit"] and commit == candidate["candidate_commit"],
      do: :ok,
      else: {:error, :adoption_proof_candidate_mismatch}
  end

  defp validate_destination(candidate, destination_ref) when is_binary(destination_ref) do
    candidate_refs = [candidate["branch"], "refs/heads/#{candidate["branch"]}"]

    cond do
      destination_ref in candidate_refs ->
        {:error, :candidate_branch_is_not_an_adoption_destination}

      destination_ref == candidate["evidence_ref"] ->
        {:error, :candidate_evidence_is_not_an_adoption_destination}

      String.starts_with?(destination_ref, "refs/arbor/") ->
        {:error, :arbor_internal_ref_is_not_an_adoption_destination}

      true ->
        :ok
    end
  end

  defp validate_destination(_candidate, _destination_ref),
    do: {:error, :invalid_adoption_destination}

  defp archive_candidate(candidate) do
    case CandidateSourceCore.adoption_evidence_mode(candidate_source(candidate)) do
      :verify_existing ->
        Git.verify_archived_evidence_ref(
          candidate["repo_path"],
          candidate["task_id"],
          candidate["workspace_id"],
          candidate["candidate_commit"]
        )

      :archive_from_branch ->
        with :ok <- reject_workspace_branch_base_shape(candidate) do
          Git.archive_branch_evidence_ref(
            candidate["repo_path"],
            candidate["branch"],
            candidate["task_id"],
            candidate["workspace_id"],
            candidate["candidate_commit"]
          )
        end
    end
  end

  # Omitted/workspace_branch must not treat a still-at-base branch plus a
  # pre-pinned candidate evidence ref as idempotent archive replay.
  defp reject_workspace_branch_base_shape(candidate) do
    source = candidate_source(candidate)

    case Git.observe_branch_ref(candidate["repo_path"], candidate["branch"]) do
      {:ok, {:present, branch_oid}} ->
        if CandidateSourceCore.workspace_branch_still_at_impossible_base?(
             source,
             branch_oid,
             candidate["base_commit"],
             candidate["candidate_commit"]
           ) do
          {:error, :branch_ref_oid_mismatch}
        else
          :ok
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_expected_evidence_ref(candidate, hidden_ref) do
    if hidden_ref == candidate["evidence_ref"],
      do: :ok,
      else: {:error, :adoption_evidence_ref_mismatch}
  end

  defp release_candidate_workspace(candidate, opts) do
    release_opts = [
      task_id: candidate["task_id"],
      principal_id: candidate["principal_id"]
    ]

    release_opts =
      case Keyword.fetch(opts, :server) do
        {:ok, server} -> Keyword.put(release_opts, :server, server)
        :error -> release_opts
      end

    WorkspaceLeaseRegistry.release(candidate["workspace_id"], :remove, release_opts)
  end

  defp settle_candidate_branch(candidate) do
    source = candidate_source(candidate)
    provenance = candidate["branch_provenance"]

    case CandidateSourceCore.branch_retirement_expected_oid(
           source,
           provenance,
           candidate["base_commit"],
           candidate["candidate_commit"]
         ) do
      {:compare_delete, expected_commit} ->
        retire_created_branch(candidate, expected_commit)

      :preserve ->
        reason =
          case provenance do
            "reused" -> "reused_branch"
            _ -> "unknown_branch_provenance"
          end

        {:ok, %{"branch_retired" => false, "branch_preserved_reason" => reason}}
    end
  end

  defp retire_created_branch(candidate, expected_commit) do
    case Git.observe_branch_ref(candidate["repo_path"], candidate["branch"]) do
      {:ok, :absent} ->
        {:ok, %{"branch_retired" => true}}

      {:ok, {:present, ^expected_commit}} ->
        case Git.delete_branch_ref(
               candidate["repo_path"],
               candidate["branch"],
               expected_commit
             ) do
          :ok -> {:ok, %{"branch_retired" => true}}
          {:error, reason} -> {:error, {:adoption_branch_retire_failed, reason}}
        end

      {:ok, {:present, _other}} ->
        {:ok,
         %{
           "branch_retired" => false,
           "branch_preserved_reason" => "branch_tip_changed"
         }}

      {:error, reason} ->
        {:error, {:adoption_branch_observation_failed, reason}}
    end
  end

  defp json_string_map(value) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(encoded) do
      {:ok, decoded}
    else
      _other -> {:error, :non_json_adoption_data}
    end
  end

  defp map_value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        _other ->
          nil
      end)
  end
end
