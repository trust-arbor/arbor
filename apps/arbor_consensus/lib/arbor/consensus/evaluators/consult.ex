defmodule Arbor.Consensus.Evaluators.Consult do
  @moduledoc """
  Convenience module for consulting evaluator agents directly.

  Instead of routing through a Coordinator, you pick an evaluator
  and ask it questions. You are the Coordinator — the evaluator
  provides analysis, you make decisions.

  ## Examples

      alias Arbor.Consensus.Evaluators.{AdvisoryLLM, Consult}

      # Ask all perspectives
      {:ok, results} = Consult.ask(AdvisoryLLM, "Should caching use Redis or ETS?",
        context: %{constraints: "must survive restarts"}
      )

      Enum.each(results, fn {perspective, eval} ->
        IO.puts("=== \#{perspective} ===")
        IO.puts(eval.reasoning)
      end)

      # Ask a single perspective
      {:ok, eval} = Consult.ask_one(AdvisoryLLM, "How should TopicMatcher work?", :design_review,
        context: %{options: ["pattern matching", "LLM classification", "hybrid"]}
      )
  """

  alias Arbor.Consensus.ConsultationLog
  alias Arbor.Contracts.Consensus.Proposal

  @default_timeout 300_000
  # :signing_authority keeps nested Engine runs in fixed-facade authority mode
  # when the parent action was authorized via SigningAuthority (never silent
  # legacy signer/authorizer). Opaque token only — no private keys.
  @nested_engine_opt_allowlist [:signer, :authorizer, :signing_authority, :max_depth]

  @doc """
  Ask an evaluator all its perspectives about a question.

  Builds a lightweight advisory proposal from the description and context,
  evaluates from each perspective in parallel, and returns the collected results.

  ## Options

  - `:context` — map of additional context for the evaluator (default: `%{}`)
  - `:timeout` — per-perspective timeout in ms (default: 120_000)
  - `:ai_module` — override the AI module (useful for testing)
  - `:provider_model` — override provider:model for all perspectives (e.g. `"anthropic:claude-sonnet-4-5-20250929"`)

  Returns `{:ok, [{perspective, evaluation}]}` sorted by perspective,
  or `{:error, reason}` if proposal creation fails.
  """
  @spec ask(module(), String.t(), keyword()) ::
          {:ok, [{atom(), Arbor.Contracts.Consensus.Evaluation.t()}]} | {:error, term()}
  def ask(evaluator_module, description, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # Pre-create council agents sequentially when research mode is enabled.
    # This avoids SessionManager contention when 13 agents try to create
    # sessions simultaneously through a single GenServer.
    if Keyword.get(opts, :research, false) and
         function_exported?(evaluator_module, :ensure_all_council_agents, 1) do
      evaluator_module.ensure_all_council_agents(opts)
    end

    with {:ok, proposal} <- build_advisory_proposal(description, context) do
      perspectives = evaluator_module.perspectives()

      # Create a shared consultation run so all perspectives log under one EvalRun
      consultation_id = ConsultationLog.create_run(description, perspectives, opts)

      eval_opts =
        opts |> Keyword.drop([:context]) |> Keyword.put(:consultation_id, consultation_id)

      tasks =
        Enum.map(perspectives, fn perspective ->
          {perspective,
           Task.async(fn ->
             evaluator_module.evaluate(proposal, perspective, eval_opts)
           end)}
        end)

      results =
        tasks
        |> Enum.map(fn {perspective, task} ->
          case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
            {:ok, {:ok, evaluation}} -> {perspective, evaluation}
            {:ok, {:error, reason}} -> {perspective, {:error, reason}}
            nil -> {perspective, {:error, :timeout}}
          end
        end)
        |> Enum.sort_by(fn {perspective, _} -> perspective end)

      # Update the run with final sample count
      ConsultationLog.complete_run(consultation_id, results)

      {:ok, results}
    end
  end

  @doc """
  Ask an evaluator a single perspective about a question.

  Like `ask/3` but for one perspective only — no parallel tasks.

  ## Options

  Same as `ask/3`, including `:provider_model` for provider:model override.
  """
  @spec ask_one(module(), String.t(), atom(), keyword()) ::
          {:ok, Arbor.Contracts.Consensus.Evaluation.t()} | {:error, term()}
  def ask_one(evaluator_module, description, perspective, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    eval_opts = Keyword.drop(opts, [:context])

    with {:ok, proposal} <- build_advisory_proposal(description, context) do
      evaluator_module.evaluate(proposal, perspective, eval_opts)
    end
  end

  @doc """
  Ask a single perspective across all providers simultaneously.

  Runs the same perspective prompt through each provider in parallel,
  so diversity comes from model differences rather than prompt differences.

  Provider list is derived dynamically from AdvisoryLLM's perspective_models map,
  extracting the unique provider:model pairs.

  Returns `{:ok, [{provider_model, evaluation}]}` sorted by provider_model,
  or `{:error, reason}` if proposal creation fails.
  """
  @spec ask_multi_model(module(), String.t(), atom(), keyword()) ::
          {:ok, [{String.t(), Arbor.Contracts.Consensus.Evaluation.t()}]} | {:error, term()}
  def ask_multi_model(evaluator_module, description, perspective, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, proposal} <- build_advisory_proposal(description, context) do
      eval_opts = Keyword.drop(opts, [:context])

      # Get unique provider:model pairs from the evaluator's perspective models
      provider_models = unique_provider_models(evaluator_module)

      tasks =
        Enum.map(provider_models, fn provider_model ->
          pm_opts = Keyword.put(eval_opts, :provider_model, provider_model)

          {provider_model,
           Task.async(fn ->
             evaluator_module.evaluate(proposal, perspective, pm_opts)
           end)}
        end)

      results =
        tasks
        |> Enum.map(fn {provider_model, task} ->
          case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
            {:ok, {:ok, evaluation}} -> {provider_model, evaluation}
            {:ok, {:error, reason}} -> {provider_model, {:error, reason}}
            nil -> {provider_model, {:error, :timeout}}
          end
        end)
        |> Enum.sort_by(fn {provider_model, _} -> provider_model end)

      {:ok, results}
    end
  end

  @doc """
  Run a council decision via the DOT engine pipeline.

  Loads the `council-decision.dot` graph, injects the question and context,
  fans out to all 13 perspectives in parallel, tallies votes, and returns
  a CouncilDecision with quorum enforcement.

  This is the binding-decision counterpart to `ask/3` (which is advisory-only).

  ## Options

  - `:graph` — path to a custom council DOT file (default: `council-decision.dot`)
  - `:quorum` — override quorum type: "majority" | "supermajority" | "unanimous" (default from DOT file)
  - `:mode` — "decision" | "advisory" (default from DOT file)
  - `:timeout` — engine timeout in ms (default: 600_000)
  - `:context` — map of additional context
  - `:run_authorization` — opaque parent authorization forwarded to the nested engine

  Returns `{:ok, decision_map}` with keys like `"council.decision"`,
  `"council.approve_count"`, etc., or `{:error, reason}`.
  """
  @spec decide(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(_evaluator_module, description, opts \\ []) do
    graph_path = Keyword.get(opts, :graph, default_council_graph_path())
    run_authorization = Keyword.get(opts, :run_authorization)

    with :ok <- reject_bound_semantic_overrides(opts, run_authorization),
         {:ok, dot_content} <- read_graph_file(graph_path),
         {:ok, graph} <- load_graph(dot_content, run_authorization),
         {:ok, nested_engine_opts} <- nested_engine_opts(opts, run_authorization) do
      graph = maybe_apply_unbound_overrides(graph, description, opts, run_authorization)

      # Set initial context values for the engine. `:context` is advertised on
      # Arbor.Consensus.decide/2 and is load-bearing for specialized council
      # DOTs (for example code-review-council.dot needs the branch diff).
      initial_context =
        opts
        |> Keyword.get(:context, %{})
        |> normalize_initial_context()
        |> Map.put("council.question", description)

      engine_opts =
        nested_engine_opts
        |> Keyword.put(:initial_values, initial_context)
        |> maybe_put_timeout(Keyword.get(opts, :timeout))
        |> maybe_bind_run_authorization(run_authorization)

      case run_engine(graph, engine_opts, Keyword.get(opts, :engine_runner)) do
        {:ok, result} ->
          extract_decision_from_result(result)

        {:error, _} = error ->
          error
      end
    end
  end

  # ============================================================================
  # Private
  # ============================================================================

  defp unique_provider_models(evaluator_module) do
    if function_exported?(evaluator_module, :provider_map, 0) do
      evaluator_module.provider_map()
      |> Map.values()
      |> Enum.uniq()
      |> Enum.sort()
    else
      # Fallback if evaluator doesn't expose provider_map
      ["anthropic:claude-sonnet-4-5-20250929"]
    end
  end

  defp build_advisory_proposal(description, context) do
    Proposal.new(%{
      proposer: "human",
      topic: :advisory,
      mode: :advisory,
      description: description,
      target_layer: 4,
      context: context
    })
  end

  # --- DOT engine helpers (runtime bridge to standalone orchestrator) ---

  @orchestrator_mod Arbor.Orchestrator
  @engine_mod Arbor.Orchestrator.Engine

  defp default_council_graph_path do
    # Try multiple candidate paths (umbrella CWD variance)
    candidates = [
      Path.join(File.cwd!(), "apps/arbor_orchestrator/specs/pipelines/council-decision.dot"),
      Path.join(File.cwd!(), "../arbor_orchestrator/specs/pipelines/council-decision.dot"),
      Path.join(File.cwd!(), "specs/pipelines/council-decision.dot")
    ]

    Enum.find(candidates, List.first(candidates), &File.exists?/1)
  end

  defp read_graph_file(path) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:graph_file_not_found, path, reason}}
    end
  end

  defp load_graph(dot_content, nil) do
    if Code.ensure_loaded?(@orchestrator_mod) do
      apply(@orchestrator_mod, :parse, [dot_content])
    else
      {:error, :orchestrator_not_available}
    end
  end

  defp load_graph(dot_content, _run_authorization) do
    if Code.ensure_loaded?(@orchestrator_mod) do
      apply(@orchestrator_mod, :compile, [dot_content])
    else
      {:error, :orchestrator_not_available}
    end
  end

  defp reject_bound_semantic_overrides(_opts, nil), do: :ok

  defp reject_bound_semantic_overrides(opts, _run_authorization) do
    case Enum.find([:mode, :quorum], &(not is_nil(Keyword.get(opts, &1)))) do
      nil -> :ok
      key -> {:error, {:bound_council_override, key}}
    end
  end

  defp maybe_apply_unbound_overrides(graph, _description, _opts, run_authorization)
       when not is_nil(run_authorization),
       do: graph

  defp maybe_apply_unbound_overrides(graph, description, opts, nil) do
    overrides = %{"council.question" => description}

    overrides =
      case Keyword.get(opts, :quorum) do
        nil -> overrides
        quorum -> Map.put(overrides, "quorum", quorum)
      end

    overrides =
      case Keyword.get(opts, :mode) do
        nil -> overrides
        mode -> Map.put(overrides, "mode", to_string(mode))
      end

    %{graph | attrs: Map.merge(graph.attrs, overrides)}
  end

  defp nested_engine_opts(_opts, nil), do: {:ok, []}

  defp nested_engine_opts(opts, _run_authorization) do
    case Keyword.get(opts, :nested_engine_opts, []) do
      nested_opts when is_list(nested_opts) ->
        if Keyword.keyword?(nested_opts) do
          {:ok, Keyword.take(nested_opts, @nested_engine_opt_allowlist)}
        else
          {:error, :invalid_nested_engine_opts}
        end

      _other ->
        {:error, :invalid_nested_engine_opts}
    end
  end

  defp maybe_put_timeout(opts, nil), do: opts
  defp maybe_put_timeout(opts, timeout), do: Keyword.put(opts, :timeout, timeout)

  defp maybe_bind_run_authorization(opts, nil), do: opts

  defp maybe_bind_run_authorization(opts, run_authorization) do
    opts
    |> Keyword.put(:authorization, true)
    |> Keyword.put(:run_authorization, run_authorization)
  end

  defp normalize_initial_context(context) when is_map(context), do: context
  defp normalize_initial_context(_context), do: %{}

  defp run_engine(graph, opts, engine_runner) when is_function(engine_runner, 2) do
    engine_runner.(graph, opts)
  end

  defp run_engine(graph, opts, _engine_runner) do
    if Code.ensure_loaded?(@engine_mod) do
      apply(@engine_mod, :run, [graph, opts])
    else
      {:error, :engine_not_available}
    end
  end

  defp extract_decision_from_result(result) do
    # Engine returns a result struct with context
    ctx =
      cond do
        is_map(result) and Map.has_key?(result, :context) ->
          result.context

        is_map(result) and Map.has_key?(result, "context") ->
          result["context"]

        true ->
          result
      end

    # Try exec.decide.* keys first (new action-based path),
    # fall back to council.* keys for backwards compatibility
    decision =
      get_context_val(ctx, "exec.decide.decision") ||
        get_context_val(ctx, "council.decision")

    if decision do
      {:ok,
       %{
         decision: decision,
         approve_count:
           get_context_val(ctx, "exec.decide.approve_count") ||
             get_context_val(ctx, "council.approve_count", 0),
         reject_count:
           get_context_val(ctx, "exec.decide.reject_count") ||
             get_context_val(ctx, "council.reject_count", 0),
         abstain_count:
           get_context_val(ctx, "exec.decide.abstain_count") ||
             get_context_val(ctx, "council.abstain_count", 0),
         quorum_met:
           get_context_val(ctx, "exec.decide.quorum_met") ||
             get_context_val(ctx, "council.quorum_met", false),
         average_confidence:
           get_context_val(ctx, "exec.decide.average_confidence") ||
             get_context_val(ctx, "council.average_confidence", 0.0),
         primary_concerns:
           get_context_val(ctx, "exec.decide.primary_concerns") ||
             get_context_val(ctx, "council.primary_concerns", "[]"),
         perspective_votes:
           get_context_val(ctx, "exec.decide.perspective_votes") ||
             get_context_val(ctx, "council.perspective_votes", %{}),
         security_veto:
           get_context_val(ctx, "exec.decide.security_veto") ||
             get_context_val(ctx, "council.security_veto", false),
         vetoes:
           get_context_val(ctx, "exec.decide.vetoes") ||
             get_context_val(ctx, "council.vetoes", []),
         status:
           get_context_val(ctx, "exec.decide.status") ||
             get_context_val(ctx, "consensus.status", "unknown")
       }}
    else
      {:error, :no_decision_in_result}
    end
  end

  defp get_context_val(ctx, key, default \\ nil) do
    cond do
      is_struct(ctx) and function_exported?(ctx.__struct__, :get, 3) ->
        apply(ctx.__struct__, :get, [ctx, key, default])

      is_map(ctx) ->
        Map.get(ctx, key, default)

      true ->
        default
    end
  end
end
