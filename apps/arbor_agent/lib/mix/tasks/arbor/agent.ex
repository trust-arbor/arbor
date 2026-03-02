defmodule Mix.Tasks.Arbor.Agent do
  @moduledoc """
  Manage agent lifecycle via RPC to the running Arbor server.

  All commands execute on the running `arbor_dev@localhost` node.
  Start the server first with `mix arbor.start`.

  ## Usage

      mix arbor.agent                           # list running agents
      mix arbor.agent list                      # same (running only)
      mix arbor.agent list --all                # running + stopped
      mix arbor.agent start <template>          # create & start from template
      mix arbor.agent resume <name|id>          # resume persisted agent
      mix arbor.agent stop <name|id>            # stop running agent
      mix arbor.agent destroy <name|id>         # delete agent + all data
      mix arbor.agent status <name|id>          # detailed agent status
      mix arbor.agent chat <name|id> "message"  # send message, print response
      mix arbor.agent auto-start <name|id>      # toggle auto-start on/off

  ## Options

    * `--name` / `-n` — display name (default: template's character name)
    * `--model` / `-m` — model ID (default: arcee-ai/trinity-large-preview:free)
    * `--provider` — provider atom (default: openrouter)
    * `--auto-start` — set auto-start on creation (with start)
    * `--timeout` — response timeout in seconds (default: 60, with chat)
    * `--all` — show both running and stopped agents (with list)
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Manage agent lifecycle (start, stop, chat, status)"

  @switches [
    name: :string,
    model: :string,
    provider: :string,
    auto_start: :boolean,
    timeout: :integer,
    all: :boolean
  ]

  @aliases [
    n: :name,
    m: :model
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, strict: @switches, aliases: @aliases)

    case args do
      [] -> do_list(opts)
      ["list"] -> do_list(opts)
      ["start"] -> do_start_usage()
      ["start", template | _] -> do_start(template, opts)
      ["resume", ref | _] -> do_resume(ref, opts)
      ["stop", ref | _] -> do_stop(ref)
      ["destroy", ref | _] -> do_destroy(ref)
      ["status", ref | _] -> do_status(ref)
      ["chat", ref, message | _] -> do_chat(ref, message, opts)
      ["chat", ref] -> do_chat_interactive(ref, opts)
      ["auto-start", ref | _] -> do_auto_start(ref)
      _ -> Mix.shell().error("Unknown command. Run `mix help arbor.agent` for usage.")
    end
  end

  # ── List ──────────────────────────────────────────────────────────────

  defp do_list(opts) do
    ensure_server!()
    {:ok, running} = remote(Arbor.Agent.Registry, :list, [])
    running_ids = MapSet.new(running, & &1.agent_id)

    agents =
      if opts[:all] do
        profiles = remote(Arbor.Agent.Lifecycle, :list_agents, [])

        # Merge: running agents + stopped profiles
        running_entries =
          Enum.map(running, fn entry ->
            profile = Enum.find(profiles, &(&1.agent_id == entry.agent_id))
            %{
              agent_id: entry.agent_id,
              name: (profile && profile.display_name) || "?",
              template: (profile && format_template(profile.template)) || "?",
              status: "running",
              model: get_in(entry.metadata, [:model_config, :id]) || "?"
            }
          end)

        stopped_entries =
          profiles
          |> Enum.reject(&MapSet.member?(running_ids, &1.agent_id))
          |> Enum.map(fn p ->
            %{
              agent_id: p.agent_id,
              name: p.display_name || "?",
              template: format_template(p.template),
              status: "stopped",
              model: "-"
            }
          end)

        running_entries ++ stopped_entries
      else
        Enum.map(running, fn entry ->
          %{
            agent_id: entry.agent_id,
            name: Map.get(entry.metadata, :display_name, "?"),
            template: "?",
            status: "running",
            model: get_in(entry.metadata, [:model_config, :id]) || "?"
          }
        end)
      end

    if agents == [] do
      Mix.shell().info("No agents found.")
      unless opts[:all], do: Mix.shell().info("Use --all to include stopped agents.")
    else
      Mix.shell().info("Agents (#{length(agents)}):\n")

      header =
        String.pad_trailing("AGENT ID", 24) <>
          String.pad_trailing("NAME", 18) <>
          String.pad_trailing("TEMPLATE", 16) <>
          String.pad_trailing("STATUS", 10) <>
          "MODEL"

      Mix.shell().info(header)
      Mix.shell().info(String.duplicate("-", 90))

      for a <- agents do
        id = String.pad_trailing(truncate(a.agent_id, 22), 24)
        name = String.pad_trailing(truncate(a.name, 16), 18)
        template = String.pad_trailing(truncate(a.template, 14), 16)
        status = String.pad_trailing(a.status, 10)
        model = truncate(a.model, 30)
        Mix.shell().info("#{id}#{name}#{template}#{status}#{model}")
      end
    end
  end

  # ── Start ─────────────────────────────────────────────────────────────

  defp do_start(template_name, opts) do
    ensure_server!()

    case remote(Arbor.Agent.TemplateStore, :get, [template_name]) do
      {:ok, template_data} ->
        display_name = opts[:name] || get_in(template_data, ["character", "name"]) || template_name
        model_id = opts[:model] || "arcee-ai/trinity-large-preview:free"
        provider = parse_provider(opts[:provider] || "openrouter")

        model_config = %{
          id: model_id,
          provider: provider,
          backend: :api,
          module: Arbor.Agent.APIAgent,
          start_opts: []
        }

        start_opts = [
          template: template_name,
          display_name: display_name,
          model_config: model_config
        ]

        case remote(Arbor.Agent.Manager, :start_or_resume, [Arbor.Agent.APIAgent, display_name, start_opts]) do
          {:ok, agent_id, _pid} ->
            Mix.shell().info("Started agent '#{display_name}' (#{agent_id})")

            if opts[:auto_start] do
              remote(Arbor.Agent.Manager, :set_auto_start, [agent_id, true])
              Mix.shell().info("Auto-start enabled.")
            end

          {:error, reason} ->
            Mix.shell().error("Failed to start agent: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        Mix.shell().error("Template '#{template_name}' not found.")
        print_available_templates()
    end
  end

  defp do_start_usage do
    ensure_server!()
    Mix.shell().info("Usage: mix arbor.agent start <template> [--name NAME] [--model MODEL]\n")
    print_available_templates()
  end

  defp print_available_templates do
    templates = remote(Arbor.Agent.TemplateStore, :list, [])

    if templates == [] do
      Mix.shell().info("No templates available. Run `mix arbor.template seed` to create builtins.")
    else
      Mix.shell().info("Available templates:\n")

      header =
        String.pad_trailing("NAME", 20) <>
          String.pad_trailing("TIER", 14) <>
          "DESCRIPTION"

      Mix.shell().info(header)
      Mix.shell().info(String.duplicate("-", 70))

      for t <- templates do
        name = String.pad_trailing(t["name"] || "?", 20)
        tier = String.pad_trailing(t["trust_tier"] || "?", 14)
        desc = truncate(t["description"] || "", 36)
        Mix.shell().info("#{name}#{tier}#{desc}")
      end

      Mix.shell().info("\nStart with: mix arbor.agent start <name>")
    end
  end

  # ── Resume ────────────────────────────────────────────────────────────

  defp do_resume(ref, _opts) do
    ensure_server!()

    case find_profile(ref) do
      {:ok, profile} ->
        case remote(Arbor.Agent.Manager, :resume_agent, [profile.agent_id, []]) do
          {:ok, agent_id, _pid} ->
            Mix.shell().info("Resumed agent '#{profile.display_name}' (#{agent_id})")

          {:error, reason} ->
            Mix.shell().error("Failed to resume: #{inspect(reason)}")
        end

      :not_found ->
        Mix.shell().error("Agent '#{ref}' not found. Use `mix arbor.agent list --all` to see all agents.")
    end
  end

  # ── Stop ──────────────────────────────────────────────────────────────

  defp do_stop(ref) do
    ensure_server!()

    case find_running(ref) do
      {:ok, agent_id, name} ->
        case remote(Arbor.Agent.Manager, :stop_agent, [agent_id]) do
          :ok -> Mix.shell().info("Stopped agent '#{name}' (#{agent_id})")
          {:error, reason} -> Mix.shell().error("Failed to stop: #{inspect(reason)}")
        end

      :not_found ->
        Mix.shell().error("Running agent '#{ref}' not found.")
    end
  end

  # ── Destroy ───────────────────────────────────────────────────────────

  defp do_destroy(ref) do
    ensure_server!()

    case find_profile(ref) do
      {:ok, profile} ->
        if Mix.shell().yes?("Destroy agent '#{profile.display_name}' (#{profile.agent_id})? This deletes all data.") do
          # Stop first if running
          remote(Arbor.Agent.Manager, :stop_agent, [profile.agent_id])
          remote(Arbor.Agent.Lifecycle, :destroy, [profile.agent_id])
          Mix.shell().info("Destroyed agent '#{profile.display_name}'.")
        else
          Mix.shell().info("Cancelled.")
        end

      :not_found ->
        Mix.shell().error("Agent '#{ref}' not found.")
    end
  end

  # ── Status ────────────────────────────────────────────────────────────

  defp do_status(ref) do
    ensure_server!()

    profile =
      case find_profile(ref) do
        {:ok, p} -> p
        :not_found -> nil
      end

    {:ok, running} = remote(Arbor.Agent.Registry, :list, [])

    running_entry =
      if profile do
        Enum.find(running, &(&1.agent_id == profile.agent_id))
      else
        Enum.find(running, fn e ->
          e.agent_id == ref or Map.get(e.metadata, :display_name) == ref
        end)
      end

    cond do
      profile == nil and running_entry == nil ->
        Mix.shell().error("Agent '#{ref}' not found.")

      profile != nil ->
        Mix.shell().info("Agent Status")
        Mix.shell().info(String.duplicate("=", 40))
        Mix.shell().info("  Agent ID:     #{profile.agent_id}")
        Mix.shell().info("  Display Name: #{profile.display_name}")
        Mix.shell().info("  Template:     #{format_template(profile.template)}")
        Mix.shell().info("  Trust Tier:   #{profile.trust_tier}")
        Mix.shell().info("  Auto Start:   #{profile.auto_start}")

        if running_entry do
          Mix.shell().info("  Status:       running")
          Mix.shell().info("  PID:          #{inspect(running_entry.pid)}")
          model = get_in(running_entry.metadata, [:model_config, :id])
          if model, do: Mix.shell().info("  Model:        #{model}")
          provider = get_in(running_entry.metadata, [:model_config, :provider])
          if provider, do: Mix.shell().info("  Provider:     #{provider}")

          uptime_ms = System.monotonic_time(:millisecond) - (running_entry.registered_at || 0)
          if running_entry.registered_at, do: Mix.shell().info("  Uptime:       #{format_duration(uptime_ms)}")
        else
          Mix.shell().info("  Status:       stopped")
          Mix.shell().info("\n  Resume with: mix arbor.agent resume #{profile.display_name}")
        end

      running_entry != nil ->
        Mix.shell().info("Agent Status (no profile)")
        Mix.shell().info(String.duplicate("=", 40))
        Mix.shell().info("  Agent ID:     #{running_entry.agent_id}")
        Mix.shell().info("  Status:       running")
        Mix.shell().info("  PID:          #{inspect(running_entry.pid)}")
        Mix.shell().info("  Module:       #{running_entry.module}")
    end
  end

  # ── Chat ──────────────────────────────────────────────────────────────

  defp do_chat(ref, message, opts) do
    ensure_server!()
    timeout = (opts[:timeout] || 60) * 1_000

    case find_running(ref) do
      {:ok, agent_id, _name} ->
        case remote(Arbor.Agent.Manager, :chat, [message, "CLI", [agent_id: agent_id, timeout: timeout]]) do
          {:ok, response} ->
            Mix.shell().info(response)

          {:error, :timeout} ->
            Mix.shell().error("Response timed out after #{opts[:timeout] || 60}s.")

          {:error, reason} ->
            Mix.shell().error("Chat failed: #{inspect(reason)}")
        end

      :not_found ->
        # Check if it exists but is stopped
        case find_profile(ref) do
          {:ok, _} ->
            Mix.shell().error("Agent '#{ref}' is not running. Resume with: mix arbor.agent resume #{ref}")

          :not_found ->
            Mix.shell().error("Agent '#{ref}' not found.")
        end
    end
  end

  defp do_chat_interactive(ref, opts) do
    Mix.shell().error("Usage: mix arbor.agent chat <name|id> \"message\"")
    Mix.shell().info("Example: mix arbor.agent chat #{ref} \"hello\"")
    _ = opts
  end

  # ── Auto-Start ────────────────────────────────────────────────────────

  defp do_auto_start(ref) do
    ensure_server!()

    case find_profile(ref) do
      {:ok, profile} ->
        new_value = !profile.auto_start

        case remote(Arbor.Agent.Manager, :set_auto_start, [profile.agent_id, new_value]) do
          :ok ->
            state = if new_value, do: "enabled", else: "disabled"
            Mix.shell().info("Auto-start #{state} for '#{profile.display_name}'.")

          {:error, reason} ->
            Mix.shell().error("Failed to toggle auto-start: #{inspect(reason)}")
        end

      :not_found ->
        Mix.shell().error("Agent '#{ref}' not found.")
    end
  end

  # ── Shared Plumbing ──────────────────────────────────────────────────

  defp ensure_server! do
    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start with: mix arbor.start")
      exit({:shutdown, 1})
    end
  end

  defp remote(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end

  defp find_profile(ref) do
    profiles = remote(Arbor.Agent.Lifecycle, :list_agents, [])

    match =
      Enum.find(profiles, fn p ->
        p.agent_id == ref or
          p.display_name == ref or
          (p.character && p.character.name == ref)
      end)

    if match, do: {:ok, match}, else: :not_found
  end

  defp find_running(ref) do
    {:ok, running} = remote(Arbor.Agent.Registry, :list, [])

    entry =
      Enum.find(running, fn e ->
        e.agent_id == ref or Map.get(e.metadata, :display_name) == ref
      end)

    if entry do
      name = Map.get(entry.metadata, :display_name, entry.agent_id)
      {:ok, entry.agent_id, name}
    else
      # Try by profile name → agent_id → registry lookup
      case find_profile(ref) do
        {:ok, profile} ->
          match = Enum.find(running, &(&1.agent_id == profile.agent_id))
          if match, do: {:ok, profile.agent_id, profile.display_name}, else: :not_found

        :not_found ->
          :not_found
      end
    end
  end

  defp parse_provider(str) when is_binary(str) do
    # Safe: bounded set of known provider atoms
    case str do
      "openrouter" -> :openrouter
      "anthropic" -> :anthropic
      "openai" -> :openai
      "google" -> :google
      "local" -> :local
      "ollama" -> :ollama
      "lmstudio" -> :lmstudio
      other -> Mix.raise("Unknown provider: #{other}")
    end
  end

  defp format_template(nil), do: "-"
  defp format_template(t) when is_binary(t), do: t
  defp format_template(t) when is_atom(t), do: Atom.to_string(t)

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  defp format_duration(ms) when ms < 0, do: "?"

  defp format_duration(ms) do
    total_seconds = div(ms, 1000)
    days = div(total_seconds, 86_400)
    hours = div(rem(total_seconds, 86_400), 3600)
    minutes = div(rem(total_seconds, 3600), 60)
    seconds = rem(total_seconds, 60)

    parts =
      [{days, "d"}, {hours, "h"}, {minutes, "m"}, {seconds, "s"}]
      |> Enum.reject(fn {val, _} -> val == 0 end)
      |> Enum.map(fn {val, unit} -> "#{val}#{unit}" end)

    case parts do
      [] -> "0s"
      _ -> Enum.join(parts, " ")
    end
  end
end
