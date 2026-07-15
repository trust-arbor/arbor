defmodule Arbor.Shell.AppleContainerProbeCore do
  @moduledoc """
  Pure Apple Container 1.1.x raw-output projection core.

  Accepts bounded raw command/file bytes already collected by an imperative
  prober and returns normalized JSON-clean evidence fragments for
  `AppleContainerAdmissionCore` / control-plane admission. Performs no IO,
  process execution, filesystem access, environment reads, Application config
  reads, GenServer calls, ETS, time, randomness, or logging.

  Raw outputs are evidence only — never executable authority. The imperative
  prober combines these projections with identity/signing/baseline authority
  for admission behind `Arbor.Shell.execute_spawn_capable/3`.
  """

  # --- Closed request surface ---

  @logical_request_keys [
    :system_architecture,
    :sw_vers_output,
    :uid_output,
    :launchctl_output,
    :system_version_json,
    :system_status_json,
    :workload_image_inspect_json,
    :vminit_image_inspect_json,
    :runtime_plugin_config_toml
  ]
  @allowed_request_keys MapSet.new(
                          @logical_request_keys ++
                            Enum.map(@logical_request_keys, &Atom.to_string/1)
                        )

  @launchd_label "com.apple.container.apiserver"
  @cli_app_name "container"
  @apiserver_app_name "container-apiserver"
  @required_build "release"
  @required_status "running"
  @required_launchd_type "LaunchAgent"
  @required_launchd_state "running"
  @plugin_abstract "Linux container runtime plugin"
  @plugin_author "Apple"
  @plugin_version "0.1"

  # --- Bounds (normal 1.1.0 output fits; hard caps block memory abuse) ---

  @max_map_keys 64
  @max_arch_bytes 128
  @max_sw_vers_bytes 64
  @max_uid_bytes 32
  @max_launchctl_bytes 65_536
  @max_launchctl_lines 512
  @max_system_json_bytes 8_192
  @max_image_json_bytes 262_144
  @max_toml_bytes 8_192
  @max_path_bytes 4_096
  @max_version_bytes 256
  @max_status_bytes 64
  @max_string_bytes 4_096
  @max_env_entries 64
  @max_env_key_bytes 256
  @max_env_value_bytes 4_096
  @max_argv_entries 16
  @max_argv_entry_bytes 4_096
  @max_variants 16
  @max_env_list_entries 64
  @max_label_keys 32
  @max_label_key_bytes 256
  @max_label_value_bytes 1_024
  @max_name_bytes 512
  @max_media_type_bytes 256
  @max_digest_bytes 80
  @max_oci_variant_bytes 32
  @max_descriptor_size 1_073_741_824
  @max_json_list 64

  @uid_re ~r/\A[0-9]{1,10}\z/
  @product_version_re ~r/\A\d+(?:\.\d+){0,3}\z/
  @arch_re ~r/\A(?:aarch64|arm64)-apple-darwin(?:[\w.-]*)\z/
  @apiserver_version_re ~r/\Acontainer-apiserver version (\d+\.\d+\.\d+) \(build: release, commit: ([0-9a-zA-Z._-]{1,64})\)\z/
  @semver_re ~r/\A\d+\.\d+\.\d+\z/
  @digest_re ~r/\Asha256:[0-9a-f]{64}\z/
  @launchd_header_re ~r/\Agui\/([0-9]{1,10})\/com\.apple\.container\.apiserver = \{\z/
  @scalar_field_re ~r/\A\t(path|type|state|program) = (.*)\z/
  @block_open_re ~r/\A\t(arguments|inherited environment|default environment|environment) = \{\z/
  @ignored_block_open_re ~r/\A\t.+= \{\z/
  @env_entry_re ~r/\A\t\t([^=\t][^=]*?) => (.*)\z/
  @argv_entry_re ~r/\A\t\t(.*)\z/
  @block_close_re ~r/\A\t\}\z/
  @root_close_re ~r/\A\}\z/

  @type projection :: %{
          host_platform: map(),
          runtime: map(),
          service_status: map(),
          control_plane: map(),
          image_inspect: map(),
          vminit_image_inspect: map()
        }

  @doc """
  Project bounded raw probe outputs into normalized admission evidence fragments.

  Returns `{:ok, projection}` or `{:error, reason}`. Never raises on malformed input.
  """
  @spec project(term()) :: {:ok, projection()} | {:error, term()}
  def project(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(input, @allowed_request_keys, @logical_request_keys, :request),
         {:ok, arch} <-
           require_bounded_utf8_field(
             input,
             :system_architecture,
             @max_arch_bytes,
             :missing_system_architecture,
             :invalid_system_architecture,
             :system_architecture_too_long
           ),
         {:ok, architecture} <- parse_system_architecture(arch),
         {:ok, sw_vers} <-
           require_bounded_utf8_field(
             input,
             :sw_vers_output,
             @max_sw_vers_bytes,
             :missing_sw_vers_output,
             :invalid_sw_vers_output,
             :sw_vers_output_too_long
           ),
         {:ok, os_version} <- parse_sw_vers(sw_vers),
         {:ok, uid_raw} <-
           require_bounded_utf8_field(
             input,
             :uid_output,
             @max_uid_bytes,
             :missing_uid_output,
             :invalid_uid_output,
             :uid_output_too_long
           ),
         {:ok, uid} <- parse_uid(uid_raw),
         {:ok, launchctl} <-
           require_bounded_utf8_field(
             input,
             :launchctl_output,
             @max_launchctl_bytes,
             :missing_launchctl_output,
             :invalid_launchctl_output,
             :launchctl_output_too_long
           ),
         {:ok, launchd} <- parse_launchctl(launchctl, uid),
         {:ok, version_json} <-
           require_bounded_binary_field(
             input,
             :system_version_json,
             @max_system_json_bytes,
             :missing_system_version_json,
             :invalid_system_version_json,
             :system_version_json_too_long
           ),
         {:ok, versions} <- parse_system_version_json(version_json),
         {:ok, status_json} <-
           require_bounded_binary_field(
             input,
             :system_status_json,
             @max_system_json_bytes,
             :missing_system_status_json,
             :invalid_system_status_json,
             :system_status_json_too_long
           ),
         {:ok, status} <- parse_system_status_json(status_json),
         :ok <- validate_version_status_consistency(versions, status),
         {:ok, workload_json} <-
           require_bounded_binary_field(
             input,
             :workload_image_inspect_json,
             @max_image_json_bytes,
             :missing_workload_image_inspect_json,
             :invalid_workload_image_inspect_json,
             :workload_image_inspect_json_too_long
           ),
         {:ok, image_inspect} <- parse_image_inspect_json(workload_json, :workload),
         {:ok, vminit_json} <-
           require_bounded_binary_field(
             input,
             :vminit_image_inspect_json,
             @max_image_json_bytes,
             :missing_vminit_image_inspect_json,
             :invalid_vminit_image_inspect_json,
             :vminit_image_inspect_json_too_long
           ),
         {:ok, vminit_image_inspect} <- parse_image_inspect_json(vminit_json, :vminit),
         {:ok, toml} <-
           require_bounded_binary_field(
             input,
             :runtime_plugin_config_toml,
             @max_toml_bytes,
             :missing_runtime_plugin_config_toml,
             :invalid_runtime_plugin_config_toml,
             :runtime_plugin_config_toml_too_long
           ),
         {:ok, plugin_config} <- parse_runtime_plugin_toml(toml) do
      {:ok,
       %{
         host_platform: %{
           os: "macos",
           version: os_version,
           architecture: architecture
         },
         runtime: %{
           cli_version: versions.cli_version,
           cli_build: versions.cli_build
         },
         service_status: %{
           status: status.status,
           install_root: status.install_root,
           apiserver_version: status.apiserver_version_full,
           apiserver_build: status.apiserver_build
         },
         control_plane: %{
           cli: %{
             version: versions.cli_version,
             build: versions.cli_build
           },
           apiserver: %{
             version: versions.api_semver,
             build: versions.api_build,
             launchd: launchd
           },
           service_status: %{
             status: status.status,
             install_root: status.install_root,
             apiserver_version: versions.api_semver,
             apiserver_build: status.apiserver_build,
             app_root: status.app_root,
             log_root: status.log_root
           },
           runtime_plugin: %{
             config: plugin_config
           }
         },
         image_inspect: image_inspect,
         vminit_image_inspect: vminit_image_inspect
       }}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def project(_input), do: {:error, :invalid_request}

  @doc """
  Convert a projection to a JSON-clean map (no raw outputs).
  """
  @spec show(projection()) :: map()
  def show(%{
        host_platform: host,
        runtime: runtime,
        service_status: service,
        control_plane: control_plane,
        image_inspect: image_inspect,
        vminit_image_inspect: vminit
      }) do
    %{
      "host_platform" => stringify_map(host),
      "runtime" => stringify_map(runtime),
      "service_status" => stringify_map(service),
      "control_plane" => show_control_plane(control_plane),
      "image_inspect" => show_image_inspect(image_inspect),
      "vminit_image_inspect" => show_image_inspect(vminit)
    }
  end

  # --- Host / architecture / uid ---

  defp parse_system_architecture(arch) do
    trimmed = String.trim(arch)

    cond do
      Regex.match?(@arch_re, trimmed) ->
        {:ok, "arm64"}

      true ->
        {:error, :unsupported_system_architecture}
    end
  end

  defp parse_sw_vers(raw) do
    lines =
      raw
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim_trailing(&1, "\r"))
      |> Enum.reject(&(&1 == ""))

    case lines do
      [version] ->
        with :ok <- require_valid_utf8(version),
             :ok <- reject_control_char(version, :unsafe_sw_vers) do
          if Regex.match?(@product_version_re, version) do
            {:ok, version}
          else
            {:error, :invalid_sw_vers_output}
          end
        end

      _other ->
        {:error, :invalid_sw_vers_output}
    end
  end

  defp parse_uid(raw) do
    trimmed = String.trim(raw)

    if Regex.match?(@uid_re, trimmed) do
      {:ok, trimmed}
    else
      {:error, :invalid_uid_output}
    end
  end

  # --- system version / status JSON ---

  defp parse_system_version_json(raw) do
    with :ok <- require_valid_utf8(raw),
         {:ok, decoded} <- decode_json(raw, :invalid_system_version_json),
         :ok <- require_list_length(decoded, 2, :invalid_system_version_json) do
      [cli_raw, api_raw] = decoded

      with {:ok, cli} <- normalize_version_component(cli_raw, :cli),
           {:ok, api} <- normalize_version_component(api_raw, :apiserver) do
        {:ok,
         %{
           cli_version: cli.version,
           cli_build: cli.build,
           cli_commit: cli.commit,
           api_version_full: api.version_full,
           api_semver: api.semver,
           api_build: api.build,
           api_commit: api.commit,
           api_commit_short: api.commit_short
         }}
      end
    end
  end

  defp normalize_version_component(map, role) when is_map(map) do
    with :ok <-
           validate_closed_string_keys(
             map,
             MapSet.new(["appName", "buildType", "commit", "version"]),
             version_scope(role)
           ),
         {:ok, app_name} <- fetch_json_string(map, "appName", @max_status_bytes),
         {:ok, build} <- fetch_json_string(map, "buildType", @max_status_bytes),
         {:ok, commit} <- fetch_json_string(map, "commit", @max_status_bytes),
         {:ok, version} <- fetch_json_string(map, "version", @max_version_bytes) do
      expected_app =
        case role do
          :cli -> @cli_app_name
          :apiserver -> @apiserver_app_name
        end

      cond do
        app_name != expected_app ->
          {:error, {:version_app_name_mismatch, role}}

        build != @required_build ->
          {:error, {:version_build_not_release, role}}

        role == :cli ->
          if Regex.match?(@semver_re, version) do
            {:ok, %{version: version, build: build, commit: commit}}
          else
            {:error, :invalid_cli_version}
          end

        role == :apiserver ->
          case Regex.run(@apiserver_version_re, version) do
            [^version, semver, commit_short] ->
              expected_short = commit_short_prefix(commit)

              if commit_short == expected_short do
                {:ok,
                 %{
                   version_full: version,
                   semver: semver,
                   build: build,
                   commit: commit,
                   commit_short: commit_short
                 }}
              else
                {:error, :apiserver_commit_prefix_mismatch}
              end

            _other ->
              {:error, :invalid_apiserver_version_line}
          end
      end
    end
  end

  defp normalize_version_component(_other, role), do: {:error, {:invalid_version_component, role}}

  defp version_scope(:cli), do: :system_version_cli
  defp version_scope(:apiserver), do: :system_version_apiserver

  defp commit_short_prefix(commit) when is_binary(commit) do
    binary_part(commit, 0, min(byte_size(commit), 7))
  end

  defp parse_system_status_json(raw) do
    with :ok <- require_valid_utf8(raw),
         {:ok, decoded} <- decode_json(raw, :invalid_system_status_json),
         :ok <- require_map(decoded, :invalid_system_status_json),
         :ok <- validate_status_keys(decoded),
         {:ok, status} <- fetch_json_string(decoded, "status", @max_status_bytes),
         {:ok, app_root_raw} <- fetch_json_string(decoded, "appRoot", @max_path_bytes),
         {:ok, install_root} <- fetch_json_string(decoded, "installRoot", @max_path_bytes),
         {:ok, log_root} <- fetch_optional_log_root(decoded),
         {:ok, api_version} <- fetch_json_string(decoded, "apiServerVersion", @max_version_bytes),
         {:ok, api_commit} <- fetch_json_string(decoded, "apiServerCommit", @max_status_bytes),
         {:ok, api_build} <- fetch_json_string(decoded, "apiServerBuild", @max_status_bytes),
         {:ok, api_app_name} <- fetch_json_string(decoded, "apiServerAppName", @max_status_bytes),
         {:ok, app_root} <- normalize_app_root(app_root_raw) do
      cond do
        status != @required_status ->
          {:error, :service_not_running}

        api_app_name != @apiserver_app_name ->
          {:error, :status_app_name_mismatch}

        api_build != @required_build ->
          {:error, :status_build_not_release}

        true ->
          {:ok,
           %{
             status: status,
             app_root: app_root,
             install_root: install_root,
             log_root: log_root,
             apiserver_version_full: api_version,
             apiserver_commit: api_commit,
             apiserver_build: api_build,
             apiserver_app_name: api_app_name
           }}
      end
    end
  end

  defp validate_status_keys(map) when is_map(map) do
    required =
      MapSet.new([
        "status",
        "appRoot",
        "installRoot",
        "apiServerVersion",
        "apiServerCommit",
        "apiServerBuild",
        "apiServerAppName"
      ])

    optional = MapSet.new(["logRoot"])
    allowed = MapSet.union(required, optional)

    keys = Map.keys(map)

    cond do
      map_size(map) > @max_map_keys ->
        {:error, :map_too_large}

      not Enum.all?(keys, &is_binary/1) ->
        {:error, :invalid_system_status_json}

      not Enum.all?(keys, &MapSet.member?(allowed, &1)) ->
        {:error, {:unsupported_keys, :system_status_json}}

      not Enum.all?(required, &Map.has_key?(map, &1)) ->
        {:error, :missing_system_status_field}

      true ->
        :ok
    end
  end

  defp fetch_optional_log_root(map) do
    case Map.fetch(map, "logRoot") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        with :ok <- bounded_string(value, @max_path_bytes, :log_root_too_long),
             :ok <- require_valid_utf8(value),
             :ok <- reject_control_char(value, :unsafe_log_root) do
          # Preserve empty string as nil only when omitted/null; empty string is kept.
          {:ok, value}
        end

      _other ->
        {:error, :invalid_log_root}
    end
  end

  # Apple reports appRoot with a trailing slash; authority bindings are canonical
  # absolute paths without one.
  defp normalize_app_root(path) when is_binary(path) do
    with :ok <- require_valid_utf8(path),
         :ok <- reject_control_char(path, :unsafe_app_root),
         :ok <- bounded_string(path, @max_path_bytes, :app_root_too_long) do
      cond do
        path == "" ->
          {:error, :invalid_app_root}

        path == "/" ->
          {:error, :invalid_app_root}

        not String.starts_with?(path, "/") ->
          {:error, :invalid_app_root}

        true ->
          stripped = String.trim_trailing(path, "/")

          if stripped == "" do
            {:error, :invalid_app_root}
          else
            {:ok, stripped}
          end
      end
    end
  end

  defp validate_version_status_consistency(versions, status) do
    cond do
      status.apiserver_version_full != versions.api_version_full ->
        {:error, :version_status_apiserver_version_mismatch}

      status.apiserver_commit != versions.api_commit ->
        {:error, :version_status_commit_mismatch}

      status.apiserver_build != versions.api_build ->
        {:error, :version_status_build_mismatch}

      true ->
        :ok
    end
  end

  # --- launchctl ---

  defp parse_launchctl(raw, uid) do
    with :ok <- require_valid_utf8(raw),
         {:ok, lines} <- split_launchctl_lines(raw),
         {:ok, body} <- validate_launchctl_frame(lines, uid),
         {:ok, fields} <- extract_launchd_fields(body) do
      {:ok,
       %{
         label: @launchd_label,
         path: fields.path,
         type: fields.type,
         state: fields.state,
         program: fields.program,
         argv: fields.argv,
         environment: fields.environment,
         inherited_environment: fields.inherited_environment,
         default_environment: fields.default_environment
       }}
    end
  end

  defp split_launchctl_lines(raw) do
    lines =
      raw
      |> String.split("\n", trim: false)
      |> Enum.map(&String.trim_trailing(&1, "\r"))

    if length(lines) > @max_launchctl_lines do
      {:error, :launchctl_too_many_lines}
    else
      {:ok, lines}
    end
  end

  defp validate_launchctl_frame(lines, uid) do
    case lines do
      [] ->
        {:error, :invalid_launchctl_header}

      [header | rest] ->
        case Regex.run(@launchd_header_re, header) do
          [^header, ^uid] ->
            case drop_trailing_empty(rest) do
              [] ->
                {:error, :incomplete_launchctl_block}

              body_and_close ->
                {close, body} = List.pop_at(body_and_close, -1)

                if close == "}" do
                  {:ok, body}
                else
                  {:error, :incomplete_launchctl_block}
                end
            end

          [^header, _other_uid] ->
            {:error, :launchctl_uid_mismatch}

          _other ->
            {:error, :invalid_launchctl_header}
        end
    end
  end

  defp drop_trailing_empty(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp extract_launchd_fields(lines) do
    required = %{
      path: :missing,
      type: :missing,
      state: :missing,
      program: :missing,
      argv: :missing,
      environment: :missing,
      inherited_environment: :missing,
      default_environment: :missing
    }

    case walk_launchctl_body(lines, required) do
      {:ok, fields} ->
        finalize_launchd_fields(fields)

      error ->
        error
    end
  end

  defp walk_launchctl_body([], acc), do: {:ok, acc}

  defp walk_launchctl_body(["" | rest], acc), do: walk_launchctl_body(rest, acc)

  defp walk_launchctl_body([line | rest], acc) do
    cond do
      Regex.match?(@root_close_re, line) ->
        {:error, :unexpected_root_close}

      match = Regex.run(@scalar_field_re, line) ->
        [_, name, value] = match
        key = scalar_key(name)

        case Map.get(acc, key) do
          :missing ->
            with :ok <- bounded_string(value, @max_path_bytes, :launchd_field_too_long),
                 :ok <- require_valid_utf8(value),
                 :ok <- reject_control_char(value, :unsafe_launchd_field) do
              walk_launchctl_body(rest, Map.put(acc, key, value))
            end

          _present ->
            {:error, {:duplicate_launchd_field, key}}
        end

      match = Regex.run(@block_open_re, line) ->
        [_, name] = match
        key = block_key(name)

        case Map.get(acc, key) do
          :missing ->
            case take_block(rest, key) do
              {:ok, value, remaining} ->
                walk_launchctl_body(remaining, Map.put(acc, key, value))

              error ->
                error
            end

          _present ->
            {:error, {:duplicate_launchd_field, key}}
        end

      Regex.match?(@ignored_block_open_re, line) ->
        case skip_block(rest) do
          {:ok, remaining} -> walk_launchctl_body(remaining, acc)
          error -> error
        end

      String.starts_with?(line, "\t") ->
        # Unrelated scalar diagnostic lines at the service root.
        walk_launchctl_body(rest, acc)

      true ->
        {:error, :malformed_launchctl_line}
    end
  end

  defp scalar_key("path"), do: :path
  defp scalar_key("type"), do: :type
  defp scalar_key("state"), do: :state
  defp scalar_key("program"), do: :program

  defp block_key("arguments"), do: :argv
  defp block_key("inherited environment"), do: :inherited_environment
  defp block_key("default environment"), do: :default_environment
  defp block_key("environment"), do: :environment

  defp take_block(lines, :argv), do: take_argv_block(lines, [])
  defp take_block(lines, env_key), do: take_env_block(lines, env_key, %{})

  defp take_argv_block([], _acc), do: {:error, :incomplete_launchctl_block}

  defp take_argv_block([line | rest], acc) do
    cond do
      Regex.match?(@block_close_re, line) ->
        {:ok, Enum.reverse(acc), rest}

      match = Regex.run(@argv_entry_re, line) ->
        [_, entry] = match

        if length(acc) >= @max_argv_entries do
          {:error, :too_many_launchd_argv}
        else
          with :ok <- bounded_string(entry, @max_argv_entry_bytes, :launchd_argv_too_long),
               :ok <- require_valid_utf8(entry),
               :ok <- reject_control_char(entry, :unsafe_launchd_argv) do
            take_argv_block(rest, [entry | acc])
          end
        end

      true ->
        {:error, :malformed_launchctl_argv}
    end
  end

  defp take_env_block([], _key, _acc), do: {:error, :incomplete_launchctl_block}

  defp take_env_block([line | rest], key, acc) do
    cond do
      Regex.match?(@block_close_re, line) ->
        {:ok, acc, rest}

      match = Regex.run(@env_entry_re, line) ->
        [_, env_key, env_value] = match

        cond do
          map_size(acc) >= @max_env_entries ->
            {:error, :too_many_launchd_env}

          Map.has_key?(acc, env_key) ->
            {:error, {:duplicate_launchd_env_key, key, env_key}}

          true ->
            with :ok <- bounded_string(env_key, @max_env_key_bytes, :launchd_env_key_too_long),
                 :ok <-
                   bounded_string(env_value, @max_env_value_bytes, :launchd_env_value_too_long),
                 :ok <- require_valid_utf8(env_key),
                 :ok <- require_valid_utf8(env_value),
                 :ok <- reject_control_char(env_key, :unsafe_launchd_env_key),
                 :ok <- reject_control_char(env_value, :unsafe_launchd_env_value) do
              if env_key == "" do
                {:error, :empty_launchd_env_key}
              else
                take_env_block(rest, key, Map.put(acc, env_key, env_value))
              end
            end
        end

      true ->
        {:error, :malformed_launchctl_env}
    end
  end

  defp skip_block(lines), do: skip_block(lines, 1)

  defp skip_block([], _depth), do: {:error, :incomplete_launchctl_block}

  defp skip_block([line | rest], depth) do
    cond do
      String.contains?(line, " = {") and String.ends_with?(String.trim_trailing(line), "{") ->
        skip_block(rest, depth + 1)

      Regex.match?(~r/\A\t+\}\z/, line) or line == "\t}" ->
        if depth == 1 do
          {:ok, rest}
        else
          skip_block(rest, depth - 1)
        end

      true ->
        skip_block(rest, depth)
    end
  end

  defp finalize_launchd_fields(fields) do
    missing =
      Enum.find_value(fields, fn
        {key, :missing} -> key
        _ -> nil
      end)

    if missing do
      {:error, {:missing_launchd_field, missing}}
    else
      with :ok <- require_exact(fields.type, @required_launchd_type, :launchd_type_mismatch),
           :ok <- require_exact(fields.state, @required_launchd_state, :launchd_state_mismatch) do
        {:ok, fields}
      end
    end
  end

  # --- image inspect JSON ---

  defp parse_image_inspect_json(raw, role) do
    with :ok <- require_valid_utf8(raw),
         {:ok, decoded} <- decode_json(raw, image_error(role, :invalid_json)),
         :ok <- require_list_length(decoded, 1, image_error(role, :invalid_array)),
         [resource] <- decoded,
         :ok <- require_map(resource, image_error(role, :invalid_resource)),
         {:ok, projected} <- project_image_resource(resource, role) do
      {:ok, projected}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, image_error(role, :invalid_json)}
    end
  end

  defp image_error(:workload, :invalid_json), do: :invalid_workload_image_inspect_json
  defp image_error(:workload, :invalid_array), do: :invalid_workload_image_array
  defp image_error(:workload, :invalid_resource), do: :invalid_workload_image_resource
  defp image_error(:vminit, :invalid_json), do: :invalid_vminit_image_inspect_json
  defp image_error(:vminit, :invalid_array), do: :invalid_vminit_image_array
  defp image_error(:vminit, :invalid_resource), do: :invalid_vminit_image_resource

  defp project_image_resource(resource, role) when is_map(resource) do
    with :ok <- require_map_key_budget(resource),
         {:ok, configuration} <- fetch_json_map(resource, "configuration"),
         {:ok, descriptor_raw} <- fetch_json_map(configuration, "descriptor"),
         {:ok, descriptor} <- project_descriptor(descriptor_raw),
         {:ok, name} <- fetch_json_string(configuration, "name", @max_name_bytes),
         {:ok, variants_raw} <- fetch_json_list(resource, "variants"),
         {:ok, variants} <- project_variants(variants_raw, role) do
      {:ok,
       %{
         configuration: %{
           descriptor: descriptor,
           name: name
         },
         variants: variants
       }}
    end
  end

  defp project_descriptor(map) when is_map(map) do
    with :ok <- require_map_key_budget(map),
         {:ok, digest} <- fetch_json_string(map, "digest", @max_digest_bytes),
         {:ok, media_type} <- fetch_json_string(map, "mediaType", @max_media_type_bytes),
         {:ok, size} <- fetch_json_non_neg_int(map, "size") do
      cond do
        not Regex.match?(@digest_re, digest) ->
          {:error, :invalid_image_digest}

        size > @max_descriptor_size ->
          {:error, :image_descriptor_too_large}

        true ->
          {:ok, %{digest: digest, media_type: media_type, size: size}}
      end
    end
  end

  defp project_variants(variants, role) when is_list(variants) do
    case take_bounded(variants, @max_variants) do
      :too_many ->
        {:error, :too_many_image_variants}

      {:ok, []} ->
        {:error, :missing_image_variants}

      {:ok, bounded} ->
        Enum.reduce_while(bounded, {:ok, []}, fn variant, {:ok, acc} ->
          case project_variant(variant, role) do
            {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error -> error
        end
    end
  end

  defp project_variant(variant, _role) when is_map(variant) do
    with :ok <- require_map_key_budget(variant),
         {:ok, digest} <- fetch_json_string(variant, "digest", @max_digest_bytes),
         :ok <- require_digest(digest, :invalid_variant_digest),
         {:ok, platform_raw} <- fetch_json_map(variant, "platform"),
         {:ok, platform} <- project_platform_map(platform_raw),
         {:ok, config_raw} <- fetch_json_map(variant, "config"),
         {:ok, config} <- project_variant_config(config_raw) do
      {:ok, %{digest: digest, platform: platform, config: config}}
    end
  end

  defp project_variant(_other, _role), do: {:error, :invalid_image_variant}

  defp project_platform_map(map) when is_map(map) do
    with :ok <- require_map_key_budget(map),
         {:ok, os} <- fetch_json_string(map, "os", @max_status_bytes),
         {:ok, architecture} <- fetch_json_string(map, "architecture", @max_status_bytes),
         {:ok, variant} <- fetch_optional_json_string(map, "variant", @max_oci_variant_bytes) do
      base = %{os: os, architecture: architecture}

      if is_nil(variant) do
        {:ok, base}
      else
        {:ok, Map.put(base, :variant, variant)}
      end
    end
  end

  defp project_variant_config(map) when is_map(map) do
    with :ok <- require_map_key_budget(map),
         {:ok, os} <- fetch_json_string(map, "os", @max_status_bytes),
         {:ok, architecture} <- fetch_json_string(map, "architecture", @max_status_bytes),
         {:ok, variant} <- fetch_optional_json_string(map, "variant", @max_oci_variant_bytes),
         {:ok, nested} <- project_optional_image_config(map) do
      base = %{os: os, architecture: architecture}

      base =
        if is_nil(variant) do
          base
        else
          Map.put(base, :variant, variant)
        end

      if map_size(nested) == 0 do
        {:ok, base}
      else
        {:ok, Map.put(base, :config, nested)}
      end
    end
  end

  defp project_optional_image_config(map) when is_map(map) do
    case Map.fetch(map, "config") do
      :error ->
        {:ok, %{}}

      {:ok, nested} when is_map(nested) ->
        with :ok <- require_map_key_budget(nested),
             {:ok, env} <- fetch_optional_env(nested),
             {:ok, labels} <- fetch_optional_labels(nested) do
          out = %{}
          out = if is_nil(env), do: out, else: Map.put(out, "Env", env)
          out = if is_nil(labels), do: out, else: Map.put(out, "Labels", labels)
          {:ok, out}
        end

      _other ->
        {:error, :invalid_image_config}
    end
  end

  defp fetch_optional_env(map) do
    case Map.fetch(map, "Env") do
      :error ->
        {:ok, nil}

      {:ok, env} when is_list(env) ->
        project_env_list(env)

      _other ->
        {:error, :invalid_image_env}
    end
  end

  defp fetch_optional_labels(map) do
    case Map.fetch(map, "Labels") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, labels} when is_map(labels) ->
        project_labels_map(labels)

      _other ->
        {:error, :invalid_image_labels}
    end
  end

  defp project_env_list(env) when is_list(env) do
    case take_bounded(env, @max_env_list_entries) do
      :too_many ->
        {:error, :too_many_image_env}

      {:ok, bounded} ->
        Enum.reduce_while(bounded, {:ok, []}, fn entry, {:ok, acc} ->
          if is_binary(entry) do
            with :ok <- bounded_string(entry, @max_string_bytes, :image_env_too_long),
                 :ok <- require_valid_utf8(entry),
                 :ok <- reject_control_char(entry, :unsafe_image_env) do
              {:cont, {:ok, [entry | acc]}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:halt, {:error, :invalid_image_env}}
          end
        end)
        |> case do
          {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
          error -> error
        end
    end
  end

  defp project_labels_map(labels) when is_map(labels) do
    if map_size(labels) > @max_label_keys do
      {:error, :too_many_image_labels}
    else
      Enum.reduce_while(labels, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        if is_binary(key) and is_binary(value) do
          with :ok <- bounded_string(key, @max_label_key_bytes, :image_label_key_too_long),
               :ok <- bounded_string(value, @max_label_value_bytes, :image_label_value_too_long),
               :ok <- require_valid_utf8(key),
               :ok <- require_valid_utf8(value),
               :ok <- reject_control_char(key, :unsafe_image_label_key),
               :ok <- reject_control_char(value, :unsafe_image_label_value) do
            {:cont, {:ok, Map.put(acc, key, value)}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:halt, {:error, :invalid_image_labels}}
        end
      end)
    end
  end

  # --- runtime plugin TOML ---

  defp parse_runtime_plugin_toml(raw) do
    with :ok <- require_valid_utf8(raw),
         {:ok, decoded} <- decode_toml(raw),
         :ok <-
           validate_closed_string_keys(
             decoded,
             MapSet.new(["abstract", "author", "version", "servicesConfig"]),
             :runtime_plugin_config
           ),
         {:ok, abstract} <- fetch_toml_string(decoded, "abstract"),
         {:ok, author} <- fetch_toml_string(decoded, "author"),
         {:ok, version} <- fetch_toml_plugin_version(decoded),
         {:ok, services_config} <- fetch_toml_services_config(decoded) do
      cond do
        abstract != @plugin_abstract ->
          {:error, :plugin_abstract_mismatch}

        author != @plugin_author ->
          {:error, :plugin_author_mismatch}

        version != @plugin_version ->
          {:error, :plugin_version_mismatch}

        true ->
          {:ok,
           %{
             abstract: abstract,
             author: author,
             version: version,
             services_config: services_config
           }}
      end
    end
  end

  defp fetch_toml_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        with :ok <- bounded_string(value, @max_string_bytes, :toml_string_too_long),
             :ok <- require_valid_utf8(value) do
          {:ok, value}
        end

      :error ->
        {:error, {:missing_toml_key, key}}

      _other ->
        {:error, {:invalid_toml_key, key}}
    end
  end

  defp fetch_toml_plugin_version(map) do
    case Map.fetch(map, "version") do
      {:ok, 0.1} ->
        {:ok, "0.1"}

      {:ok, _other} ->
        {:error, :invalid_plugin_toml_version}

      :error ->
        {:error, :missing_plugin_toml_version}
    end
  end

  defp fetch_toml_services_config(map) do
    case Map.fetch(map, "servicesConfig") do
      {:ok, sc} when is_map(sc) ->
        with :ok <-
               validate_closed_string_keys(
                 sc,
                 MapSet.new(["loadAtBoot", "runAtLoad", "defaultArguments", "services"]),
                 :services_config
               ),
             {:ok, load_at_boot} <- fetch_toml_boolean(sc, "loadAtBoot"),
             {:ok, run_at_load} <- fetch_toml_boolean(sc, "runAtLoad"),
             {:ok, default_arguments} <- fetch_toml_default_arguments(sc),
             {:ok, services} <- fetch_toml_services(sc) do
          if load_at_boot == false and run_at_load == false and default_arguments == [] and
               services == [%{type: "runtime"}] do
            {:ok,
             %{
               load_at_boot: false,
               run_at_load: false,
               default_arguments: [],
               services: services
             }}
          else
            {:error, :plugin_services_config_mismatch}
          end
        end

      :error ->
        {:error, :missing_services_config}

      _other ->
        {:error, :invalid_services_config}
    end
  end

  defp fetch_toml_boolean(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> {:error, {:missing_toml_key, key}}
      _other -> {:error, {:invalid_toml_key, key}}
    end
  end

  defp fetch_toml_default_arguments(map) do
    case Map.fetch(map, "defaultArguments") do
      {:ok, args} when is_list(args) ->
        if Enum.all?(args, &is_binary/1) and length(args) <= @max_argv_entries do
          {:ok, args}
        else
          {:error, :invalid_default_arguments}
        end

      :error ->
        {:error, :missing_default_arguments}

      _other ->
        {:error, :invalid_default_arguments}
    end
  end

  defp fetch_toml_services(map) do
    case Map.fetch(map, "services") do
      {:ok, [%{} = entry]} ->
        with :ok <-
               validate_closed_string_keys(entry, MapSet.new(["type"]), :service_entry),
             {:ok, type} <- fetch_toml_string(entry, "type") do
          {:ok, [%{type: type}]}
        end

      {:ok, _other} ->
        {:error, :invalid_services}

      :error ->
        {:error, :missing_services}

      _other ->
        {:error, :invalid_services}
    end
  end

  # --- show helpers ---

  defp show_control_plane(control_plane) do
    %{
      "cli" => stringify_map(control_plane.cli),
      "apiserver" => %{
        "version" => control_plane.apiserver.version,
        "build" => control_plane.apiserver.build,
        "launchd" => show_launchd(control_plane.apiserver.launchd)
      },
      "service_status" => show_service_status(control_plane.service_status),
      "runtime_plugin" => %{
        "config" => show_plugin_config(control_plane.runtime_plugin.config)
      }
    }
  end

  defp show_launchd(launchd) do
    %{
      "label" => launchd.label,
      "path" => launchd.path,
      "type" => launchd.type,
      "state" => launchd.state,
      "program" => launchd.program,
      "argv" => launchd.argv,
      "environment" => launchd.environment,
      "inherited_environment" => launchd.inherited_environment,
      "default_environment" => launchd.default_environment
    }
  end

  defp show_service_status(status) do
    %{
      "status" => status.status,
      "install_root" => status.install_root,
      "apiserver_version" => status.apiserver_version,
      "apiserver_build" => status.apiserver_build,
      "app_root" => status.app_root,
      "log_root" => status.log_root
    }
  end

  defp show_plugin_config(config) do
    %{
      "abstract" => config.abstract,
      "author" => config.author,
      "version" => config.version,
      "services_config" => %{
        "load_at_boot" => config.services_config.load_at_boot,
        "run_at_load" => config.services_config.run_at_load,
        "default_arguments" => config.services_config.default_arguments,
        "services" => Enum.map(config.services_config.services, &stringify_map/1)
      }
    }
  end

  defp show_image_inspect(inspect) do
    %{
      "configuration" => %{
        "descriptor" => %{
          "digest" => inspect.configuration.descriptor.digest,
          "media_type" => inspect.configuration.descriptor.media_type,
          "size" => inspect.configuration.descriptor.size
        },
        "name" => inspect.configuration.name
      },
      "variants" => Enum.map(inspect.variants, &show_variant/1)
    }
  end

  defp show_variant(variant) do
    %{
      "digest" => variant.digest,
      "platform" => stringify_map(variant.platform),
      "config" => show_variant_config(variant.config)
    }
  end

  defp show_variant_config(config) do
    base =
      config
      |> Map.take([:os, :architecture, :variant])
      |> stringify_map()

    case Map.get(config, :config) do
      nil -> base
      nested when is_map(nested) -> Map.put(base, "config", nested)
    end
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} when is_binary(key) -> {key, value}
    end)
  end

  # --- primitives ---

  defp decode_json(raw, invalid) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, invalid}
    end
  rescue
    _ -> {:error, invalid}
  end

  defp decode_toml(raw) when is_binary(raw) do
    case Toml.decode(raw, keys: :strings) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, :invalid_runtime_plugin_config_toml}
      {:error, _} -> {:error, :invalid_runtime_plugin_config_toml}
    end
  rescue
    _ -> {:error, :invalid_runtime_plugin_config_toml}
  end

  defp require_list_length(list, n, invalid) when is_list(list) do
    if length(list) == n and length(list) <= @max_json_list do
      :ok
    else
      {:error, invalid}
    end
  end

  defp require_list_length(_other, _n, invalid), do: {:error, invalid}

  defp require_map(value, _invalid) when is_map(value), do: :ok
  defp require_map(_value, invalid), do: {:error, invalid}

  defp require_digest(digest, invalid) when is_binary(digest) do
    if Regex.match?(@digest_re, digest), do: :ok, else: {:error, invalid}
  end

  defp require_map_key_budget(map) when is_map(map) do
    if map_size(map) > @max_map_keys do
      {:error, :map_too_large}
    else
      :ok
    end
  end

  defp fetch_json_map(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) ->
        with :ok <- require_map_key_budget(value), do: {:ok, value}

      :error ->
        {:error, {:missing_json_key, key}}

      _other ->
        {:error, {:invalid_json_key, key}}
    end
  end

  defp fetch_json_list(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) -> {:ok, value}
      :error -> {:error, {:missing_json_key, key}}
      _other -> {:error, {:invalid_json_key, key}}
    end
  end

  defp fetch_json_string(map, key, max) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        with :ok <- bounded_string(value, max, :json_string_too_long),
             :ok <- require_valid_utf8(value),
             :ok <- reject_control_char(value, :unsafe_json_string) do
          {:ok, value}
        end

      :error ->
        {:error, {:missing_json_key, key}}

      _other ->
        {:error, {:invalid_json_key, key}}
    end
  end

  defp fetch_optional_json_string(map, key, max) when is_map(map) do
    case Map.fetch(map, key) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        with :ok <- bounded_string(value, max, :json_string_too_long),
             :ok <- require_valid_utf8(value),
             :ok <- reject_control_or_whitespace(value, :unsafe_json_string) do
          {:ok, value}
        end

      _other ->
        {:error, {:invalid_json_key, key}}
    end
  end

  defp fetch_json_non_neg_int(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 ->
        {:ok, value}

      :error ->
        {:error, {:missing_json_key, key}}

      _other ->
        {:error, {:invalid_json_key, key}}
    end
  end

  defp validate_closed_keys(map, allowed, logical, scope) when is_map(map) do
    if map_size(map) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(map)

      with :ok <- reject_unknown_keys(keys, allowed, scope),
           :ok <- reject_duplicate_key_aliases(keys, logical, scope) do
        :ok
      end
    end
  end

  defp validate_closed_string_keys(map, allowed, scope) when is_map(map) do
    if map_size(map) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(map)

      if Enum.all?(keys, &is_binary/1) and Enum.all?(keys, &MapSet.member?(allowed, &1)) do
        :ok
      else
        {:error, {:unsupported_keys, scope}}
      end
    end
  end

  defp reject_unknown_keys(keys, allowed, scope) do
    if Enum.all?(keys, &MapSet.member?(allowed, &1)) do
      :ok
    else
      {:error, {:unsupported_keys, scope}}
    end
  end

  defp reject_duplicate_key_aliases(keys, logical, scope) do
    key_set = MapSet.new(keys)

    Enum.reduce_while(logical, :ok, fn atom_key, :ok ->
      has_atom? = MapSet.member?(key_set, atom_key)
      has_string? = MapSet.member?(key_set, Atom.to_string(atom_key))

      if has_atom? and has_string? do
        {:halt, {:error, {:duplicate_key_alias, scope, atom_key}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp require_bounded_utf8_field(map, key, max, missing, invalid, too_long) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_binary(value) ->
        cond do
          byte_size(value) > max ->
            {:error, too_long}

          not String.valid?(value) ->
            {:error, :invalid_utf8}

          true ->
            {:ok, value}
        end

      _other ->
        {:error, invalid}
    end
  end

  defp require_bounded_binary_field(map, key, max, missing, invalid, too_long) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      value when is_binary(value) ->
        if byte_size(value) > max, do: {:error, too_long}, else: {:ok, value}

      _other ->
        {:error, invalid}
    end
  end

  defp get_field(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp require_exact(actual, expected, mismatch) do
    if actual === expected, do: :ok, else: {:error, mismatch}
  end

  defp take_bounded(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    take_bounded(list, max + 1, 0, [])
  end

  defp take_bounded(_list, limit, count, _acc) when count >= limit, do: :too_many
  defp take_bounded([], _limit, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_bounded([head | rest], limit, count, acc) do
    take_bounded(rest, limit, count + 1, [head | acc])
  end

  defp require_valid_utf8(value) when is_binary(value) do
    if String.valid?(value), do: :ok, else: {:error, :invalid_utf8}
  end

  defp require_valid_utf8(_), do: {:error, :invalid_utf8}

  defp bounded_string(value, max, too_long) when is_binary(value) do
    if byte_size(value) <= max, do: :ok, else: {:error, too_long}
  end

  defp reject_control_or_whitespace(value, reason) when is_binary(value) do
    if has_control_or_whitespace?(value), do: {:error, reason}, else: :ok
  end

  defp reject_control_char(value, reason) when is_binary(value) do
    if has_control_char?(value) or binary_contains?(value, <<0>>),
      do: {:error, reason},
      else: :ok
  end

  defp has_control_or_whitespace?(value) when is_binary(value) do
    has_control_char?(value) or has_whitespace?(value) or binary_contains?(value, <<0>>)
  end

  defp has_whitespace?(value) when is_binary(value) do
    :binary.match(value, [" ", "\t", "\n", "\r", "\f", "\v"]) != :nomatch or
      String.match?(value, ~r/[[:space:]]/)
  end

  defp has_control_char?(value) when is_binary(value) do
    has_control_char_bytes?(value)
  end

  defp has_control_char_bytes?(<<>>), do: false
  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true
  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)

  defp binary_contains?(haystack, needle)
       when is_binary(haystack) and is_binary(needle) and needle != "" do
    :binary.match(haystack, needle) != :nomatch
  end
end
