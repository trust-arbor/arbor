defmodule Arbor.Actions.Coding.SecurityRegression do
  @moduledoc """
  Actions-side two-revision security-regression validation.

  `Validate` is registered for the executable CodingPlan security profile. The
  profile's reviewed graph and semantic preflight bind it to a one-shot Council
  attestation and a capped timeout.
  """
end

defmodule Arbor.Actions.Coding.SecurityRegression.Validate do
  @moduledoc """
  Validate focused tests against the immutable tree reviewed by the council.

  The action accepts only an opaque review attestation id and bounded timeout.
  The registry claims the one-shot token before the shell can spawn code, then
  supplies the authoritative workspace, revisions, tests, and profile.
  """

  use Jido.Action,
    name: "coding_security_regression_validate",
    description: "Validate a security regression against candidate and exact base revisions",
    category: "coding",
    tags: ["coding", "security", "regression", "test", "two-revision"],
    schema: [
      review_attestation_id: [
        type: :string,
        required: true,
        doc: "One-shot reviewed-tree attestation id"
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
      review_attestation_id: :control,
      timeout: :control
    }
  end

  def effect_class, do: :process_spawn

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, context) when is_map(params) and is_map(context) do
    Actions.emit_started(__MODULE__, %{
      review_attestation_id: param(params, :review_attestation_id)
    })

    with {:ok, input} <- Core.new(params),
         {:ok, result} <- Shell.run(input, context) do
      Actions.emit_completed(__MODULE__, %{
        review_attestation_id: input.review_attestation_id,
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
