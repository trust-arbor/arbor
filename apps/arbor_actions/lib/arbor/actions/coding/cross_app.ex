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

  1. compile attested dependencies, then umbrella compile with
     `--no-deps-check --warnings-as-errors` (dev environment)
  2. xref graph evidence with `--no-deps-check` (does not claim zero cycles)
  3. repeat the dependency bootstrap and warning-strict compile under
     explicit `MIX_ENV=test`
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

    with {:ok, input} <- Core.new(params),
         {:ok, result} <- Shell.run(input, context) do
      Actions.emit_completed(__MODULE__, %{
        workspace_id: input.workspace_id,
        passed: result.passed,
        reason: result.reason
      })

      {:ok, result}
    else
      {:error, reason} ->
        Actions.emit_failed(__MODULE__, reason)
        {:error, reason}
    end
  end

  def run(_params, _context), do: {:error, :invalid_cross_app_input}

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end
end
