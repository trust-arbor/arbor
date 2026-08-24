defmodule Mix.Tasks.Arbor.Eval.Task do
  @moduledoc """
  Run v3 real-bug memory ablation evaluation.

  Starts a real diagnostician agent against a real bug in a git worktree,
  using different heartbeat.dot pipeline variants to control memory persistence.
  Measures heartbeats-to-proposal, proposal quality, and behavioral metrics.

  ## Usage

      mix arbor.eval.task                                    # bare + full, glob bug
      mix arbor.eval.task --variants bare,goals,full         # specific variants
      mix arbor.eval.task --max-heartbeats 20 --reps 3       # statistical runs
      mix arbor.eval.task --model "anthropic/claude-3-5-haiku-latest"
      mix arbor.eval.task --council                          # enable council eval
      mix arbor.eval.task --tag "first-run"                  # persistence tag

  ## Options

    * `--variants` - Comma-separated variant names: bare, goals, notes, identity, full (default: bare,full)
    * `--max-heartbeats` - Max heartbeats per trial (default: 15)
    * `--reps` - Repetitions per variant (default: 1)
    * `--model` - LLM model (default: openrouter/anthropic/claude-3-5-haiku-latest)
    * `--provider` - LLM provider (default: openrouter)
    * `--bug` - Bug case ID (default: glob_wildcard)
    * `--council` - Enable council evaluation of proposals
    * `--tag` - Tag for persistence
  """

  use Mix.Task

  alias Arbor.Agent.Eval.ProviderRoutePin

  # Scope the ProviderRouter to the model under test.
  #
  # A heartbeat's llm_call runs in router mode, where — as LlmHandler puts it —
  # "the session provider may be stale once ProviderRouter selects an exact
  # destination". The router picks from `:provider_route_profile`, so the
  # eval's --model/--provider were OVERRIDDEN and the run measured whatever the
  # production profile happened to list (gpt-5.6-sol / grok-4.6). With those
  # OAuth destinations at status "login_required" the beat stalled until the
  # 5-minute timeout and reported 0 heartbeats — never contacting the model
  # under test at all.
  #
  # That also made admission circular: a model had to already be in the route
  # profile to be measured for entry into it. Same shape as the candidate
  # discovery circularity fixed in 5af3bd57c, one layer up.
  #
  # Pinning the profile to {model, provider} is not enough: the policy maps
  # (`provider_route_concurrency_limits`, `provider_spend_ceilings_usd`,
  # `subscription_capacity_states`) are a second per-provider allowlist.
  # `RouteConcurrency` reads limits at init, so a provider with a scoreboard
  # row but no policy row fails as `:unconfigured_route` →
  # `:no_eligible_routes`. Write those rows here too — eval-scoped, merged
  # into the loaded maps, same values as the reviewed profile. This is not a
  # production promotion.
  #
  # Pin BEFORE the apps start. ProviderRouteReadiness caches the route set at
  # boot and fails closed with `:route_set_changed` if it changes underneath.
  defp pin_provider_route!(model, provider) when is_binary(model) and model != "" do
    pin =
      ProviderRoutePin.build(
        model,
        provider,
        %{
          concurrency: Application.get_env(:arbor_ai, :provider_route_concurrency_limits, %{}),
          ceilings: Application.get_env(:arbor_ai, :provider_spend_ceilings_usd, %{}),
          capacity: Application.get_env(:arbor_ai, :subscription_capacity_states, %{})
        },
        now: DateTime.utc_now()
      )

    Application.put_env(:arbor_ai, :provider_route_profile, pin.profile)
    Application.put_env(:arbor_ai, :provider_route_concurrency_limits, pin.concurrency)
    Application.put_env(:arbor_ai, :provider_spend_ceilings_usd, pin.ceilings)
    Application.put_env(:arbor_ai, :subscription_capacity_states, pin.capacity)
    Application.put_env(:arbor_ai, :eval_route_catalog_overlays, pin.catalog_overlays)

    Mix.shell().info(
      "  Route pinned to #{to_string(provider)}/#{model} for this eval (policy rows included).\n"
    )
  end

  defp pin_provider_route!(_model, _provider), do: :ok

  # `config/runtime.exs` is applied by the `app.config` task, which `mix run`
  # and `mix test` invoke for you. A custom task that starts applications
  # itself does NOT get it — so every runtime-configured value was nil here.
  #
  # Concretely: `provider_usage_ledger_target` is set in runtime.exs, so
  # without this `ProviderRouteEvidence` initialized with no target, parked at
  # {:blocked, :target_unset}, and every route assembly failed. The eval then
  # reported `Avg heartbeats: 0.0` while still printing "Successful: 1",
  # because nothing crashed. `mix run` on the same machine worked, which made
  # this look like host contention rather than missing config.
  @requirements ["app.config"]

  @shortdoc "Run v3 real-bug memory ablation eval"

  @switches [
    variants: :string,
    max_heartbeats: :integer,
    reps: :integer,
    model: :string,
    provider: :string,
    bug: :string,
    council: :boolean,
    tag: :string
  ]

  @valid_variants ~w(bare goals notes identity full)a

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    # Pin BEFORE the apps start. ProviderRouteReadiness derives and caches its
    # requirements from the profile at boot, and fails closed with
    # {:provider_route_readiness, :route_set_changed} if the route set changes
    # underneath it. Pinning after startup therefore produced five consecutive
    # heartbeat failures and a disabled heartbeat — the gate behaving correctly
    # against a profile swapped out from under it.
    #
    # Resolve the default model *before* pinning. `opts[:model]` is nil on the
    # documented no-arg invocation, and `pin_provider_route!/2` no-ops then —
    # production routing would override the eval model.
    {model, provider} = resolve_pin_target(opts)
    pin_provider_route!(model, provider)

    # Dev/prod journal is Postgres with start_store: false — it expects
    # `mix arbor.start` to already own the named store. This Mix task is a
    # dedicated BEAM; using that config made every heartbeat fail
    # `:journal_unavailable`, including after a successful LLM call.
    # Volatile ETS is honest for a short-lived eval process.
    Application.put_env(:arbor_orchestrator, :run_journal, [])

    # Persistence first so QueryableStore/Repo exist before orchestrator
    # and agent profile writes. Starting it last raced sqlite/Postgres
    # connections and surfaced as `database is locked`.
    _ = Application.ensure_all_started(:arbor_persistence_ecto)

    # This Mix task is a dedicated BEAM, but arbor_agent still starts Bootstrap
    # and Reconciler. Those would auto-start persisted agents into the eval
    # route pin (scoreboard, policy rows, catalog overlays). Disable both
    # before app start. OpenCode Zen probe ids are registered per eval
    # principal after TaskEval starts the agent — not as Application env.
    isolate_eval_agent_runtime!()

    # Start required apps (orchestrator must come before agent — provides EventRegistry + Session)
    for app <- [:arbor_memory, :arbor_ai, :arbor_orchestrator, :arbor_agent] do
      start_or_raise!(app)
    end

    await_provider_route_evidence!()

    variants = parse_variants(opts[:variants])
    bug = parse_bug(opts[:bug])
    max_heartbeats = opts[:max_heartbeats] || 15
    reps = opts[:reps] || 1
    council? = opts[:council] || false
    tag = opts[:tag]

    Mix.shell().info("""

    ╔═══════════════════════════════════════════════════════╗
    ║          v3 Real-Bug Memory Ablation Eval             ║
    ╠═══════════════════════════════════════════════════════╣
    ║  Bug:          #{pad(to_string(bug), 38)}║
    ║  Variants:     #{pad(inspect(variants), 38)}║
    ║  Max HB:       #{pad(to_string(max_heartbeats), 38)}║
    ║  Reps:         #{pad(to_string(reps), 38)}║
    ║  Model:        #{pad(model, 38)}║
    ║  Provider:     #{pad(to_string(provider), 38)}║
    ║  Council:      #{pad(to_string(council?), 38)}║
    ║  Tag:          #{pad(tag || "(none)", 38)}║
    ╚═══════════════════════════════════════════════════════╝
    """)

    eval_opts = [
      bug: bug,
      variants: variants,
      max_heartbeats: max_heartbeats,
      reps: reps,
      model: model,
      provider: provider,
      council: council?,
      tag: tag
    ]

    case Arbor.Agent.Eval.TaskEval.run(eval_opts) do
      {:ok, summary} ->
        print_summary(summary)
        print_comparison(summary)

      {:error, reason} ->
        Mix.shell().error("\nEval failed: #{inspect(reason)}")
    end
  end

  # -- Parsers --

  # `ProviderRouteEvidence` becomes ready asynchronously after `arbor_ai`
  # starts. The eval used to begin beating immediately, so every heartbeat hit
  # `route_failure_snapshot/1` before it was ready, got `{:error, :unavailable}`,
  # and failed route assembly — reported as `Avg heartbeats: 0.0` while the
  # trial was still scored "Successful" because nothing crashed.
  #
  # A long-running server never shows this: by the time anything beats, evidence
  # has long been ready. Only the short-lived eval process races it.
  #
  # Wait rather than bypassing the route profile: the profile gates production
  # routing (`strict_evidence: true`), and an eval that skipped it would measure
  # something other than what actually runs.
  defp await_provider_route_evidence!(timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    case wait_for_evidence(deadline) do
      :ok ->
        :ok

      :timeout ->
        Mix.raise("""
        Provider route evidence did not become ready within #{div(timeout_ms, 1000)}s.
        Status: #{inspect(safe_evidence_status())}
        Refusing to score a 0-heartbeat run as a successful trial.
        """)
    end
  end

  defp wait_for_evidence(deadline) do
    if evidence_ready?() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        :timeout
      else
        Process.sleep(250)
        wait_for_evidence(deadline)
      end
    end
  end

  defp safe_evidence_status do
    Arbor.AI.provider_route_evidence_status()
  rescue
    e -> {:status_unavailable, Exception.message(e)}
  catch
    k, r -> {:status_unavailable, {k, r}}
  end

  defp evidence_ready? do
    match?(%{available: true}, Arbor.AI.provider_route_evidence_status())
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  # A bare `{:ok, _} =` match turned any startup failure into a MatchError whose
  # message was the raw error tuple — which is how a 5s ActionRegistry
  # :lock_core timeout on a slow VM presented as an unreadable crash rather than
  # "the orchestrator did not start". Name the app and the reason.
  defp start_or_raise!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _started} ->
        :ok

      {:error,
       {failed_app, {:bad_return, {_mfa, {:EXIT, {:timeout, {GenServer, :call, [name | _]}}}}}}} ->
        Mix.raise("""
        Could not start #{inspect(app)}: #{inspect(failed_app)} timed out calling #{inspect(name)}.

        This is usually slow-hardware startup, not a code fault — registry lock
        does disk-backed module loading. Raise the budget with:

          config :arbor_kernel_runtime, registry_lock_core_timeout: 120_000
        """)

      {:error, reason} ->
        Mix.raise("Could not start #{inspect(app)}: #{inspect(reason)}")
    end
  end

  defp parse_variants(nil), do: [:bare, :full]

  defp parse_variants(str) do
    str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_existing_atom/1)
    |> Enum.filter(&(&1 in @valid_variants))
  end

  defp parse_bug(nil), do: :glob_wildcard
  defp parse_bug(str), do: String.to_existing_atom(str)

  defp parse_provider(nil), do: :openrouter
  defp parse_provider(str), do: String.to_existing_atom(str)

  @doc false
  def resolve_pin_target(opts) when is_list(opts) do
    model = opts[:model] || Arbor.Agent.LLMDefaults.default_model()
    provider = parse_provider(opts[:provider])
    {model, provider}
  end

  defp isolate_eval_agent_runtime! do
    Application.put_env(:arbor_agent, :bootstrap_enabled, false)

    reconciler = Application.get_env(:arbor_agent, Arbor.Agent.Reconciler, [])

    reconciler =
      if is_list(reconciler) do
        Keyword.put(reconciler, :enabled, false)
      else
        [enabled: false]
      end

    Application.put_env(:arbor_agent, Arbor.Agent.Reconciler, reconciler)
  end

  # -- Output --

  defp print_summary(summary) do
    Mix.shell().info("\n── Results ──")
    Mix.shell().info("  Total trials:  #{summary.total_trials}")
    Mix.shell().info("  Successful:    #{summary.successful_trials}")
    Mix.shell().info("  Failed:        #{summary.failed_trials}")

    for {variant, stats} <- Enum.sort(summary.variants) do
      Mix.shell().info("""

        ── #{variant} (#{stats.trial_count} trial(s)) ──
          Proposals submitted:  #{stats.proposals_submitted}/#{stats.trial_count}
          Avg heartbeats:       #{stats.avg_heartbeats}
          Avg quality:          #{fmt(stats.avg_quality)}
          Avg file reads:       #{stats.avg_file_reads}
          Avg unique files:     #{stats.avg_unique_files}
          Avg repeated reads:   #{stats.avg_repeated_reads}
      """)
    end
  end

  defp print_comparison(summary) do
    variants = summary.variants

    if map_size(variants) < 2 do
      :ok
    else
      Mix.shell().info("\n── Comparison Table ──")

      header =
        "  #{"Metric" |> String.pad_trailing(22)}" <>
          Enum.map_join(Enum.sort(variants), "", fn {v, _} ->
            to_string(v) |> String.pad_trailing(12)
          end)

      Mix.shell().info(header)
      Mix.shell().info("  " <> String.duplicate("─", 22 + map_size(variants) * 12))

      metrics = [
        {"Proposals", fn s -> "#{s.proposals_submitted}/#{s.trial_count}" end},
        {"Avg Heartbeats", fn s -> fmt(s.avg_heartbeats) end},
        {"Avg Quality", fn s -> fmt(s.avg_quality) end},
        {"Avg File Reads", fn s -> fmt(s.avg_file_reads) end},
        {"Avg Unique Files", fn s -> fmt(s.avg_unique_files) end},
        {"Avg Repeated Reads", fn s -> fmt(s.avg_repeated_reads) end}
      ]

      for {label, extractor} <- metrics do
        row =
          "  #{String.pad_trailing(label, 22)}" <>
            Enum.map_join(Enum.sort(variants), "", fn {_v, stats} ->
              String.pad_trailing(extractor.(stats), 12)
            end)

        Mix.shell().info(row)
      end
    end
  end

  defp fmt(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp fmt(n), do: to_string(n)

  defp pad(str, width) do
    len = String.length(str)
    if len >= width, do: str, else: str <> String.duplicate(" ", width - len)
  end
end
