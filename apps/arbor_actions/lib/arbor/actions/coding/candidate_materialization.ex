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
      ],
      materialize_window: [
        type: :integer,
        required: true,
        doc: "Compiler-owned capacity window ordinal; not identity"
      ],
      evidence_ref: [
        type: :string,
        required: false,
        doc: "Checkpointed hidden evidence ref; omitted on first pin"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CandidateMaterializationShell
  alias Arbor.Actions.Coding.Workspace

  @max_materialize_window 2_000

  @allowed_param_names MapSet.new(~w[
                         workspace_id
                         candidate_materialization
                         pinned_descriptor_digest
                         candidate_materialization_digest
                         source_commit_oid
                         expected_tree_oid
                         acquired_base_commit
                         materialize_window
                         evidence_ref
                       ])

  def taint_roles do
    %{
      workspace_id: :control,
      candidate_materialization: :control,
      pinned_descriptor_digest: :control,
      candidate_materialization_digest: :control,
      source_commit_oid: :control,
      expected_tree_oid: :control,
      acquired_base_commit: :control,
      materialize_window: :control,
      evidence_ref: :control
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
           {:ok, window} <- admit_materialize_window(params),
           {:ok, task_id, principal_id} <- trusted_identity(context),
           {:ok, workspace_id} <- require_binary(params, :workspace_id),
           {:ok, pin} <- require_binary(params, :pinned_descriptor_digest),
           {:ok, checkpoint_digest} <- require_binary(params, :candidate_materialization_digest),
           {:ok, source_commit_oid} <- require_binary(params, :source_commit_oid),
           {:ok, expected_tree_oid} <- require_binary(params, :expected_tree_oid),
           {:ok, acquired_base_commit} <- require_binary(params, :acquired_base_commit),
           {:ok, evidence_ref} <- admit_window_evidence_ref(window, params) do
        input = %{
          workspace_id: workspace_id,
          task_id: task_id,
          principal_id: principal_id,
          candidate_materialization: param(params, :candidate_materialization),
          pinned_descriptor_digest: pin,
          candidate_materialization_digest: checkpoint_digest,
          source_commit_oid: source_commit_oid,
          expected_tree_oid: expected_tree_oid,
          acquired_base_commit: acquired_base_commit,
          require_evidence_ref: window > 0
        }

        input =
          case evidence_ref do
            ref when is_binary(ref) and ref != "" -> Map.put(input, :evidence_ref, ref)
            _ -> input
          end

        input =
          case registry_server(context) do
            nil -> input
            server -> Map.put(input, :server, server)
          end

        CandidateMaterializationShell.resolve_or_materialize(input)
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

  defp admit_materialize_window(params) do
    value = param(params, :materialize_window)

    if is_integer(value) and value >= 0 and value <= @max_materialize_window,
      do: {:ok, value},
      else: {:error, :invalid_materialization_params}
  end

  defp admit_window_evidence_ref(window, params) do
    case param(params, :evidence_ref) do
      value when value in [nil, ""] ->
        admit_optional_or_required_ref(window)

      ref when is_binary(ref) ->
        cond do
          not String.valid?(ref) ->
            {:error, :incomplete_immutable_review_binding}

          String.trim(ref) == "" ->
            {:error, :incomplete_immutable_review_binding}

          true ->
            {:ok, ref}
        end

      _other ->
        {:error, :incomplete_immutable_review_binding}
    end
  end

  defp admit_optional_or_required_ref(window) when window > 0,
    do: {:error, :incomplete_immutable_review_binding}

  defp admit_optional_or_required_ref(_window), do: {:ok, nil}

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

  defp registry_server(context) do
    context
    |> Workspace.registry_caller(%{})
    |> Map.get(:server)
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
end
