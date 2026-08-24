defmodule Arbor.Actions.Coding.ContractChange do
  @moduledoc """
  Actions-side contract_change validation.

  `Validate` is registered for the executable CodingPlan `contract_change` profile.
  Authority is a live workspace lease resolved via task_id + principal; the
  opaque `workspace_id` alone is not sufficient.

  Compile and xref are source-compatibility evidence only. Binding council
  review owns semantic / consumer API compatibility.
  """
end

defmodule Arbor.Actions.Coding.ContractChange.Validate do
  @moduledoc """
  Validate a leased contract_change candidate against CONTRACT_RULES preflight
  and the arbor_kernel contract conformance suite.

  Derives changed files from immutable base and candidate snapshots, admits only
  a recognized contract surface, then runs two owner-owned Mix children:

  1. warning-strict compile + xref graph + census `--fail-on-violation`
     (source-compatibility evidence + executable CONTRACT_RULES admission)
  2. warning-strict exact-file contract tests

  Does not run the unbounded cross_app downstream suite. Domain failures return
  `{:ok, %{passed: false, ...}}`; authority/setup/mutation return `{:error, reason}`.
  """

  use Jido.Action,
    name: "coding_contract_change_validate",
    description:
      "Validate CONTRACT_RULES preflight and bounded contract tests for a leased contract change",
    category: "coding",
    tags: ["coding", "contract_change", "compile", "census", "test"],
    schema: [
      workspace_id: [
        type: :string,
        required: true,
        doc: "Opaque workspace lease id (resolved only via task_id + principal)"
      ],
      timeout: [
        type: :non_neg_integer,
        doc:
          "Per-operation Mix process timeout in milliseconds (1,000 to intensive Shell ceiling)"
      ],
      stage_timeout: [
        type: :non_neg_integer,
        doc:
          "Optional whole-validation timeout in milliseconds (1,000 up to two intensive child ceilings)"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.ContractChange.Core
  alias Arbor.Actions.Coding.ContractChange.Shell

  def taint_roles do
    %{
      workspace_id: :control,
      timeout: :control,
      stage_timeout: :control
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

  def run(_params, _context), do: {:error, :invalid_contract_change_input}

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end
end
