defmodule Arbor.Actions.Judge.Quick do
  @moduledoc """
  Quick convenience action for judging output.

  Infers the domain from content heuristics, auto-selects mode,
  and delegates to `Judge.Evaluate`. Useful for ad-hoc quality checks.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `content` | string | yes | The text/output to evaluate |
  | `domain` | string | no | Override domain inference |
  | `mode` | atom | no | Override mode (default: inferred) |
  | `llm_fn` | function | no | Override LLM call for testing |

  ## Returns

  Same as `Judge.Evaluate`.
  """

  use Jido.Action,
    name: "judge_quick",
    description: "Quick quality check — infers domain, auto-selects mode",
    category: "judge",
    tags: ["judge", "quick", "quality"],
    schema: [
      content: [
        type: :string,
        required: true,
        doc: "The text/output to evaluate"
      ],
      domain: [
        type: :string,
        doc: "Override domain inference"
      ],
      mode: [
        type: :atom,
        doc: "Override mode (:critique or :verification)"
      ],
      llm_fn: [
        type: :any,
        doc: "Override LLM call function for testing"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Judge.Evaluate

  def taint_roles do
    %{
      content: :data,
      domain: :control,
      mode: :control,
      llm_fn: :control
    }
  end

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, context) do
    content = params[:content]
    domain = params[:domain] || infer_domain(content)
    mode = params[:mode] || infer_mode(content)

    Actions.emit_started(__MODULE__, %{domain: domain, mode: mode})

    eval_params =
      params
      |> Map.put(:domain, domain)
      |> Map.put(:mode, mode)

    case Evaluate.run(eval_params, context) do
      {:ok, result} ->
        Actions.emit_completed(__MODULE__, %{
          domain: domain,
          mode: mode,
          overall_score: result.verdict.overall_score
        })

        {:ok, result}

      {:error, _} = error ->
        Actions.emit_failed(__MODULE__, %{domain: domain, reason: "evaluation_failed"})
        error
    end
  end

  # ============================================================================
  # Domain & Mode Inference
  # ============================================================================

  @code_indicators ~w(defmodule def function class module import require use)
  @advisory_indicators ~w(recommend consider suggest analysis perspective security stability)

  defp infer_domain(content) when is_binary(content) do
    lower = String.downcase(content)

    code_score = Enum.count(@code_indicators, &String.contains?(lower, &1))
    advisory_score = Enum.count(@advisory_indicators, &String.contains?(lower, &1))

    if code_score > advisory_score, do: "code", else: "advisory"
  end

  defp infer_domain(_), do: "advisory"

  defp infer_mode(content) when is_binary(content) do
    # Short content or simple format → verification only
    if String.length(content) < 200, do: :verification, else: :critique
  end

  defp infer_mode(_), do: :verification
end
