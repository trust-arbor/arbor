defmodule Arbor.Shell.AppleContainerControlPlaneAdmissionCore do
  @moduledoc """
  Pure Apple Container control-plane admission decision core.

  Consumes startup-owner identity bindings plus already-collected bounded
  probe evidence and returns either a compact admitted receipt or a stable
  fail-closed error. Performs no IO, process execution, filesystem access,
  environment reads, Application config reads, or GenServer calls.

  Fixed platform authority (CLI/API/plugin paths, signing identifiers, team
  ID, designated requirements, install/shadow roots) lives inside this
  module — never as caller options.

  Service-status evidence is corroboration only and never establishes
  version, path, or signing authority. A returned receipt is evidence for the
  imperative admission path behind `Arbor.Shell.execute_spawn_capable/3`.
  """

  import Bitwise

  alias Arbor.Shell.TrustedPath
  alias Arbor.Shell.TrustedPath.Identity

  # --- Fixed control-plane authority ---

  @cli_path "/usr/local/bin/container"
  @apiserver_path "/usr/local/bin/container-apiserver"
  @plugin_path "/usr/local/libexec/container/plugins/container-runtime-linux/bin/container-runtime-linux"
  @plugin_config_path "/usr/local/libexec/container/plugins/container-runtime-linux/config.toml"
  @user_plugin_root_path "/usr/local/libexec/container-plugins"
  @install_root "/usr/local/"
  @container_install_root_env "/usr/local"
  @team_id "UPBK2H6LZM"
  @cli_identifier "com.apple.container.cli"
  @apiserver_identifier "com.apple.container.apiserver"
  @plugin_identifier "com.apple.container.container-runtime-linux"
  @launchd_label "com.apple.container.apiserver"
  @required_build "release"
  @compat_major 1
  @compat_minor 1
  @plugin_config_abstract "Linux container runtime plugin"
  @plugin_config_author "Apple"
  @plugin_config_version "0.1"

  @cli_requirement ~s(identifier "com.apple.container.cli" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = UPBK2H6LZM)
  @apiserver_requirement ~s(identifier "com.apple.container.apiserver" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = UPBK2H6LZM)
  @plugin_requirement ~s(identifier "com.apple.container.container-runtime-linux" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = UPBK2H6LZM)

  # --- Closed key surfaces ---

  @logical_binding_keys [
    :cli_identity,
    :apiserver_identity,
    :runtime_plugin_identity,
    :runtime_plugin_config_identity,
    :kernel_identity,
    :app_root
  ]
  @allowed_binding_keys MapSet.new(
                          @logical_binding_keys ++
                            Enum.map(@logical_binding_keys, &Atom.to_string/1)
                        )

  @logical_evidence_keys [
    :cli,
    :apiserver,
    :service_status,
    :runtime_plugin,
    :user_plugin_root,
    :kernel_identity
  ]
  @allowed_evidence_keys MapSet.new(
                           @logical_evidence_keys ++
                             Enum.map(@logical_evidence_keys, &Atom.to_string/1)
                         )

  @logical_cli_keys [:identity, :version, :build, :signing]
  @allowed_cli_keys MapSet.new(
                      @logical_cli_keys ++ Enum.map(@logical_cli_keys, &Atom.to_string/1)
                    )

  @logical_apiserver_keys [:identity, :version, :build, :signing, :launchd]
  @allowed_apiserver_keys MapSet.new(
                            @logical_apiserver_keys ++
                              Enum.map(@logical_apiserver_keys, &Atom.to_string/1)
                          )

  @logical_service_keys [
    :status,
    :install_root,
    :apiserver_version,
    :apiserver_build,
    :app_root,
    :log_root
  ]
  @allowed_service_keys MapSet.new(
                          @logical_service_keys ++
                            Enum.map(@logical_service_keys, &Atom.to_string/1)
                        )

  @logical_plugin_keys [:identity, :config_identity, :signing, :config]
  @allowed_plugin_keys MapSet.new(
                         @logical_plugin_keys ++ Enum.map(@logical_plugin_keys, &Atom.to_string/1)
                       )

  @logical_user_plugin_root_keys [:path, :status]
  @allowed_user_plugin_root_keys MapSet.new(
                                   @logical_user_plugin_root_keys ++
                                     Enum.map(@logical_user_plugin_root_keys, &Atom.to_string/1)
                                 )

  @logical_signing_keys [
    :identifier,
    :team_id,
    :designated_requirement,
    :verified_against,
    :status
  ]
  @allowed_signing_keys MapSet.new(
                          @logical_signing_keys ++
                            Enum.map(@logical_signing_keys, &Atom.to_string/1)
                        )

  @logical_launchd_keys [
    :label,
    :path,
    :type,
    :state,
    :program,
    :argv,
    :environment,
    :inherited_environment,
    :default_environment
  ]
  @allowed_launchd_keys MapSet.new(
                          @logical_launchd_keys ++
                            Enum.map(@logical_launchd_keys, &Atom.to_string/1)
                        )

  @launchd_type "LaunchAgent"
  @launchd_state "running"
  @launchd_plist_relative "apiserver/apiserver.plist"
  @required_job_env_keys ["CONTAINER_APP_ROOT", "CONTAINER_INSTALL_ROOT"]
  @allowed_job_env_keys MapSet.new([
                          "CONTAINER_APP_ROOT",
                          "CONTAINER_INSTALL_ROOT",
                          "XPC_SERVICE_NAME",
                          "OSLogRateLimit"
                        ])
  @proxy_env_names MapSet.new([
                     "http_proxy",
                     "https_proxy",
                     "all_proxy",
                     "no_proxy"
                   ])
  @oslog_rate_limit_re ~r/\A[0-9]+\z/

  @logical_plugin_config_keys [:abstract, :author, :version, :services_config]
  @allowed_plugin_config_keys MapSet.new(
                                @logical_plugin_config_keys ++
                                  Enum.map(@logical_plugin_config_keys, &Atom.to_string/1)
                              )

  @logical_services_config_keys [:load_at_boot, :run_at_load, :default_arguments, :services]
  @allowed_services_config_keys MapSet.new(
                                  @logical_services_config_keys ++
                                    Enum.map(@logical_services_config_keys, &Atom.to_string/1)
                                )

  @logical_service_entry_keys [:type]
  @allowed_service_entry_keys MapSet.new(
                                @logical_service_entry_keys ++
                                  Enum.map(@logical_service_entry_keys, &Atom.to_string/1)
                              )

  # --- Bounds ---

  @max_map_keys 64
  @max_path_bytes 4_096
  @max_version_bytes 64
  @max_status_bytes 64
  @max_signing_field_bytes 1_024
  @max_digest_hex 64
  @max_file_bytes 512 * 1024 * 1024
  @max_mode 0xFFFF_FFFF
  @max_metadata_int 0xFFFF_FFFF_FFFF_FFFF
  @max_env_entries 64
  @max_env_key_bytes 256
  @max_env_value_bytes 4_096
  @max_oslog_rate_limit_bytes 20
  @max_argv_entries 16
  @max_argv_entry_bytes 4_096

  @hex64_re ~r/\A[0-9a-f]{64}\z/
  @version_re ~r/\A(\d+)\.(\d+)\.(\d+)\z/

  @type receipt :: %{
          admitted: true,
          app_root: String.t(),
          cli: map(),
          apiserver: map(),
          runtime_plugin: map(),
          user_plugin_root: map(),
          kernel: map(),
          service: map()
        }

  @doc """
  Admit control-plane authority from startup bindings and probe evidence.

  `bindings` is owner-bound identity authority (separate from probe evidence).
  `evidence` is the closed normalized probe surface. Returns `{:ok, receipt}`
  only when every fixed path, signing requirement, identity binding, launchd
  shape, plugin config, and service corroboration holds.
  """
  @spec new(term(), term()) :: {:ok, receipt()} | {:error, term()}
  def new(bindings, evidence) when is_map(bindings) and is_map(evidence) do
    with :ok <-
           validate_closed_keys(
             bindings,
             @allowed_binding_keys,
             @logical_binding_keys,
             :bindings
           ),
         :ok <-
           validate_closed_keys(
             evidence,
             @allowed_evidence_keys,
             @logical_evidence_keys,
             :evidence
           ),
         {:ok, normalized_bindings} <- normalize_bindings(bindings),
         {:ok, normalized_evidence} <- normalize_evidence(evidence),
         :ok <-
           validate_identity_match(
             normalized_bindings.cli_identity,
             normalized_evidence.cli.identity,
             :cli_identity_mismatch
           ),
         :ok <-
           validate_identity_match(
             normalized_bindings.apiserver_identity,
             normalized_evidence.apiserver.identity,
             :apiserver_identity_mismatch
           ),
         :ok <-
           validate_identity_match(
             normalized_bindings.runtime_plugin_identity,
             normalized_evidence.runtime_plugin.identity,
             :runtime_plugin_identity_mismatch
           ),
         :ok <-
           validate_identity_match(
             normalized_bindings.runtime_plugin_config_identity,
             normalized_evidence.runtime_plugin.config_identity,
             :runtime_plugin_config_identity_mismatch
           ),
         :ok <-
           validate_identity_match(
             normalized_bindings.kernel_identity,
             normalized_evidence.kernel_identity,
             :kernel_identity_mismatch
           ),
         {:ok, cli_version} <-
           validate_release_semver(normalized_evidence.cli.version, :invalid_cli_version),
         :ok <-
           require_exact(
             normalized_evidence.cli.build,
             @required_build,
             :non_release_cli_build
           ),
         :ok <-
           validate_signing(
             normalized_evidence.cli.signing,
             @cli_identifier,
             @cli_requirement
           ),
         {:ok, api_version} <-
           validate_release_semver(
             normalized_evidence.apiserver.version,
             :invalid_apiserver_version
           ),
         :ok <-
           require_exact(
             normalized_evidence.apiserver.build,
             @required_build,
             :non_release_apiserver_build
           ),
         :ok <-
           validate_signing(
             normalized_evidence.apiserver.signing,
             @apiserver_identifier,
             @apiserver_requirement
           ),
         :ok <- require_exact(cli_version, api_version, :cli_api_version_mismatch),
         :ok <-
           validate_launchd(
             normalized_evidence.apiserver.launchd,
             normalized_bindings.app_root
           ),
         :ok <-
           validate_signing(
             normalized_evidence.runtime_plugin.signing,
             @plugin_identifier,
             @plugin_requirement
           ),
         :ok <- validate_plugin_config(normalized_evidence.runtime_plugin.config),
         :ok <- validate_user_plugin_root(normalized_evidence.user_plugin_root),
         :ok <-
           validate_service_corroboration(
             normalized_evidence.service_status,
             api_version,
             normalized_evidence.apiserver.build,
             normalized_bindings.app_root
           ) do
      receipt = build_receipt(normalized_bindings, normalized_evidence, cli_version, api_version)
      {:ok, receipt}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def new(_bindings, _evidence), do: {:error, :invalid_request}

  @doc """
  Convert an admission receipt to a JSON-clean map (no structs or raw output).
  """
  @spec show(receipt()) :: map()
  def show(%{admitted: true} = receipt) do
    %{
      "admitted" => true,
      "app_root" => receipt.app_root,
      "cli" => show_signed_binary(receipt.cli),
      "apiserver" => show_apiserver(receipt.apiserver),
      "runtime_plugin" => show_runtime_plugin(receipt.runtime_plugin),
      "user_plugin_root" => %{
        "path" => receipt.user_plugin_root.path,
        "status" => receipt.user_plugin_root.status
      },
      "kernel" => %{
        "path" => receipt.kernel.path,
        "sha256" => receipt.kernel.sha256
      },
      "service" => %{
        "status" => receipt.service.status,
        "install_root" => receipt.service.install_root,
        "app_root" => receipt.service.app_root,
        "log_root_configured" => false,
        "corroborated" => true
      }
    }
  end

  @doc "Fixed CLI path."
  @spec cli_path() :: String.t()
  def cli_path, do: @cli_path

  @doc "Fixed API server path."
  @spec apiserver_path() :: String.t()
  def apiserver_path, do: @apiserver_path

  @doc "Fixed runtime plugin executable path."
  @spec plugin_path() :: String.t()
  def plugin_path, do: @plugin_path

  @doc "Fixed runtime plugin config path."
  @spec plugin_config_path() :: String.t()
  def plugin_config_path, do: @plugin_config_path

  @doc "Fixed user plugin shadow root path that must be absent."
  @spec user_plugin_root_path() :: String.t()
  def user_plugin_root_path, do: @user_plugin_root_path

  @doc "Fixed Apple team identifier."
  @spec team_id() :: String.t()
  def team_id, do: @team_id

  @doc "Fixed codesign identifier for the container CLI."
  @spec cli_identifier() :: String.t()
  def cli_identifier, do: @cli_identifier

  @doc "Fixed codesign identifier for the container API server."
  @spec apiserver_identifier() :: String.t()
  def apiserver_identifier, do: @apiserver_identifier

  @doc "Fixed codesign identifier for the Linux runtime plugin."
  @spec plugin_identifier() :: String.t()
  def plugin_identifier, do: @plugin_identifier

  @doc "Fixed designated requirement for the container CLI."
  @spec cli_designated_requirement() :: String.t()
  def cli_designated_requirement, do: @cli_requirement

  @doc "Fixed designated requirement for the container API server."
  @spec apiserver_designated_requirement() :: String.t()
  def apiserver_designated_requirement, do: @apiserver_requirement

  @doc "Fixed designated requirement for the Linux runtime plugin."
  @spec plugin_designated_requirement() :: String.t()
  def plugin_designated_requirement, do: @plugin_requirement

  # --- Normalization ---

  defp normalize_bindings(bindings) do
    with {:ok, cli_identity} <-
           fetch_identity_binding(
             bindings,
             :cli_identity,
             @cli_path,
             true,
             :missing_cli_identity,
             :invalid_cli_identity
           ),
         {:ok, apiserver_identity} <-
           fetch_identity_binding(
             bindings,
             :apiserver_identity,
             @apiserver_path,
             true,
             :missing_apiserver_identity,
             :invalid_apiserver_identity
           ),
         {:ok, runtime_plugin_identity} <-
           fetch_identity_binding(
             bindings,
             :runtime_plugin_identity,
             @plugin_path,
             true,
             :missing_runtime_plugin_identity,
             :invalid_runtime_plugin_identity
           ),
         {:ok, runtime_plugin_config_identity} <-
           fetch_identity_binding(
             bindings,
             :runtime_plugin_config_identity,
             @plugin_config_path,
             false,
             :missing_runtime_plugin_config_identity,
             :invalid_runtime_plugin_config_identity
           ),
         {:ok, kernel_identity} <-
           fetch_kernel_binding(bindings),
         {:ok, app_root} <- fetch_app_root(bindings) do
      {:ok,
       %{
         cli_identity: cli_identity,
         apiserver_identity: apiserver_identity,
         runtime_plugin_identity: runtime_plugin_identity,
         runtime_plugin_config_identity: runtime_plugin_config_identity,
         kernel_identity: kernel_identity,
         app_root: app_root
       }}
    end
  end

  defp normalize_evidence(evidence) do
    with {:ok, cli} <- fetch_cli_evidence(evidence),
         {:ok, apiserver} <- fetch_apiserver_evidence(evidence),
         {:ok, service_status} <- fetch_service_status(evidence),
         {:ok, runtime_plugin} <- fetch_runtime_plugin(evidence),
         {:ok, user_plugin_root} <- fetch_user_plugin_root(evidence),
         {:ok, kernel_identity} <- fetch_evidence_identity(evidence, :kernel_identity) do
      {:ok,
       %{
         cli: cli,
         apiserver: apiserver,
         service_status: service_status,
         runtime_plugin: runtime_plugin,
         user_plugin_root: user_plugin_root,
         kernel_identity: kernel_identity
       }}
    end
  end

  defp fetch_cli_evidence(evidence) do
    with {:ok, cli} <- fetch_required_map(evidence, :cli, :missing_cli, :invalid_cli),
         :ok <- validate_closed_keys(cli, @allowed_cli_keys, @logical_cli_keys, :cli),
         {:ok, identity} <- fetch_evidence_identity(cli, :identity),
         {:ok, version} <-
           require_bounded_binary_field(
             cli,
             :version,
             @max_version_bytes,
             :missing_cli_version,
             :invalid_cli_version,
             :cli_version_too_long
           ),
         {:ok, build} <-
           require_bounded_binary_field(
             cli,
             :build,
             @max_status_bytes,
             :missing_cli_build,
             :invalid_cli_build,
             :cli_build_too_long
           ),
         {:ok, signing} <- fetch_signing(cli) do
      {:ok, %{identity: identity, version: version, build: build, signing: signing}}
    end
  end

  defp fetch_apiserver_evidence(evidence) do
    with {:ok, apiserver} <-
           fetch_required_map(evidence, :apiserver, :missing_apiserver, :invalid_apiserver),
         :ok <-
           validate_closed_keys(
             apiserver,
             @allowed_apiserver_keys,
             @logical_apiserver_keys,
             :apiserver
           ),
         {:ok, identity} <- fetch_evidence_identity(apiserver, :identity),
         {:ok, version} <-
           require_bounded_binary_field(
             apiserver,
             :version,
             @max_version_bytes,
             :missing_apiserver_version,
             :invalid_apiserver_version,
             :apiserver_version_too_long
           ),
         {:ok, build} <-
           require_bounded_binary_field(
             apiserver,
             :build,
             @max_status_bytes,
             :missing_apiserver_build,
             :invalid_apiserver_build,
             :apiserver_build_too_long
           ),
         {:ok, signing} <- fetch_signing(apiserver),
         {:ok, launchd} <- fetch_launchd(apiserver) do
      {:ok,
       %{
         identity: identity,
         version: version,
         build: build,
         signing: signing,
         launchd: launchd
       }}
    end
  end

  defp fetch_service_status(evidence) do
    with {:ok, service} <-
           fetch_required_map(
             evidence,
             :service_status,
             :missing_service_status,
             :invalid_service_status
           ),
         :ok <-
           validate_closed_keys(
             service,
             @allowed_service_keys,
             @logical_service_keys,
             :service_status
           ),
         {:ok, status} <-
           require_bounded_binary_field(
             service,
             :status,
             @max_status_bytes,
             :missing_service_run_status,
             :invalid_service_run_status,
             :service_status_too_long
           ),
         {:ok, install_root} <-
           require_bounded_binary_field(
             service,
             :install_root,
             @max_path_bytes,
             :missing_install_root,
             :invalid_install_root,
             :install_root_too_long
           ),
         {:ok, apiserver_version} <-
           require_bounded_binary_field(
             service,
             :apiserver_version,
             @max_version_bytes,
             :missing_service_apiserver_version,
             :invalid_service_apiserver_version,
             :service_apiserver_version_too_long
           ),
         {:ok, apiserver_build} <-
           require_bounded_binary_field(
             service,
             :apiserver_build,
             @max_status_bytes,
             :missing_service_apiserver_build,
             :invalid_service_apiserver_build,
             :service_apiserver_build_too_long
           ),
         {:ok, app_root} <-
           require_bounded_binary_field(
             service,
             :app_root,
             @max_path_bytes,
             :missing_service_app_root,
             :invalid_service_app_root,
             :service_app_root_too_long
           ),
         {:ok, log_root} <- fetch_required_nil_log_root(service) do
      {:ok,
       %{
         status: status,
         install_root: install_root,
         apiserver_version: apiserver_version,
         apiserver_build: apiserver_build,
         app_root: app_root,
         log_root: log_root
       }}
    end
  end

  # log_root must be explicitly present and nil. A missing key fails closed as
  # missing (never treated as nil). Any non-nil value is forbidden; rejected
  # path text is not retained.
  defp fetch_required_nil_log_root(service) when is_map(service) do
    atom_key = :log_root
    string_key = "log_root"

    cond do
      Map.has_key?(service, atom_key) ->
        case Map.fetch!(service, atom_key) do
          nil -> {:ok, nil}
          _other -> {:error, :service_log_root_forbidden}
        end

      Map.has_key?(service, string_key) ->
        case Map.fetch!(service, string_key) do
          nil -> {:ok, nil}
          _other -> {:error, :service_log_root_forbidden}
        end

      true ->
        {:error, :missing_service_log_root}
    end
  end

  defp fetch_runtime_plugin(evidence) do
    with {:ok, plugin} <-
           fetch_required_map(
             evidence,
             :runtime_plugin,
             :missing_runtime_plugin,
             :invalid_runtime_plugin
           ),
         :ok <-
           validate_closed_keys(
             plugin,
             @allowed_plugin_keys,
             @logical_plugin_keys,
             :runtime_plugin
           ),
         {:ok, identity} <- fetch_evidence_identity(plugin, :identity),
         {:ok, config_identity} <- fetch_evidence_identity(plugin, :config_identity),
         {:ok, signing} <- fetch_signing(plugin),
         {:ok, config} <- fetch_plugin_config(plugin) do
      {:ok,
       %{
         identity: identity,
         config_identity: config_identity,
         signing: signing,
         config: config
       }}
    end
  end

  defp fetch_user_plugin_root(evidence) do
    with {:ok, root} <-
           fetch_required_map(
             evidence,
             :user_plugin_root,
             :missing_user_plugin_root,
             :invalid_user_plugin_root
           ),
         :ok <-
           validate_closed_keys(
             root,
             @allowed_user_plugin_root_keys,
             @logical_user_plugin_root_keys,
             :user_plugin_root
           ),
         {:ok, path} <-
           require_bounded_binary_field(
             root,
             :path,
             @max_path_bytes,
             :missing_user_plugin_root_path,
             :invalid_user_plugin_root_path,
             :user_plugin_root_path_too_long
           ),
         {:ok, status} <-
           require_bounded_binary_field(
             root,
             :status,
             @max_status_bytes,
             :missing_user_plugin_root_status,
             :invalid_user_plugin_root_status,
             :user_plugin_root_status_too_long
           ) do
      {:ok, %{path: path, status: status}}
    end
  end

  defp fetch_signing(map) do
    with {:ok, signing} <-
           fetch_required_map(map, :signing, :missing_signing, :invalid_signing),
         :ok <-
           validate_closed_keys(signing, @allowed_signing_keys, @logical_signing_keys, :signing),
         {:ok, identifier} <-
           require_bounded_binary_field(
             signing,
             :identifier,
             @max_signing_field_bytes,
             :missing_signing_identifier,
             :invalid_signing_identifier,
             :signing_identifier_too_long
           ),
         {:ok, team_id} <-
           require_bounded_binary_field(
             signing,
             :team_id,
             @max_signing_field_bytes,
             :missing_team_id,
             :invalid_team_id,
             :team_id_too_long
           ),
         {:ok, designated_requirement} <-
           require_bounded_binary_field(
             signing,
             :designated_requirement,
             @max_signing_field_bytes,
             :missing_designated_requirement,
             :invalid_designated_requirement,
             :designated_requirement_too_long
           ),
         {:ok, verified_against} <-
           require_bounded_binary_field(
             signing,
             :verified_against,
             @max_signing_field_bytes,
             :missing_verified_against,
             :invalid_verified_against,
             :verified_against_too_long
           ),
         {:ok, status} <-
           require_bounded_binary_field(
             signing,
             :status,
             @max_status_bytes,
             :missing_signing_status,
             :invalid_signing_status,
             :signing_status_too_long
           ) do
      {:ok,
       %{
         identifier: identifier,
         team_id: team_id,
         designated_requirement: designated_requirement,
         verified_against: verified_against,
         status: status
       }}
    end
  end

  defp fetch_launchd(apiserver) do
    with {:ok, launchd} <-
           fetch_required_map(apiserver, :launchd, :missing_launchd, :invalid_launchd),
         :ok <-
           validate_closed_keys(launchd, @allowed_launchd_keys, @logical_launchd_keys, :launchd),
         {:ok, label} <-
           require_bounded_binary_field(
             launchd,
             :label,
             @max_signing_field_bytes,
             :missing_launchd_label,
             :invalid_launchd_label,
             :launchd_label_too_long
           ),
         {:ok, path} <-
           require_bounded_binary_field(
             launchd,
             :path,
             @max_path_bytes,
             :missing_launchd_path,
             :invalid_launchd_path,
             :launchd_path_too_long
           ),
         {:ok, type} <-
           require_bounded_binary_field(
             launchd,
             :type,
             @max_status_bytes,
             :missing_launchd_type,
             :invalid_launchd_type,
             :launchd_type_too_long
           ),
         {:ok, state} <-
           require_bounded_binary_field(
             launchd,
             :state,
             @max_status_bytes,
             :missing_launchd_state,
             :invalid_launchd_state,
             :launchd_state_too_long
           ),
         {:ok, program} <-
           require_bounded_binary_field(
             launchd,
             :program,
             @max_path_bytes,
             :missing_launchd_program,
             :invalid_launchd_program,
             :launchd_program_too_long
           ),
         {:ok, argv} <- fetch_argv(launchd),
         {:ok, environment} <-
           fetch_environment_map(
             launchd,
             :environment,
             :missing_launchd_environment,
             :invalid_launchd_environment,
             :too_many_launchd_env
           ),
         {:ok, inherited_environment} <-
           fetch_environment_map(
             launchd,
             :inherited_environment,
             :missing_launchd_inherited_environment,
             :invalid_launchd_inherited_environment,
             :too_many_launchd_inherited_env
           ),
         {:ok, default_environment} <-
           fetch_environment_map(
             launchd,
             :default_environment,
             :missing_launchd_default_environment,
             :invalid_launchd_default_environment,
             :too_many_launchd_default_env
           ) do
      {:ok,
       %{
         label: label,
         path: path,
         type: type,
         state: state,
         program: program,
         argv: argv,
         environment: environment,
         inherited_environment: inherited_environment,
         default_environment: default_environment
       }}
    end
  end

  defp fetch_argv(launchd) do
    case get_field(launchd, :argv) do
      nil ->
        {:error, :missing_launchd_argv}

      argv when is_list(argv) ->
        case take_bounded(argv, @max_argv_entries) do
          :too_many ->
            {:error, :too_many_launchd_argv}

          {:ok, bounded} ->
            if Enum.all?(bounded, &is_binary/1) do
              Enum.reduce_while(bounded, {:ok, []}, fn entry, {:ok, acc} ->
                with :ok <- bounded_string(entry, @max_argv_entry_bytes, :launchd_argv_too_long),
                     :ok <- require_valid_utf8(entry),
                     :ok <- reject_control_char(entry, :unsafe_launchd_argv) do
                  {:cont, {:ok, [entry | acc]}}
                else
                  {:error, reason} -> {:halt, {:error, reason}}
                end
              end)
              |> case do
                {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
                error -> error
              end
            else
              {:error, :invalid_launchd_argv}
            end
        end

      _other ->
        {:error, :invalid_launchd_argv}
    end
  end

  # Normalize a string-keyed environment map. Atom keys are rejected so a later
  # imperative prober cannot smuggle aliases past the closed UTF-8 surface.
  defp fetch_environment_map(launchd, field, missing, invalid, too_many) do
    case get_field(launchd, field) do
      nil ->
        {:error, missing}

      env when is_map(env) ->
        if map_size(env) > @max_env_entries do
          {:error, too_many}
        else
          keys = Map.keys(env)

          if Enum.all?(keys, &is_binary/1) and Enum.all?(Map.values(env), &is_binary/1) do
            Enum.reduce_while(env, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
              with :ok <- bounded_string(key, @max_env_key_bytes, :launchd_env_key_too_long),
                   :ok <- bounded_string(value, @max_env_value_bytes, :launchd_env_value_too_long),
                   :ok <- require_valid_utf8(key),
                   :ok <- require_valid_utf8(value),
                   :ok <- reject_control_char(key, :unsafe_launchd_env_key),
                   :ok <- reject_control_char(value, :unsafe_launchd_env_value) do
                if key == "" do
                  {:halt, {:error, :empty_launchd_env_key}}
                else
                  {:cont, {:ok, Map.put(acc, key, value)}}
                end
              else
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
          else
            {:error, invalid}
          end
        end

      _other ->
        {:error, invalid}
    end
  end

  defp fetch_plugin_config(plugin) do
    with {:ok, config} <-
           fetch_required_map(plugin, :config, :missing_plugin_config, :invalid_plugin_config),
         :ok <-
           validate_closed_keys(
             config,
             @allowed_plugin_config_keys,
             @logical_plugin_config_keys,
             :plugin_config
           ),
         {:ok, abstract} <-
           require_bounded_binary_field(
             config,
             :abstract,
             @max_signing_field_bytes,
             :missing_plugin_abstract,
             :invalid_plugin_abstract,
             :plugin_abstract_too_long
           ),
         {:ok, author} <-
           require_bounded_binary_field(
             config,
             :author,
             @max_signing_field_bytes,
             :missing_plugin_author,
             :invalid_plugin_author,
             :plugin_author_too_long
           ),
         {:ok, version} <-
           require_bounded_binary_field(
             config,
             :version,
             @max_version_bytes,
             :missing_plugin_config_version,
             :invalid_plugin_config_version,
             :plugin_config_version_too_long
           ),
         {:ok, services_config} <- fetch_services_config(config) do
      {:ok,
       %{
         abstract: abstract,
         author: author,
         version: version,
         services_config: services_config
       }}
    end
  end

  defp fetch_services_config(config) do
    with {:ok, services_config} <-
           fetch_required_map(
             config,
             :services_config,
             :missing_services_config,
             :invalid_services_config
           ),
         :ok <-
           validate_closed_keys(
             services_config,
             @allowed_services_config_keys,
             @logical_services_config_keys,
             :services_config
           ),
         {:ok, load_at_boot} <- fetch_required_boolean(services_config, :load_at_boot),
         {:ok, run_at_load} <- fetch_required_boolean(services_config, :run_at_load),
         {:ok, default_arguments} <- fetch_default_arguments(services_config),
         {:ok, services} <- fetch_services(services_config) do
      {:ok,
       %{
         load_at_boot: load_at_boot,
         run_at_load: run_at_load,
         default_arguments: default_arguments,
         services: services
       }}
    end
  end

  defp fetch_default_arguments(services_config) do
    case get_field(services_config, :default_arguments) do
      nil ->
        {:error, :missing_default_arguments}

      args when is_list(args) ->
        case take_bounded(args, @max_argv_entries) do
          :too_many ->
            {:error, :too_many_default_arguments}

          {:ok, bounded} ->
            if Enum.all?(bounded, &is_binary/1) do
              {:ok, bounded}
            else
              {:error, :invalid_default_arguments}
            end
        end

      _other ->
        {:error, :invalid_default_arguments}
    end
  end

  defp fetch_services(services_config) do
    case get_field(services_config, :services) do
      nil ->
        {:error, :missing_services}

      services when is_list(services) ->
        case take_bounded(services, 8) do
          :too_many ->
            {:error, :too_many_services}

          {:ok, bounded} ->
            if Enum.all?(bounded, &is_map/1) do
              Enum.reduce_while(bounded, {:ok, []}, fn entry, {:ok, acc} ->
                case normalize_service_entry(entry) do
                  {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
                  {:error, reason} -> {:halt, {:error, reason}}
                end
              end)
              |> case do
                {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
                error -> error
              end
            else
              {:error, :invalid_services}
            end
        end

      _other ->
        {:error, :invalid_services}
    end
  end

  defp normalize_service_entry(entry) when is_map(entry) do
    with :ok <-
           validate_closed_keys(
             entry,
             @allowed_service_entry_keys,
             @logical_service_entry_keys,
             :service_entry
           ),
         {:ok, type} <-
           require_bounded_binary_field(
             entry,
             :type,
             @max_status_bytes,
             :missing_service_type,
             :invalid_service_type,
             :service_type_too_long
           ) do
      {:ok, %{type: type}}
    end
  end

  defp fetch_required_boolean(map, key) do
    case get_field(map, key) do
      nil -> {:error, {:missing, key}}
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, {:invalid, key}}
    end
  end

  defp fetch_identity_binding(map, key, expected_path, executable_required, missing, invalid) do
    case get_field(map, key) do
      nil ->
        {:error, missing}

      %Identity{} = identity ->
        case validate_identity_plausibility(identity, expected_path, executable_required) do
          :ok -> {:ok, identity}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, invalid}
    end
  end

  defp fetch_kernel_binding(bindings) do
    case get_field(bindings, :kernel_identity) do
      nil ->
        {:error, :missing_kernel_identity}

      %Identity{} = identity ->
        with {:ok, _path} <- validate_absolute_canonical_path(identity.path),
             :ok <- validate_identity_plausibility(identity, identity.path, false) do
          {:ok, identity}
        end

      _other ->
        {:error, :invalid_kernel_identity}
    end
  end

  defp fetch_evidence_identity(map, key) do
    case get_field(map, key) do
      nil ->
        {:error, {:missing, key}}

      %Identity{} = identity ->
        {:ok, identity}

      _other ->
        {:error, {:invalid, key}}
    end
  end

  defp fetch_app_root(bindings) do
    case get_field(bindings, :app_root) do
      nil ->
        {:error, :missing_app_root}

      app_root ->
        case validate_absolute_canonical_path(app_root) do
          {:ok, path} -> {:ok, path}
          {:error, reason} -> {:error, {:invalid_app_root, reason}}
        end
    end
  end

  # --- Validation ---

  defp validate_identity_plausibility(
         %Identity{} = identity,
         expected_path,
         executable_required
       ) do
    with :ok <- validate_identity_path_text(identity.path),
         :ok <- validate_identity_metadata(identity),
         :ok <- require_exact(identity.path, expected_path, :identity_path_mismatch),
         :ok <- require_exact(identity.type, :regular, :identity_not_regular_file),
         :ok <- require_exact(identity.uid, 0, :identity_not_root_owned),
         :ok <-
           require_exact(
             identity.executable_required,
             executable_required,
             :identity_executable_flag_mismatch
           ),
         :ok <- validate_mode_permissions(identity.mode, executable_required),
         {:ok, _sha} <- validate_hex64(identity.sha256, :invalid_identity_sha256) do
      :ok
    end
  end

  defp validate_identity_metadata(%Identity{} = identity) do
    fields = [
      identity.device,
      identity.inode,
      identity.size,
      identity.mtime,
      identity.ctime,
      identity.mode,
      identity.uid,
      identity.gid
    ]

    cond do
      not Enum.all?(fields, &(is_integer(&1) and &1 >= 0 and &1 <= @max_metadata_int)) ->
        {:error, :invalid_identity_metadata}

      identity.size > @max_file_bytes ->
        {:error, :identity_file_too_large}

      identity.mode > @max_mode ->
        {:error, :invalid_identity_mode}

      true ->
        :ok
    end
  end

  defp validate_mode_permissions(mode, executable_required) when is_integer(mode) do
    cond do
      (mode &&& 0o022) != 0 ->
        {:error, :identity_group_or_other_writable}

      executable_required and (mode &&& 0o111) == 0 ->
        {:error, :identity_not_executable}

      true ->
        :ok
    end
  end

  defp validate_identity_match(binding, evidence, mismatch) do
    if TrustedPath.same_identity?(binding, evidence) do
      :ok
    else
      {:error, mismatch}
    end
  end

  defp validate_signing(signing, expected_identifier, expected_requirement) do
    with :ok <- require_valid_utf8(signing.identifier),
         :ok <- require_valid_utf8(signing.team_id),
         :ok <- require_valid_utf8(signing.designated_requirement),
         :ok <- require_valid_utf8(signing.verified_against),
         :ok <- require_valid_utf8(signing.status) do
      cond do
        signing.identifier != expected_identifier ->
          {:error, :signing_identifier_mismatch}

        signing.team_id != @team_id ->
          {:error, :signing_team_mismatch}

        signing.designated_requirement != expected_requirement ->
          {:error, :designated_requirement_mismatch}

        signing.verified_against != expected_requirement ->
          {:error, :verified_against_mismatch}

        signing.status != "valid" ->
          {:error, :codesign_not_verified}

        signing.verified_against != signing.designated_requirement ->
          {:error, :codesign_requirement_unbound}

        true ->
          :ok
      end
    end
  end

  defp validate_release_semver(version, invalid) do
    with :ok <- bounded_string(version, @max_version_bytes, :version_too_long),
         :ok <- require_valid_utf8(version),
         :ok <- reject_control_or_whitespace(version, invalid) do
      case Regex.run(@version_re, version) do
        [^version, major_s, minor_s, _patch_s] ->
          major = String.to_integer(major_s)
          minor = String.to_integer(minor_s)

          if major == @compat_major and minor == @compat_minor do
            {:ok, version}
          else
            {:error, :version_not_supported}
          end

        _other ->
          {:error, invalid}
      end
    end
  end

  defp validate_launchd(launchd, app_root) do
    expected_plist_path = app_root <> "/" <> @launchd_plist_relative

    with :ok <- require_valid_utf8(launchd.label),
         :ok <- require_valid_utf8(launchd.path),
         :ok <- require_valid_utf8(launchd.type),
         :ok <- require_valid_utf8(launchd.state),
         :ok <- require_valid_utf8(launchd.program),
         :ok <- require_exact(launchd.label, @launchd_label, :launchd_label_mismatch),
         :ok <- require_exact(launchd.path, expected_plist_path, :launchd_path_mismatch),
         :ok <- require_exact(launchd.type, @launchd_type, :launchd_type_mismatch),
         :ok <- require_exact(launchd.state, @launchd_state, :launchd_state_mismatch),
         :ok <- require_exact(launchd.program, @apiserver_path, :launchd_program_mismatch),
         :ok <- validate_launchd_argv(launchd.argv),
         :ok <-
           validate_environment_section_security(
             launchd.environment,
             :launchd_environment_forbidden
           ),
         :ok <-
           validate_environment_section_security(
             launchd.inherited_environment,
             :launchd_environment_forbidden
           ),
         :ok <-
           validate_environment_section_security(
             launchd.default_environment,
             :launchd_environment_forbidden
           ),
         :ok <- validate_job_environment(launchd.environment, app_root, launchd.label) do
      :ok
    end
  end

  defp validate_launchd_argv(argv) do
    if argv == [@apiserver_path, "start"] do
      :ok
    else
      if Enum.any?(argv, &(&1 == "--debug")) do
        {:error, :launchd_debug_forbidden}
      else
        {:error, :launchd_argv_mismatch}
      end
    end
  end

  # Security scan applied to job, inherited, and default environments before any
  # section is discarded. Proxy / unexpected CONTAINER_ / log-root keys fail closed.
  defp validate_environment_section_security(environment, forbidden_reason)
       when is_map(environment) do
    Enum.reduce_while(Map.keys(environment), :ok, fn key, :ok ->
      if forbidden_environment_key?(key) do
        {:halt, {:error, forbidden_reason}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp forbidden_environment_key?(key) when is_binary(key) do
    downcased = String.downcase(key)

    MapSet.member?(@proxy_env_names, downcased) or
      (String.starts_with?(key, "CONTAINER_") and key not in @required_job_env_keys) or
      (String.contains?(downcased, "log") and String.contains?(downcased, "root"))
  end

  defp validate_job_environment(environment, app_root, label) when is_map(environment) do
    unknown_keys =
      Enum.reject(Map.keys(environment), &MapSet.member?(@allowed_job_env_keys, &1))

    cond do
      unknown_keys != [] ->
        {:error, :launchd_environment_forbidden}

      Map.get(environment, "CONTAINER_APP_ROOT") != app_root ->
        {:error, :launchd_environment_mismatch}

      Map.get(environment, "CONTAINER_INSTALL_ROOT") != @container_install_root_env ->
        {:error, :launchd_environment_mismatch}

      true ->
        with :ok <- validate_optional_xpc_service_name(environment, label),
             :ok <- validate_optional_oslog_rate_limit(environment) do
          :ok
        end
    end
  end

  defp validate_optional_xpc_service_name(environment, label) do
    case Map.fetch(environment, "XPC_SERVICE_NAME") do
      :error ->
        :ok

      {:ok, value} ->
        require_exact(value, label, :launchd_environment_mismatch)
    end
  end

  defp validate_optional_oslog_rate_limit(environment) do
    case Map.fetch(environment, "OSLogRateLimit") do
      :error ->
        :ok

      {:ok, value} when is_binary(value) ->
        with :ok <-
               bounded_string(
                 value,
                 @max_oslog_rate_limit_bytes,
                 :launchd_environment_mismatch
               ),
             :ok <- require_valid_utf8(value) do
          if Regex.match?(@oslog_rate_limit_re, value) do
            :ok
          else
            {:error, :launchd_environment_mismatch}
          end
        end

      _other ->
        {:error, :launchd_environment_mismatch}
    end
  end

  defp validate_plugin_config(config) do
    with :ok <- require_valid_utf8(config.abstract),
         :ok <- require_valid_utf8(config.author),
         :ok <- require_valid_utf8(config.version) do
      expected_services_config = %{
        load_at_boot: false,
        run_at_load: false,
        default_arguments: [],
        services: [%{type: "runtime"}]
      }

      cond do
        config.abstract != @plugin_config_abstract ->
          {:error, :plugin_abstract_mismatch}

        config.author != @plugin_config_author ->
          {:error, :plugin_author_mismatch}

        config.version != @plugin_config_version ->
          {:error, :plugin_config_version_mismatch}

        config.services_config != expected_services_config ->
          {:error, :plugin_services_config_mismatch}

        true ->
          :ok
      end
    end
  end

  defp validate_user_plugin_root(root) do
    with :ok <- require_valid_utf8(root.path),
         :ok <- require_valid_utf8(root.status) do
      cond do
        root.path != @user_plugin_root_path ->
          {:error, :user_plugin_root_path_mismatch}

        root.status != "absent" ->
          {:error, :user_plugin_root_not_absent}

        true ->
          :ok
      end
    end
  end

  # Service status corroborates the already-validated signed API version/build
  # and the owner-bound app root. It never establishes path/signing/version
  # authority and must not track the CLI alone. A non-nil log root is forbidden
  # (Apple propagates CONTAINER_LOG_ROOT into plugin environments).
  defp validate_service_corroboration(
         service,
         signed_api_version,
         signed_api_build,
         bound_app_root
       ) do
    with :ok <- require_valid_utf8(service.status),
         :ok <- require_valid_utf8(service.install_root),
         :ok <- require_valid_utf8(service.apiserver_version),
         :ok <- require_valid_utf8(service.apiserver_build),
         :ok <- require_valid_utf8(service.app_root) do
      cond do
        service.status != "running" ->
          {:error, :service_not_running}

        service.install_root != @install_root ->
          {:error, :install_root_mismatch}

        service.apiserver_version != signed_api_version ->
          {:error, :service_apiserver_version_mismatch}

        service.apiserver_build != signed_api_build ->
          {:error, :service_apiserver_build_mismatch}

        service.app_root != bound_app_root ->
          {:error, :service_app_root_mismatch}

        not is_nil(service.log_root) ->
          {:error, :service_log_root_forbidden}

        true ->
          :ok
      end
    end
  end

  defp build_receipt(bindings, _evidence, cli_version, api_version) do
    safe_job_environment = %{
      "CONTAINER_APP_ROOT" => bindings.app_root,
      "CONTAINER_INSTALL_ROOT" => @container_install_root_env
    }

    %{
      admitted: true,
      app_root: bindings.app_root,
      cli: %{
        path: @cli_path,
        version: cli_version,
        build: @required_build,
        sha256: bindings.cli_identity.sha256,
        signing_identifier: @cli_identifier,
        team_id: @team_id,
        designated_requirement: @cli_requirement,
        codesign_verified: true
      },
      apiserver: %{
        path: @apiserver_path,
        version: api_version,
        build: @required_build,
        sha256: bindings.apiserver_identity.sha256,
        signing_identifier: @apiserver_identifier,
        team_id: @team_id,
        designated_requirement: @apiserver_requirement,
        codesign_verified: true,
        launchd: %{
          label: @launchd_label,
          path: bindings.app_root <> "/" <> @launchd_plist_relative,
          type: @launchd_type,
          state: @launchd_state,
          program: @apiserver_path,
          argv: [@apiserver_path, "start"],
          environment: safe_job_environment,
          inherited_environment_checked: true,
          default_environment_checked: true,
          proxy_free: true
        }
      },
      runtime_plugin: %{
        path: @plugin_path,
        sha256: bindings.runtime_plugin_identity.sha256,
        signing_identifier: @plugin_identifier,
        team_id: @team_id,
        designated_requirement: @plugin_requirement,
        codesign_verified: true,
        config: %{
          path: @plugin_config_path,
          sha256: bindings.runtime_plugin_config_identity.sha256,
          abstract: @plugin_config_abstract,
          author: @plugin_config_author,
          version: @plugin_config_version,
          services_config: %{
            load_at_boot: false,
            run_at_load: false,
            default_arguments: [],
            services: [%{type: "runtime"}]
          }
        }
      },
      user_plugin_root: %{
        path: @user_plugin_root_path,
        status: "absent"
      },
      kernel: %{
        path: bindings.kernel_identity.path,
        sha256: bindings.kernel_identity.sha256
      },
      service: %{
        status: "running",
        install_root: @install_root,
        app_root: bindings.app_root,
        log_root_configured: false,
        corroborated: true
      }
    }
  end

  defp show_signed_binary(binary) do
    %{
      "path" => binary.path,
      "version" => binary.version,
      "build" => binary.build,
      "sha256" => binary.sha256,
      "signing_identifier" => binary.signing_identifier,
      "team_id" => binary.team_id,
      "designated_requirement" => binary.designated_requirement,
      "codesign_verified" => true
    }
  end

  defp show_apiserver(apiserver) do
    show_signed_binary(apiserver)
    |> Map.put("launchd", %{
      "label" => apiserver.launchd.label,
      "path" => apiserver.launchd.path,
      "type" => apiserver.launchd.type,
      "state" => apiserver.launchd.state,
      "program" => apiserver.launchd.program,
      "argv" => apiserver.launchd.argv,
      "environment" => apiserver.launchd.environment,
      "inherited_environment_checked" => apiserver.launchd.inherited_environment_checked,
      "default_environment_checked" => apiserver.launchd.default_environment_checked,
      "proxy_free" => apiserver.launchd.proxy_free
    })
  end

  defp show_runtime_plugin(plugin) do
    %{
      "path" => plugin.path,
      "sha256" => plugin.sha256,
      "signing_identifier" => plugin.signing_identifier,
      "team_id" => plugin.team_id,
      "designated_requirement" => plugin.designated_requirement,
      "codesign_verified" => true,
      "config" => %{
        "path" => plugin.config.path,
        "sha256" => plugin.config.sha256,
        "abstract" => plugin.config.abstract,
        "author" => plugin.config.author,
        "version" => plugin.config.version,
        "services_config" => %{
          "load_at_boot" => false,
          "run_at_load" => false,
          "default_arguments" => [],
          "services" => [%{"type" => "runtime"}]
        }
      }
    }
  end

  # --- Shape / primitive helpers ---

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

  defp fetch_required_map(map, key, missing, invalid) do
    case get_field(map, key) do
      nil -> {:error, missing}
      value when is_map(value) -> {:ok, value}
      _other -> {:error, invalid}
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

  defp validate_hex64(value, invalid) when is_binary(value) do
    with :ok <- bounded_string(value, @max_digest_hex, invalid),
         :ok <- require_valid_utf8(value) do
      cond do
        has_control_or_whitespace?(value) ->
          {:error, invalid}

        Regex.match?(@hex64_re, value) ->
          {:ok, value}

        true ->
          {:error, invalid}
      end
    end
  end

  defp validate_hex64(_, invalid), do: {:error, invalid}

  defp validate_absolute_canonical_path(path) when is_binary(path) do
    cond do
      path == "" ->
        {:error, :empty_path}

      byte_size(path) > @max_path_bytes ->
        {:error, :path_too_long}

      not String.valid?(path) ->
        {:error, :invalid_utf8}

      binary_contains?(path, <<0>>) ->
        {:error, :nul_byte}

      has_control_char?(path) ->
        {:error, :control_char}

      not String.starts_with?(path, "/") ->
        {:error, :relative_path}

      String.contains?(path, "//") ->
        {:error, :non_canonical_path}

      path != "/" and String.ends_with?(path, "/") ->
        {:error, :trailing_slash}

      Enum.any?(Path.split(path), &(&1 in [".", ".."])) ->
        {:error, :dot_segment}

      true ->
        {:ok, path}
    end
  end

  defp validate_absolute_canonical_path(_), do: {:error, :invalid_path}

  defp validate_identity_path_text(path) when is_binary(path) do
    cond do
      byte_size(path) > @max_path_bytes -> {:error, :identity_path_too_long}
      not String.valid?(path) -> {:error, :invalid_utf8}
      true -> :ok
    end
  end

  defp validate_identity_path_text(_path), do: {:error, :invalid_identity_path}

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
