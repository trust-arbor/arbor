defmodule Arbor.Actions.Coding.SecurityRegression do
  @moduledoc """
  Actions-side two-revision security-regression validation.

  `Validate` is intentionally not registered yet. Phase 5 integration enables
  the reviewed profile only after this primitive and semantic preflight are
  wired together.
  """
end

defmodule Arbor.Actions.Coding.SecurityRegression.Validate do
  @moduledoc """
  Prove that focused security tests pass on a leased candidate workspace and
  fail as real ExUnit test failures at that lease's exact base commit.

  The action accepts only an opaque workspace lease id, sorted repository-
  relative test paths, and a bounded timeout. Repository paths, refs, commands,
  expected exits, environment, and build paths are registry- or shell-derived.
  """

  use Jido.Action,
    name: "coding_security_regression_validate",
    description: "Validate a security regression against candidate and exact base revisions",
    category: "coding",
    tags: ["coding", "security", "regression", "test", "two-revision"],
    schema: [
      workspace_id: [
        type: :string,
        required: true,
        doc: "Opaque workspace lease id"
      ],
      test_paths: [
        type: {:list, :string},
        required: true,
        doc: "Sorted repository-relative *_test.exs paths"
      ],
      timeout: [
        type: :non_neg_integer,
        doc: "Per-revision timeout in milliseconds (1,000 to 600,000)"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Coding.SecurityRegression.Core
  alias Arbor.Actions.Coding.SecurityRegression.Shell

  def taint_roles do
    %{
      workspace_id: :control,
      test_paths: {:control, requires: [:path_traversal]},
      timeout: :control
    }
  end

  def effect_class, do: :process_spawn

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, context) when is_map(params) and is_map(context) do
    Actions.emit_started(__MODULE__, %{
      workspace_id: param(params, :workspace_id),
      test_count: params |> param(:test_paths) |> List.wrap() |> length()
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

  def run(_params, _context), do: {:error, :invalid_security_regression_input}

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> value
      :error -> Map.get(params, Atom.to_string(key))
    end
  end
end
