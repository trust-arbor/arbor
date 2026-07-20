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
  alias Arbor.Consensus.ReviewerOutcomes
  alias Arbor.Contracts.Consensus.Proposal
  alias Arbor.Contracts.Security.SigningAuthority

  @default_timeout 300_000
  # :signing_authority keeps nested Engine runs in fixed-facade authority mode
  # when the parent action was authorized via SigningAuthority (never silent
  # legacy signer/authorizer). Opaque token only — no private keys.
  @nested_engine_opt_allowlist [:signer, :authorizer, :signing_authority, :max_depth]

  # Root authorized launches (legacy coding council without inherited
  # RunAuthorization) carry principal/workdir lineage as top-level opts.
  # These never enter initial_values / checkpoints.
  @authorized_root_identity_opts [
    :caller_id,
    :author_id,
    :graph_author_id,
    :task_id,
    :session_id,
    :workdir
  ]

  # Key-presence mixed credential rejection (including nil values).
  @mixed_credential_keys [:signer, :authorizer, :identity_private_key]
  # Nested root opts may carry only max_depth — never credentials or authority.
  @root_nested_forbidden_keys [:signer, :authorizer, :identity_private_key, :signing_authority]

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
  - `:authorization` — when `true` without `:run_authorization`, launch an
    authorized root run via `Arbor.Orchestrator.run_as/4` (legacy coding path)

  Returns `{:ok, decision_map}` with keys like `"council.decision"`,
  `"council.approve_count"`, etc., or `{:error, reason}`.
  """
  @spec decide(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def decide(_evaluator_module, description, opts \\ []) do
    graph_path = Keyword.get(opts, :graph, default_council_graph_path())

    # Bound when an opaque parent RunAuthorization is forwarded *or* the caller
    # explicitly requests a root authorized launch (`authorization: true`) for
    # the legacy coding path (principal + signing lineage, no parent RA).
    # Launch selectors (run_authorization / authorization / signing_authority)
    # are all-occurrences — never Keyword first-wins.
    with {:ok, run_authorization} <- resolve_run_authorization_opt(opts),
         {:ok, bound?} <- bound_council_launch?(opts, run_authorization),
         :ok <- reject_bound_semantic_overrides(opts, bound?),
         {:ok, launch} <- resolve_council_launch(opts, run_authorization),
         {:ok, dot_content} <- read_graph_file(graph_path),
         {:ok, graph} <- load_graph(dot_content, bound?) do
      graph = maybe_apply_unbound_overrides(graph, description, opts, bound?)

      # Set initial context values for the engine. `:context` is advertised on
      # Arbor.Consensus.decide/2 and is load-bearing for specialized council
      # DOTs (for example code-review-council.dot needs the branch diff).
      # Credentials and RunAuthorization must never enter this map.
      initial_context =
        opts
        |> Keyword.get(:context, %{})
        |> normalize_initial_context()
        |> Map.put("council.question", description)

      engine_runner = Keyword.get(opts, :engine_runner)
      timeout = Keyword.get(opts, :timeout)

      case launch do
        {:inherited, run_authorization, nested_engine_opts} ->
          engine_opts =
            nested_engine_opts
            |> Keyword.put(:initial_values, initial_context)
            |> maybe_put_timeout(timeout)
            |> Keyword.put(:authorization, true)
            |> Keyword.put(:run_authorization, run_authorization)

          run_engine(graph, engine_opts, engine_runner)

        {:authorized_root, principal, authority, root_opts} ->
          run_authorized_root(
            graph,
            principal,
            authority,
            root_opts,
            initial_context,
            timeout,
            engine_runner
          )

        :unbound ->
          engine_opts =
            []
            |> Keyword.put(:initial_values, initial_context)
            |> maybe_put_timeout(timeout)

          run_engine(graph, engine_opts, engine_runner)
      end
      |> case do
        {:ok, result} -> extract_decision_from_result(result)
        {:error, _} = error -> error
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

  # Bound when parent RunAuthorization is present, or when the caller requests a
  # root authorized launch, or when a top-level signing_authority key is present
  # (including nil/malformed — presence binds and later fails closed).
  # authorization / signing_authority are all-occurrences; conflict fails closed.
  defp bound_council_launch?(_opts, run_authorization) when not is_nil(run_authorization),
    do: {:ok, true}

  defp bound_council_launch?(opts, nil) do
    with {:ok, auth_true?} <- authorization_true?(opts) do
      {:ok, auth_true? or list_claim_values(opts, :signing_authority) != []}
    end
  end

  # All-values run_authorization: equal non-nil duplicates collapse; all-nil is
  # absence; mixed nil/non-nil or unequal values fail closed.
  defp resolve_run_authorization_opt(opts) do
    case list_claim_values(opts, :run_authorization) do
      [] ->
        {:ok, nil}

      values ->
        case Enum.uniq(values) do
          [nil] ->
            {:ok, nil}

          [authority] when not is_nil(authority) ->
            {:ok, authority}

          _conflict ->
            {:error, :conflicting_run_authorization}
        end
    end
  end

  # authorization: true is the only truthy binding claim. Conflicting true/false
  # (or true/other) across atom/string/duplicate occurrences fails closed.
  defp authorization_true?(opts) do
    case list_claim_values(opts, :authorization) do
      [] ->
        {:ok, false}

      values ->
        case Enum.uniq(values) do
          [true] ->
            {:ok, true}

          [only] when only != true ->
            {:ok, false}

          _conflict ->
            {:error, :conflicting_authorization}
        end
    end
  end

  defp resolve_council_launch(opts, run_authorization) when not is_nil(run_authorization) do
    with {:ok, nested} <- nested_engine_opts(opts) do
      {:ok, {:inherited, run_authorization, nested}}
    end
  end

  defp resolve_council_launch(opts, nil) do
    with {:ok, auth_true?} <- authorization_true?(opts) do
      if auth_true? or list_claim_values(opts, :signing_authority) != [] do
        resolve_authorized_root_launch(opts)
      else
        {:ok, :unbound}
      end
    end
  end

  defp resolve_authorized_root_launch(opts) do
    with :ok <- reject_mixed_root_credentials(opts),
         {:ok, %SigningAuthority{} = authority} <- require_top_level_signing_authority(opts),
         principal = authority.principal_id,
         :ok <- reject_system_principal(principal),
         :ok <- agree_root_identity_opts(opts, principal),
         {:ok, root_opts} <- root_engine_opts(opts) do
      {:ok, {:authorized_root, principal, authority, root_opts}}
    end
  end

  defp reject_mixed_root_credentials(opts) do
    # Top-level mixed credentials: any atom/string occurrence of a forbidden key.
    top_level_mixed =
      Enum.filter(@mixed_credential_keys, fn key ->
        list_claim_values(opts, key) != []
      end)

    nested_result =
      case list_claim_values(opts, :nested_engine_opts) do
        [] ->
          {:ok, []}

        envelopes ->
          Enum.reduce_while(envelopes, {:ok, []}, fn nested, {:ok, acc} ->
            case nested do
              nil ->
                {:cont, {:ok, acc}}

              nested when is_list(nested) ->
                if Keyword.keyword?(nested) do
                  forbidden =
                    Enum.filter(@root_nested_forbidden_keys, &Keyword.has_key?(nested, &1))

                  {:cont, {:ok, acc ++ forbidden}}
                else
                  {:halt, {:error, :invalid_nested_engine_opts}}
                end

              _other ->
                {:halt, {:error, :invalid_nested_engine_opts}}
            end
          end)
      end

    case nested_result do
      {:error, _} = error ->
        error

      {:ok, nested_mixed} ->
        forbidden = Enum.uniq(top_level_mixed ++ nested_mixed)

        if forbidden == [] do
          :ok
        else
          {:error, {:mixed_signing_credentials, forbidden}}
        end
    end
  end

  # Authority is top-level only — never discovered from nested_engine_opts.
  # Present nil/malformed fails closed (never unbound). Accept only an actual
  # %SigningAuthority{} struct; well-formed maps/lists must not rehydrate via
  # canonicalize/1.
  # All-occurrences: every atom/string/duplicate claim is validated; equal
  # canonical duplicates may pass; nil/malformed/conflict fail closed.
  defp require_top_level_signing_authority(opts) do
    case list_claim_values(opts, :signing_authority) do
      [] ->
        {:error, :missing_signing_authority}

      values ->
        collapse_signing_authority_claims(values)
    end
  end

  defp collapse_signing_authority_claims(values) do
    Enum.reduce_while(values, :absent, fn raw, acc ->
      case normalize_signing_authority_claim(raw) do
        {:ok, canonical} ->
          case acc do
            :absent ->
              {:cont, {:ok, canonical}}

            {:ok, ^canonical} ->
              {:cont, {:ok, canonical}}

            {:ok, _other} ->
              {:halt, {:error, :conflicting_signing_authority}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      :absent -> {:error, :missing_signing_authority}
      other -> other
    end
  end

  defp normalize_signing_authority_claim(nil), do: {:error, :invalid_signing_authority}

  defp normalize_signing_authority_claim(%SigningAuthority{} = authority) do
    case SigningAuthority.canonicalize(authority) do
      {:ok, %SigningAuthority{} = canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, {:invalid_signing_authority, reason}}
    end
  end

  defp normalize_signing_authority_claim(_other), do: {:error, :invalid_signing_authority}

  defp reject_system_principal(principal) when principal in ["system", "agent_system"],
    do: {:error, :system_principal_forbidden}

  defp reject_system_principal(_principal), do: :ok

  # Every present execution-principal identity claim must equal
  # authority.principal_id. Missing keys are fine; present-but-blank /
  # mismatched / malformed fail closed. caller_id / author_id / session_id are
  # distinct lineage and are not compared against principal here.
  # Engine context carries execution identity in the flat key "session.agent_id"
  # — never infer authority from a nested session map.
  #
  # All-occurrences (never first-wins): lists may contain duplicate atom keys
  # and mixed atom/string tuples. Do not call Keyword APIs with string keys.
  # Enumerate every occurrence, validate independently, and fail closed on
  # malformed or conflicting claims. Equal duplicates may pass.
  defp agree_root_identity_opts(opts, principal) when is_list(opts) do
    with :ok <- agree_list_direct_identity_claims(opts, :agent_id, principal),
         :ok <- agree_list_direct_identity_claims(opts, :execution_principal, principal),
         :ok <- agree_list_direct_identity_claims(opts, :principal_id, principal),
         :ok <- agree_list_flat_session_agent_id_claims(opts, principal),
         :ok <- agree_list_nested_identity_claims(opts, :auth_context, :principal_id, principal),
         :ok <- agree_list_nested_identity_claims(opts, :signed_request, :agent_id, principal),
         :ok <- agree_list_lineage_claims(opts, :task_id),
         :ok <- agree_list_lineage_claims(opts, :caller_id),
         :ok <- agree_list_lineage_claims(opts, :author_id),
         :ok <- agree_list_lineage_claims(opts, :session_id) do
      :ok
    end
  end

  defp agree_root_identity_opts(_opts, _principal), do: {:error, :invalid_root_opts}

  # Direct claims: every occurrence of the logical key binds (including nil).
  defp agree_list_direct_identity_claims(opts, field, principal) do
    opts
    |> list_claim_values(field)
    |> Enum.reduce_while(:ok, fn raw, :ok ->
      case normalize_present_identity(raw) do
        :absent ->
          {:halt, {:error, :invalid_principal_id}}

        {:ok, ^principal} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, {:identity_mismatch, field}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp agree_list_flat_session_agent_id_claims(opts, principal) do
    opts
    |> list_claim_values_for_keys([:"session.agent_id", "session.agent_id"])
    |> Enum.reduce_while(:ok, fn raw, :ok ->
      case normalize_present_identity(raw) do
        :absent ->
          {:halt, {:error, :invalid_principal_id}}

        {:ok, ^principal} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, {:identity_mismatch, :session_agent_id}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # Nested envelopes may omit the identity field. Present nested keys (including
  # nil) under every atom/string spelling of the envelope are all-values claims.
  defp agree_list_nested_identity_claims(opts, envelope_key, nested_field, principal) do
    opts
    |> list_claim_values(envelope_key)
    |> Enum.reduce_while(:ok, fn envelope, :ok ->
      case agree_nested_field_claims(envelope, nested_field, principal, envelope_key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp agree_nested_field_claims(envelope, nested_field, principal, source)
       when is_map(envelope) do
    envelope
    |> map_claim_values(nested_field)
    |> Enum.reduce_while(:ok, fn raw, :ok ->
      case normalize_present_identity(raw) do
        :absent ->
          {:halt, {:error, :invalid_principal_id}}

        {:ok, ^principal} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, {:identity_mismatch, source}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp agree_nested_field_claims(_envelope, _nested_field, _principal, _source), do: :ok

  # Lineage is not compared to principal, but present claims must be well-formed
  # and non-conflicting across every atom/string/duplicate occurrence.
  defp agree_list_lineage_claims(opts, field) do
    case reduce_lineage_claim_values(list_claim_values(opts, field), field) do
      :absent -> :ok
      {:ok, _id} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp reduce_lineage_claim_values(values, field) do
    Enum.reduce_while(values, :absent, fn raw, acc ->
      case normalize_present_identity(raw) do
        :absent ->
          {:halt, {:error, :invalid_principal_id}}

        {:ok, id} ->
          case acc do
            :absent ->
              {:cont, {:ok, id}}

            {:ok, ^id} ->
              {:cont, {:ok, id}}

            {:ok, _other} ->
              {:halt, {:error, {:identity_mismatch, field}}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_present_identity(nil), do: :absent

  defp normalize_present_identity(value) when is_atom(value) and value not in [true, false] do
    normalize_present_identity(Atom.to_string(value))
  end

  # Opaque after validation: blank includes whitespace-only (trim only as
  # predicate). Accepted values are never rewritten before exact comparison.
  defp normalize_present_identity(value) when is_binary(value) do
    cond do
      String.trim(value) == "" ->
        {:error, :invalid_principal_id}

      not String.valid?(value) or String.contains?(value, <<0>>) ->
        {:error, :invalid_principal_id}

      value in ["system", "agent_system"] ->
        {:error, :system_principal_forbidden}

      true ->
        {:ok, value}
    end
  end

  defp normalize_present_identity(_value), do: {:error, :invalid_principal_id}

  # Enumerate every occurrence of a logical key. Never use Keyword.* with string
  # keys (raises / misses mixed tuples). Order is stable for equal-dup collapse.
  defp list_claim_values(opts, key) when is_list(opts) and is_atom(key) do
    list_claim_values_for_keys(opts, [key, Atom.to_string(key)])
  end

  defp list_claim_values(_opts, _key), do: []

  defp list_claim_values_for_keys(opts, keys) when is_list(opts) and is_list(keys) do
    key_set = MapSet.new(keys)

    opts
    |> Enum.reduce([], fn
      {candidate, value}, acc ->
        if MapSet.member?(key_set, candidate) do
          [value | acc]
        else
          acc
        end

      _other, acc ->
        acc
    end)
    |> Enum.reverse()
  end

  defp list_claim_values_for_keys(_opts, _keys), do: []

  defp map_claim_values(context, key) when is_map(context) and is_atom(key) do
    string_key = Atom.to_string(key)

    []
    |> then(fn acc ->
      if Map.has_key?(context, key), do: [Map.get(context, key) | acc], else: acc
    end)
    |> then(fn acc ->
      if Map.has_key?(context, string_key), do: [Map.get(context, string_key) | acc], else: acc
    end)
    |> Enum.reverse()
  end

  defp map_claim_values(_context, _key), do: []

  defp root_engine_opts(opts) do
    with {:ok, identity} <- authorized_root_identity_opts(opts),
         {:ok, extra} <- root_non_credential_nested_opts(opts) do
      {:ok, Keyword.merge(identity, extra)}
    end
  end

  # Project root identity/lineage opts after all-occurrences validation.
  # Engine surface uses atom keys; string-key-only claims still project once
  # their agreed opaque value is known.
  defp authorized_root_identity_opts(opts) when is_list(opts) do
    Enum.reduce_while(@authorized_root_identity_opts, {:ok, []}, fn key, {:ok, acc} ->
      case project_authorized_root_opt(opts, key) do
        :absent ->
          {:cont, {:ok, acc}}

        {:ok, value} ->
          {:cont, {:ok, [{key, value} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _reason} = error -> error
    end
  end

  defp project_authorized_root_opt(opts, key)
       when key in [:caller_id, :author_id, :graph_author_id, :task_id, :session_id] do
    reduce_lineage_claim_values(list_claim_values(opts, key), key)
  end

  # workdir is path authority, not a principal id. Every present occurrence
  # (including nil) is an authority-bearing claim — never discard nil before
  # reconciliation. Equal valid path values may pass; nil, malformed, or
  # conflicting values fail closed.
  defp project_authorized_root_opt(opts, :workdir) do
    case list_claim_values(opts, :workdir) do
      [] ->
        :absent

      values ->
        Enum.reduce_while(values, :absent, fn raw, acc ->
          case normalize_present_workdir(raw) do
            {:ok, path} ->
              case acc do
                :absent ->
                  {:cont, {:ok, path}}

                {:ok, ^path} ->
                  {:cont, {:ok, path}}

                {:ok, _other} ->
                  {:halt, {:error, {:identity_mismatch, :workdir}}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp project_authorized_root_opt(opts, key) do
    reduce_lineage_claim_values(list_claim_values(opts, key), key)
  end

  # Present workdir claims are opaque after validation: blank includes
  # whitespace-only (trim only as predicate). Accepted bytes are never rewritten.
  defp normalize_present_workdir(nil), do: {:error, :invalid_workdir}

  defp normalize_present_workdir(path) when is_binary(path) do
    cond do
      String.trim(path) == "" ->
        {:error, :invalid_workdir}

      not String.valid?(path) or String.contains?(path, <<0>>) ->
        {:error, :invalid_workdir}

      true ->
        {:ok, path}
    end
  end

  defp normalize_present_workdir(_other), do: {:error, :invalid_workdir}

  # All-values nested_engine_opts: each envelope projects to max_depth-only;
  # equal projections collapse. Conflicts fail closed. Non-max_depth keys on a
  # single envelope are stripped and cannot alter the sanitized root boundary
  # once mixed credentials were already rejected.
  defp root_non_credential_nested_opts(opts) do
    case list_claim_values(opts, :nested_engine_opts) do
      [] ->
        {:ok, []}

      values ->
        Enum.reduce_while(values, :absent, fn nested, acc ->
          case project_root_nested_opts(nested) do
            {:ok, projected} ->
              case acc do
                :absent ->
                  {:cont, {:ok, projected}}

                {:ok, ^projected} ->
                  {:cont, {:ok, projected}}

                {:ok, _other} ->
                  {:halt, {:error, :conflicting_nested_engine_opts}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          :absent -> {:ok, []}
          other -> other
        end
    end
  end

  defp project_root_nested_opts(nil), do: {:ok, []}
  defp project_root_nested_opts([]), do: {:ok, []}

  defp project_root_nested_opts(nested) when is_list(nested) do
    if Keyword.keyword?(nested) do
      depths =
        nested
        |> Enum.filter(fn {key, _value} -> key == :max_depth end)
        |> Enum.map(fn {_key, value} -> value end)

      case Enum.uniq(depths) do
        [] ->
          {:ok, []}

        [max_depth] ->
          {:ok, [max_depth: max_depth]}

        _conflict ->
          {:error, :conflicting_nested_engine_opts}
      end
    else
      {:error, :invalid_nested_engine_opts}
    end
  end

  defp project_root_nested_opts(_other), do: {:error, :invalid_nested_engine_opts}

  defp load_graph(dot_content, false) do
    if Code.ensure_loaded?(@orchestrator_mod) do
      apply(@orchestrator_mod, :parse, [dot_content])
    else
      {:error, :orchestrator_not_available}
    end
  end

  defp load_graph(dot_content, true) do
    if Code.ensure_loaded?(@orchestrator_mod) do
      apply(@orchestrator_mod, :compile, [dot_content])
    else
      {:error, :orchestrator_not_available}
    end
  end

  defp reject_bound_semantic_overrides(_opts, false), do: :ok

  # Bound launches reject mode/quorum overrides. All-occurrences: a later
  # non-nil claim after a first-wins nil must still fail closed.
  defp reject_bound_semantic_overrides(opts, true) do
    case Enum.find([:mode, :quorum], fn key ->
           Enum.any?(list_claim_values(opts, key), &(not is_nil(&1)))
         end) do
      nil -> :ok
      key -> {:error, {:bound_council_override, key}}
    end
  end

  defp maybe_apply_unbound_overrides(graph, _description, _opts, true), do: graph

  defp maybe_apply_unbound_overrides(graph, description, opts, false) do
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

  # Inherited-path only: forward allowlisted nested engine credentials with
  # key-presence semantics (including explicit nil). All nested_engine_opts
  # envelopes (atom/string/duplicate) must project to the identical allowlisted
  # keyword so a first-wins alias cannot smuggle alternate credentials.
  defp nested_engine_opts(opts) do
    case list_claim_values(opts, :nested_engine_opts) do
      [] ->
        {:ok, []}

      values ->
        Enum.reduce_while(values, :absent, fn nested, acc ->
          case project_inherited_nested_opts(nested) do
            {:ok, projected} ->
              case acc do
                :absent ->
                  {:cont, {:ok, projected}}

                {:ok, ^projected} ->
                  {:cont, {:ok, projected}}

                {:ok, _other} ->
                  {:halt, {:error, :conflicting_nested_engine_opts}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          :absent -> {:ok, []}
          other -> other
        end
    end
  end

  defp project_inherited_nested_opts(nil), do: {:ok, []}
  defp project_inherited_nested_opts([]), do: {:ok, []}

  defp project_inherited_nested_opts(nested_opts) when is_list(nested_opts) do
    if Keyword.keyword?(nested_opts) do
      Enum.reduce_while(@nested_engine_opt_allowlist, {:ok, []}, fn key, {:ok, acc} ->
        values =
          nested_opts
          |> Enum.filter(fn {candidate, _value} -> candidate == key end)
          |> Enum.map(fn {_candidate, value} -> value end)

        case Enum.uniq(values) do
          [] ->
            {:cont, {:ok, acc}}

          [only] ->
            {:cont, {:ok, [{key, only} | acc]}}

          _conflict ->
            {:halt, {:error, :conflicting_nested_engine_opts}}
        end
      end)
      |> case do
        {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
        {:error, _reason} = error -> error
      end
    else
      {:error, :invalid_nested_engine_opts}
    end
  end

  defp project_inherited_nested_opts(_other), do: {:error, :invalid_nested_engine_opts}

  defp maybe_put_timeout(opts, nil), do: opts
  defp maybe_put_timeout(opts, timeout), do: Keyword.put(opts, :timeout, timeout)

  defp normalize_initial_context(context) when is_map(context), do: context
  defp normalize_initial_context(_context), do: %{}

  defp run_authorized_root(
         graph,
         principal,
         authority,
         root_opts,
         initial_context,
         timeout,
         engine_runner
       ) do
    run_opts =
      root_opts
      |> Keyword.put(:initial_values, initial_context)
      |> maybe_put_timeout(timeout)
      |> Keyword.put(:authorization, true)
      |> Keyword.put(:execution_principal, principal)
      |> Keyword.put(:agent_id, principal)

    case engine_runner do
      fun when is_function(fun, 2) ->
        # Test seam: surface the Engine-bound opts run_as would install,
        # including process-local signing_authority (never initial_values).
        fun.(graph, Keyword.put(run_opts, :signing_authority, authority))

      _ ->
        # Production root path: public facade enforces the coarse orchestrator
        # gate and binds principal + SigningAuthority process-locally.
        if Code.ensure_loaded?(@orchestrator_mod) and
             function_exported?(@orchestrator_mod, :run_as, 4) do
          apply(@orchestrator_mod, :run_as, [graph, principal, authority, run_opts])
        else
          {:error, :orchestrator_not_available}
        end
    end
  end

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

  # Closed allowlist of code-review council fields emitted by
  # `consensus_decide_review` (and legacy council-prefixed equivalents).
  # Projected only when present so ordinary generic council decisions remain
  # free of review-specific keys (never default `human_required: false`).
  @review_decision_fields [
    :review_cycle,
    :finding_ledger,
    :findings,
    :out_of_scope,
    :review_disposition,
    :blocking_ids,
    :blocking_reasons,
    :reviewer_outcomes,
    :human_required
  ]

  # Engine returns {:ok, run_result} even when final_outcome.status is :fail.
  # Inspect the terminal outcome first so a failed pipeline cannot surface
  # stale decision keys from context as a successful council decision.
  @max_council_failure_reason_bytes 512

  defp extract_decision_from_result(result) do
    case terminal_pipeline_failure(result) do
      {:failed, failure_reason} ->
        {:error, {:council_pipeline_failed, failure_reason}}

      :ok ->
        extract_decision_from_context(result)
    end
  end

  defp extract_decision_from_context(result) do
    # Engine returns a result struct/map with context; injected test runners
    # may return the context map directly.
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
      base = %{
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
      }

      {:ok, Map.merge(base, project_review_decision_fields(ctx))}
    else
      {:error, :no_decision_in_result}
    end
  end

  # Duck-type Engine run_result.final_outcome without importing orchestrator
  # internals. Absent/nil final_outcome keeps the legacy extraction path for
  # injected runners. When final_outcome is present, only :success and
  # :partial_success may extract decision context — retry, skipped, fail,
  # unknown, or malformed present outcomes fail closed with a causal reason.
  defp terminal_pipeline_failure(result) when is_map(result) do
    case fetch_result_field(result, :final_outcome) do
      {:ok, nil} ->
        :ok

      {:ok, outcome} ->
        classify_terminal_outcome(outcome)

      :error ->
        :ok
    end
  end

  defp terminal_pipeline_failure(_result), do: :ok

  defp classify_terminal_outcome(outcome) when is_map(outcome) do
    status = fetch_outcome_field(outcome, :status)

    if decision_admissible_status?(status) do
      :ok
    else
      {:failed, causal_terminal_failure_reason(outcome, status)}
    end
  end

  defp classify_terminal_outcome(_malformed), do: {:failed, "malformed final_outcome"}

  defp decision_admissible_status?(:success), do: true
  defp decision_admissible_status?("success"), do: true
  defp decision_admissible_status?(:partial_success), do: true
  defp decision_admissible_status?("partial_success"), do: true
  defp decision_admissible_status?(_), do: false

  defp causal_terminal_failure_reason(outcome, status) do
    explicit = fetch_outcome_field(outcome, :failure_reason)

    cond do
      is_binary(explicit) and explicit != "" ->
        bound_failure_reason(explicit)

      is_atom(explicit) and not is_nil(explicit) ->
        bound_failure_reason(Atom.to_string(explicit))

      is_atom(status) and not is_nil(status) ->
        bound_failure_reason("terminal outcome status: #{status}")

      is_binary(status) and status != "" ->
        bound_failure_reason("terminal outcome status: #{status}")

      true ->
        "malformed final_outcome"
    end
  end

  defp fetch_result_field(result, key) when is_map(result) and is_atom(key) do
    cond do
      is_struct(result) and Map.has_key?(result, key) ->
        {:ok, Map.get(result, key)}

      Map.has_key?(result, key) ->
        {:ok, Map.get(result, key)}

      Map.has_key?(result, Atom.to_string(key)) ->
        {:ok, Map.get(result, Atom.to_string(key))}

      true ->
        :error
    end
  end

  # Outcome may be a struct (Engine.Outcome) or atom/string-keyed map.
  # Avoid pattern-matching a foreign struct type so consensus stays free of
  # orchestrator compile-time deps.
  defp fetch_outcome_field(outcome, key) when is_map(outcome) and is_atom(key) do
    cond do
      is_struct(outcome) and Map.has_key?(outcome, key) ->
        Map.get(outcome, key)

      Map.has_key?(outcome, key) ->
        Map.get(outcome, key)

      Map.has_key?(outcome, Atom.to_string(key)) ->
        Map.get(outcome, Atom.to_string(key))

      true ->
        nil
    end
  end

  defp fetch_outcome_field(_outcome, _key), do: nil

  # JSON-clean boundary: only forward valid UTF-8, never mid-codepoint cuts.
  # Already-invalid binaries fail closed to a known-good default string.
  defp bound_failure_reason(reason) when is_binary(reason) do
    cond do
      not String.valid?(reason) ->
        "pipeline failed"

      byte_size(reason) <= @max_council_failure_reason_bytes ->
        reason

      true ->
        truncate_utf8_prefix(reason, @max_council_failure_reason_bytes)
    end
  end

  defp bound_failure_reason(reason) when is_atom(reason) and not is_nil(reason) do
    bound_failure_reason(Atom.to_string(reason))
  end

  defp bound_failure_reason(_), do: "pipeline failed"

  defp truncate_utf8_prefix(bin, max_bytes)
       when is_binary(bin) and is_integer(max_bytes) and max_bytes >= 0 do
    size = min(byte_size(bin), max_bytes)
    do_truncate_utf8_prefix(bin, size)
  end

  defp do_truncate_utf8_prefix(_bin, size) when size <= 0, do: ""

  defp do_truncate_utf8_prefix(bin, size) do
    part = binary_part(bin, 0, size)

    if String.valid?(part) do
      part
    else
      do_truncate_utf8_prefix(bin, size - 1)
    end
  end

  # Presence-aware projection: only copy allowlisted review fields that the
  # engine context actually carries under `exec.decide.*` (preferred) or
  # `council.*` (legacy). Preserves false, 0, [], and %{} — never invents keys.
  defp project_review_decision_fields(ctx) do
    Enum.reduce(@review_decision_fields, %{}, fn field, acc ->
      case fetch_decide_field(ctx, field) do
        {:ok, value} -> Map.put(acc, field, project_review_field(field, value))
        :error -> acc
      end
    end)
  end

  defp project_review_field(:reviewer_outcomes, outcomes),
    do: ReviewerOutcomes.sanitize(outcomes)

  defp project_review_field(_field, value), do: value

  defp fetch_decide_field(ctx, field) when is_atom(field) do
    name = Atom.to_string(field)

    case fetch_context_val(ctx, "exec.decide." <> name) do
      {:ok, _} = ok ->
        ok

      :error ->
        fetch_context_val(ctx, "council." <> name)
    end
  end

  defp fetch_context_val(ctx, key) when is_binary(key) do
    cond do
      # Prefer fetch/2 when a context type exports true presence semantics.
      is_struct(ctx) and function_exported?(ctx.__struct__, :fetch, 2) ->
        case apply(ctx.__struct__, :fetch, [ctx, key]) do
          {:ok, value} -> {:ok, value}
          :error -> :error
          _other -> :error
        end

      # Production Engine.Context (and similar) only export get/3. Detect
      # presence with an unforgeable sentinel so legitimate false, "", [], %{},
      # 0, and nil values are preserved while absent keys stay omitted.
      is_struct(ctx) and function_exported?(ctx.__struct__, :get, 3) ->
        sentinel = make_ref()

        case apply(ctx.__struct__, :get, [ctx, key, sentinel]) do
          ^sentinel -> :error
          value -> {:ok, value}
        end

      is_map(ctx) and Map.has_key?(ctx, key) ->
        {:ok, Map.get(ctx, key)}

      true ->
        :error
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
