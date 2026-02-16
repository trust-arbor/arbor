defmodule Arbor.Actions.Judge.Evaluate do
  @moduledoc """
  Full LLM-as-judge evaluation pipeline.

  Runs evidence producers, optionally calls an LLM judge for qualitative
  critique, and stores the verdict. Supports two modes:

  - `:verification` — evidence-only, no LLM call. Fast and deterministic.
  - `:critique` — evidence + LLM judge. Full qualitative analysis. Default.

  ## Parameters

  | Name | Type | Required | Description |
  |------|------|----------|-------------|
  | `content` | string | yes | The text/output to evaluate |
  | `domain` | string | no | Rubric domain ("advisory", "code"). Default: "advisory" |
  | `mode` | atom | no | `:critique` or `:verification`. Default: `:critique` |
  | `perspective` | string | no | Perspective that produced the content |
  | `question` | string | no | Original question/prompt |
  | `reference_docs` | list | no | Reference document paths |
  | `perspective_prompt` | string | no | The perspective's system prompt |
  | `intent` | string | no | Task description/constraints |
  | `rubric` | map | no | Custom rubric (overrides domain preset) |
  | `llm_fn` | function | no | Override LLM call for testing |

  ## Returns

  - `verdict` — the `Verdict` struct
  - `evidence` — list of `Evidence` structs
  - `rubric` — the rubric used
  - `duration_ms` — total evaluation time
  - `run_id` — persistence run ID (if stored)
  """

  use Jido.Action,
    name: "judge_evaluate",
    description: "Evaluate output quality using LLM-as-judge with evidence producers",
    category: "judge",
    tags: ["judge", "evaluate", "quality", "llm"],
    schema: [
      content: [
        type: :string,
        required: true,
        doc: "The text/output to evaluate"
      ],
      domain: [
        type: :string,
        default: "advisory",
        doc: "Rubric domain (advisory, code)"
      ],
      mode: [
        type: :atom,
        default: :critique,
        doc: "Evaluation mode (:critique or :verification)"
      ],
      perspective: [
        type: :string,
        doc: "Perspective that produced the content"
      ],
      question: [
        type: :string,
        doc: "Original question/prompt"
      ],
      reference_docs: [
        type: {:list, :string},
        default: [],
        doc: "Reference document paths"
      ],
      perspective_prompt: [
        type: :string,
        doc: "The perspective's system prompt"
      ],
      intent: [
        type: :string,
        doc: "Task description/constraints"
      ],
      rubric: [
        type: :map,
        doc: "Custom rubric (overrides domain preset)"
      ],
      llm_fn: [
        type: :any,
        doc: "Override LLM call function for testing"
      ]
    ]

  alias Arbor.Actions
  alias Arbor.Actions.Judge.{EvidenceRunner, PromptBuilder, ResultStore, Rubrics}
  alias Arbor.Contracts.Judge.{Rubric, Verdict}

  def taint_roles do
    %{
      content: :data,
      domain: :control,
      mode: :control,
      perspective: :data,
      question: :data,
      reference_docs: :data,
      perspective_prompt: :data,
      intent: :data,
      rubric: :control,
      llm_fn: :control
    }
  end

  @impl true
  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, _context) do
    _content = params[:content]
    domain = params[:domain] || "advisory"
    mode = params[:mode] || :critique
    llm_fn = params[:llm_fn]

    Actions.emit_started(__MODULE__, %{domain: domain, mode: mode})
    start_time = System.monotonic_time(:millisecond)

    with {:ok, rubric} <- resolve_rubric(params[:rubric], domain),
         subject <- build_subject(params),
         context <- build_context(params),
         evidence <- EvidenceRunner.run(subject, context),
         {:ok, verdict} <- evaluate(subject, rubric, evidence, mode, llm_fn, params) do
      duration_ms = System.monotonic_time(:millisecond) - start_time

      # Store verdict
      run_id =
        case ResultStore.store(verdict, subject, rubric,
               judge_model: Map.get(verdict.meta, :judge_model, "evidence_only"),
               judge_provider: Map.get(verdict.meta, :judge_provider, "local"),
               evidence_count: length(evidence),
               duration_ms: duration_ms
             ) do
          {:ok, id} -> id
          _ -> nil
        end

      result = %{
        verdict: verdict,
        evidence: evidence,
        rubric: rubric,
        duration_ms: duration_ms,
        run_id: run_id
      }

      Actions.emit_completed(__MODULE__, %{
        domain: domain,
        mode: mode,
        overall_score: verdict.overall_score,
        recommendation: verdict.recommendation,
        duration_ms: duration_ms
      })

      {:ok, result}
    else
      {:error, reason} = error ->
        Actions.emit_failed(__MODULE__, %{domain: domain, mode: mode, reason: inspect(reason)})
        error
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp resolve_rubric(nil, domain) do
    case Rubrics.for_domain(domain) do
      {:ok, rubric} -> {:ok, rubric}
      {:error, :unknown_domain} -> {:error, {:unknown_domain, domain}}
    end
  end

  defp resolve_rubric(%Rubric{} = rubric, _domain), do: {:ok, rubric}

  defp resolve_rubric(rubric_map, _domain) when is_map(rubric_map) do
    Rubric.new(rubric_map)
  end

  defp build_subject(params) do
    %{
      content: params[:content] || "",
      perspective: params[:perspective],
      metadata: %{}
    }
  end

  defp build_context(params) do
    %{
      question: params[:question],
      reference_docs: params[:reference_docs] || [],
      perspective_prompt: params[:perspective_prompt],
      perspective: safe_to_atom(params[:perspective])
    }
  end

  defp evaluate(_subject, rubric, evidence, :verification, _llm_fn, _params) do
    # Verification mode: verdict from evidence scores alone
    overall = EvidenceRunner.aggregate_score(evidence)

    dimension_scores =
      Map.new(rubric.dimensions, fn dim ->
        # Use matching evidence score if available, else overall
        evidence_score =
          Enum.find_value(evidence, fn e ->
            if e.type == dim[:name], do: e.score
          end)

        {dim[:name], evidence_score || overall}
      end)

    recommendation =
      cond do
        overall >= 0.6 -> :keep
        overall >= 0.3 -> :revise
        true -> :reject
      end

    Verdict.new(%{
      overall_score: overall,
      dimension_scores: dimension_scores,
      strengths: extract_strengths(evidence),
      weaknesses: extract_weaknesses(evidence),
      recommendation: recommendation,
      mode: :verification,
      meta: %{
        judge_model: "evidence_only",
        judge_provider: "local",
        judge_confidence: 0.7,
        evidence_gaps: find_gaps(evidence, rubric)
      }
    })
  end

  defp evaluate(subject, rubric, evidence, :critique, llm_fn, params) do
    evidence_summary = EvidenceRunner.summarize(evidence)

    {system_prompt, user_prompt} =
      PromptBuilder.build(subject, rubric, evidence_summary, :critique, intent: params[:intent])

    case call_llm(system_prompt, user_prompt, llm_fn) do
      {:ok, response, llm_meta} ->
        case PromptBuilder.parse_response(response, rubric, :critique) do
          {:ok, verdict} ->
            # Enrich verdict meta with LLM info
            enriched_meta =
              Map.merge(verdict.meta, %{
                judge_model: Map.get(llm_meta, :model, "unknown"),
                judge_provider: Map.get(llm_meta, :provider, "unknown"),
                evidence_gaps: find_gaps(evidence, rubric),
                rubric_snapshot: Rubric.snapshot(rubric)
              })

            {:ok, %{verdict | meta: enriched_meta}}

          {:error, _} = parse_error ->
            parse_error
        end

      {:error, _} = llm_error ->
        llm_error
    end
  end

  defp call_llm(system_prompt, user_prompt, llm_fn) when is_function(llm_fn, 2) do
    llm_fn.(system_prompt, user_prompt)
  end

  defp call_llm(system_prompt, user_prompt, nil) do
    # Runtime bridge to Arbor.AI
    if Code.ensure_loaded?(Arbor.AI) and function_exported?(Arbor.AI, :generate_text, 2) do
      case apply(Arbor.AI, :generate_text, [
             user_prompt,
             [system_prompt: system_prompt, temperature: 0.15]
           ]) do
        {:ok, %{text: text} = response} ->
          meta = %{
            model: Map.get(response, :model, "unknown"),
            provider: Map.get(response, :provider, "unknown")
          }

          {:ok, text, meta}

        {:ok, text} when is_binary(text) ->
          {:ok, text, %{}}

        {:error, _} = error ->
          error
      end
    else
      {:error, :llm_unavailable}
    end
  end

  defp extract_strengths(evidence) do
    evidence
    |> Enum.filter(& &1.passed)
    |> Enum.map(&"#{&1.type}: #{&1.detail}")
  end

  defp extract_weaknesses(evidence) do
    evidence
    |> Enum.reject(& &1.passed)
    |> Enum.map(&"#{&1.type}: #{&1.detail}")
  end

  defp find_gaps(evidence, rubric) do
    evidence_types = MapSet.new(evidence, & &1.type)
    dimension_names = MapSet.new(rubric.dimensions, & &1[:name])

    MapSet.difference(dimension_names, evidence_types)
    |> MapSet.to_list()
    |> Enum.map(&to_string/1)
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(s) when is_atom(s), do: s

  defp safe_to_atom(s) when is_binary(s) do
    case Arbor.Common.SafeAtom.to_existing(s) do
      {:ok, atom} -> atom
      {:error, _} -> s
    end
  end
end
