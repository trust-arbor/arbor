defmodule Mix.Tasks.Arbor.Doctor do
  @shortdoc "Provider health + runtime axis introspection"
  @moduledoc """
  Multi-mode triage tool. With no flags, runs the LLM provider health
  check (the original behavior). Subcommand flags surface specific
  runtime-axis introspection without making any LLM calls.

      $ mix arbor.doctor                              # Provider health (default)
      $ mix arbor.doctor --runtimes                   # Registered runtimes + profiles
      $ mix arbor.doctor --model claude-opus-4-6      # Selection preview for a model
      $ mix arbor.doctor --model claude-opus-4-6 \\
          --fallback "runtime=acp" \\
          --fallback "model=claude-haiku-4-5-20251001"

  ## Options

  ### Provider-health mode (default)

    * `--refresh`   - Force refresh the provider catalog cache
    * `--json`      - Output as JSON instead of table format
    * `--verbose`   - Show detailed check results for each provider
    * `--configure` - Auto-detect best LLM provider and write to .env

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

  ## Auto-Configuration

  `mix arbor.doctor --configure` picks the best available provider and writes
  `ARBOR_DEFAULT_PROVIDER` and `ARBOR_DEFAULT_MODEL` to your `.env` file.

  Priority: Anthropic > OpenAI > Gemini > xAI > OpenRouter > ACP > Ollama > LM Studio

  Model selection uses LLMDB to find the best available model for the chosen
  provider (requires chat capability). Falls back to hardcoded defaults if
  LLMDB is unavailable.
  """
  use Mix.Task

  # Provider priority order (highest quality first).
  # Catalog key = ProviderCatalog string, config atom = what goes in .env/config,
  # LLMDB atom = what LLMDB uses for model lookup.
  @provider_priority [
    {"anthropic", :anthropic, :anthropic},
    {"openai", :openai, :openai},
    {"google", :gemini, :google},
    {"xai", :xai, :xai},
    {"open_router", :openrouter, :openrouter},
    {"acp", :acp, :acp},
    {"ollama", :ollama, :ollama_cloud},
    {"lm_studio", :lmstudio, :lmstudio}
  ]

  # Fallback models when LLMDB is unavailable or has no match
  @fallback_models %{
    anthropic: "claude-sonnet-4-5-20250514",
    openai: "gpt-4.1",
    google: "gemini-2.5-flash",
    xai: "grok-3-mini",
    openrouter: "arcee-ai/trinity-large-preview:free",
    acp: "claude",
    ollama_cloud: "llama3.2",
    lmstudio: "default"
  }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          refresh: :boolean,
          json: :boolean,
          verbose: :boolean,
          configure: :boolean,
          runtimes: :boolean,
          model: :string,
          fallback: :keep,
          runtime: :string
        ]
      )

    # Start minimal deps for provider discovery
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:req_llm)
    Application.ensure_all_started(:llm_db)

    # Load LLMDB for model lookup
    ensure_llmdb()

    cond do
      opts[:runtimes] -> run_runtimes_view(opts)
      opts[:model] -> run_model_view(opts, args)
      true -> run_provider_health(opts)
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

    case pick_best_provider(ready) do
      nil ->
        Mix.shell().info(
          "  No LLM providers available. Add an API key to .env or start a local model."
        )

        Mix.shell().info("")

      {provider_str, provider_atom, model} ->
        current_provider = System.get_env("ARBOR_DEFAULT_PROVIDER")
        current_model = System.get_env("ARBOR_DEFAULT_MODEL")

        if current_provider do
          Mix.shell().info("  Default LLM: #{current_provider} / #{current_model || "(not set)"}")
          Mix.shell().info("  Recommended: #{provider_str} / #{model}")

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
          configure_default(provider_atom, model)
        end

        Mix.shell().info("")
    end
  end

  defp pick_best_provider(ready_entries) do
    ready_providers = MapSet.new(ready_entries, & &1.provider)

    Enum.find_value(@provider_priority, fn {catalog_key, config_atom, llmdb_atom} ->
      if MapSet.member?(ready_providers, catalog_key) do
        model = select_best_model(llmdb_atom, config_atom)
        {catalog_key, config_atom, model}
      end
    end)
  end

  # ACP "model" is the agent name, not an LLMDB model.
  # Pick best detected CLI agent by quality priority.
  @acp_agent_priority ~w(claude gemini codex goose aider opencode cline)

  defp select_best_model(:acp, :acp) do
    acp_mod = Arbor.AI.LLM.Adapter.Acp

    agents =
      if Code.ensure_loaded?(acp_mod) and function_exported?(acp_mod, :detected_agents, 0) do
        apply(acp_mod, :detected_agents, [])
      else
        []
      end

    Enum.find(@acp_agent_priority, "claude", fn agent -> agent in agents end)
  end

  # Use LLMDB to find the best model for a provider.
  # Requires chat + tools support, prefers non-deprecated active models.
  defp select_best_model(llmdb_provider, config_provider) do
    if Code.ensure_loaded?(LLMDB) and function_exported?(LLMDB, :select, 1) do
      case apply(LLMDB, :select, [
             [require: [chat: true], prefer: [llmdb_provider], scope: llmdb_provider]
           ]) do
        {:ok, {_provider, model_id}} ->
          model_id

        _ ->
          Map.get(@fallback_models, llmdb_provider) ||
            Map.get(@fallback_models, config_provider, "default")
      end
    else
      Map.get(@fallback_models, llmdb_provider) ||
        Map.get(@fallback_models, config_provider, "default")
    end
  end

  defp ensure_llmdb do
    if Code.ensure_loaded?(LLMDB) and function_exported?(LLMDB, :load, 1) do
      apply(LLMDB, :load, [[]])
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp configure_default(provider_atom, model) do
    env_path = Path.join(File.cwd!(), ".env")

    unless File.exists?(env_path) do
      Mix.shell().error("  No .env file found. Run mix arbor.setup first.")
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

  defp write_env_key(env_path, key, value) do
    content = File.read!(env_path)

    if has_env_key?(content, key) do
      updated =
        content
        |> String.split("\n")
        |> Enum.map_join("\n", fn line ->
          trimmed = String.trim(line)

          if not String.starts_with?(trimmed, "#") and String.starts_with?(trimmed, key <> "=") do
            "#{key}=#{value}"
          else
            line
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
    |> Enum.any?(fn line ->
      trimmed = String.trim(line)
      not String.starts_with?(trimmed, "#") and String.starts_with?(trimmed, key <> "=")
    end)
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

      {:error, failures} ->
        for {check, reason} <- failures do
          Mix.shell().info("    #{check}: FAILED — #{inspect(reason)}")
        end
    end
  end

  defp install_hint(entry) do
    case entry.check_result do
      {:error, failures} ->
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
