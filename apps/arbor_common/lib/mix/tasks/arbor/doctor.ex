defmodule Mix.Tasks.Arbor.Doctor do
  @shortdoc "Check LLM provider health and capabilities"
  @moduledoc """
  Runs health checks on all registered LLM providers and reports their status,
  capabilities, and install hints for missing providers.

      $ mix arbor.doctor

  ## Options

    * `--refresh` - Force refresh the provider catalog cache
    * `--json`    - Output as JSON instead of table format
    * `--verbose` - Show detailed check results for each provider

  ## Output

  Displays a table of all providers with:
    - Status (ready/missing)
    - Type (API/CLI/Local)
    - Capability flags (streaming, thinking, tools, vision, etc.)
    - Install hints for missing providers
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [refresh: :boolean, json: :boolean, verbose: :boolean])

    # Start minimal deps for provider discovery
    Application.ensure_all_started(:req)
    Application.ensure_all_started(:req_llm)

    catalog_mod = Arbor.Orchestrator.UnifiedLLM.ProviderCatalog

    unless Code.ensure_loaded?(catalog_mod) do
      Mix.shell().error("ProviderCatalog not available. Is arbor_orchestrator compiled?")
      System.halt(1)
    end

    if opts[:refresh], do: catalog_mod.refresh()

    entries = catalog_mod.all([])

    if opts[:json] do
      print_json(entries)
    else
      print_table(entries, opts)
    end
  end

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
