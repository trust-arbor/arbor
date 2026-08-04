defmodule Arbor.AI.AcpSession.RuntimeHome do
  @moduledoc false

  import Bitwise

  alias Arbor.Common.SafePath

  @create_attempts 4
  @grok_auth_filename "auth.json"
  @grok_auth_lock_filename "auth.json.lock"
  @grok_auth_payload_filename "arbor-xai-access.json"
  @grok_home_directory "grok"
  @grok_log_filename "grok.log"
  @grok_agent_profile_filename "arbor-agent-profile.md"
  @grok_agent_profile_content """
  ---
  name: arbor-no-shell
  description: Arbor ACP coding profile with native file tools and no process execution.
  prompt_mode: full
  permission_mode: default
  agents_md: true
  tools:
    - read_file
    - search_replace
    - grep
    - list_dir
  disallowedTools:
    - run_terminal_cmd
    - task
    - get_task_output
    - kill_task
  ---

  Use native file tools for reading and editing.
  Process execution and subagents are unavailable by design.
  """
  @max_grok_auth_payload_bytes 65_600
  @max_grok_access_token_bytes 65_536
  @max_grok_auth_ttl_seconds 300
  @grok_external_auth_scope_prefix "https://auth.x.ai::"
  @grok_external_auth_cache_fields [
    "auth_mode",
    "coding_data_retention_opt_out",
    "create_time",
    "email",
    "expires_at",
    "first_name",
    "key",
    "principal_id",
    "principal_type",
    "profile_image_asset_id",
    "user_id"
  ]
  @grok_auth_method_id "grok.com"
  @grok_auth_provider_command ~s(/bin/cat "$ARBOR_GROK_AUTH_PAYLOAD_PATH")
  @grok_auth_provider_label "Arbor"
  @grok_auth_token_ttl "300"
  @grok_auth_early_invalidation_seconds "60"
  @grok_empty_auth_selectors [
    "XAI_API_KEY",
    "GROK_CODE_XAI_API_KEY",
    "GROK_AUTH",
    "GROK_AUTH_PATH",
    "GROK_AUTH_PROVIDER_ACCESS_TOKEN",
    "GROK_AUTH_PROVIDER_REFRESH_TOKEN",
    "GROK_AUTH_PROVIDER_EXPIRES_AT"
  ]
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

  @doc false
  @spec grok_agent_profile_path(String.t()) :: String.t()
  def grok_agent_profile_path(grok_home) when is_binary(grok_home),
    do: Path.join(grok_home, @grok_agent_profile_filename)

  @doc false
  @spec grok_auth_payload_path(String.t()) :: String.t()
  def grok_auth_payload_path(grok_home) when is_binary(grok_home),
    do: Path.join(grok_home, @grok_auth_payload_filename)

  @doc false
  @spec grok_external_auth_method() :: %{required(String.t()) => String.t()}
  def grok_external_auth_method do
    %{"id" => @grok_auth_method_id, "name" => @grok_auth_provider_label}
  end

  @doc false
  @spec stage_grok_external_auth(map()) :: :ok | {:error, atom()}
  def stage_grok_external_auth(%{path: runtime_home})
      when is_binary(runtime_home) and runtime_home != "" do
    update_grok_external_auth(runtime_home, :initial)
  end

  def stage_grok_external_auth(_cleanup_identity),
    do: {:error, :grok_external_auth_unavailable}

  @doc false
  @spec refresh_grok_external_auth(map()) :: :ok | {:error, atom()}
  def refresh_grok_external_auth(%{path: runtime_home})
      when is_binary(runtime_home) and runtime_home != "" do
    update_grok_external_auth(runtime_home, :existing)
  end

  def refresh_grok_external_auth(_cleanup_identity),
    do: {:error, :grok_external_auth_unavailable}

  @doc false
  @spec scrub_grok_external_auth_cache(map()) :: :ok | {:error, atom()}
  def scrub_grok_external_auth_cache(%{path: runtime_home})
      when is_binary(runtime_home) and runtime_home != "" do
    grok_home = Path.join(runtime_home, @grok_home_directory)
    payload_path = grok_auth_payload_path(grok_home)
    auth_path = Path.join(grok_home, @grok_auth_filename)
    lock_path = Path.join(grok_home, @grok_auth_lock_filename)

    with :ok <- verify_private_directory(grok_home),
         {:ok, %{"access_token" => access_token}} <-
           read_verified_grok_auth_payload(payload_path, grok_home),
         :ok <- verify_and_remove_grok_external_auth_cache(auth_path, grok_home, access_token),
         :ok <- verify_and_remove_grok_external_auth_lock(lock_path, grok_home),
         :ok <- refuse_legacy_grok_auth(grok_home) do
      :ok
    else
      _other -> {:error, :grok_external_auth_unavailable}
    end
  rescue
    _exception -> {:error, :grok_external_auth_unavailable}
  catch
    _kind, _reason -> {:error, :grok_external_auth_unavailable}
  end

  def scrub_grok_external_auth_cache(_cleanup_identity),
    do: {:error, :grok_external_auth_unavailable}

  defp update_grok_external_auth(runtime_home, presence) do
    grok_home = Path.join(runtime_home, @grok_home_directory)
    payload_path = grok_auth_payload_path(grok_home)

    with :ok <- verify_private_directory(grok_home),
         :ok <- refuse_legacy_grok_auth(grok_home),
         :ok <- verify_grok_auth_payload_presence(payload_path, grok_home, presence),
         {:ok, payload} <- Arbor.LLM.oauth_external_auth_payload(:xai_oauth),
         :ok <- publish_grok_auth_payload(payload_path, payload),
         :ok <- verify_grok_auth_payload(payload_path, grok_home) do
      :ok
    else
      _other -> {:error, :grok_external_auth_unavailable}
    end
  rescue
    _exception -> {:error, :grok_external_auth_unavailable}
  catch
    _kind, _reason -> {:error, :grok_external_auth_unavailable}
  end

  @doc false
  @spec prepare_grok_external_auth(term(), String.t()) :: {:ok, list()} | {:error, atom()}
  def prepare_grok_external_auth(env, grok_home) when is_binary(grok_home) do
    payload_path = grok_auth_payload_path(grok_home)

    with :ok <- refuse_legacy_grok_auth(grok_home),
         {:ok, payload_path} <- contained_payload_path(payload_path, grok_home) do
      values =
        [
          {"GROK_AUTH_PROVIDER_COMMAND", @grok_auth_provider_command},
          {"ARBOR_GROK_AUTH_PAYLOAD_PATH", payload_path},
          {"GROK_AUTH_PROVIDER_LABEL", @grok_auth_provider_label},
          {"GROK_AUTH_TOKEN_TTL", @grok_auth_token_ttl},
          {"GROK_AUTH_EARLY_INVALIDATION_SECS", @grok_auth_early_invalidation_seconds}
        ] ++ Enum.map(@grok_empty_auth_selectors, &{&1, ""})

      put_env_values(env, values)
    else
      _other -> {:error, :grok_external_auth_unavailable}
    end
  end

  def prepare_grok_external_auth(_env, _grok_home),
    do: {:error, :grok_external_auth_unavailable}

  @doc false
  @spec verify_grok_external_auth(String.t(), term()) :: :ok | {:error, atom()}
  def verify_grok_external_auth(grok_home, env) when is_binary(grok_home) and is_list(env) do
    payload_path = grok_auth_payload_path(grok_home)

    with {:ok, ^payload_path} <- contained_payload_path(payload_path, grok_home),
         :ok <- verify_exact_external_auth_env(env, payload_path),
         :ok <- refuse_legacy_grok_auth(grok_home),
         :ok <- verify_grok_auth_payload(payload_path, grok_home) do
      :ok
    else
      _other -> {:error, :grok_external_auth_attestation_failed}
    end
  end

  def verify_grok_external_auth(_grok_home, _env),
    do: {:error, :grok_external_auth_attestation_failed}

  @doc false
  @spec verify_grok_agent_profile(String.t()) :: :ok | {:error, atom()}
  def verify_grok_agent_profile(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode, size: size}}
      when (mode &&& 0o7777) == 0o600 and size == byte_size(@grok_agent_profile_content) ->
        case Arbor.LLM.read_bounded_regular_file(path, byte_size(@grok_agent_profile_content)) do
          {:ok, @grok_agent_profile_content} -> :ok
          {:ok, _other} -> {:error, :grok_agent_profile_tampered}
          {:error, _reason} -> {:error, :grok_agent_profile_unavailable}
        end

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :grok_agent_profile_insecure}

      {:ok, _other} ->
        {:error, :grok_agent_profile_nonregular}

      {:error, :enoent} ->
        {:error, :grok_agent_profile_missing}

      {:error, _reason} ->
        {:error, :grok_agent_profile_unavailable}
    end
  end

  def verify_grok_agent_profile(_path), do: {:error, :grok_agent_profile_unavailable}

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
           :ok <- stage_grok_agent_profile(grok_home, created?),
           {:ok, profile_path} <- bind_grok_agent_profile(client_opts, grok_home),
           {:ok, env} <- put_grok_isolation_env(Keyword.get(client_opts, :env), grok_home),
           {:ok, env} <- prepare_grok_external_auth(env, grok_home) do
        {:ok,
         client_opts
         |> Keyword.put(:command, profile_command(client_opts, profile_path))
         |> Keyword.put(:env, env)}
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
      when Bitwise.band(mode, 0o7777) == 0o700 ->
        :ok

      _other ->
        {:error, :grok_runtime_home_unavailable}
    end
  end

  defp stage_grok_agent_profile(grok_home, true) do
    path = grok_agent_profile_path(grok_home)

    case write_private_file(path, @grok_agent_profile_content, :grok_agent_profile_stage_failed) do
      :ok -> verify_grok_agent_profile(path)
      {:error, :already_exists} -> verify_grok_agent_profile(path)
      {:error, _reason} -> {:error, :grok_agent_profile_stage_failed}
    end
  end

  defp stage_grok_agent_profile(grok_home, false) do
    grok_home
    |> grok_agent_profile_path()
    |> verify_grok_agent_profile()
  end

  defp bind_grok_agent_profile(client_opts, grok_home) do
    profile_path = grok_agent_profile_path(grok_home)

    case Keyword.get(client_opts, :command) do
      command when is_list(command) ->
        case List.to_tuple(command) do
          {"grok", "--sandbox", "strict", "--no-memory", "--no-subagents", "--disable-web-search",
           "--deny", "MCPTool(*)", "--deny", "Bash(*)", "agent", "--no-leader", "--model",
           "grok-4.5", "stdio"} ->
            {:ok, profile_path}

          _other ->
            {:error, :grok_agent_command_mismatch}
        end

      _other ->
        {:error, :grok_agent_command_mismatch}
    end
  end

  defp profile_command(client_opts, profile_path) do
    command = Keyword.fetch!(client_opts, :command)
    agent_index = Enum.find_index(command, &(&1 == "agent"))

    List.insert_at(command, agent_index + 1, "--agent-profile")
    |> List.insert_at(agent_index + 2, profile_path)
  end

  defp write_private_file(path, content, failure_reason) when is_binary(content) do
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
             true <- Bitwise.band(mode, 0o7777) == 0o600,
             true <- size == byte_size(content) do
          :ok
        else
          _other -> {:error, failure_reason}
        end

      {:error, :eexist} ->
        {:error, :already_exists}

      {:error, _reason} ->
        {:error, failure_reason}
    end
  end

  defp refuse_legacy_grok_auth(grok_home) do
    [@grok_auth_filename, @grok_auth_lock_filename]
    |> Enum.reduce_while(:ok, fn filename, :ok ->
      case File.lstat(Path.join(grok_home, filename)) do
        {:error, :enoent} -> {:cont, :ok}
        _other -> {:halt, {:error, :grok_legacy_auth_forbidden}}
      end
    end)
  end

  defp contained_payload_path(payload_path, grok_home) do
    contained_grok_file_path(payload_path, grok_home, @grok_auth_payload_filename)
  end

  defp contained_grok_file_path(path, grok_home, expected_filename) do
    expanded_home = Path.expand(grok_home)
    expanded_path = Path.expand(path)

    with true <- Path.dirname(expanded_path) == expanded_home,
         true <- Path.basename(expanded_path) == expected_filename,
         {:ok, ^expanded_path} <- SafePath.resolve_within(expanded_path, expanded_home) do
      {:ok, expanded_path}
    else
      _other -> {:error, :grok_auth_payload_path_mismatch}
    end
  end

  defp verify_grok_auth_payload_presence(payload_path, _grok_home, :initial) do
    case File.lstat(payload_path) do
      {:error, :enoent} -> :ok
      _other -> {:error, :grok_auth_payload_already_present}
    end
  end

  defp verify_grok_auth_payload_presence(payload_path, grok_home, :existing) do
    case File.lstat(payload_path) do
      {:ok, _stat} -> verify_grok_auth_payload(payload_path, grok_home)
      _other -> {:error, :grok_auth_payload_unavailable}
    end
  end

  defp verify_grok_auth_payload(payload_path, grok_home) do
    case read_verified_grok_auth_payload(payload_path, grok_home) do
      {:ok, _payload} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp read_verified_grok_auth_payload(payload_path, grok_home) do
    with {:ok, ^payload_path} <- contained_payload_path(payload_path, grok_home),
         {:ok, %File.Stat{type: :regular, links: 1, mode: mode, size: size} = before} <-
           File.lstat(payload_path),
         true <- (mode &&& 0o7777) == 0o600,
         true <- size > 0 and size <= @max_grok_auth_payload_bytes,
         {:ok, payload} <-
           Arbor.LLM.read_bounded_regular_file(payload_path, @max_grok_auth_payload_bytes),
         true <- byte_size(payload) == size,
         {:ok, %File.Stat{type: :regular, links: 1} = after_stat} <- File.lstat(payload_path),
         true <- grok_file_identity(before) == grok_file_identity(after_stat),
         {:ok, decoded} <-
           Arbor.LLM.decode_bounded_json(payload,
             max_bytes: @max_grok_auth_payload_bytes,
             max_nodes: 8,
             max_depth: 2,
             max_map_keys: 2,
             max_list_items: 1
           ),
         :ok <- validate_grok_auth_payload(decoded) do
      {:ok, decoded}
    else
      _other -> {:error, :grok_auth_payload_invalid}
    end
  end

  defp verify_and_remove_grok_external_auth_cache(auth_path, grok_home, access_token) do
    case File.lstat(auth_path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, links: 1, mode: mode, size: size} = before}
      when (mode &&& 0o7777) == 0o600 and size > 0 and
             size <= @max_grok_auth_payload_bytes ->
        with {:ok, ^auth_path} <-
               contained_grok_file_path(auth_path, grok_home, @grok_auth_filename),
             {:ok, payload} <-
               Arbor.LLM.read_bounded_regular_file(
                 auth_path,
                 @max_grok_auth_payload_bytes
               ),
             true <- byte_size(payload) == size,
             {:ok, decoded} <-
               Arbor.LLM.decode_bounded_json(payload,
                 max_bytes: @max_grok_auth_payload_bytes,
                 max_nodes: 32,
                 max_depth: 3,
                 max_map_keys: 16,
                 max_list_items: 1
               ),
             :ok <- validate_grok_external_auth_cache(decoded, access_token),
             {:ok, %File.Stat{type: :regular, links: 1} = after_stat} <-
               File.lstat(auth_path),
             true <- grok_file_identity(before) == grok_file_identity(after_stat),
             :ok <- File.rm(auth_path),
             {:error, :enoent} <- File.lstat(auth_path) do
          :ok
        else
          _other -> {:error, :grok_external_auth_cache_invalid}
        end

      _other ->
        {:error, :grok_external_auth_cache_invalid}
    end
  end

  defp validate_grok_external_auth_cache(cache, access_token)
       when is_map(cache) and map_size(cache) == 1 and is_binary(access_token) do
    with [{scope, record}] <- Map.to_list(cache),
         true <- is_binary(scope) and byte_size(scope) <= 1_024,
         true <- String.starts_with?(scope, @grok_external_auth_scope_prefix),
         true <- is_map(record),
         true <- map_size(record) <= length(@grok_external_auth_cache_fields),
         true <- Enum.all?(Map.keys(record), &(&1 in @grok_external_auth_cache_fields)),
         "external" <- Map.get(record, "auth_mode"),
         ^access_token <- Map.get(record, "key"),
         true <- Enum.all?(Map.values(record), &grok_external_auth_scalar?/1) do
      :ok
    else
      _other -> {:error, :grok_external_auth_cache_invalid}
    end
  end

  defp validate_grok_external_auth_cache(_cache, _access_token),
    do: {:error, :grok_external_auth_cache_invalid}

  defp grok_external_auth_scalar?(value),
    do: is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value)

  defp verify_and_remove_grok_external_auth_lock(lock_path, grok_home) do
    case File.lstat(lock_path) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{type: :regular, links: 1, mode: mode, size: 0}}
      when (mode &&& 0o022) == 0 ->
        with {:ok, ^lock_path} <-
               contained_grok_file_path(lock_path, grok_home, @grok_auth_lock_filename),
             :ok <- File.rm(lock_path),
             {:error, :enoent} <- File.lstat(lock_path) do
          :ok
        else
          _other -> {:error, :grok_external_auth_cache_invalid}
        end

      _other ->
        {:error, :grok_external_auth_cache_invalid}
    end
  end

  defp validate_grok_auth_payload(
         %{
           "access_token" => access_token,
           "expires_in" => expires_in
         } = payload
       )
       when map_size(payload) == 2 and is_binary(access_token) and
              byte_size(access_token) > 0 and
              byte_size(access_token) <= @max_grok_access_token_bytes and
              is_integer(expires_in) and expires_in > 0 and
              expires_in <= @max_grok_auth_ttl_seconds do
    if String.valid?(access_token) and
         not String.match?(access_token, ~r/[\x00-\x1F\x7F]/) do
      :ok
    else
      {:error, :grok_auth_payload_invalid}
    end
  end

  defp validate_grok_auth_payload(_payload), do: {:error, :grok_auth_payload_invalid}

  defp grok_file_identity(stat) do
    {
      stat.type,
      stat.mode &&& 0o7777,
      stat.size,
      stat.mtime,
      stat.ctime,
      stat.major_device,
      stat.minor_device,
      stat.inode,
      stat.links
    }
  end

  defp publish_grok_auth_payload(payload_path, payload)
       when is_binary(payload) and byte_size(payload) > 0 and
              byte_size(payload) <= @max_grok_auth_payload_bytes do
    temp_path =
      Path.join(
        Path.dirname(payload_path),
        ".#{@grok_auth_payload_filename}." <>
          Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> ".tmp"
      )

    result =
      case :file.open(temp_path, [:raw, :binary, :write, :exclusive]) do
        {:ok, io} ->
          try do
            with :ok <- :file.change_mode(temp_path, 0o600),
                 :ok <- :file.write(io, payload),
                 :ok <- :file.sync(io),
                 :ok <- :file.close(io),
                 :ok <- verify_grok_auth_payload_temp(temp_path, payload),
                 :ok <- File.rename(temp_path, payload_path) do
              :ok
            else
              _other -> {:error, :grok_auth_payload_publish_failed}
            end
          rescue
            _exception -> {:error, :grok_auth_payload_publish_failed}
          catch
            _kind, _reason -> {:error, :grok_auth_payload_publish_failed}
          after
            _ = close_file_silent(io)
          end

        {:error, _reason} ->
          {:error, :grok_auth_payload_publish_failed}
      end

    _ = File.rm(temp_path)
    result
  end

  defp publish_grok_auth_payload(_payload_path, _payload),
    do: {:error, :grok_auth_payload_publish_failed}

  defp verify_grok_auth_payload_temp(path, expected_payload) do
    with {:ok, %File.Stat{type: :regular, links: 1, mode: mode, size: size} = before} <-
           File.lstat(path),
         true <- (mode &&& 0o7777) == 0o600,
         true <- size == byte_size(expected_payload),
         {:ok, ^expected_payload} <-
           Arbor.LLM.read_bounded_regular_file(path, @max_grok_auth_payload_bytes),
         {:ok, %File.Stat{type: :regular, links: 1} = after_stat} <- File.lstat(path),
         true <- grok_file_identity(before) == grok_file_identity(after_stat) do
      :ok
    else
      _other -> {:error, :grok_auth_payload_publish_failed}
    end
  end

  defp close_file_silent(io) do
    try do
      :file.close(io)
    catch
      _kind, _reason -> :ok
    end
  end

  defp verify_exact_external_auth_env(env, payload_path) do
    expected =
      %{
        "GROK_AUTH_PROVIDER_COMMAND" => @grok_auth_provider_command,
        "ARBOR_GROK_AUTH_PAYLOAD_PATH" => payload_path,
        "GROK_AUTH_PROVIDER_LABEL" => @grok_auth_provider_label,
        "GROK_AUTH_TOKEN_TTL" => @grok_auth_token_ttl,
        "GROK_AUTH_EARLY_INVALIDATION_SECS" => @grok_auth_early_invalidation_seconds
      }
      |> Map.merge(Map.new(@grok_empty_auth_selectors, &{&1, ""}))

    normalized =
      Enum.reduce_while(env, {:ok, []}, fn
        {key, value}, {:ok, acc} ->
          case normalize_env_key(key) do
            {:ok, normalized_key} -> {:cont, {:ok, [{normalized_key, value} | acc]}}
            :error -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end)

    case normalized do
      {:ok, pairs} ->
        if Enum.all?(expected, fn {key, value} ->
             Enum.filter(pairs, &match?({^key, ^value}, &1)) == [{key, value}] and
               Enum.count(pairs, &match?({^key, _}, &1)) == 1
           end),
           do: :ok,
           else: {:error, :grok_external_auth_env_mismatch}

      :error ->
        {:error, :grok_external_auth_env_mismatch}
    end
  end

  defp normalize_env_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_env_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}

  defp normalize_env_key(key) when is_list(key) do
    try do
      {:ok, List.to_string(key)}
    rescue
      _exception -> :error
    catch
      _kind, _reason -> :error
    end
  end

  defp normalize_env_key(_key), do: :error

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
