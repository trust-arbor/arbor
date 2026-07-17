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
  selects directly changed apps plus downstream in-umbrella dependents, then
  runs (fail-closed, later stages skipped on earlier failure):

  1. umbrella compile with `--warnings-as-errors` (dev environment)
  2. xref graph evidence (does not claim zero cycles)
  3. explicit `MIX_ENV=test` compile with `--warnings-as-errors`
  4. focused per-file tests under an aggregate monotonic budget that starts
     only after the test-environment compile succeeds. Each Mix process is
     still capped by the per-operation Shell spawn-capable ceiling.

  Domain failures return `{:ok, %{passed: false, ...}}` so the DOT rework
  branch can run; authority/setup/execution failures return `{:error, reason}`.
  """

  use Jido.Action,
    name: "coding_cross_app_validate",
    description:
      "Validate compile, xref, MIX_ENV=test compile, and downstream tests for the changed cross-app surface",
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
        doc: "Per-operation Mix process timeout in milliseconds (1,000 to 600,000)"
      ],
      test_stage_timeout: [
        type: :non_neg_integer,
        doc:
          "Aggregate sequential test-stage timeout in milliseconds (1,000 to 1,200,000); independent of per-process Shell ceiling"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.CrossApp.Core
  alias Arbor.Actions.Coding.CrossApp.Shell

  def taint_roles do
    %{
      workspace_id: :control,
      timeout: :control,
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
