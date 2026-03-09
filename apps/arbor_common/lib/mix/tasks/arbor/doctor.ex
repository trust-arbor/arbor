defmodule Mix.Tasks.Arbor.Doctor do
  @shortdoc "Check LLM provider health and capabilities"
  @moduledoc """
  Runs health checks on all registered LLM providers and reports their status,
  capabilities, and install hints for missing providers.

      $ mix arbor.doctor

  ## Options

    * `--refresh`   - Force refresh the provider catalog cache
    * `--json`      - Output as JSON instead of table format
    * `--verbose`   - Show detailed check results for each provider
    * `--configure` - Auto-detect best LLM provider and write to .env

  ## Auto-Configuration

  `mix arbor.doctor --configure` picks the best available provider and writes
  `ARBOR_DEFAULT_PROVIDER` and `ARBOR_DEFAULT_MODEL` to your `.env` file.

  Priority: Anthropic > OpenAI > Gemini > xAI > OpenRouter > Ollama > LM Studio

  Model selection uses LLMDB to find the best available model for the chosen
  provider (requires chat capability). Falls back to hardcoded defaults if
  LLMDB is unavailable.

  ## Output

  Displays a table of all providers with:
    - Status (ready/missing)
    - Type (API/CLI/Local)
    - Capability flags (streaming, thinking, tools, vision, etc.)
    - Install hints for missing providers
  """
  use Mix.Task

  # Provider priority order (highest quality first).
  # Catalog key = ProviderCatalog string, config atom = what goes in .env/config,
  # LLMDB atom = what LLMDB uses for model lookup.
  @provider_priority [
    {"anthropic", :anthropic, :anthropic},
    {"openai", :openai, :openai},
    {"gemini", :gemini, :google},
    {"xai", :xai, :xai},
    {"open_router", :openrouter, :openrouter},
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
    ollama_cloud: "llama3.2",
    lmstudio: "default"
  }

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [refresh: :boolean, json: :boolean, verbose: :boolean, configure: :boolean]
      )

    # Start minimal deps for provider discovery
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:req_llm)

    # Load LLMDB for model lookup
    ensure_llmdb()

    catalog_mod = Arbor.Orchestrator.UnifiedLLM.ProviderCatalog

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

  # ── Default LLM Recommendation ──────────────────────────────────────

  defp recommend_default(entries, opts) do
    ready = Enum.filter(entries, & &1.available?)

    case pick_best_provider(ready) do
      nil ->
        Mix.shell().info("  No LLM providers available. Add an API key to .env or start a local model.")
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
