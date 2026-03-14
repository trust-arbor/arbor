defmodule Mix.Tasks.Arbor.User.Config do
  @moduledoc """
  Manage per-user configuration via RPC to the running server.

  ## Usage

      mix arbor.user.config list <user_id>          # show all settings
      mix arbor.user.config get <user_id> <key>      # get a setting
      mix arbor.user.config set <user_id> <key> <val> # set a setting
      mix arbor.user.config delete <user_id> <key>    # delete a setting
      mix arbor.user.config api_key <user_id> <provider> <key>  # set API key

  ## Known Settings

      default_model      — Default LLM model (e.g., "claude-sonnet-4-5-20250514")
      default_provider   — Default LLM provider (e.g., "anthropic")
      workspace_root     — Custom workspace path override
      timezone           — User's timezone (e.g., "America/Los_Angeles")
  """

  use Mix.Task

  alias Mix.Tasks.Arbor.Helpers, as: Config

  @shortdoc "Manage per-user configuration"

  @impl Mix.Task
  def run(args) do
    {_opts, args, _} = OptionParser.parse(args, strict: [])

    Config.ensure_distribution()

    unless Config.server_running?() do
      Mix.shell().error("Arbor server is not running. Start it with: mix arbor.start")
      exit({:shutdown, 1})
    end

    case args do
      ["list", user_id] ->
        list_config(user_id)

      ["get", user_id, key] ->
        get_config(user_id, key)

      ["set", user_id, key, value] ->
        set_config(user_id, key, value)

      ["delete", user_id, key] ->
        delete_config(user_id, key)

      ["api_key", user_id, provider, api_key] ->
        set_api_key(user_id, provider, api_key)

      _ ->
        Mix.shell().error(
          "Usage: mix arbor.user.config [list|get|set|delete|api_key] <user_id> [key] [value]"
        )
    end
  end

  defp list_config(user_id) do
    config = rpc!(Arbor.Agent.UserConfig, :get_all, [user_id])

    if config == %{} do
      Mix.shell().info("No configuration for #{user_id}")
    else
      Mix.shell().info("Configuration for #{user_id}:\n")

      config
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.each(fn {key, value} ->
        display_value = format_value(key, value)
        Mix.shell().info("  #{key}: #{display_value}")
      end)
    end
  end

  defp get_config(user_id, key) do
    atom_key = safe_to_atom(key)

    case rpc!(Arbor.Agent.UserConfig, :get, [user_id, atom_key]) do
      nil ->
        effective = rpc!(Arbor.Agent.UserConfig, :get_effective, [user_id, atom_key])

        if effective do
          Mix.shell().info("#{key} = #{inspect(effective)} (from app config)")
        else
          Mix.shell().info("#{key} is not set")
        end

      value ->
        Mix.shell().info("#{key} = #{format_value(atom_key, value)}")
    end
  end

  defp set_config(user_id, key, value) do
    atom_key = safe_to_atom(key)
    parsed_value = parse_value(value)

    case rpc!(Arbor.Agent.UserConfig, :put, [user_id, atom_key, parsed_value]) do
      :ok ->
        Mix.shell().info("Set #{key} = #{inspect(parsed_value)} for #{user_id}")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp delete_config(user_id, key) do
    atom_key = safe_to_atom(key)

    case rpc!(Arbor.Agent.UserConfig, :delete, [user_id, atom_key]) do
      :ok ->
        Mix.shell().info("Deleted #{key} for #{user_id}")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp set_api_key(user_id, provider, api_key) do
    provider_atom = safe_to_atom(provider)

    case rpc!(Arbor.Agent.UserConfig, :put_api_key, [user_id, provider_atom, api_key]) do
      :ok ->
        masked = String.slice(api_key, 0, 8) <> "..." <> String.slice(api_key, -4, 4)
        Mix.shell().info("Set #{provider} API key for #{user_id}: #{masked}")

      {:error, reason} ->
        Mix.shell().error("Failed: #{inspect(reason)}")
    end
  end

  defp rpc!(mod, fun, args) do
    Config.rpc!(Config.full_node_name(), mod, fun, args)
  end

  # Mask API keys in display
  defp format_value(:api_keys, keys) when is_map(keys) do
    masked =
      Enum.map(keys, fn {provider, key} ->
        masked_key =
          if is_binary(key) and byte_size(key) > 12 do
            String.slice(key, 0, 8) <> "..." <> String.slice(key, -4, 4)
          else
            "***"
          end

        "#{provider}: #{masked_key}"
      end)

    "{#{Enum.join(masked, ", ")}}"
  end

  defp format_value(_key, value), do: inspect(value)

  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp safe_to_atom(str) do
    try do
      String.to_existing_atom(str)
    rescue
      ArgumentError -> String.to_atom(str)
    end
  end
end
