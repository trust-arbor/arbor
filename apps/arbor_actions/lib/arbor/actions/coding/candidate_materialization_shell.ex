defmodule Arbor.Actions.Coding.CandidateMaterializationShell do
  @moduledoc false

  alias Arbor.Actions.Coding.CandidateMaterializationAdmissionCore, as: Core
  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Contracts.Coding.CandidateMaterialization

  @doc false
  @spec admit_and_materialize(term(), term()) :: {:ok, map()} | {:error, term()}
  def admit_and_materialize(input, context \\ %{})

  def admit_and_materialize(input, context) when is_map(input) and is_map(context) do
    with {:ok, request} <- Core.admit_input(input),
         {:ok, descriptor} <- re_admit(request.descriptor),
         {:ok, view} <- inspect_active_lease(request),
         lookup <- identity_lookup(request),
         {:ok, authorized} <- Core.authorize_identity(lookup, lease_facts(view)),
         {:ok, facts} <- gather_git_facts(authorized, descriptor),
         {:ok, proof} <- Core.prove_trees_and_delta(facts),
         {:ok, descriptor} <- re_admit(proof.descriptor),
         {:ok, :commit, effects} <-
           Core.decide_effects(%{proof | descriptor: descriptor}, authorized) do
      commit_effects(authorized, proof, effects, request)
    end
  end

  def admit_and_materialize(_input, _context), do: {:error, :malformed_admission_input}

  defp re_admit(%CandidateMaterialization{} = descriptor) do
    CandidateMaterialization.new(CandidateMaterialization.to_map(descriptor))
  end

  defp re_admit(attrs), do: CandidateMaterialization.new(attrs)

  defp identity_lookup(request) do
    %{
      task_id: request.task_id,
      principal_id: request.principal_id,
      workspace_id: request.workspace_id
    }
  end

  defp lease_facts(view) when is_map(view) do
    %{
      task_id: Map.get(view, :task_id) || Map.get(view, "task_id"),
      principal_id: Map.get(view, :principal_id) || Map.get(view, "principal_id"),
      workspace_id: Map.get(view, :workspace_id) || Map.get(view, "workspace_id"),
      active: Map.get(view, :active, Map.get(view, "active")),
      base_commit: Map.get(view, :base_commit) || Map.get(view, "base_commit"),
      repo_path: Map.get(view, :repo_path) || Map.get(view, "repo_path")
    }
  end

  defp inspect_active_lease(request) do
    opts = if request.server, do: [server: request.server], else: []

    case WorkspaceLeaseRegistry.inspect_lease_by_lineage(
           request.workspace_id,
           request.task_id,
           request.principal_id,
           opts
         ) do
      {:ok, view} -> {:ok, view}
      {:error, :not_found} -> {:error, :workspace_not_found}
      {:error, :not_authorized} -> {:error, :workspace_unauthorized}
      {:error, :invalid_task_principal} -> {:error, :invalid_task_principal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gather_git_facts(authorized, descriptor) do
    repo = authorized.repo_path
    source = descriptor.source_commit_oid
    base = authorized.base_commit

    with {:ok, source_type} <- Git.object_type(repo, source),
         {:ok, descendant?} <- Git.commit_descendant?(repo, base, source),
         {:ok, source_tree} <- Git.commit_tree_oid(repo, source),
         {:ok, base_tree} <- git_base_tree_oid(repo, base),
         {:ok, base_listing} <- Git.ls_tree_z(repo, base),
         {:ok, source_listing} <- Git.ls_tree_z(repo, source),
         {:ok, base_manifest} <- BlobManifest.parse_ls_tree_z(base_listing),
         {:ok, candidate_manifest} <- BlobManifest.parse_ls_tree_z(source_listing) do
      {:ok,
       %{
         descriptor: descriptor,
         source_object_type: source_type,
         source_is_descendant: descendant?,
         observed_source_tree_oid: source_tree,
         observed_base_tree_oid: base_tree,
         base_manifest: base_manifest,
         candidate_manifest: candidate_manifest,
         base_commit: base
       }}
    else
      {:error, :invalid_git_oid} -> {:error, :source_commit_missing}
      {:error, {:git_evidence_oid_not_commit, _}} -> {:error, :source_commit_missing}
      {:error, {:git_evidence_oid_lookup_failed, _}} -> {:error, :source_commit_missing}
      {:error, :commit_tree_oid_failed} -> {:error, :base_tree_oid_unavailable}
      {:error, {:commit_tree_oid_failed, _}} -> {:error, :base_tree_oid_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp git_base_tree_oid(repo, base) do
    case Git.commit_tree_oid(repo, base) do
      {:ok, tree} -> {:ok, tree}
      {:error, _reason} -> {:error, :base_tree_oid_unavailable}
    end
  end

  defp commit_effects(authorized, proof, effects, request) when is_list(effects) do
    Enum.reduce_while(effects, {:ok, %{}}, fn effect, {:ok, acc} ->
      case perform_effect(effect, authorized, proof, request, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp perform_effect(
         {:materialize_object_snapshot, meta},
         authorized,
         proof,
         request,
         acc
       ) do
    caller = registry_caller(authorized, request)
    bounds = MixAction.snapshot_bounds()

    acquire_opts =
      Map.merge(caller, %{
        object_backed_snapshot: true,
        snapshot_bounds: bounds
      })

    case WorkspaceLeaseRegistry.acquire_validation_resource(
           authorized.workspace_id,
           acquire_opts
         ) do
      {:ok, resource} ->
        materialize_acquired(resource, meta, proof, authorized, request, acc)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform_effect({:pin_evidence_ref, pin}, authorized, _proof, request, acc) do
    case Git.pin_task_workspace_commit(
           authorized.repo_path,
           pin.task_id,
           pin.workspace_id,
           pin.source_commit_oid
         ) do
      {:ok, %{hidden_ref: hidden_ref}} ->
        {:ok,
         acc
         |> Map.put(:hidden_ref, hidden_ref)
         |> Map.put(:source_commit_oid, pin.source_commit_oid)}

      {:error, reason} ->
        _ = release_acquired(acc, authorized, request)
        {:error, reason}
    end
  end

  defp perform_effect(_effect, _authorized, _proof, _request, _acc),
    do: {:error, :malformed_admission_facts}

  defp materialize_acquired(resource, meta, proof, authorized, request, acc) do
    caller = registry_caller(authorized, request)
    bounds = MixAction.snapshot_bounds()

    owner_meta = %{
      expected_tree_oid: meta.expected_tree_oid,
      object_format: meta.object_format,
      blob_manifest: meta.candidate_manifest,
      max_entries: bounds.max_entries,
      max_bytes: bounds.max_bytes,
      max_depth: bounds.max_depth
    }

    case WorkspaceLeaseRegistry.materialize_object_backed_snapshot(
           resource.resource_id,
           owner_meta,
           caller
         ) do
      {:ok, binding} ->
        {:ok,
         acc
         |> Map.put(:resource_id, resource.resource_id)
         |> Map.put(:candidate_path, resource.candidate_path)
         |> Map.put(:tree_oid, Map.get(binding, :tree_oid) || meta.expected_tree_oid)
         |> Map.put(:expected_tree_oid, meta.expected_tree_oid)
         |> Map.put(:object_format, format_name(proof.object_format))
         |> Map.put(:dest_verify, Map.get(binding, :dest_verify))
         |> Map.put(
           :observed_at,
           Map.get(binding, :observed_at) || Map.get(binding, "observed_at")
         )}

      {:error, reason} ->
        _ =
          WorkspaceLeaseRegistry.release_validation_resource(
            resource.resource_id,
            caller
          )

        {:error, reason}
    end
  end

  defp release_acquired(acc, authorized, request) do
    case Map.get(acc, :resource_id) do
      id when is_binary(id) and id != "" ->
        WorkspaceLeaseRegistry.release_validation_resource(
          id,
          registry_caller(authorized, request)
        )

      _other ->
        :ok
    end
  end

  defp registry_caller(authorized, request) do
    caller = %{
      task_id: authorized.task_id,
      principal_id: authorized.principal_id
    }

    if request.server, do: Map.put(caller, :server, request.server), else: caller
  end

  defp format_name(:sha1), do: "sha1"
  defp format_name(:sha256), do: "sha256"
end
