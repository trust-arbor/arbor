defmodule Mix.Tasks.Arbor.Profile do
  @moduledoc """
  Manage agent profiles.

  Profiles are runtime instances of agents stored in Postgres.
  Each profile contains the agent's identity, trust tier, template
  reference, and configuration.

  ## Usage

      mix arbor.profile                           # list all profiles
      mix arbor.profile list                      # same as above
      mix arbor.profile show <name|id>            # show profile details
      mix arbor.profile edit <name|id> --set k=v  # modify a field
      mix arbor.profile delete <name|id>          # delete a profile
      mix arbor.profile export <name|id>          # dump profile as JSON
      mix arbor.profile import <file.json>        # import profile from JSON

  ## Editable Fields (via --set)

    * `trust_tier=<tier>` — untrusted, probationary, trusted, veteran, autonomous
    * `auto_start=true|false` — auto-start on boot
    * `display_name=<name>` — display name
    * `metadata.<key>=<value>` — nested metadata field
  """

  use Mix.Task

  @shortdoc "Manage agent profiles"

  @switches [
    set: :keep
  ]

  @impl Mix.Task
  def run(args) do
    {opts, args, _} = OptionParser.parse(args, strict: @switches)

    # Start the app to access Postgres
    Mix.Task.run("app.start", [])

    case args do
      [] -> list_profiles()
      ["list"] -> list_profiles()
      ["show", ref] -> show_profile(ref)
      ["edit", ref] -> edit_profile(ref, opts)
      ["delete", ref] -> delete_profile(ref)
      ["export", ref] -> export_profile(ref)
      ["import", path] -> import_profile(path)
      _ -> Mix.shell().error("Unknown command. Run `mix help arbor.profile` for usage.")
    end
  end

  defp list_profiles do
    profiles = Arbor.Agent.ProfileStore.list_profiles()

    if profiles == [] do
      Mix.shell().info("No agent profiles found.")
    else
      Mix.shell().info("Agent Profiles (#{length(profiles)}):\n")

      header =
        String.pad_trailing("AGENT ID", 24) <>
        String.pad_trailing("NAME", 18) <>
        String.pad_trailing("TEMPLATE", 16) <>
        String.pad_trailing("TIER", 14) <>
        "AUTO"
      Mix.shell().info(header)
      Mix.shell().info(String.duplicate("-", 80))

      for p <- profiles do
        id = String.pad_trailing(truncate(p.agent_id, 22), 24)
        name = String.pad_trailing(p.display_name || "?", 18)
        template = String.pad_trailing(format_template(p.template), 16)
        tier = String.pad_trailing(to_string(p.trust_tier), 14)
        auto = if p.auto_start, do: "yes", else: "no"
        Mix.shell().info("#{id}#{name}#{template}#{tier}#{auto}")
      end
    end
  end

  defp show_profile(ref) do
    case find_profile(ref) do
      {:ok, p} ->
        Mix.shell().info("Agent ID: #{p.agent_id}")
        Mix.shell().info("Display Name: #{p.display_name}")
        Mix.shell().info("Template: #{format_template(p.template)}")
        Mix.shell().info("Trust Tier: #{p.trust_tier}")
        Mix.shell().info("Auto Start: #{p.auto_start}")
        Mix.shell().info("Version: #{p.version}")

        if p.character do
          Mix.shell().info("\nCharacter:")
          Mix.shell().info("  Name: #{p.character.name}")
          Mix.shell().info("  Role: #{p.character.role}")
          Mix.shell().info("  Tone: #{p.character.tone}")
        end

        Mix.shell().info("\nGoals: #{length(p.initial_goals || [])}")
        Mix.shell().info("Capabilities: #{length(p.initial_capabilities || [])}")
        Mix.shell().info("Created: #{p.created_at && DateTime.to_iso8601(p.created_at)}")

        if p.metadata && map_size(p.metadata) > 0 do
          Mix.shell().info("\nMetadata:")
          for {k, v} <- p.metadata do
            Mix.shell().info("  #{k}: #{inspect(v)}")
          end
        end

      :not_found ->
        Mix.shell().error("Profile '#{ref}' not found.")
    end
  end

  defp edit_profile(ref, opts) do
    case find_profile(ref) do
      {:ok, profile} ->
        changes = parse_set_opts(opts[:set] || [])

        if changes == %{} do
          Mix.shell().error("No changes specified. Use --set key=value")
        else
          updated = apply_changes(profile, changes)

          case Arbor.Agent.ProfileStore.store_profile(updated) do
            :ok ->
              Mix.shell().info("Profile '#{profile.display_name}' updated.")
              for {k, v} <- changes do
                Mix.shell().info("  #{k} = #{inspect(v)}")
              end

            {:error, reason} ->
              Mix.shell().error("Failed to update: #{inspect(reason)}")
          end
        end

      :not_found ->
        Mix.shell().error("Profile '#{ref}' not found.")
    end
  end

  defp delete_profile(ref) do
    case find_profile(ref) do
      {:ok, profile} ->
        if Mix.shell().yes?("Delete profile '#{profile.display_name}' (#{profile.agent_id})?") do
          case Arbor.Agent.ProfileStore.delete_profile(profile.agent_id) do
            :ok -> Mix.shell().info("Profile deleted.")
            {:error, reason} -> Mix.shell().error("Failed to delete: #{inspect(reason)}")
          end
        else
          Mix.shell().info("Cancelled.")
        end

      :not_found ->
        Mix.shell().error("Profile '#{ref}' not found.")
    end
  end

  defp export_profile(ref) do
    case find_profile(ref) do
      {:ok, profile} ->
        case Arbor.Agent.Profile.to_json(profile) do
          {:ok, json} -> Mix.shell().info(json)
          {:error, reason} -> Mix.shell().error("Export failed: #{inspect(reason)}")
        end

      :not_found ->
        Mix.shell().error("Profile '#{ref}' not found.")
    end
  end

  defp import_profile(path) do
    case File.read(path) do
      {:ok, json} ->
        case Arbor.Agent.Profile.from_json(json) do
          {:ok, profile} ->
            case Arbor.Agent.ProfileStore.store_profile(profile) do
              :ok ->
                Mix.shell().info("Imported profile '#{profile.display_name}' (#{profile.agent_id}).")

              {:error, reason} ->
                Mix.shell().error("Failed to import: #{inspect(reason)}")
            end

          {:error, reason} ->
            Mix.shell().error("Invalid profile JSON: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.shell().error("Cannot read file '#{path}': #{inspect(reason)}")
    end
  end

  # -- Helpers --

  defp find_profile(ref) do
    profiles = Arbor.Agent.ProfileStore.list_profiles()

    match =
      Enum.find(profiles, fn p ->
        p.agent_id == ref or
          p.display_name == ref or
          (p.character && p.character.name == ref)
      end)

    if match, do: {:ok, match}, else: :not_found
  end

  defp parse_set_opts(set_list) when is_list(set_list) do
    Enum.reduce(set_list, %{}, fn kv, acc ->
      case String.split(kv, "=", parts: 2) do
        [key, value] -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp apply_changes(profile, changes) do
    Enum.reduce(changes, profile, fn {key, value}, p ->
      case key do
        "trust_tier" ->
          tier = String.to_existing_atom(value)
          %{p | trust_tier: tier}

        "auto_start" ->
          %{p | auto_start: value in ["true", "1", "yes"]}

        "display_name" ->
          %{p | display_name: value}

        "metadata." <> meta_key ->
          metadata = Map.put(p.metadata || %{}, meta_key, value)
          %{p | metadata: metadata}

        _ ->
          Mix.shell().error("Unknown field: #{key}")
          p
      end
    end)
  end

  defp format_template(nil), do: "-"
  defp format_template(t) when is_binary(t), do: t
  defp format_template(t) when is_atom(t), do: Atom.to_string(t)

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."
end
