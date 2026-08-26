defmodule Mix.Tasks.Arbor.Doctor do
  @shortdoc "Provider health + runtime axis introspection"
  @moduledoc """
  Multi-mode triage tool. With no flags, runs the LLM provider health
  check (the original behavior). Subcommand flags surface specific
  runtime-axis introspection without making any LLM calls.

      $ mix arbor.doctor                              # Provider health (default)
      $ mix arbor.doctor --runtimes                   # Registered runtimes + profiles
      $ mix arbor.doctor --model claude-opus-4-6      # Selection preview for a model
      $ mix arbor.doctor --refresh-models             # Reload the llm_db catalog
      $ mix arbor.doctor --model claude-opus-4-6 \\
          --fallback "runtime=acp" \\
          --fallback "model=claude-haiku-4-5-20251001"

  ## Options

  ### Provider-health mode (default)

    * `--refresh`   - Force refresh the provider catalog cache
    * `--json`      - Output as JSON instead of table format
    * `--verbose`   - Show detailed check results for each provider
    * `--configure` - Choose the default LLM provider and write it to .env.
      On a terminal this shows a numbered menu of the ready providers plus
      any that only need an API key (pick one and paste the key; it is
      saved to .env). Enter takes the recommended one. With piped stdin,
      `--provider`, or `--non-interactive` it takes the recommended one
      automatically.
    * `--provider <name>` - Skip the menu and configure this provider
      (catalog key, e.g. `opencode_zen`, `lm_studio`, `acp`)
    * `--acp-agent <id>` - With ACP, use this installed agent (`claude`,
      `codex`, `gemini`, …) instead of the preferred one. On the menu each
      installed agent is its own row.
    * `--non-interactive` - Never prompt; take the recommended provider

  ### Runtime-axis introspection

    * `--runtimes` - Render registered `Arbor.AI.Runtime` modules and
      their `RuntimeProfile` capabilities (the OpenClaw 8 questions).
    * `--model <id>` - Resolve a model through the selection chain
      (`Selector.choose/2` + `RuntimeRegistry.lookup/1`) WITHOUT making
      an LLM call. Shows which provider + runtime would serve the
      request and which adapter module backs that runtime.
    * `--fallback <override>` - Append a fallback chain entry to the
      preview. Repeatable. Each value is comma-separated `key=value`
      pairs (e.g. `"runtime=acp,model=claude-sonnet-4-6"`). Only valid
      with `--model`.
    * `--runtime <atom>` - Set the policy runtime override for the
      preview (defaults to the per-model default).
    * `--refresh-models` - Reload the llm_db catalog. Reports before/
      after model counts and duration; emits `[:arbor, :model_registry,
      :refreshed]` telemetry. Idempotent — repeated calls with no
      config change are no-ops at the llm_db level. Composes with
      `--json`.

  ## Auto-Configuration

  `mix arbor.doctor --configure` lets you choose among the providers that are
  ready (API key set, local server up, ACP agent installed, or the keyless
  free tier) and writes `ARBOR_DEFAULT_PROVIDER` and `ARBOR_DEFAULT_MODEL` to
  your `.env` file. On a terminal it shows a numbered menu; otherwise it takes
  the recommended provider.

  Recommended order: OpenRouter > Ollama > LM Studio > ACP > OpenCode Zen (keyless) > Anthropic > OpenAI > Gemini > xAI

  Model selection uses LLMDB to find the best available model for the chosen
  provider (requires chat capability). Falls back to hardcoded defaults if
  LLMDB is unavailable.
  """
  use Mix.Task

  # Provider priority order for --configure: free / local / ACP before paid APIs.
  # Catalog key = ProviderCatalog string, config atom = what goes in .env/config,
  # LLMDB atom = what LLMDB uses for model lookup.
  @provider_priority [
    {"openrouter", :openrouter, :openrouter},
    {"ollama", :ollama, :ollama_cloud},
    {"lm_studio", :lmstudio, :lmstudio},
    {"acp", :acp, :acp},
    {"opencode_zen", :opencode_zen, :opencode_zen},
    {"anthropic", :anthropic, :anthropic},
    {"openai", :openai, :openai},
    {"google", :gemini, :google},
    {"xai", :xai, :xai}
  ]

  @doc false
  def provider_priority, do: @provider_priority

  # NOTE: there is intentionally NO hard-coded per-provider model map here.
  # Hard-coded model ids go stale (cf. the retired trinity-large-preview) and bake in
  # a cloud assumption that conflicts with local-first use. When LLMDB can't answer,
  # `select_best_model/2` falls back to `fallback_model/2`: the user's configured
  # default → live discovery from local providers → honest nil (never a fabricated guess).

  @impl Mix.Task
  def run(args) do
    # `strict:`, not `switches:`. With `switches:`, OptionParser DISCARDS an
    # unrecognized flag entirely — `parse(["--bogus"], switches: [...])` returns
    # `{[], [], []}`, so it appears in neither opts, argv, nor invalid. A
    # mistyped or unsupported flag was therefore a silent no-op: the task ran
    # with its defaults, wrote a config, and reported success while ignoring
    # what the operator asked for. `parse_strict/2` surfaces them in `invalid`.
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          refresh: :boolean,
          json: :boolean,
          verbose: :boolean,
          configure: :boolean,
          non_interactive: :boolean,
          provider: :string,
          acp_agent: :string,
          runtimes: :boolean,
          model: :string,
          fallback: :keep,
          runtime: :string,
          refresh_models: :boolean
        ]
      )

    # OptionParser drops unrecognized switches into `invalid` and carries on.
    # Discarding that made a mistyped or unsupported flag a SILENT no-op: the
    # task ran with its defaults, wrote a config, and reported success while
    # ignoring what the operator actually asked for. That is how
    # `--provider opencode_zen` appeared to work before the flag existed.
    unless invalid == [] do
      names = Enum.map_join(invalid, ", ", fn {name, _value} -> name end)
      Mix.raise("Unknown option(s) for mix arbor.doctor: #{names}")
    end

    # Start minimal deps for provider discovery
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:req_llm)
    Application.ensure_all_started(:llm_db)

    # Load LLMDB for model lookup
    ensure_llmdb()

    cond do
      opts[:refresh_models] -> run_refresh_models(opts)
      opts[:runtimes] -> run_runtimes_view(opts)
      opts[:model] -> run_model_view(opts, args)
      true -> run_provider_health(opts)
    end
  end

  # ── Model registry refresh (--refresh-models) ────────────────────────

  defp run_refresh_models(opts) do
    case Arbor.Common.ModelProfile.refresh() do
      {:ok, summary} ->
        if opts[:json] do
          Mix.shell().info(Jason.encode!(summary, pretty: true))
        else
          delta = summary.after - summary.before

          delta_str =
            cond do
              delta > 0 -> "+#{delta}"
              delta < 0 -> "#{delta}"
              true -> "no change"
            end

          Mix.shell().info("")
          Mix.shell().info("  Model registry refreshed.")
          Mix.shell().info("    Before:   #{summary.before} models")
          Mix.shell().info("    After:    #{summary.after} models (#{delta_str})")
          Mix.shell().info("    Duration: #{summary.duration_ms}ms")
          Mix.shell().info("")
        end

      {:error, :llm_db_unavailable} ->
        Mix.shell().error("llm_db is not loaded — cannot refresh the model registry.")
        System.halt(1)

      {:error, {:llm_db_error, reason}} ->
        Mix.shell().error("llm_db refresh failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # ── Provider Health (default mode, original behavior) ────────────────

  defp run_provider_health(opts) do
    catalog_mod = Arbor.LLM.ProviderCatalog

    unless Code.ensure_loaded?(catalog_mod) do
      Mix.shell().error("ProviderCatalog not available. Is arbor_orchestrator compiled?")
      System.halt(1)
    end

    if opts[:refresh], do: apply(catalog_mod, :refresh, [])

    entries = apply(catalog_mod, :all, [[]])

    if opts[:json] do
      print_json(entries)
    else
      print_table(entries, opts)
      recommend_default(entries, opts)
    end
  end

  # ── Runtimes view (--runtimes) ───────────────────────────────────────

  defp run_runtimes_view(opts) do
    unless Code.ensure_loaded?(Arbor.AI.Runtime.Registry) do
      Mix.shell().error("Runtime.Registry not available. Is arbor_ai compiled?")
      System.halt(1)
    end

    registry = apply(Arbor.AI.Runtime.Registry, :all, [])

    if opts[:json] do
      print_runtimes_json(registry)
    else
      print_runtimes_table(registry)
    end
  end

  defp print_runtimes_table(registry) do
    Mix.shell().info("")
    Mix.shell().info("  Arbor Runtime Registry")
    Mix.shell().info("  ======================")
    Mix.shell().info("")

    Mix.shell().info(
      "  #{pad("Runtime", 12)} #{pad("Module", 36)} #{pad("Loop", 6)} #{pad("Hist", 6)} #{pad("Jido", 6)} #{pad("Hook", 6)} #{pad("Tool", 6)} #{pad("CtxE", 6)}"
    )

    Mix.shell().info(
      "  #{String.duplicate("-", 12)} #{String.duplicate("-", 36)} #{String.duplicate("-", 6)} #{String.duplicate("-", 6)} #{String.duplicate("-", 6)} #{String.duplicate("-", 6)} #{String.duplicate("-", 6)} #{String.duplicate("-", 6)}"
    )

    for {atom, module} <- Enum.sort_by(registry, fn {a, _} -> Atom.to_string(a) end) do
      profile = apply(Arbor.AI.Runtime.Registry, :profile, [atom])
      render_runtime_row(atom, module, profile)
    end

    Mix.shell().info("")

    Mix.shell().info("""
      Legend:
        Loop = owns_model_loop, Hist = owns_thread_history,
        Jido = supports_jido_actions, Hook = supports_action_hooks,
        Tool = supports_native_tools, CtxE = runs_context_engine
    """)

    Mix.shell().info("")
  end

  defp render_runtime_row(atom, module, :not_loaded) do
    Mix.shell().info(
      "  #{pad(":" <> Atom.to_string(atom), 12)} #{pad(inspect(module), 36)} #{pad("?", 6)} #{pad("?", 6)} #{pad("?", 6)} #{pad("?", 6)} #{pad("?", 6)} #{pad("?", 6)}"
    )

    Mix.shell().info("    (profile not loaded — module may not implement the behaviour)")
  end

  defp render_runtime_row(atom, module, profile) do
    Mix.shell().info(
      "  #{pad(":" <> Atom.to_string(atom), 12)} #{pad(inspect(module), 36)} " <>
        "#{flag(profile.owns_model_loop, 6)} #{flag(profile.owns_thread_history, 6)} " <>
        "#{flag(profile.supports_jido_actions, 6)} #{flag(profile.supports_action_hooks, 6)} " <>
        "#{flag(profile.supports_native_tools, 6)} #{flag(profile.runs_context_engine, 6)}"
    )

    Mix.shell().info("    #{profile.display_name}")

    if profile.unsupported_features != [] do
      Mix.shell().info(
        "    unsupported: #{Enum.map_join(profile.unsupported_features, ", ", &Atom.to_string/1)}"
      )
    end
  end

  defp print_runtimes_json(registry) do
    data =
      Enum.map(registry, fn {atom, module} ->
        case apply(Arbor.AI.Runtime.Registry, :profile, [atom]) do
          :not_loaded ->
            %{runtime: atom, module: inspect(module), profile: nil}

          profile ->
            %{
              runtime: atom,
              module: inspect(module),
              display_name: profile.display_name,
              owns_model_loop: profile.owns_model_loop,
              owns_thread_history: profile.owns_thread_history,
              supports_jido_actions: profile.supports_jido_actions,
              supports_action_hooks: profile.supports_action_hooks,
              supports_native_tools: profile.supports_native_tools,
              runs_context_engine: profile.runs_context_engine,
              exposes_compaction_data: profile.exposes_compaction_data,
              unsupported_features: profile.unsupported_features
            }
        end
      end)

    Mix.shell().info(Jason.encode!(data, pretty: true))
  end

  # ── Model resolution view (--model X [--fallback ...]) ───────────────

  defp run_model_view(opts, _raw_args) do
    unless Code.ensure_loaded?(Arbor.AI.Runtime.Dispatch) do
      Mix.shell().error("Runtime.Dispatch not available. Is arbor_ai compiled?")
      System.halt(1)
    end

    model = opts[:model]
    fallback_entries = collect_fallback_overrides(opts)
    runtime_override = parse_runtime_atom(opts[:runtime])

    policy =
      %{fallback_chain: fallback_entries}
      |> maybe_put(:runtime, runtime_override)

    results = apply(Arbor.AI.Runtime.Dispatch, :enumerate_chain, [model, policy])

    if opts[:json] do
      print_model_json(model, policy, results)
    else
      print_model_table(model, policy, results)
    end
  end

  defp print_model_table(model, policy, results) do
    Mix.shell().info("")
    Mix.shell().info("  Selection chain for #{model}")
    Mix.shell().info("  #{String.duplicate("=", 24 + String.length(model))}")

    case Map.get(policy, :runtime) do
      nil -> :ok
      atom -> Mix.shell().info("  Policy runtime override: :#{atom}")
    end

    Mix.shell().info("")

    Mix.shell().info(
      "  #{pad("Step", 6)} #{pad("Override", 50)} #{pad("Model", 28)} #{pad("Provider", 14)} #{pad("Runtime", 9)} Result"
    )

    Mix.shell().info("  #{String.duplicate("-", 124)}")

    results
    |> Enum.with_index()
    |> Enum.each(fn {entry, idx} ->
      render_chain_row(idx, entry)
    end)

    Mix.shell().info("")
  end

  defp render_chain_row(idx, {:ok, attempt}) do
    Mix.shell().info(
      "  #{pad(to_string(idx), 6)} #{pad(label_for(attempt.override), 50)} #{pad(attempt.model_entry.canonical_id, 28)} " <>
        "#{pad(Atom.to_string(attempt.selection.provider.id), 14)} " <>
        "#{pad(":" <> Atom.to_string(attempt.selection.runtime), 9)} OK"
    )
  end

  defp render_chain_row(idx, {:error, reason, marker}) do
    Mix.shell().info(
      "  #{pad(to_string(idx), 6)} #{pad(label_for(marker), 50)} #{pad("(not resolved)", 28)} " <>
        "#{pad("-", 14)} #{pad("-", 9)} ERROR: #{inspect(reason)}"
    )
  end

  defp label_for(:primary), do: "primary"
  defp label_for(override) when is_map(override), do: inspect(override)

  defp print_model_json(model, policy, results) do
    data = %{
      model: model,
      policy: %{
        runtime: Map.get(policy, :runtime),
        fallback_chain: Map.get(policy, :fallback_chain, [])
      },
      attempts: Enum.map(results, &chain_entry_to_json/1)
    }

    Mix.shell().info(Jason.encode!(data, pretty: true))
  end

  defp chain_entry_to_json({:ok, attempt}) do
    %{
      status: "ok",
      override: chain_marker_to_json(attempt.override),
      model: attempt.model_entry.canonical_id,
      provider: Atom.to_string(attempt.selection.provider.id),
      runtime: attempt.selection.runtime
    }
  end

  defp chain_entry_to_json({:error, reason, marker}) do
    %{
      status: "error",
      override: chain_marker_to_json(marker),
      reason: inspect(reason)
    }
  end

  defp chain_marker_to_json(:primary), do: "primary"
  defp chain_marker_to_json(override), do: stringify_override(override)

  defp stringify_override(override) when is_map(override) do
    Map.new(override, fn {k, v} -> {Atom.to_string(k), inspect(v)} end)
  end

  # ── Fallback / runtime arg parsing ───────────────────────────────────

  # OptionParser with `switches: [fallback: :keep]` (from run/1) yields
  # each --fallback value as a separate {:fallback, value} tuple in
  # opts. Collect them, then parse each comma-separated key=value
  # string into an override map.
  defp collect_fallback_overrides(opts) do
    for {:fallback, value} <- opts do
      parse_override_string(value)
    end
    |> Enum.reject(&(&1 == %{}))
  end

  # "runtime=acp,model=claude-sonnet-4-6" → %{runtime: :acp, model: "claude-sonnet-4-6"}
  defp parse_override_string(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn pair, acc ->
      case String.split(pair, "=", parts: 2) do
        [k, v] ->
          k_atom = String.trim(k) |> safe_existing_atom()
          v_trimmed = String.trim(v)
          if k_atom, do: Map.put(acc, k_atom, coerce_override_value(k_atom, v_trimmed)), else: acc

        _ ->
          acc
      end
    end)
  end

  # Runtime / provider values are atoms in the policy; model stays binary.
  defp coerce_override_value(:runtime, value), do: safe_existing_atom(value)
  defp coerce_override_value(:provider, value), do: safe_existing_atom(value)
  defp coerce_override_value(_, value), do: value

  defp safe_existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp parse_runtime_atom(nil), do: nil
  defp parse_runtime_atom(value) when is_binary(value), do: safe_existing_atom(value)

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)

  # ── Default LLM Recommendation ──────────────────────────────────────

  defp recommend_default(entries, opts) do
    ready = Enum.filter(entries, & &1.available?)

    case choose_provider(entries, ready, opts) do
      nil ->
        Mix.shell().info(
          "  No LLM providers available. Add an API key to .env or start a local model."
        )

        Mix.shell().info("")

      {provider_str, _provider_atom, nil} ->
        Mix.shell().info(
          "  Best available provider: #{provider_str}, but no model could be determined " <>
            "(LLMDB unavailable, and no configured or locally-discoverable model). " <>
            "Set ARBOR_DEFAULT_MODEL, or ensure a local model is loaded (Ollama/LM Studio)."
        )

        Mix.shell().info("")

      {provider_str, provider_atom, model} ->
        current_provider = System.get_env("ARBOR_DEFAULT_PROVIDER")
        current_model = System.get_env("ARBOR_DEFAULT_MODEL")

        # In --configure mode the line reports what was chosen (possibly from the
        # menu), not merely what the doctor would suggest.
        label = if opts[:configure], do: "Configuring", else: "Recommended"

        if current_provider do
          Mix.shell().info("  Default LLM: #{current_provider} / #{current_model || "(not set)"}")
          Mix.shell().info("  #{label}: #{provider_str} / #{model}")

          if current_provider != to_string(provider_atom) and not opts[:configure] do
            Mix.shell().info("  Run: mix arbor.doctor --configure  to update")
          end
        else
          Mix.shell().info("  Recommended default LLM: #{provider_str} / #{model}")

          unless opts[:configure] do
            Mix.shell().info("  Run: mix arbor.doctor --configure  to set automatically")
          end
        end

        if opts[:configure] do
          case maybe_acknowledge_keyless(provider_atom) do
            :ok ->
              configure_default(provider_atom, model)

            {:error, :disclosure_not_acknowledged} ->
              Mix.shell().error(
                "  OpenCode Zen was not configured: the data-disclosure warning was not acknowledged."
              )
          end
        end

        Mix.shell().info("")
    end
  end

  # An explicit `--provider` is an operator decision and outranks the priority
  # list. Without this there was no way to CHOOSE the keyless tier: the priority
  # list prefers a detected ACP CLI, and those live on PATH rather than in HOME,
  # so any machine with Claude Code / Codex / Gemini CLI installed — i.e. most
  # machines whose owner is reading Arbor's docs — silently skipped the
  # zero-config path QUICKSTART advertises, and the disclosure was never even
  # offered.
  defp pick_best_provider(ready_entries, requested)
       when is_binary(requested) and requested != "" do
    ready_providers = MapSet.new(ready_entries, & &1.provider)

    match =
      Enum.find(@provider_priority, fn {catalog_key, config_atom, _llmdb} ->
        requested in [catalog_key, to_string(config_atom)]
      end)

    case match do
      nil ->
        known = Enum.map_join(@provider_priority, ", ", fn {k, _, _} -> k end)
        Mix.raise("Unknown --provider #{inspect(requested)}. Known providers: #{known}")

      {catalog_key, config_atom, llmdb_atom} ->
        unless MapSet.member?(ready_providers, catalog_key) do
          Mix.raise("""
          --provider #{catalog_key} was requested but it is not available.
          Run `mix arbor.doctor` to see what each provider needs.
          """)
        end

        {catalog_key, config_atom, select_best_model(llmdb_atom, config_atom)}
    end
  end

  defp pick_best_provider(ready_entries, _requested) do
    ready_providers = MapSet.new(ready_entries, & &1.provider)

    Enum.find_value(@provider_priority, fn {catalog_key, config_atom, llmdb_atom} ->
      if MapSet.member?(ready_providers, catalog_key) do
        model = select_best_model(llmdb_atom, config_atom)
        {catalog_key, config_atom, model}
      end
    end)
  end

  # ── Interactive picker (--configure on a terminal) ───────────────────
  #
  # `--configure` used to silently take the first ready provider in
  # @provider_priority, which meant a user who set ANTHROPIC_API_KEY was handed
  # the keyless free tier without being asked. On a terminal we now show the
  # ready providers as a numbered menu (the priority order still decides which
  # one is "recommended" / the default answer). The automatic choice remains
  # the behaviour for `--provider`, `--non-interactive`, and piped stdin, so
  # scripts and CI are unchanged.
  alias Mix.Tasks.Arbor.Doctor.ProviderPicker

  defp choose_provider(entries, ready, opts) do
    cond do
      is_binary(opts[:provider]) and opts[:provider] != "" ->
        ready
        |> pick_best_provider(opts[:provider])
        |> override_acp_agent(opts[:acp_agent])

      opts[:configure] && !opts[:non_interactive] && interactive_stdin?() ->
        pick_provider_interactively(entries)

      true ->
        ready
        |> pick_best_provider(nil)
        |> override_acp_agent(opts[:acp_agent])
    end
  end

  # `--acp-agent codex` with `--provider acp` (or when ACP is the automatic
  # choice): use that agent instead of the preference order, if it's installed.
  defp override_acp_agent({"acp", :acp, _auto_agent}, agent) when is_binary(agent) do
    agents = detected_acp_agents()

    if agent in agents do
      {"acp", :acp, agent}
    else
      Mix.raise(
        "--acp-agent #{agent} is not installed. Detected ACP agents: " <>
          if(agents == [], do: "none", else: Enum.join(agents, ", "))
      )
    end
  end

  defp override_acp_agent(choice, _agent), do: choice

  @max_picker_attempts 3

  # The menu offers ready providers AND providers that are only missing an API
  # key (marked "needs <VAR>"); picking one of those prompts for the key.
  defp pick_provider_interactively(entries) do
    case ProviderPicker.options(entries, @provider_priority, acp_agents: detected_acp_agents()) do
      [] ->
        nil

      [%{needs_key: nil} = only] ->
        Mix.shell().info("  Only one LLM provider is available: #{only.display_name}")
        to_choice(only)

      options ->
        Mix.shell().info("")
        Mix.shell().info(ProviderPicker.render(options))
        Mix.shell().info("")
        prompt_for_choice(options, @max_picker_attempts)
    end
  end

  # Reads the key without echo when the terminal supports it, stores it in
  # `.env` (the same file `ARBOR_DEFAULT_*` go to) and in this process's env so
  # the rest of `--configure` sees the provider as configured. Nothing is
  # printed back except the variable NAME.
  defp collect_api_key(%{needs_key: var, display_name: name} = option) do
    Mix.shell().info("  #{name} needs #{var}.")

    case ProviderPicker.parse_api_key(read_secret("  Paste #{var} (input hidden): ")) do
      {:ok, key} ->
        env_path = Path.join(File.cwd!(), ".env")

        unless File.exists?(env_path) do
          Mix.raise("No .env file found. Run ./bin/mix arbor.setup first.")
        end

        write_env_key(env_path, var, key)
        System.put_env(var, key)
        Mix.shell().info("  ✓ Saved #{var} to .env")
        Mix.shell().info("")
        to_choice(%{option | needs_key: nil})

      {:error, :empty} ->
        Mix.raise("No #{var} entered. Re-run `mix arbor.doctor --configure` when you have it.")

      {:error, :multiline} ->
        Mix.raise("#{var} must be a single line.")
    end
  end

  # Same technique as `mix hex.user` (Hex's `password_get/1`): read the line
  # with `IO.gets` while a helper keeps rewriting the prompt over the echoed
  # characters, so the key never sits visible on screen. It works on every
  # terminal; `:io.get_password/0` was tried first and blocks under some ptys.
  defp read_secret(prompt) do
    clearer = spawn_link(fn -> clear_echo_loop(prompt) end)
    value = IO.gets(prompt)
    send(clearer, :done)
    IO.write("\n")
    if is_binary(value), do: value, else: nil
  end

  defp clear_echo_loop(prompt) do
    receive do
      :done -> :ok
    after
      1 ->
        IO.write("\e[2K\r#{prompt}")
        clear_echo_loop(prompt)
    end
  end

  defp prompt_for_choice(options, attempts_left) when attempts_left > 0 do
    answer = Mix.shell().prompt("  Choose a provider [1]: ")

    case ProviderPicker.parse_selection(answer, options) do
      {:ok, %{needs_key: var} = option} when is_binary(var) ->
        Mix.shell().info("")
        collect_api_key(option)

      {:ok, option} ->
        Mix.shell().info("")
        to_choice(option)

      {:error, {:out_of_range, n}} ->
        Mix.shell().error("  #{n} is not on the menu (1-#{length(options)}).")
        prompt_for_choice(options, attempts_left - 1)

      {:error, {:unknown, input}} ->
        Mix.shell().error(
          "  #{inspect(input)} is not a listed provider; type its number or name."
        )

        prompt_for_choice(options, attempts_left - 1)

      {:error, :empty_menu} ->
        nil
    end
  end

  defp prompt_for_choice(_options, _attempts_left) do
    Mix.raise("No valid provider selected. Re-run, or pass --provider <name>.")
  end

  defp to_choice(%{acp_agent: agent} = option) when is_binary(agent) do
    {option.catalog_key, option.config_atom, agent}
  end

  defp to_choice(option) do
    {option.catalog_key, option.config_atom,
     select_best_model(option.llmdb_atom, option.config_atom)}
  end

  # A pipe or a here-doc is not a terminal; then the menu would block on a
  # read nobody answers, so fall back to the automatic choice.
  defp interactive_stdin? do
    :standard_io
    |> :io.getopts()
    |> Keyword.get(:stdin, false)
  rescue
    _ -> false
  end

  # ACP "model" is the agent name, not an LLMDB model.
  # Pick best detected CLI agent by quality priority.
  @acp_agent_priority ~w(claude gemini codex goose aider opencode cline)

  # Installed ACP agents, best first (quality preference, then any others the
  # adapter knows about that we have no opinion on).
  defp detected_acp_agents do
    acp_mod = Arbor.AI.LLM.Adapter.Acp

    agents =
      if Code.ensure_loaded?(acp_mod) and function_exported?(acp_mod, :detected_agents, 0) do
        apply(acp_mod, :detected_agents, [])
      else
        []
      end

    Enum.filter(@acp_agent_priority, &(&1 in agents)) ++ (agents -- @acp_agent_priority)
  end

  defp select_best_model(:opencode_zen, :opencode_zen) do
    case Arbor.LLM.OpenCodeZen.admitted_ids() do
      [id | _] -> id
      _ -> nil
    end
  end

  defp select_best_model(:acp, :acp) do
    case detected_acp_agents() do
      [best | _] -> best
      [] -> "claude"
    end
  end

  # Use LLMDB to find the best model for a provider.
  # Requires chat + tools support, prefers non-deprecated active models.
  # When LLMDB is unavailable or has no match, defer to fallback_model/2 (no
  # hard-coded model strings — see the note by @provider_priority).
  defp select_best_model(llmdb_provider, config_provider) do
    with true <- Code.ensure_loaded?(LLMDB) and function_exported?(LLMDB, :select, 1),
         {:ok, {_provider, model_id}} <-
           apply(LLMDB, :select, [
             [require: [chat: true], prefer: [llmdb_provider], scope: llmdb_provider]
           ]) do
      model_id
    else
      _ -> fallback_model(config_provider, runtime_fallback_deps())
    end
  end

  # Resolve a model when LLMDB can't answer, WITHOUT hard-coding model ids (which go
  # stale) or assuming a cloud provider. Layered, most-trusted source first:
  #   1. the user's CONFIGURED default model — but only for the default provider
  #   2. LIVE discovery from local providers (Ollama/LM Studio) — staleness-proof,
  #      reflects exactly what the user has loaded
  #   3. nil — honest "couldn't determine"; the caller reports it rather than
  #      recommending a fabricated model that may itself be retired
  # Pure given `deps` (so it's unit-testable); `runtime_fallback_deps/0` wires the
  # real sources. Public only for testing.
  @doc false
  @spec fallback_model(atom(), map()) :: String.t() | nil
  def fallback_model(config_provider, deps) do
    cond do
      is_binary(deps.default_model) and not is_nil(deps.default_provider) and
          config_provider == deps.default_provider ->
        deps.default_model

      true ->
        case deps.discover.(config_provider) do
          [model | _] when is_binary(model) -> model
          _ -> nil
        end
    end
  end

  defp runtime_fallback_deps do
    %{
      default_provider: ai_config(:default_provider),
      default_model: ai_config(:default_model),
      discover: &discover_local_models/1
    }
  end

  # Runtime-resolved read of Arbor.AI.Config (arbor_ai is above arbor_common in the
  # hierarchy — same Code.ensure_loaded?/apply pattern used for LLMDB above).
  defp ai_config(fun) do
    mod = Arbor.AI.Config

    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 0) do
      apply(mod, fun, [])
    end
  end

  # Live model list from a local provider via the existing Arbor.LLM.Preflight
  # helper (Ollama GET /api/tags, LM Studio GET /v1/models). Returns [] for cloud
  # providers (no "loaded model" concept) or when the endpoint is unreachable.
  defp discover_local_models(config_provider) do
    {pf_provider, base_url} =
      case config_provider do
        :ollama -> {:ollama, local_base_url(:ollama)}
        :lmstudio -> {:lm_studio, local_base_url(:lm_studio)}
        _ -> {nil, nil}
      end

    pf = Arbor.LLM.Preflight

    if (pf_provider && Code.ensure_loaded?(pf)) and function_exported?(pf, :loaded_models, 2) do
      case apply(pf, :loaded_models, [pf_provider, base_url]) do
        {:ok, ids} when is_list(ids) -> ids
        _ -> []
      end
    else
      []
    end
  end

  defp local_base_url(:ollama),
    do: System.get_env("OLLAMA_BASE_URL") || "http://localhost:11434"

  defp local_base_url(:lm_studio),
    do: System.get_env("LM_STUDIO_BASE_URL") || "http://localhost:1234/v1"

  defp ensure_llmdb do
    if Code.ensure_loaded?(LLMDB) and function_exported?(LLMDB, :load, 1) do
      apply(LLMDB, :load, [[]])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp maybe_acknowledge_keyless(:opencode_zen),
    do: Arbor.LLM.OpenCodeZen.prompt_acknowledgement()

  defp maybe_acknowledge_keyless(_provider), do: :ok

  defp configure_default(provider_atom, model) do
    env_path = Path.join(File.cwd!(), ".env")

    unless File.exists?(env_path) do
      Mix.shell().error("  No .env file found. Run ./bin/mix arbor.setup first.")
      return()
    end

    provider_str = to_string(provider_atom)

    write_env_key(env_path, "ARBOR_DEFAULT_PROVIDER", provider_str)
    write_env_key(env_path, "ARBOR_DEFAULT_MODEL", model)

    Mix.shell().info("")
    Mix.shell().info("  ✓ Wrote to .env:")
    Mix.shell().info("    ARBOR_DEFAULT_PROVIDER=#{provider_str}")
    Mix.shell().info("    ARBOR_DEFAULT_MODEL=#{model}")
    Mix.shell().info("    (takes effect on next app start)")
  end

  defp return, do: :ok

  @doc false
  def write_env_key(env_path, key, value) do
    content = File.read!(env_path)

    if has_env_key?(content, key) do
      updated =
        content
        |> String.split("\n")
        |> Enum.map_join("\n", fn line ->
          case env_key_line(line, key) do
            {:match, "export " <> _} -> "export #{key}=#{value}"
            {:match, _} -> "#{key}=#{value}"
            :no_match -> line
          end
        end)

      File.write!(env_path, updated)
    else
      separator = if String.ends_with?(content, "\n"), do: "", else: "\n"
      File.write!(env_path, content <> separator <> "#{key}=#{value}\n")
    end
  end

  defp has_env_key?(content, key) do
    content
    |> String.split("\n")
    |> Enum.any?(fn line -> match?({:match, _}, env_key_line(line, key)) end)
  end

  # `.env` assignments may carry an `export ` prefix — `config/runtime.exs`
  # strips it when loading (`String.replace_leading("export ", "")`), so both
  # forms are live. Matching only the bare form made `has_env_key?/2` miss an
  # existing `export ARBOR_DEFAULT_PROVIDER=...` and APPEND a second
  # assignment, leaving the file with two entries for one key.
  #
  # Returns `{:match, trimmed_line}` so the caller can preserve whichever
  # prefix the line already used.
  defp env_key_line(line, key) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "#") -> :no_match
      String.starts_with?(trimmed, key <> "=") -> {:match, trimmed}
      String.starts_with?(trimmed, "export " <> key <> "=") -> {:match, trimmed}
      true -> :no_match
    end
  end

  # ── Health Check Table ────────────────────────────────────────────────

  defp print_table(entries, opts) do
    ready = Enum.filter(entries, & &1.available?)
    missing = Enum.reject(entries, & &1.available?)

    Mix.shell().info("")
    Mix.shell().info("  Arbor LLM Provider Health Check")
    Mix.shell().info("  ================================")
    Mix.shell().info("")

    # Header
    Mix.shell().info(
      "  #{pad("Provider", 18)} #{pad("Status", 10)} #{pad("Type", 7)} #{pad("Stream", 8)} #{pad("Think", 7)} #{pad("Tools", 7)} #{pad("Vision", 7)}"
    )

    Mix.shell().info(
      "  #{String.duplicate("-", 18)} #{String.duplicate("-", 10)} #{String.duplicate("-", 7)} #{String.duplicate("-", 8)} #{String.duplicate("-", 7)} #{String.duplicate("-", 7)} #{String.duplicate("-", 7)}"
    )

    # Ready providers
    for entry <- ready do
      caps = entry.capabilities || struct!(Arbor.Contracts.AI.Capabilities)

      Mix.shell().info(
        "  #{pad(entry.display_name, 18)} #{pad("ready", 10)} #{pad(type_label(entry.type), 7)} #{flag(caps.streaming, 8)} #{flag(caps.thinking, 7)} #{flag(caps.tool_calls, 7)} #{flag(caps.vision, 7)}"
      )

      if entry.provider == "acp", do: print_acp_agents()
      if opts[:verbose], do: print_check_details(entry)
    end

    # Missing providers
    for entry <- missing do
      Mix.shell().info(
        "  #{pad(entry.display_name, 18)} #{pad("missing", 10)} #{pad(type_label(entry.type), 7)}"
      )

      if opts[:verbose], do: print_check_details(entry)
    end

    Mix.shell().info("")
    Mix.shell().info("  #{length(ready)} ready, #{length(missing)} missing")

    # Install hints for missing
    if missing != [] do
      Mix.shell().info("")
      Mix.shell().info("  Missing providers:")

      for entry <- missing do
        hint = install_hint(entry)
        if hint, do: Mix.shell().info("    #{entry.display_name}: #{hint}")
      end
    end

    Mix.shell().info("")
  end

  defp print_acp_agents do
    acp_mod = Arbor.AI.LLM.Adapter.Acp

    agents =
      if Code.ensure_loaded?(acp_mod) and function_exported?(acp_mod, :detected_agents, 0) do
        apply(acp_mod, :detected_agents, [])
      else
        []
      end

    if agents != [] do
      Mix.shell().info("    Detected agents: #{Enum.join(agents, ", ")}")
    end
  end

  defp print_check_details(entry) do
    case entry.check_result do
      {:ok, details} ->
        for {check, result} <- details, result != :skipped do
          Mix.shell().info("    #{check}: #{inspect(result)}")
        end

      {:error, failures} when is_list(failures) ->
        for {check, reason} <- failures do
          Mix.shell().info("    #{check}: FAILED — #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().info("    availability: FAILED — #{Arbor.LLM.ExternalTerm.inspect(reason)}")
    end
  end

  defp install_hint(entry) do
    case entry.check_result do
      {:error, failures} when is_list(failures) ->
        failures
        |> Enum.map(fn
          {:cli_tools, {:missing, tools, _}} when is_list(tools) ->
            Enum.map_join(tools, ", ", fn t -> "Install #{t.name}: #{t.install_hint}" end)

          {:cli_tools, {:missing, tool, _}} when is_binary(tool) ->
            "Install: #{tool}"

          {:env_vars, {:missing, vars, _}} when is_list(vars) ->
            missing_names =
              Enum.map_join(vars, ", ", fn
                %{name: n} -> n
                n when is_binary(n) -> n
              end)

            "Set env var(s): #{missing_names}"

          {:env_vars, {:missing, var, _}} when is_binary(var) ->
            "Set env var: #{var}"

          {:probes, {:failed, probes, _}} when is_list(probes) ->
            Enum.map_join(probes, ", ", fn
              %{url: url} -> "Start service at #{url}"
              p when is_binary(p) -> "Start service at #{p}"
            end)

          {:probes, {:failed, probe, _}} when is_binary(probe) ->
            "Start service at #{probe}"

          _ ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.join("; ")
        |> presence()

      # Local providers (:ollama, :lm_studio) report a SINGLE sanitized reason
      # from `ProviderCatalog.bounded_local_check/2`, not a keyword list of
      # {check, reason}. That fell into the list mapper above, matched no
      # clause, and produced an empty string — and `""` is truthy, so the
      # caller printed a bare "LM Studio: " with no advice at all.
      {:error, _sanitized_reason} ->
        local_start_hint(entry)

      _ ->
        nil
    end
  end

  # `Enum.join([])` is `""`, which is truthy — an unhandled failure shape would
  # otherwise print a dangling "<provider>: " label. Collapse empty to nil so
  # the caller skips the line entirely.
  defp presence(""), do: nil
  defp presence(hint) when is_binary(hint), do: hint

  defp local_start_hint(%{type: :local} = entry) do
    case local_probe_base(entry) do
      nil -> "Start the local server, then re-run mix arbor.doctor"
      base -> "Start the local server at #{base}"
    end
  end

  defp local_start_hint(_entry), do: nil

  # The contract probes an OpenAI-compatible model-list endpoint
  # (`<base>/v1/models`). Show the SERVER ROOT instead — that is what the
  # operator actually starts and what the *_BASE_URL env vars take. Printing
  # the probe path told users to "start the local server at
  # http://localhost:11434/v1", which is an API route, not an address.
  defp local_probe_base(entry) do
    case Map.get(entry, :contract) do
      %{probes: [%{url: url} | _]} when is_binary(url) ->
        url
        |> String.replace_suffix("/models", "")
        |> String.replace_suffix("/v1", "")

      _ ->
        nil
    end
  end

  defp print_json(entries) do
    data =
      Enum.map(entries, fn entry ->
        caps = entry.capabilities || struct!(Arbor.Contracts.AI.Capabilities)

        %{
          provider: entry.provider,
          display_name: entry.display_name,
          type: entry.type,
          available: entry.available?,
          capabilities: %{
            streaming: caps.streaming,
            thinking: caps.thinking,
            tool_calls: caps.tool_calls,
            vision: caps.vision,
            structured_output: caps.structured_output,
            resume: caps.resume
          }
        }
      end)

    Mix.shell().info(Jason.encode!(data, pretty: true))
  end

  defp pad(str, width) do
    str = to_string(str)

    if String.length(str) >= width do
      String.slice(str, 0, width)
    else
      str <> String.duplicate(" ", width - String.length(str))
    end
  end

  defp flag(true, width), do: pad("Y", width)
  defp flag(false, width), do: pad("-", width)
  defp flag(nil, width), do: pad("-", width)

  defp type_label(:cli), do: "CLI"
  defp type_label(:api), do: "API"
  defp type_label(:local), do: "Local"
  defp type_label(other), do: to_string(other)
end
