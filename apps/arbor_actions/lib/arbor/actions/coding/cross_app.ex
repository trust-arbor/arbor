defmodule Arbor.Actions.Coding.CrossApp do
  @moduledoc """
  Actions-side cross-app dependency-surface validation.

  `Validate` is registered for the executable CodingPlan `cross_app` profile.
  Authority is a live workspace lease resolved via task_id + principal; the
  opaque `workspace_id` alone is not sufficient.
  """
end

defmodule Arbor.Actions.Coding.CrossApp.Validate do
  @moduledoc """
  Validate the changed cross-app dependency surface for a leased workspace.

  Derives changed files from the lease base through the dirty worktree,
  freezes candidate `apps/*/mix.exs` bytes and a path/mode/blob manifest with the
  committable tree OID, loads the base-commit blob manifest + mix.exs at the
  validated full lease OID, derives changed paths from those two immutable
  manifests, and selects via base-plus-candidate topology comparison (union path
  classification; full candidate validation on app add/remove/edge change;
  focused downstream closure when topology is unchanged). Then runs (fail-closed,
  later stages skipped on earlier failure):

  1. umbrella compile with `--warnings-as-errors` (dev environment; Mix
     compiles attested deps into the empty private `MIX_BUILD_PATH`)
  2. xref graph evidence with `--no-deps-check` (does not claim zero cycles)
  3. repeat the warning-strict compile under explicit `MIX_ENV=test`
  4. focused per-file tests under an aggregate monotonic budget that starts
     only after the test-environment compile succeeds. Batches run
     sequentially under one shared absolute deadline. Each Mix child is
     capped by `min(intensive Shell ceiling, remaining aggregate budget)`
     (profile-aware, hard max 1_200_000 ms per child). Admission starts the
     first batch whenever residual aggregate budget is positive — per-batch
     ceilings are never summed as a predicted total duration. The aggregate
     test-stage budget is a separate reviewed ceiling (hard max 4_200_000 ms),
     further bounded by the coding plan wall clock at compile time. Exact
     inventory is preserved; tags are never excluded.

  Domain failures return `{:ok, %{passed: false, ...}}` so the DOT rework
  branch can run; authority/setup/execution failures return `{:error, reason}`.
  """

  use Jido.Action,
    name: "coding_cross_app_validate",
    description:
      "Validate dependency-bootstrapped compile, xref, MIX_ENV=test compile, and downstream tests for the changed cross-app surface",
    category: "coding",
    tags: ["coding", "cross_app", "compile", "xref", "test", "umbrella"],
    schema: [
      workspace_id: [
        type: :string,
        required: true,
        doc: "Opaque workspace lease id (resolved only via task_id + principal)"
      ],
      timeout: [
        type: :non_neg_integer,
        doc:
          "Per-operation Mix process timeout in milliseconds (1,000 to 1,200,000 under intensive)"
      ],
      stage_timeout: [
        type: :non_neg_integer,
        doc:
          "Optional whole-validation timeout in milliseconds (1,000 up to the Actions-owned whole-stage maximum of three intensive pre-test ceilings plus the aggregate test-stage maximum); caps every contained stage without widening per-operation limits"
      ],
      test_stage_timeout: [
        type: :non_neg_integer,
        doc:
          "Aggregate sequential test-stage timeout in milliseconds (1,000 to 4,200,000); distinct from the intensive per-process Shell ceiling"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.Shell
  alias Arbor.Actions.Coding.CrossApp.StaticReceiptBoundary

  def taint_roles do
    %{
      workspace_id: :control,
      timeout: :control,
      stage_timeout: :control,
      test_stage_timeout: :control
    }
  end

  def effect_class, do: :process_spawn

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, context) when is_map(params) and is_map(context) do
    Actions.emit_started(__MODULE__, %{
      workspace_id: param(params, :workspace_id)
    })

    with {:ok, params, window} <- take_window(params, context),
         {:ok, input} <- Core.new(params),
         {:ok, result} <- Shell.run(input, context, window) do
      Actions.emit_completed(__MODULE__, %{
        workspace_id: input.workspace_id,
        passed: result_passed(result),
        reason: result_reason(result)
      })

      {:ok, result}
    else
      {:error, reason} ->
        Actions.emit_failed(__MODULE__, reason)
        {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_cross_app_input}

  defp take_window(params, context) do
    with {:ok, params, param_progress} <-
           pop_alias(params, "cross_app_progress", :cross_app_progress),
         {:ok, params, param_binding} <-
           pop_alias(params, "cross_app_progress_binding", :cross_app_progress_binding),
         {:ok, context_progress} <-
           fetch_alias(context, "cross_app_progress", :cross_app_progress),
         {:ok, context_binding} <-
           fetch_alias(context, "cross_app_progress_binding", :cross_app_progress_binding) do
      resolve_window(
        params,
        context,
        param_progress,
        param_binding,
        context_progress,
        context_binding
      )
    end
  end

  defp resolve_window(
         params,
         context,
         param_progress,
         param_binding,
         context_progress,
         context_binding
       ) do
    progress = present_value(context_progress) || present_value(param_progress)
    context_binding = present_value(context_binding)
    param_binding = present_value(param_binding)
    boundary = StaticReceiptBoundary.state(context)

    cond do
      conflict?(param_progress, context_progress) ->
        {:error, :invalid_cross_app_input}

      conflict?(param_binding, context_binding) ->
        {:error, :invalid_cross_app_input}

      is_nil(progress) and is_nil(context_binding) and is_nil(param_binding) and
          boundary == :absent ->
        {:ok, params, :ordinary}

      is_nil(progress) and is_nil(context_binding) and is_nil(param_binding) and
          boundary == :invalid ->
        {:error, :invalid_trusted_cross_app_static_receipt_boundary}

      is_nil(progress) and is_nil(context_binding) and is_nil(param_binding) and
          boundary == :ready ->
        {:ok, params, :seed}

      is_nil(progress) ->
        {:error, :missing_progress}

      boundary != :ready ->
        {:error, :invalid_trusted_cross_app_static_receipt_boundary}

      is_nil(context_binding) ->
        {:error, :missing_progress_binding}

      true ->
        {:ok, params, {:window, progress, context_binding}}
    end
  end

  defp conflict?(left, right) do
    not is_nil(present_value(left)) and not is_nil(present_value(right)) and
      present_value(left) !== present_value(right)
  end

  defp present_value(""), do: nil
  defp present_value(nil), do: nil
  defp present_value(value), do: value

  defp pop_alias(map, string_key, atom_key) do
    has_string = Map.has_key?(map, string_key)
    has_atom = Map.has_key?(map, atom_key)

    cond do
      has_string and has_atom ->
        {:error, :invalid_cross_app_input}

      has_string ->
        {:ok, Map.delete(map, string_key), Map.get(map, string_key)}

      has_atom ->
        {:ok, Map.delete(map, atom_key), Map.get(map, atom_key)}

      true ->
        {:ok, map, nil}
    end
  end

  defp fetch_alias(map, string_key, atom_key) do
    has_string = Map.has_key?(map, string_key)
    has_atom = Map.has_key?(map, atom_key)

    cond do
      has_string and has_atom -> {:error, :invalid_cross_app_input}
      has_string -> {:ok, Map.get(map, string_key)}
      has_atom -> {:ok, Map.get(map, atom_key)}
      true -> {:ok, nil}
    end
  end

  defp result_passed(result) when is_map(result) do
    case Map.get(result, :passed, Map.get(result, "passed")) do
      value when is_boolean(value) ->
        value

      _ ->
        Map.get(result, "disposition_type") == "completed" or
          get_in(result, ["disposition", "type"]) == "completed"
    end
  end

  defp result_reason(result) when is_map(result) do
    Map.get(result, :reason) || Map.get(result, "reason") ||
      get_in(result, ["disposition", "reason"])
  end

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end
end
