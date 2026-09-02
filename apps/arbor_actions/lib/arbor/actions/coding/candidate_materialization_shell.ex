defmodule Arbor.Actions.Coding.CandidateMaterializationShell do
  @moduledoc false

  alias Arbor.Actions.Coding.CandidateMaterializationAdmissionCore, as: Core
  alias Arbor.Actions.Coding.BlobManifest
  alias Arbor.Actions.Coding.ValidationResourceOwner
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
  alias Arbor.Actions.Git
  alias Arbor.Actions.Mix, as: MixAction
  alias Arbor.Contracts.Coding.CandidateMaterialization

  @closed_result_keys [
    "resource_id",
    "candidate_path",
    "tree_oid",
    "expected_tree_oid",
    "source_commit_oid",
    "hidden_ref",
    "object_format",
    "descriptor_digest",
    "base_commit",
    "workspace_id",
    "observed_at"
  ]

  @doc false
  @spec resolve_or_materialize(term()) :: {:ok, map()} | {:error, term()}
  def resolve_or_materialize(input) when is_map(input) do
    with {:ok, admitted} <- admit_resolve_input(input),
         {:ok, view} <-
           inspect_lease(
             admitted.workspace_id,
             admitted.task_id,
             admitted.principal_id,
             admitted.server
           ),
         :ok <- require_owned_workspace(view),
         :ok <- require_acquired_base(view, admitted.acquired_base_commit),
         :ok <- require_evidence_for_consumer(admitted),
         identities <- bind_caller(admitted, admitted.evidence_ref) do
      case WorkspaceLeaseRegistry.inspect_object_backed_validation_binding(
             admitted.workspace_id,
             identities
           ) do
        {:ok, binding} ->
          with :ok <- maybe_match_evidence_ref(binding, admitted.evidence_ref) do
            reuse_or_rematerialize(binding, admitted, identities, view)
          end

        {:error, :not_found} ->
          rematerialize_missing(admitted, identities, view)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def resolve_or_materialize(_input), do: {:error, :malformed_admission_input}

  @doc false
  @spec with_resolved_snapshot(term(), map(), (map() -> result)) :: result | {:error, term()}
        when result: term()
  def with_resolved_snapshot(input, context, fun)
      when is_map(input) and is_map(context) and is_function(fun, 1) do
    with {:ok, handle} <- resolve_or_materialize(input),
         {:ok, admitted} <- admit_resolve_input(input),
         caller <- bind_caller(admitted, handle["hidden_ref"]),
         {:ok, resource} <-
           WorkspaceLeaseRegistry.bind_existing_object_backed_validation_resource(
             handle["resource_id"],
             caller
           ),
         resource <- maybe_put_server(resource, admitted.server),
         :ok <- MixAction.recapture_committable_snapshot(resource),
         :ok <- reject_worktree_alias(resource, Map.get(input, :worktree_path)) do
      fun.(resource)
    end
  end

  def with_resolved_snapshot(_input, _context, _fun),
    do: {:error, :malformed_admission_input}

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

  defp admit_resolve_input(input) when is_map(input) do
    with {:ok, workspace_id} <- require_binary_attr(input, :workspace_id),
         {:ok, task_id} <- require_binary_attr(input, :task_id),
         {:ok, principal_id} <- require_binary_attr(input, :principal_id),
         {:ok, pin} <- require_binary_attr(input, :pinned_descriptor_digest),
         {:ok, checkpoint_digest} <- require_binary_attr(input, :candidate_materialization_digest),
         {:ok, source_commit_oid} <- require_binary_attr(input, :source_commit_oid),
         {:ok, expected_tree_oid} <- require_binary_attr(input, :expected_tree_oid),
         {:ok, acquired_base_commit} <- require_binary_attr(input, :acquired_base_commit),
         descriptor_attrs <- attr(input, :candidate_materialization),
         {:ok, descriptor} <- CandidateMaterialization.new(descriptor_attrs),
         {:ok, digest} <- CandidateMaterialization.digest(descriptor),
         :ok <-
           bind_compiler_identities(
             digest,
             pin,
             checkpoint_digest,
             descriptor,
             source_commit_oid,
             expected_tree_oid
           ),
         {:ok, evidence_ref} <- optional_evidence_ref(input) do
      {:ok,
       %{
         workspace_id: workspace_id,
         task_id: task_id,
         principal_id: principal_id,
         descriptor: descriptor,
         digest: digest,
         source_commit_oid: source_commit_oid,
         expected_tree_oid: expected_tree_oid,
         acquired_base_commit: acquired_base_commit,
         evidence_ref: evidence_ref,
         require_evidence_ref: attr(input, :require_evidence_ref) == true,
         server: attr(input, :server)
       }}
    end
  end

  defp admit_resolve_input(_input), do: {:error, :malformed_admission_input}

  defp bind_compiler_identities(
         digest,
         pin,
         checkpoint_digest,
         descriptor,
         source_commit_oid,
         expected_tree_oid
       ) do
    cond do
      not is_binary(pin) or pin == "" ->
        {:error, :compiler_descriptor_binding_missing}

      digest != pin or digest != checkpoint_digest ->
        {:error, :compiler_descriptor_mismatch}

      descriptor.source_commit_oid != source_commit_oid ->
        {:error, :compiler_descriptor_mismatch}

      descriptor.expected_tree_oid != expected_tree_oid ->
        {:error, :compiler_descriptor_mismatch}

      true ->
        :ok
    end
  end

  defp optional_evidence_ref(input) do
    value = attr(input, :evidence_ref)

    cond do
      is_nil(value) or value == "" ->
        {:ok, nil}

      is_binary(value) and String.trim(value) != "" and String.valid?(value) ->
        {:ok, value}

      true ->
        {:error, :incomplete_immutable_review_binding}
    end
  end

  defp inspect_lease(workspace_id, task_id, principal_id, server) do
    opts = if server, do: [server: server], else: []

    case WorkspaceLeaseRegistry.ensure_active_by_lineage(
           workspace_id,
           task_id,
           principal_id,
           opts
         ) do
      {:ok, view} ->
        {:ok, view}

      {:error, reason}
      when reason in [:not_found, :retained_workspace_not_found] ->
        {:error, :workspace_not_found}

      {:error, reason}
      when reason in [:not_authorized, :retained_workspace_not_authorized] ->
        {:error, :workspace_unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_acquired_base(view, acquired_base_commit) do
    base = Map.get(view, :base_commit) || Map.get(view, "base_commit")

    if is_binary(base) and base == acquired_base_commit,
      do: :ok,
      else: {:error, :acquired_base_mismatch}
  end

  defp require_owned_workspace(view) do
    case Map.get(view, :ownership) || Map.get(view, "ownership") do
      ownership when ownership in [:owned, "owned"] -> :ok
      _other -> {:error, :descriptor_workspace_not_owned}
    end
  end

  defp bind_caller(admitted, evidence_ref) do
    caller = %{
      task_id: admitted.task_id,
      principal_id: admitted.principal_id,
      workspace_id: admitted.workspace_id,
      source_commit_oid: admitted.source_commit_oid,
      expected_tree_oid: admitted.expected_tree_oid,
      candidate_materialization_digest: admitted.digest,
      acquired_base_commit: admitted.acquired_base_commit,
      evidence_ref: evidence_ref
    }

    if admitted.server, do: Map.put(caller, :server, admitted.server), else: caller
  end

  defp maybe_match_evidence_ref(_binding, nil), do: :ok

  defp maybe_match_evidence_ref(binding, expected) when is_binary(expected) do
    observed = string_field(binding, :hidden_ref) || string_field(binding, :evidence_ref)

    if observed == expected, do: :ok, else: {:error, :evidence_ref_mismatch}
  end

  defp rematerialize_missing(admitted, identities, view) do
    with :ok <- verify_existing_evidence_ref(admitted, view) do
      materialize_fresh(admitted, identities)
    end
  end

  defp require_evidence_for_consumer(%{require_evidence_ref: true, evidence_ref: ref})
       when not is_binary(ref) or ref == "",
       do: {:error, :incomplete_immutable_review_binding}

  defp require_evidence_for_consumer(_admitted), do: :ok

  defp verify_existing_evidence_ref(%{evidence_ref: nil}, _view), do: :ok

  defp verify_existing_evidence_ref(admitted, view) do
    repo = Map.get(view, :repo_path) || Map.get(view, "repo_path")

    case Git.verify_archived_evidence_ref(
           repo,
           admitted.task_id,
           admitted.workspace_id,
           admitted.source_commit_oid
         ) do
      {:ok, %{hidden_ref: hidden_ref}} when hidden_ref == admitted.evidence_ref ->
        :ok

      {:ok, %{hidden_ref: _other}} ->
        {:error, :evidence_ref_mismatch}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reuse_or_rematerialize(binding, admitted, identities, view) do
    case encode_result(
           binding,
           admitted.digest,
           admitted.source_commit_oid,
           admitted.expected_tree_oid,
           admitted.acquired_base_commit,
           admitted.workspace_id
         ) do
      {:ok, _payload} = ok ->
        ok

      {:error, :invalid_observed_at} = error ->
        error

      {:error, :non_json_materialization_result} = error ->
        resource_id = string_field(binding, :resource_id)

        if is_binary(resource_id) and resource_id != "" do
          with {:ok, _released} <-
                 WorkspaceLeaseRegistry.release_validation_resource(resource_id, identities) do
            rematerialize_missing(admitted, identities, view)
          end
        else
          error
        end
    end
  end

  defp materialize_fresh(admitted, identities) do
    input = %{
      workspace_id: admitted.workspace_id,
      task_id: admitted.task_id,
      principal_id: admitted.principal_id,
      candidate_materialization: CandidateMaterialization.to_map(admitted.descriptor)
    }

    input =
      case admitted.server do
        nil -> input
        server -> Map.put(input, :server, server)
      end

    case admit_and_materialize(input) do
      {:ok, raw} ->
        finish_fresh(raw, admitted, identities)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_fresh(raw, admitted, identities) do
    result =
      with {:ok, encoded} <-
             encode_result(
               raw,
               admitted.digest,
               admitted.descriptor.source_commit_oid,
               admitted.descriptor.expected_tree_oid,
               identities.acquired_base_commit,
               admitted.workspace_id
             ),
           :ok <- maybe_fail_after_acquire(),
           :ok <- maybe_match_evidence_ref(encoded, admitted.evidence_ref),
           {:ok, _bound} <-
             WorkspaceLeaseRegistry.bind_existing_object_backed_validation_resource(
               encoded["resource_id"],
               bind_caller(admitted, encoded["hidden_ref"])
             ) do
        {:ok, encoded}
      end

    case result do
      {:ok, encoded} ->
        {:ok, encoded}

      {:error, reason} ->
        _ = release_fresh_resource(raw, admitted)
        {:error, reason}
    end
  end

  defp release_fresh_resource(raw, admitted) do
    case string_field(raw, :resource_id) do
      id when is_binary(id) and id != "" ->
        WorkspaceLeaseRegistry.release_validation_resource(id, bind_caller(admitted, nil))

      _other ->
        :ok
    end
  end

  if Mix.env() == :test do
    defp maybe_fail_after_acquire do
      case Process.delete({__MODULE__, :fail_after_acquire}) do
        reason when reason != nil -> {:error, reason}
        nil -> :ok
      end
    end
  else
    defp maybe_fail_after_acquire, do: :ok
  end

  defp encode_result(
         raw,
         digest,
         source_commit_oid,
         expected_tree_oid,
         acquired_base_commit,
         workspace_id
       )
       when is_map(raw) do
    payload = %{
      "resource_id" => string_field(raw, :resource_id),
      "candidate_path" => string_field(raw, :candidate_path),
      "tree_oid" => string_field(raw, :tree_oid) || expected_tree_oid,
      "expected_tree_oid" => string_field(raw, :expected_tree_oid) || expected_tree_oid,
      "source_commit_oid" => string_field(raw, :source_commit_oid) || source_commit_oid,
      "hidden_ref" => string_field(raw, :hidden_ref),
      "object_format" => string_field(raw, :object_format),
      "descriptor_digest" => digest,
      "base_commit" =>
        string_field(raw, :base_commit) || string_field(raw, :acquired_base_commit) ||
          acquired_base_commit,
      "workspace_id" => string_field(raw, :workspace_id) || workspace_id,
      "observed_at" => string_field(raw, :observed_at)
    }

    cond do
      match?({:error, :invalid_observed_at}, admit_encoded_observed_at(payload)) ->
        {:error, :invalid_observed_at}

      Enum.any?(Map.keys(raw), &is_atom/1) and not Enum.any?(Map.keys(raw), &is_binary/1) ->
        finalize_encoded(payload)

      Enum.any?(Map.keys(payload), &(not is_binary(&1))) ->
        {:error, :non_json_materialization_result}

      true ->
        finalize_encoded(payload)
    end
  end

  defp encode_result(_raw, _digest, _source, _tree, _base, _workspace),
    do: {:error, :non_json_materialization_result}

  defp admit_encoded_observed_at(%{"observed_at" => value})
       when is_binary(value) and value != "" do
    ValidationResourceOwner.admit_utc_observed_at(value)
  end

  defp admit_encoded_observed_at(_payload), do: :ok

  defp finalize_encoded(payload) do
    if Map.keys(payload) |> Enum.sort() == Enum.sort(@closed_result_keys) and
         Enum.all?(payload, fn {key, value} ->
           is_binary(key) and is_binary(value) and value != "" and String.valid?(value)
         end) do
      {:ok, payload}
    else
      {:error, :non_json_materialization_result}
    end
  end

  defp reject_worktree_alias(resource, worktree_path) do
    candidate_path =
      Map.get(resource, "candidate_path") || Map.get(resource, :candidate_path)

    cond do
      not is_binary(candidate_path) or candidate_path == "" ->
        {:error, :validation_infrastructure_failed}

      is_binary(worktree_path) and candidate_path == worktree_path ->
        {:error, :validation_infrastructure_failed}

      true ->
        :ok
    end
  end

  defp maybe_put_server(resource, nil), do: resource
  defp maybe_put_server(resource, server), do: Map.put(resource, :server, server)

  defp require_binary_attr(attrs, key) do
    value = attr(attrs, key)

    if is_binary(value) and String.trim(value) != "" and String.valid?(value),
      do: {:ok, value},
      else: {:error, :compiler_descriptor_binding_missing}
  end

  defp attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp string_field(map, key) when is_atom(key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    if is_binary(value) and value != "", do: value, else: nil
  end
end
