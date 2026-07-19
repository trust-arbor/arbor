defmodule Arbor.AI.AcpSession.RuntimeHome do
  @moduledoc false

  @create_attempts 4
  @grok_auth_filename "auth.json"
  @grok_home_directory "grok"
  @grok_log_filename "grok.log"
  @max_grok_auth_bytes 1_048_576
  @grok_isolation_env [
    {"GROK_CLAUDE_MCPS_ENABLED", "false"},
    {"GROK_CURSOR_MCPS_ENABLED", "false"},
    {"GROK_CODEX_MCPS_ENABLED", "false"},
    {"GROK_MANAGED_MCPS_ENABLED", "false"},
    {"GROK_MCP_RECURSIVE_CONFIG_WATCH", "0"},
    {"GROK_CLAUDE_HOOKS_ENABLED", "false"},
    {"GROK_CURSOR_HOOKS_ENABLED", "false"},
    {"GROK_CODEX_HOOKS_ENABLED", "false"},
    {"GROK_OFFICIAL_MARKETPLACE_AUTO_REGISTER", "false"},
    {"GROK_TELEMETRY_ENABLED", "false"},
    {"GROK_FEEDBACK_ENABLED", "false"},
    {"GROK_MEMORY", "0"},
    {"GROK_SUBAGENTS", "0"},
    {"GROK_WEB_FETCH", "0"},
    {"RUST_LOG", "warn"}
  ]

  @spec create() :: {:ok, map()} | {:error, :acp_runtime_home_unavailable}
  def create, do: create(@create_attempts)

  @spec inject(keyword(), map()) :: {:ok, keyword()} | {:error, atom()}
  def inject(client_opts, cleanup_identity), do: inject(client_opts, cleanup_identity, nil)

  @spec inject(keyword(), map(), atom() | nil) :: {:ok, keyword()} | {:error, atom()}
  def inject(client_opts, %{path: runtime_home}, provider)
      when is_list(client_opts) and is_binary(runtime_home) and runtime_home != "" do
    if Keyword.keyword?(client_opts) do
      with {:ok, client_opts} <- inject_arbor_home(client_opts, runtime_home),
           {:ok, client_opts} <- inject_provider_home(client_opts, runtime_home, provider) do
        {:ok, client_opts}
      end
    else
      {:error, :invalid_acp_client_options}
    end
  end

  def inject(_client_opts, _cleanup_identity, _provider),
    do: {:error, :invalid_acp_client_options}

  @spec cleanup(map()) :: :ok | {:error, term()}
  def cleanup(cleanup_identity) when is_map(cleanup_identity) do
    Arbor.Shell.remove_owned_tree(cleanup_identity)
  end

  def cleanup(_cleanup_identity), do: {:error, :invalid_acp_runtime_home}

  defp create(0), do: {:error, :acp_runtime_home_unavailable}

  defp create(attempts_left) do
    case System.tmp_dir() do
      root when is_binary(root) and root != "" ->
        path =
          Path.join(
            Path.expand(root),
            "arbor-acp-runtime-" <>
              Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
          )

        case Arbor.Shell.create_private_owned_tree(path) do
          {:ok, cleanup_identity} -> {:ok, cleanup_identity}
          {:error, :root_exists} -> create(attempts_left - 1)
          {:error, _reason} -> {:error, :acp_runtime_home_unavailable}
        end

      _other ->
        {:error, :acp_runtime_home_unavailable}
    end
  end

  defp inject_arbor_home(client_opts, runtime_home) do
    if Keyword.has_key?(client_opts, :adapter) do
      inject_adapter(client_opts, runtime_home)
    else
      inject_native(client_opts, runtime_home)
    end
  end

  defp inject_native(client_opts, runtime_home) do
    with {:ok, env} <- put_arbor_home(Keyword.get(client_opts, :env), runtime_home) do
      {:ok, Keyword.put(client_opts, :env, env)}
    end
  end

  defp inject_adapter(client_opts, runtime_home) do
    case Keyword.get(client_opts, :adapter_opts, []) do
      adapter_opts when is_list(adapter_opts) ->
        if Keyword.keyword?(adapter_opts) do
          with {:ok, env} <- put_arbor_home(Keyword.get(adapter_opts, :env), runtime_home) do
            adapter_opts = Keyword.put(adapter_opts, :env, env)
            {:ok, Keyword.put(client_opts, :adapter_opts, adapter_opts)}
          end
        else
          {:error, :invalid_acp_adapter_options}
        end

      _other ->
        {:error, :invalid_acp_adapter_options}
    end
  end

  defp put_arbor_home(nil, runtime_home), do: {:ok, [{"ARBOR_HOME", runtime_home}]}

  defp put_arbor_home(env, runtime_home) when is_map(env) do
    env = env |> Map.drop(["ARBOR_HOME", :ARBOR_HOME, ~c"ARBOR_HOME"]) |> Map.to_list()
    {:ok, env ++ [{"ARBOR_HOME", runtime_home}]}
  end

  defp put_arbor_home(env, runtime_home) when is_list(env) do
    if Enum.all?(env, &(is_tuple(&1) and tuple_size(&1) == 2)) do
      env = Enum.reject(env, fn {key, _value} -> arbor_home_key?(key) end)
      {:ok, env ++ [{"ARBOR_HOME", runtime_home}]}
    else
      {:error, :invalid_acp_launch_env}
    end
  end

  defp put_arbor_home(_env, _runtime_home), do: {:error, :invalid_acp_launch_env}

  defp arbor_home_key?(key),
    do: key == "ARBOR_HOME" or key == :ARBOR_HOME or key == ~c"ARBOR_HOME"

  defp inject_provider_home(client_opts, runtime_home, :grok) do
    if Keyword.has_key?(client_opts, :adapter) or Keyword.has_key?(client_opts, :adapter_opts) do
      {:error, :grok_runtime_native_transport_required}
    else
      grok_home = Path.join(runtime_home, @grok_home_directory)

      with {:ok, created?} <- ensure_private_grok_home(grok_home),
           :ok <- maybe_stage_grok_auth(grok_home, created?),
           {:ok, env} <- put_grok_isolation_env(Keyword.get(client_opts, :env), grok_home) do
        {:ok, Keyword.put(client_opts, :env, env)}
      end
    end
  end

  defp inject_provider_home(client_opts, _runtime_home, _provider), do: {:ok, client_opts}

  defp ensure_private_grok_home(grok_home) do
    case File.lstat(grok_home) do
      {:error, :enoent} ->
        with :ok <- File.mkdir(grok_home),
             :ok <- File.chmod(grok_home, 0o700),
             :ok <- verify_private_directory(grok_home) do
          {:ok, true}
        else
          _other -> {:error, :grok_runtime_home_unavailable}
        end

      {:ok, %File.Stat{type: :directory}} ->
        case verify_private_directory(grok_home) do
          :ok -> {:ok, false}
          {:error, _reason} = error -> error
        end

      _other ->
        {:error, :grok_runtime_home_unavailable}
    end
  end

  defp verify_private_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory, mode: mode}}
      when Bitwise.band(mode, 0o777) == 0o700 ->
        :ok

      _other ->
        {:error, :grok_runtime_home_unavailable}
    end
  end

  defp maybe_stage_grok_auth(_grok_home, false), do: :ok

  defp maybe_stage_grok_auth(grok_home, true) do
    with {:ok, source_home} <- source_grok_home() do
      source = Path.join(source_home, @grok_auth_filename)

      case File.lstat(source) do
        {:error, :enoent} ->
          :ok

        {:ok, %File.Stat{type: :regular}} ->
          with {:ok, auth} <- Arbor.LLM.read_bounded_regular_file(source, @max_grok_auth_bytes),
               :ok <- write_private_file(Path.join(grok_home, @grok_auth_filename), auth) do
            :ok
          else
            _other -> {:error, :unsafe_grok_auth_source}
          end

        _other ->
          {:error, :unsafe_grok_auth_source}
      end
    end
  end

  defp source_grok_home do
    case System.get_env("GROK_HOME") do
      nil -> {:ok, Path.expand("~/.grok")}
      "" -> {:ok, Path.expand("~/.grok")}
      path when is_binary(path) -> validate_absolute_path(path)
    end
  end

  defp validate_absolute_path(path) do
    if String.valid?(path) and not String.contains?(path, [<<0>>, "\n", "\r"]) and
         Path.type(path) == :absolute do
      {:ok, Path.expand(path)}
    else
      {:error, :invalid_grok_auth_source_home}
    end
  end

  defp write_private_file(path, content) when is_binary(content) do
    case :file.open(path, [:raw, :binary, :write, :exclusive]) do
      {:ok, io} ->
        result =
          with :ok <- :file.change_mode(path, 0o600),
               :ok <- :file.write(io, content),
               :ok <- :file.sync(io) do
            :ok
          end

        _ = :file.close(io)

        with :ok <- result,
             {:ok, %File.Stat{type: :regular, mode: mode, size: size}} <- File.lstat(path),
             true <- Bitwise.band(mode, 0o777) == 0o600,
             true <- size == byte_size(content) do
          :ok
        else
          _other -> {:error, :grok_auth_stage_failed}
        end

      {:error, _reason} ->
        {:error, :grok_auth_stage_failed}
    end
  end

  defp put_grok_isolation_env(env, grok_home) do
    values = [
      {"GROK_HOME", grok_home},
      {"GROK_LOG_FILE", Path.join(grok_home, @grok_log_filename)}
      | @grok_isolation_env
    ]

    put_env_values(env, values)
  end

  defp put_env_values(nil, values), do: {:ok, values}

  defp put_env_values(env, values) when is_map(env) do
    put_env_values(Map.to_list(env), values)
  end

  defp put_env_values(env, values) when is_list(env) do
    if Enum.all?(env, &(is_tuple(&1) and tuple_size(&1) == 2)) do
      keys = MapSet.new(values, fn {key, _value} -> key end)
      env = Enum.reject(env, fn {key, _value} -> env_key_member?(keys, key) end)
      {:ok, env ++ values}
    else
      {:error, :invalid_acp_launch_env}
    end
  end

  defp put_env_values(_env, _values), do: {:error, :invalid_acp_launch_env}

  defp env_key_member?(keys, key) when is_binary(key), do: MapSet.member?(keys, key)
  defp env_key_member?(keys, key) when is_atom(key), do: MapSet.member?(keys, Atom.to_string(key))

  defp env_key_member?(keys, key) when is_list(key) do
    try do
      MapSet.member?(keys, List.to_string(key))
    rescue
      _error -> false
    catch
      _kind, _reason -> false
    end
  end

  defp env_key_member?(_keys, _key), do: false
end
