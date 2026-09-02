defmodule Arbor.Actions.Coding.CandidateMaterialization do
  @moduledoc """
  Pipeline-internal candidate materialization syscall.

  | Action | Canonical URI |
  |--------|---------------|
  | `Materialize` | `arbor://action/coding/candidate_materialization` |
  """
end

defmodule Arbor.Actions.Coding.CandidateMaterialization.Materialize do
  @moduledoc """
  Materialize a compiler-owned CandidateMaterialization descriptor into the
  existing object-backed validation resource path.

  Task and principal come only from trusted execution context. The compiler
  pins `pinned_descriptor_digest` and binds checkpointed identities. Auto
  trust cannot substitute a different descriptor map.
  """

  use Jido.Action,
    name: "coding_candidate_materialize",
    description:
      "Materialize a compiler-owned candidate descriptor into an object-backed snapshot",
    category: "coding",
    tags: ["coding", "candidate", "materialization", "pipeline_internal"],
    schema: [
      workspace_id: [
        type: :string,
        required: true,
        doc: "Opaque workspace lease id from acquire"
      ],
      candidate_materialization: [
        type: :map,
        required: true,
        doc: "Compiler-owned admitted candidate materialization descriptor"
      ],
      pinned_descriptor_digest: [
        type: :string,
        required: true,
        doc: "Compiler-pinned descriptor digest from the compiled graph"
      ],
      candidate_materialization_digest: [
        type: :string,
        required: true,
        doc: "Engine-checkpointed descriptor digest"
      ],
      source_commit_oid: [
        type: :string,
        required: true,
        doc: "Engine-checkpointed source commit oid"
      ],
      expected_tree_oid: [
        type: :string,
        required: true,
        doc: "Engine-checkpointed expected tree oid"
      ],
      acquired_base_commit: [
        type: :string,
        required: true,
        doc: "Engine-checkpointed acquired base commit"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CandidateMaterializationShell
  alias Arbor.Actions.Coding.ValidationResourceOwner
  alias Arbor.Actions.Coding.Workspace
  alias Arbor.Actions.Coding.WorkspaceLeaseRegistry
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

  @allowed_param_names MapSet.new(~w[
                         workspace_id
                         candidate_materialization
                         pinned_descriptor_digest
                         candidate_materialization_digest
                         source_commit_oid
                         expected_tree_oid
                         acquired_base_commit
                       ])

  def taint_roles do
    %{
      workspace_id: :control,
      candidate_materialization: :control,
      pinned_descriptor_digest: :control,
      candidate_materialization_digest: :control,
      source_commit_oid: :control,
      expected_tree_oid: :control,
      acquired_base_commit: :control
    }
  end

  def effect_class, do: :local_write

  def execution_idempotency, do: :idempotent_with_key

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, context) when is_map(params) and is_map(context) do
    Actions.emit_started(__MODULE__, %{workspace_id: param(params, :workspace_id)})

    result =
      with :ok <- reject_forbidden_params(params),
           {:ok, task_id, principal_id} <- trusted_identity(context),
           {:ok, workspace_id} <- require_binary(params, :workspace_id),
           {:ok, pin} <- require_binary(params, :pinned_descriptor_digest),
           {:ok, checkpoint_digest} <- require_binary(params, :candidate_materialization_digest),
           {:ok, source_commit_oid} <- require_binary(params, :source_commit_oid),
           {:ok, expected_tree_oid} <- require_binary(params, :expected_tree_oid),
           {:ok, acquired_base_commit} <- require_binary(params, :acquired_base_commit),
           descriptor_attrs <- param(params, :candidate_materialization),
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
           {:ok, view} <-
             inspect_lease(workspace_id, task_id, principal_id, context),
           :ok <- require_owned_workspace(view),
           :ok <- require_acquired_base(view, acquired_base_commit),
           identities <-
             bind_caller(
               workspace_id,
               task_id,
               principal_id,
               source_commit_oid,
               expected_tree_oid,
               digest,
               acquired_base_commit,
               nil,
               registry_server(context)
             ) do
        case WorkspaceLeaseRegistry.inspect_object_backed_validation_binding(
               workspace_id,
               identities
             ) do
          {:ok, binding} ->
            reuse_or_rematerialize(
              binding,
              workspace_id,
              task_id,
              principal_id,
              descriptor,
              digest,
              source_commit_oid,
              expected_tree_oid,
              acquired_base_commit,
              identities
            )

          {:error, :not_found} ->
            materialize_fresh(
              workspace_id,
              task_id,
              principal_id,
              descriptor,
              digest,
              identities
            )

          {:error, reason} ->
            {:error, reason}
        end
      end

    case result do
      {:ok, payload} ->
        Actions.emit_completed(__MODULE__, %{workspace_id: payload["workspace_id"]})
        {:ok, payload}

      {:error, reason} = error ->
        Actions.emit_failed(__MODULE__, reason)
        error
    end
  end

  def run(_params, _context), do: {:error, :malformed_admission_input}

  defp materialize_fresh(workspace_id, task_id, principal_id, descriptor, digest, identities) do
    input = %{
      workspace_id: workspace_id,
      task_id: task_id,
      principal_id: principal_id,
      candidate_materialization: CandidateMaterialization.to_map(descriptor)
    }

    input =
      case Map.get(identities, :server) do
        nil -> input
        server -> Map.put(input, :server, server)
      end

    case CandidateMaterializationShell.admit_and_materialize(input) do
      {:ok, raw} ->
        with {:ok, encoded} <-
               encode_result(
                 raw,
                 digest,
                 descriptor.source_commit_oid,
                 descriptor.expected_tree_oid,
                 identities.acquired_base_commit,
                 workspace_id
               ),
             {:ok, _bound} <-
               WorkspaceLeaseRegistry.bind_existing_object_backed_validation_resource(
                 encoded["resource_id"],
                 bind_caller(
                   workspace_id,
                   task_id,
                   principal_id,
                   descriptor.source_commit_oid,
                   descriptor.expected_tree_oid,
                   digest,
                   identities.acquired_base_commit,
                   encoded["hidden_ref"],
                   Map.get(identities, :server)
                 )
               ) do
          {:ok, encoded}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reuse_or_rematerialize(
         binding,
         workspace_id,
         task_id,
         principal_id,
         descriptor,
         digest,
         source_commit_oid,
         expected_tree_oid,
         acquired_base_commit,
         identities
       ) do
    case encode_result(
           binding,
           digest,
           source_commit_oid,
           expected_tree_oid,
           acquired_base_commit,
           workspace_id
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
            materialize_fresh(
              workspace_id,
              task_id,
              principal_id,
              descriptor,
              digest,
              identities
            )
          end
        else
          error
        end
    end
  end

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

  defp trusted_identity(context) do
    task_id = Workspace.context_task_id(context)
    principal_id = Workspace.context_principal_id(context)

    if is_binary(task_id) and String.trim(task_id) != "" and is_binary(principal_id) and
         String.trim(principal_id) != "" do
      {:ok, task_id, principal_id}
    else
      {:error, :invalid_task_principal}
    end
  end

  defp inspect_lease(workspace_id, task_id, principal_id, context) do
    opts =
      case registry_server(context) do
        nil -> []
        server -> [server: server]
      end

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

  defp bind_caller(
         workspace_id,
         task_id,
         principal_id,
         source_commit_oid,
         expected_tree_oid,
         digest,
         acquired_base_commit,
         evidence_ref,
         server
       ) do
    caller = %{
      task_id: task_id,
      principal_id: principal_id,
      workspace_id: workspace_id,
      source_commit_oid: source_commit_oid,
      expected_tree_oid: expected_tree_oid,
      candidate_materialization_digest: digest,
      acquired_base_commit: acquired_base_commit,
      evidence_ref: evidence_ref
    }

    if server, do: Map.put(caller, :server, server), else: caller
  end

  defp registry_server(context) do
    context
    |> Workspace.registry_caller(%{})
    |> Map.get(:server)
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

  defp reject_forbidden_params(params) do
    names =
      params
      |> Map.keys()
      |> Enum.map(fn
        key when is_atom(key) -> Atom.to_string(key)
        key when is_binary(key) -> key
        _ -> ""
      end)

    normalized = MapSet.new(names)

    cond do
      "" in names ->
        {:error, :invalid_materialization_params}

      length(names) != MapSet.size(normalized) ->
        {:error, :invalid_materialization_params}

      not MapSet.subset?(normalized, @allowed_param_names) ->
        {:error, :invalid_materialization_params}

      true ->
        :ok
    end
  end

  defp require_binary(params, key) do
    value = param(params, key)

    if is_binary(value) and String.trim(value) != "" and String.valid?(value),
      do: {:ok, value},
      else: {:error, :compiler_descriptor_binding_missing}
  end

  defp param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp string_field(map, key) when is_atom(key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    if is_binary(value) and value != "", do: value, else: nil
  end
end
