defmodule Arbor.Consensus.ConsultationLog do
  @moduledoc """
  Persists council consultation results for LLM-as-judge evaluation.

  Every advisory evaluation is automatically logged with full metadata:
  question, perspective, provider, model, response, timing, scores.
  Results are stored as `EvalRun` + `EvalResult` records in the existing
  eval tables via `Arbor.Persistence`.

  ## Dataset Schema

  Each consultation creates an `EvalRun` (domain: `"advisory_consultation"`)
  grouping one `EvalResult` per perspective. This enables:

  - Comparing model performance per perspective over time
  - LLM-as-judge evaluation of advisory quality
  - JSONL export for offline analysis

  ## Graceful Degradation

  Uses runtime bridge to `Arbor.Persistence`. When Postgres isn't running,
  results are silently dropped (logged at debug level). This ensures
  consultations never fail due to persistence issues.
  """

  require Logger

  @persistence_mod Arbor.Persistence
  @domain "advisory_consultation"

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Log a single perspective evaluation result.

  Called automatically from `AdvisoryLLM.do_evaluate/3` after each successful
  LLM call. Creates an individual `EvalResult` record.

  ## Parameters

  - `question` — the consultation question/description
  - `perspective` — atom like `:security`, `:brainstorming`
  - `eval` — the `Evaluation` struct with vote, confidence, reasoning, etc.
  - `llm_meta` — map with `:provider`, `:model`, `:duration_ms`, `:raw_response`,
    `:system_prompt`, `:user_prompt`
  """
  @spec log_single(String.t(), atom(), map(), map(), keyword()) :: :ok
  def log_single(question, perspective, eval, llm_meta, opts \\ []) do
    if available?() do
      run_id =
        case Keyword.get(opts, :run_id) do
          nil -> ensure_run(question)
          id -> id
        end

      result_attrs = build_result(run_id, question, perspective, eval, llm_meta)

      case apply(@persistence_mod, :insert_eval_result, [result_attrs]) do
        {:ok, _} ->
          Logger.debug("ConsultationLog: stored #{perspective} result for run #{run_id}")

        {:error, reason} ->
          Logger.debug("ConsultationLog: failed to store #{perspective}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc """
  Create an EvalRun upfront for a batch consultation.

  Returns a run ID that should be passed as `:consultation_id` in eval opts
  so all perspective results log under the same run.
  """
  @spec create_run(String.t(), [atom()], keyword()) :: String.t() | nil
  def create_run(question, perspectives, opts \\ []) do
    if available?() do
      run_id = generate_id()
      context = Keyword.get(opts, :context, %{})
      reference_docs = get_in(context, [:reference_docs]) || []

      run_attrs = %{
        id: run_id,
        domain: @domain,
        model: "multi",
        provider: "multi",
        dataset: slugify(question),
        sample_count: length(perspectives),
        status: "running",
        config: %{
          "question" => question,
          "context" => stringify_keys(context),
          "reference_docs" => reference_docs
        },
        metadata: %{
          "source" => "consult_all",
          "perspective_count" => length(perspectives),
          "perspectives" => Enum.map(perspectives, &to_string/1)
        }
      }

      case apply(@persistence_mod, :insert_eval_run, [run_attrs]) do
        {:ok, _} -> run_id
        {:error, _} -> nil
      end
    end
  end

  @doc """
  Mark a consultation run as completed and update sample count.
  """
  @spec complete_run(String.t() | nil, [{atom(), term()}]) :: :ok
  def complete_run(nil, _results), do: :ok

  def complete_run(run_id, results) do
    if available?() do
      successful = Enum.count(results, fn {_, eval} -> is_map(eval) end)

      apply(@persistence_mod, :update_eval_run, [
        run_id,
        %{status: "completed", sample_count: successful}
      ])
    end

    :ok
  end

  @doc """
  Log a batch of perspective results from a full consultation.

  Called from `Consult.ask/3` after all parallel evaluations complete.
  Creates an `EvalRun` with batch-inserted `EvalResult` records.

  ## Parameters

  - `question` — the consultation question/description
  - `results` — list of `{perspective, eval}` tuples
  - `opts` — consultation options (context, reference_docs, etc.)
  """
  @spec log_consultation(String.t(), [{atom(), map()}], keyword()) :: {:ok, String.t()} | :ok
  def log_consultation(question, results, opts \\ []) do
    if available?() do
      run_id = generate_id()
      context = Keyword.get(opts, :context, %{})
      reference_docs = Keyword.get(opts, :reference_docs, [])

      run_attrs = %{
        id: run_id,
        domain: @domain,
        model: "multi",
        provider: "multi",
        dataset: slugify(question),
        sample_count: length(results),
        status: "completed",
        config: %{
          "question" => question,
          "context" => stringify_keys(context),
          "reference_docs" => reference_docs
        },
        metadata: %{
          "source" => "consult_all",
          "perspective_count" => length(results),
          "perspectives" => Enum.map(results, fn {p, _} -> to_string(p) end)
        }
      }

      case apply(@persistence_mod, :insert_eval_run, [run_attrs]) do
        {:ok, _} ->
          result_attrs =
            Enum.map(results, fn {perspective, eval} ->
              # Extract provider/model from eval metadata if available
              llm_meta = Map.get(eval, :llm_meta, %{})
              build_result(run_id, question, perspective, eval, llm_meta)
            end)

          apply(@persistence_mod, :insert_eval_results_batch, [result_attrs])
          Logger.debug("ConsultationLog: stored consultation #{run_id} with #{length(results)} results")
          {:ok, run_id}

        {:error, reason} ->
          Logger.debug("ConsultationLog: failed to create run: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  List consultation runs with optional filters.

  ## Filters

  - `:limit` — max results (default: 50)
  - `:status` — "completed", "failed"
  """
  @spec list_consultations(keyword()) :: {:ok, [map()]} | {:error, :unavailable}
  def list_consultations(filters \\ []) do
    if available?() do
      filters = Keyword.put(filters, :domain, @domain)
      apply(@persistence_mod, :list_eval_runs, [filters])
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Get a single consultation with all perspective results preloaded.
  """
  @spec get_consultation(String.t()) :: {:ok, map()} | {:error, term()}
  def get_consultation(run_id) do
    if available?() do
      apply(@persistence_mod, :get_eval_run, [run_id])
    else
      {:error, :unavailable}
    end
  end

  @doc """
  Export consultation results as JSONL for offline LLM-as-judge evaluation.

  Each line is a JSON object with all fields needed for judge evaluation:
  question, perspective, provider, model, response, vote, confidence, scores.
  """
  @spec export_jsonl(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def export_jsonl(path, filters \\ []) do
    case list_consultations(filters) do
      {:ok, runs} ->
        lines =
          Enum.flat_map(runs, fn run ->
            case get_consultation(run.id) do
              {:ok, run_with_results} ->
                Enum.map(run_with_results.results, fn result ->
                  %{
                    consultation_id: run.id,
                    question: get_in(run.config, ["question"]) || run.dataset,
                    domain: run.domain,
                    perspective: result.sample_id,
                    provider: get_in(result.metadata, ["provider"]),
                    model: get_in(result.metadata, ["model"]),
                    input: result.input,
                    response: result.actual,
                    vote: get_in(result.scores, ["vote"]),
                    confidence: get_in(result.scores, ["confidence"]),
                    risk_score: get_in(result.scores, ["risk_score"]),
                    benefit_score: get_in(result.scores, ["benefit_score"]),
                    duration_ms: result.duration_ms,
                    concerns: get_in(result.metadata, ["concerns"]),
                    recommendations: get_in(result.metadata, ["recommendations"]),
                    created_at: result.inserted_at
                  }
                  |> Jason.encode!()
                end)

              {:error, _} ->
                []
            end
          end)

        content = Enum.join(lines, "\n") <> "\n"
        File.write(path, content)
        {:ok, length(lines)}

      {:error, _} = error ->
        error
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp available? do
    Code.ensure_loaded?(@persistence_mod) and
      function_exported?(@persistence_mod, :insert_eval_run, 1) and
      repo_started?()
  end

  defp repo_started? do
    repo = Arbor.Persistence.Repo

    Code.ensure_loaded?(repo) and
      is_pid(GenServer.whereis(repo))
  rescue
    _ -> false
  end

  defp ensure_run(question) do
    # For single-perspective calls, create a minimal run
    run_id = generate_id()

    run_attrs = %{
      id: run_id,
      domain: @domain,
      model: "multi",
      provider: "multi",
      dataset: slugify(question),
      sample_count: 1,
      status: "completed",
      config: %{"question" => question},
      metadata: %{"source" => "consult_one"}
    }

    case apply(@persistence_mod, :insert_eval_run, [run_attrs]) do
      {:ok, _} -> run_id
      {:error, _} -> run_id
    end
  end

  defp build_result(run_id, _question, perspective, eval, llm_meta) do
    %{
      id: generate_id(),
      run_id: run_id,
      sample_id: to_string(perspective),
      input: Map.get(llm_meta, :user_prompt, ""),
      actual: Map.get(llm_meta, :raw_response, Map.get(eval, :reasoning, "")),
      passed: Map.get(eval, :vote) == :approve,
      scores: %{
        "vote" => to_string(Map.get(eval, :vote, "unknown")),
        "confidence" => Map.get(eval, :confidence, 0.0),
        "risk_score" => Map.get(eval, :risk_score, 0.0),
        "benefit_score" => Map.get(eval, :benefit_score, 0.0)
      },
      duration_ms: Map.get(llm_meta, :duration_ms, 0),
      metadata: %{
        "provider" => to_string(Map.get(llm_meta, :provider, "")),
        "model" => to_string(Map.get(llm_meta, :model, "")),
        "perspective" => to_string(perspective),
        "system_prompt_hash" => hash_prompt(Map.get(llm_meta, :system_prompt, "")),
        "concerns" => Map.get(eval, :concerns, []),
        "recommendations" => Map.get(eval, :recommendations, [])
      }
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp slugify(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split()
    |> Enum.take(8)
    |> Enum.join("-")
  end

  defp slugify(_), do: "unknown"

  defp hash_prompt(prompt) when is_binary(prompt) do
    :crypto.hash(:sha256, prompt) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp hash_prompt(_), do: ""

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_keys(other), do: other
end
