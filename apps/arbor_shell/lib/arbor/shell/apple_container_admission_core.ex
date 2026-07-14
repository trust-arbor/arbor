defmodule Arbor.Shell.AppleContainerAdmissionCore do
  @moduledoc """
  Pure Apple Container admission evidence validation.

  This aggregate core consumes operator-owned immutable image/dependency policy
  plus already-collected bounded evidence, composes the nested control-plane
  admission decision, and returns either a compact admitted receipt or a stable
  fail-closed error. It performs no IO, process execution, filesystem access,
  environment reads, Application config reads, or TrustedPath disk verification.

  Fixed platform authority (macOS 26+/arm64, `/usr/local/bin/container`,
  CLI/API 1.1.x release line, Apple signing identity/requirement) lives inside
  this module and the nested control-plane core - never as caller options.

  Startup-owner control-plane bindings are required separately from probe
  evidence. Nested `evidence.control_plane` is the closed probe surface accepted
  by `AppleContainerControlPlaneAdmissionCore`. Legacy aggregate `runtime` and
  `service_status` fields remain as corroborating compatibility evidence and
  never establish authority over the signed control-plane receipt.

  Do not treat a caller-provided receipt as executable authority. The production
  `Arbor.Shell.execute_spawn_capable/3` facade remains fail-closed until a later
  imperative adapter interprets admitted receipts.
  """

  alias Arbor.Shell.AppleContainerControlPlaneAdmissionCore, as: ControlPlane
  alias Arbor.Shell.LinuxDependencyBaselineCore

  # --- Fixed platform authority (not caller-configurable) ---

  @runtime_path "/usr/local/bin/container"
  @install_root "/usr/local/"
  @required_os "macos"
  @min_os_major 26
  @required_arch "arm64"
  @guest_platform "linux/arm64"
  @compat_major 1
  @compat_minor 1
  @required_build "release"
  @signing_identifier "com.apple.container.cli"
  @team_id "UPBK2H6LZM"

  @designated_requirement ~s(identifier "com.apple.container.cli" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = UPBK2H6LZM)

  @allowed_media_types MapSet.new([
                         "application/vnd.oci.image.index.v1+json",
                         "application/vnd.docker.distribution.manifest.list.v2+json"
                       ])

  @fixed_label_schema "org.arbor.validation.schema"
  @fixed_label_role "org.arbor.validation.role"
  @fixed_label_platform "org.arbor.validation.platform"
  @fixed_label_erlang "org.arbor.validation.erlang"
  @fixed_label_elixir "org.arbor.validation.elixir"
  @fixed_label_mix_lock "org.arbor.validation.mix-lock-sha256"
  @fixed_label_deps_tree "org.arbor.validation.deps-tree-sha256"

  @fixed_schema_value "1"
  @fixed_role_value "spawn-containment"

  # --- Closed request surface ---

  @logical_request_keys [:policy, :evidence]
  @allowed_request_keys MapSet.new(
                          @logical_request_keys ++
                            Enum.map(@logical_request_keys, &Atom.to_string/1)
                        )

  @logical_policy_keys [
    :image,
    :manifest_digest,
    :vminit_image,
    :vminit_manifest_digest,
    :env,
    :labels,
    :mix_lock_digest,
    :baseline_tree_digest,
    :toolchain
  ]
  @allowed_policy_keys MapSet.new(
                         @logical_policy_keys ++ Enum.map(@logical_policy_keys, &Atom.to_string/1)
                       )

  @logical_toolchain_keys [:erlang, :elixir]
  @allowed_toolchain_keys MapSet.new(
                            @logical_toolchain_keys ++
                              Enum.map(@logical_toolchain_keys, &Atom.to_string/1)
                          )

  @logical_evidence_keys [
    :host_platform,
    :runtime,
    :service_status,
    :image_inspect,
    :vminit_image_inspect,
    :dependency_baseline,
    :control_plane
  ]
  @allowed_evidence_keys MapSet.new(
                           @logical_evidence_keys ++
                             Enum.map(@logical_evidence_keys, &Atom.to_string/1)
                         )

  @logical_host_platform_keys [:os, :version, :architecture]
  @allowed_host_platform_keys MapSet.new(
                                @logical_host_platform_keys ++
                                  Enum.map(@logical_host_platform_keys, &Atom.to_string/1)
                              )

  @logical_runtime_keys [:path, :cli_version, :cli_build, :signing, :executable_sha256]
  @allowed_runtime_keys MapSet.new(
                          @logical_runtime_keys ++
                            Enum.map(@logical_runtime_keys, &Atom.to_string/1)
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

  @logical_service_keys [:status, :install_root, :apiserver_version, :apiserver_build]
  @allowed_service_keys MapSet.new(
                          @logical_service_keys ++
                            Enum.map(@logical_service_keys, &Atom.to_string/1)
                        )

  @logical_image_inspect_keys [:configuration, :variants]
  @allowed_image_inspect_keys MapSet.new(
                                @logical_image_inspect_keys ++
                                  Enum.map(@logical_image_inspect_keys, &Atom.to_string/1)
                              )

  @logical_configuration_keys [:descriptor, :name]
  @allowed_configuration_keys MapSet.new(
                                @logical_configuration_keys ++
                                  Enum.map(@logical_configuration_keys, &Atom.to_string/1)
                              )

  @logical_descriptor_keys [:digest, :media_type, :size]
  # Real container 1.1.0 inspect uses camelCase mediaType; accept only one form.
  @allowed_descriptor_keys MapSet.new(
                             @logical_descriptor_keys ++
                               Enum.map(@logical_descriptor_keys, &Atom.to_string/1) ++
                               ["mediaType", :mediaType]
                           )

  @logical_variant_keys [:digest, :platform, :config]
  @allowed_variant_keys MapSet.new(
                          @logical_variant_keys ++
                            Enum.map(@logical_variant_keys, &Atom.to_string/1)
                        )

  @logical_variant_platform_keys [:os, :architecture]
  # Optional OCI variant field (e.g. "v8") - closed allowlist only.
  @optional_variant_platform_keys [:variant]
  @allowed_variant_platform_keys MapSet.new(
                                   @logical_variant_platform_keys ++
                                     Enum.map(@logical_variant_platform_keys, &Atom.to_string/1) ++
                                     @optional_variant_platform_keys ++
                                     Enum.map(@optional_variant_platform_keys, &Atom.to_string/1)
                                 )

  @logical_variant_config_keys [:os, :architecture, :config]
  @optional_variant_config_keys [:variant]
  @allowed_variant_config_keys MapSet.new(
                                 @logical_variant_config_keys ++
                                   Enum.map(@logical_variant_config_keys, &Atom.to_string/1) ++
                                   @optional_variant_config_keys ++
                                   Enum.map(@optional_variant_config_keys, &Atom.to_string/1)
                               )

  # Allow atom forms for Env/Labels only when string forms are absent.
  @allowed_image_config_keys MapSet.new([
                               :Env,
                               :Labels,
                               "Env",
                               "Labels",
                               :env,
                               :labels,
                               "env",
                               "labels"
                             ])

  # dependency_baseline evidence is the compact receipt from
  # LinuxDependencyBaselineCore.show/1 / normalize_compact_receipt/1.
  # Closed-key validation lives in that core (no provisioning/status/mode).

  # --- Bounds ---

  @max_map_keys 64
  @max_image_bytes 512
  @max_repository_bytes 255
  @max_digest_hex 64
  @max_version_bytes 64
  @max_toolchain_version_bytes 64
  @max_path_bytes 4_096
  @max_env_entries 64
  @max_env_entry_bytes 4_096
  @max_label_keys 32
  @max_label_key_bytes 256
  @max_label_value_bytes 1_024
  @max_variants 16
  @max_media_type_bytes 256
  @max_oci_variant_bytes 32
  @max_apiserver_version_bytes 256
  @max_name_bytes 512
  @max_signing_field_bytes 1_024
  @max_status_bytes 64
  @max_descriptor_size 1_073_741_824
  @required_arm64_variant "v8"

  # Deterministic local-only execution aliases (derived from index digests;
  # never accepted as independent policy source references).
  @local_alias_registry "127.0.0.1:0"
  @workload_alias_repository "arbor/workload"
  @vminit_alias_repository "arbor/vminit"

  # Fully-qualified immutable image: registry hostname with at least one '.'
  # (optionally :port) + repository path + digest. Hosts without a dot
  # (e.g. registry/arbor/...) are default-registry-ambiguous and rejected.
  @image_re ~r/\A([a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+(?::[0-9]+)?(?:\/[a-z0-9]+(?:[._-][a-z0-9]+)*)+)@sha256:([0-9a-f]{64})\z/
  @digest_re ~r/\Asha256:([0-9a-f]{64})\z/
  @hex64_re ~r/\A[0-9a-f]{64}\z/
  @version_re ~r/\A(\d+)\.(\d+)\.(\d+)\z/
  @os_version_re ~r/\A(\d+)(?:\.(\d+))?(?:\.(\d+))?\z/
  @apiserver_version_re ~r/\Acontainer-apiserver version (\d+\.\d+\.\d+) \(build: release, commit: ([0-9a-zA-Z._-]{1,64})\)\z/
  @env_entry_re ~r/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/s
  @toolchain_version_re ~r/\A[A-Za-z0-9][A-Za-z0-9._+-]{0,62}\z/

  @type receipt :: %{
          admitted: true,
          platform: %{os: String.t(), version: String.t(), architecture: String.t()},
          runtime: %{
            path: String.t(),
            cli_version: String.t(),
            api_version: String.t(),
            build: String.t(),
            executable_sha256: String.t(),
            signing_identifier: String.t(),
            team_id: String.t(),
            designated_requirement: String.t(),
            codesign_verified: true
          },
          service: %{
            status: String.t(),
            install_root: String.t(),
            app_root: String.t(),
            log_root_configured: false
          },
          control_plane: ControlPlane.receipt(),
          image: %{
            reference: String.t(),
            execution_reference: String.t(),
            index_digest: String.t(),
            manifest_digest: String.t(),
            platform: String.t(),
            env: [String.t()],
            labels: %{optional(String.t()) => String.t()}
          },
          vminit: %{
            reference: String.t(),
            execution_reference: String.t(),
            index_digest: String.t(),
            manifest_digest: String.t(),
            platform: String.t()
          },
          toolchain: %{erlang: String.t(), elixir: String.t()},
          dependency_baseline: %{
            schema: String.t(),
            platform: String.t(),
            image_index_digest: String.t(),
            image_manifest_digest: String.t(),
            mix_lock_digest: String.t(),
            baseline_tree_digest: String.t(),
            toolchain: %{erlang: String.t(), elixir: String.t()},
            entry_count: non_neg_integer(),
            total_bytes: non_neg_integer()
          }
        }

  @type execution_references :: %{
          image: %{
            reference: String.t(),
            execution_reference: String.t(),
            index_digest: String.t(),
            manifest_digest: String.t()
          },
          vminit: %{
            reference: String.t(),
            execution_reference: String.t(),
            index_digest: String.t(),
            manifest_digest: String.t()
          }
        }

  @doc """
  Legacy single-argument constructor. Always fails closed.

  Control-plane startup bindings are required authority and cannot be omitted
  or embedded in probe evidence. Call `new/2` with owner-issued bindings.
  """
  @spec new(term()) :: {:error, :control_plane_bindings_required}
  def new(_input), do: {:error, :control_plane_bindings_required}

  @doc """
  Construct and validate an admission receipt from policy + bounded evidence
  plus startup-owner control-plane bindings.

  `control_plane_bindings` is owner-bound identity authority passed unchanged to
  `ControlPlane.new/2`. Nested `evidence.control_plane` is the closed control-plane
  probe surface. Returns `{:ok, receipt}` only when every aggregate bound field
  and the nested control-plane admission succeed and are mutually consistent.
  Fails closed on partial, oversized, malformed, or mismatched evidence.
  """
  @spec new(term(), term()) :: {:ok, receipt()} | {:error, term()}
  def new(input, control_plane_bindings) when is_map(input) do
    with :ok <-
           validate_closed_keys(input, @allowed_request_keys, @logical_request_keys, :request),
         {:ok, policy} <- fetch_required_map(input, :policy, :missing_policy, :invalid_policy),
         {:ok, evidence} <-
           fetch_required_map(input, :evidence, :missing_evidence, :invalid_evidence),
         :ok <-
           validate_closed_keys(
             evidence,
             @allowed_evidence_keys,
             @logical_evidence_keys,
             :evidence
           ),
         {:ok, normalized_policy} <- normalize_closed_policy(policy),
         {:ok, host_platform} <- fetch_host_platform(evidence),
         {:ok, runtime} <- fetch_runtime(evidence),
         {:ok, service} <- fetch_service_status(evidence),
         {:ok, control_plane_evidence} <- fetch_control_plane_evidence(evidence),
         {:ok, image_inspect} <- fetch_image_inspect(evidence),
         {:ok, vminit_image_inspect} <- fetch_vminit_image_inspect(evidence),
         {:ok, baseline} <- fetch_dependency_baseline(evidence),
         :ok <- validate_host_platform(host_platform),
         {:ok, cli_version, api_version, executable_sha256} <-
           validate_runtime_and_service(runtime, service),
         {:ok, image_fields} <- validate_workload_image(normalized_policy, image_inspect),
         {:ok, vminit_fields} <- validate_vminit_image(normalized_policy, vminit_image_inspect),
         {:ok, baseline_fields} <-
           validate_dependency_baseline(normalized_policy, baseline, image_fields),
         {:ok, child_receipt} <- ControlPlane.new(control_plane_bindings, control_plane_evidence),
         :ok <-
           cross_check_control_plane(
             runtime,
             service,
             cli_version,
             api_version,
             executable_sha256,
             child_receipt
           ) do
      receipt = %{
        admitted: true,
        platform: %{
          os: @required_os,
          version: host_platform.version,
          architecture: @required_arch
        },
        # Runtime/service authority comes from the admitted control-plane child,
        # not from unbound aggregate corroboration fields alone.
        runtime: %{
          path: child_receipt.cli.path,
          cli_version: child_receipt.cli.version,
          api_version: child_receipt.apiserver.version,
          build: child_receipt.cli.build,
          executable_sha256: child_receipt.cli.sha256,
          signing_identifier: child_receipt.cli.signing_identifier,
          team_id: child_receipt.cli.team_id,
          designated_requirement: child_receipt.cli.designated_requirement,
          codesign_verified: true
        },
        service: %{
          status: child_receipt.service.status,
          install_root: child_receipt.service.install_root,
          app_root: child_receipt.service.app_root,
          log_root_configured: false
        },
        control_plane: child_receipt,
        image: image_fields,
        vminit: vminit_fields,
        toolchain: normalized_policy.toolchain,
        dependency_baseline: baseline_fields
      }

      {:ok, receipt}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  def new(_input, _control_plane_bindings), do: {:error, :invalid_request}

  @doc """
  Pure preflight: derive normalized workload/vminit execution aliases from the
  closed operator policy map.

  Reuses the same closed-policy normalization path as `new/2` so local execution
  references cannot drift from admission receipts. Accepts policy only (not a
  full request). Performs no IO, config, env, process, or authority checks.
  """
  @spec execution_references(term()) :: {:ok, execution_references()} | {:error, term()}
  def execution_references(policy) when is_map(policy) do
    with {:ok, normalized} <- normalize_closed_policy(policy) do
      {:ok,
       %{
         image: %{
           reference: normalized.image,
           execution_reference: derive_execution_alias(:workload, normalized.index_digest),
           index_digest: normalized.index_digest,
           manifest_digest: normalized.manifest_digest
         },
         vminit: %{
           reference: normalized.vminit_image,
           execution_reference: derive_execution_alias(:vminit, normalized.vminit_index_digest),
           index_digest: normalized.vminit_index_digest,
           manifest_digest: normalized.vminit_manifest_digest
         }
       }}
    end
  rescue
    _ -> {:error, :invalid_policy}
  end

  def execution_references(_), do: {:error, :invalid_policy}

  @doc """
  Convert an admission receipt to a JSON-clean map (no raw command output).
  """
  @spec show(receipt()) :: map()
  def show(%{admitted: true} = receipt) do
    %{
      "admitted" => true,
      "platform" => %{
        "os" => receipt.platform.os,
        "version" => receipt.platform.version,
        "architecture" => receipt.platform.architecture
      },
      "runtime" => %{
        "path" => receipt.runtime.path,
        "cli_version" => receipt.runtime.cli_version,
        "api_version" => receipt.runtime.api_version,
        "build" => receipt.runtime.build,
        "executable_sha256" => receipt.runtime.executable_sha256,
        "signing_identifier" => receipt.runtime.signing_identifier,
        "team_id" => receipt.runtime.team_id,
        "designated_requirement" => receipt.runtime.designated_requirement,
        "codesign_verified" => true
      },
      "service" => %{
        "status" => receipt.service.status,
        "install_root" => receipt.service.install_root,
        "app_root" => receipt.service.app_root,
        "log_root_configured" => false
      },
      "control_plane" => ControlPlane.show(receipt.control_plane),
      "image" => %{
        "reference" => receipt.image.reference,
        "execution_reference" => receipt.image.execution_reference,
        "index_digest" => receipt.image.index_digest,
        "manifest_digest" => receipt.image.manifest_digest,
        "platform" => receipt.image.platform,
        "env" => receipt.image.env,
        "labels" => receipt.image.labels
      },
      "vminit" => %{
        "reference" => receipt.vminit.reference,
        "execution_reference" => receipt.vminit.execution_reference,
        "index_digest" => receipt.vminit.index_digest,
        "manifest_digest" => receipt.vminit.manifest_digest,
        "platform" => receipt.vminit.platform
      },
      "toolchain" => %{
        "erlang" => receipt.toolchain.erlang,
        "elixir" => receipt.toolchain.elixir
      },
      "dependency_baseline" => %{
        "schema" => receipt.dependency_baseline.schema,
        "platform" => receipt.dependency_baseline.platform,
        "image_index_digest" => receipt.dependency_baseline.image_index_digest,
        "image_manifest_digest" => receipt.dependency_baseline.image_manifest_digest,
        "mix_lock_digest" => receipt.dependency_baseline.mix_lock_digest,
        "baseline_tree_digest" => receipt.dependency_baseline.baseline_tree_digest,
        "toolchain" => %{
          "erlang" => receipt.dependency_baseline.toolchain.erlang,
          "elixir" => receipt.dependency_baseline.toolchain.elixir
        },
        "entry_count" => receipt.dependency_baseline.entry_count,
        "total_bytes" => receipt.dependency_baseline.total_bytes
      }
    }
  end

  @doc "Fixed runtime executable path required for admission."
  @spec runtime_path() :: String.t()
  def runtime_path, do: @runtime_path

  @doc "Fixed install root required in service-status evidence."
  @spec install_root() :: String.t()
  def install_root, do: @install_root

  @doc "Fixed Apple designated requirement for the container CLI."
  @spec designated_requirement() :: String.t()
  def designated_requirement, do: @designated_requirement

  @doc "Fixed Apple signing identifier for the container CLI."
  @spec signing_identifier() :: String.t()
  def signing_identifier, do: @signing_identifier

  @doc "Fixed Apple team identifier for the container CLI."
  @spec team_id() :: String.t()
  def team_id, do: @team_id

  @doc "Required guest/image platform string."
  @spec guest_platform() :: String.t()
  def guest_platform, do: @guest_platform

  # --- Field extraction ---

  # Shared closed-policy path for new/2 and execution_references/1 so derived
  # local aliases cannot drift from admission receipts.
  defp normalize_closed_policy(policy) do
    with :ok <- validate_closed_keys(policy, @allowed_policy_keys, @logical_policy_keys, :policy),
         {:ok, normalized} <- normalize_policy(policy) do
      {:ok, normalized}
    end
  end

  defp normalize_policy(policy) do
    with {:ok, image} <- fetch_policy_image(policy),
         {:ok, manifest_digest} <- fetch_policy_manifest_digest(policy),
         {:ok, vminit_image} <- fetch_policy_vminit_image(policy),
         {:ok, vminit_manifest_digest} <- fetch_policy_vminit_manifest_digest(policy),
         {:ok, env} <- fetch_policy_env(policy),
         {:ok, labels} <- fetch_policy_labels(policy),
         {:ok, mix_lock_digest} <-
           fetch_hex64_field(policy, :mix_lock_digest, :missing_mix_lock_digest),
         {:ok, baseline_tree_digest} <-
           fetch_hex64_field(policy, :baseline_tree_digest, :missing_baseline_tree_digest),
         {:ok, toolchain} <- fetch_policy_toolchain(policy),
         :ok <-
           validate_fixed_attestation_labels(
             labels,
             toolchain,
             mix_lock_digest,
             baseline_tree_digest
           ) do
      index_digest = "sha256:" <> image_digest(image)
      vminit_index_digest = "sha256:" <> image_digest(vminit_image)

      with :ok <-
             validate_distinct_workload_vminit(
               image,
               index_digest,
               manifest_digest,
               vminit_image,
               vminit_index_digest,
               vminit_manifest_digest
             ) do
        {:ok,
         %{
           image: image,
           index_digest: index_digest,
           manifest_digest: manifest_digest,
           vminit_image: vminit_image,
           vminit_index_digest: vminit_index_digest,
           vminit_manifest_digest: vminit_manifest_digest,
           env: env,
           labels: labels,
           mix_lock_digest: mix_lock_digest,
           baseline_tree_digest: baseline_tree_digest,
           toolchain: toolchain
         }}
      end
    end
  end

  defp fetch_policy_image(policy) do
    case get_field(policy, :image) do
      nil -> {:error, :missing_image}
      image -> validate_external_source_image(image, :invalid_image)
    end
  end

  defp fetch_policy_manifest_digest(policy) do
    case get_field(policy, :manifest_digest) do
      nil -> {:error, :missing_manifest_digest}
      digest -> validate_digest(digest, :invalid_manifest_digest)
    end
  end

  defp fetch_policy_vminit_image(policy) do
    case get_field(policy, :vminit_image) do
      nil -> {:error, :missing_vminit_image}
      image -> validate_external_source_image(image, :invalid_vminit_image)
    end
  end

  defp fetch_policy_vminit_manifest_digest(policy) do
    case get_field(policy, :vminit_manifest_digest) do
      nil -> {:error, :missing_vminit_manifest_digest}
      digest -> validate_digest(digest, :invalid_vminit_manifest_digest)
    end
  end

  # Source refs, index digests, and selected manifests for workload vs vminit
  # must be pairwise distinct so one image cannot satisfy both roles.
  defp validate_distinct_workload_vminit(
         image,
         index_digest,
         manifest_digest,
         vminit_image,
         vminit_index_digest,
         vminit_manifest_digest
       ) do
    cond do
      image == vminit_image ->
        {:error, :workload_vminit_image_collision}

      index_digest == vminit_index_digest ->
        {:error, :workload_vminit_index_collision}

      manifest_digest == vminit_manifest_digest ->
        {:error, :workload_vminit_manifest_collision}

      index_digest == manifest_digest ->
        {:error, :workload_index_manifest_collision}

      vminit_index_digest == vminit_manifest_digest ->
        {:error, :vminit_index_manifest_collision}

      index_digest == vminit_manifest_digest ->
        {:error, :workload_vminit_digest_collision}

      manifest_digest == vminit_index_digest ->
        {:error, :workload_vminit_digest_collision}

      true ->
        :ok
    end
  end

  defp fetch_policy_env(policy) do
    case get_field(policy, :env) do
      nil -> {:error, :missing_env}
      env -> validate_env_list(env, :invalid_env)
    end
  end

  defp fetch_policy_labels(policy) do
    case get_field(policy, :labels) do
      nil -> {:error, :missing_labels}
      labels -> validate_labels_map(labels, :invalid_labels)
    end
  end

  defp fetch_policy_toolchain(policy) do
    with {:ok, toolchain} <-
           fetch_required_map(policy, :toolchain, :missing_toolchain, :invalid_toolchain),
         :ok <-
           validate_closed_keys(
             toolchain,
             @allowed_toolchain_keys,
             @logical_toolchain_keys,
             :toolchain
           ),
         {:ok, erlang} <-
           require_bounded_binary_field(
             toolchain,
             :erlang,
             @max_toolchain_version_bytes,
             :missing_toolchain_erlang,
             :invalid_toolchain_erlang,
             :toolchain_erlang_too_long
           ),
         {:ok, elixir} <-
           require_bounded_binary_field(
             toolchain,
             :elixir,
             @max_toolchain_version_bytes,
             :missing_toolchain_elixir,
             :invalid_toolchain_elixir,
             :toolchain_elixir_too_long
           ),
         :ok <- require_valid_utf8(erlang),
         :ok <- require_valid_utf8(elixir),
         :ok <- reject_control_or_whitespace(erlang, :unsafe_toolchain_erlang),
         :ok <- reject_control_or_whitespace(elixir, :unsafe_toolchain_elixir),
         :ok <- validate_toolchain_version(erlang, :invalid_toolchain_erlang),
         :ok <- validate_toolchain_version(elixir, :invalid_toolchain_elixir) do
      {:ok, %{erlang: erlang, elixir: elixir}}
    end
  end

  defp validate_toolchain_version(value, invalid) do
    if Regex.match?(@toolchain_version_re, value), do: :ok, else: {:error, invalid}
  end

  defp validate_fixed_attestation_labels(labels, toolchain, mix_lock_digest, baseline_tree_digest) do
    required = %{
      @fixed_label_schema => @fixed_schema_value,
      @fixed_label_role => @fixed_role_value,
      @fixed_label_platform => @guest_platform,
      @fixed_label_erlang => toolchain.erlang,
      @fixed_label_elixir => toolchain.elixir,
      @fixed_label_mix_lock => mix_lock_digest,
      @fixed_label_deps_tree => baseline_tree_digest
    }

    Enum.reduce_while(required, :ok, fn {key, expected}, :ok ->
      case Map.fetch(labels, key) do
        :error ->
          {:halt, {:error, :missing_fixed_attestation_label}}

        {:ok, ^expected} ->
          {:cont, :ok}

        {:ok, _other} ->
          {:halt, {:error, :fixed_attestation_label_mismatch}}
      end
    end)
  end

  defp fetch_hex64_field(map, key, missing) do
    case get_field(map, key) do
      nil -> {:error, missing}
      value -> validate_hex64(value, {:invalid, key})
    end
  end

  defp fetch_host_platform(evidence) do
    with {:ok, platform} <-
           fetch_required_map(
             evidence,
             :host_platform,
             :missing_host_platform,
             :invalid_host_platform
           ),
         :ok <-
           validate_closed_keys(
             platform,
             @allowed_host_platform_keys,
             @logical_host_platform_keys,
             :host_platform
           ) do
      with {:ok, os} <-
             require_bounded_binary_field(
               platform,
               :os,
               @max_version_bytes,
               :missing_host_os,
               :invalid_host_os,
               :host_os_too_long
             ),
           {:ok, version} <-
             require_bounded_binary_field(
               platform,
               :version,
               @max_version_bytes,
               :missing_host_version,
               :invalid_host_version,
               :host_version_too_long
             ),
           {:ok, architecture} <-
             require_bounded_binary_field(
               platform,
               :architecture,
               @max_version_bytes,
               :missing_host_architecture,
               :invalid_host_architecture,
               :host_architecture_too_long
             ) do
        {:ok, %{os: os, version: version, architecture: architecture}}
      end
    end
  end

  defp fetch_runtime(evidence) do
    with {:ok, runtime} <-
           fetch_required_map(evidence, :runtime, :missing_runtime, :invalid_runtime),
         :ok <-
           validate_closed_keys(runtime, @allowed_runtime_keys, @logical_runtime_keys, :runtime),
         {:ok, path} <-
           require_bounded_binary_field(
             runtime,
             :path,
             @max_path_bytes,
             :missing_runtime_path,
             :invalid_runtime_path,
             :runtime_path_too_long
           ),
         {:ok, cli_version} <-
           require_bounded_binary_field(
             runtime,
             :cli_version,
             @max_version_bytes,
             :missing_cli_version,
             :invalid_cli_version,
             :cli_version_too_long
           ),
         {:ok, cli_build} <-
           require_bounded_binary_field(
             runtime,
             :cli_build,
             @max_status_bytes,
             :missing_cli_build,
             :invalid_cli_build,
             :cli_build_too_long
           ),
         {:ok, executable_sha256} <-
           require_bounded_binary_field(
             runtime,
             :executable_sha256,
             @max_digest_hex,
             :missing_executable_sha256,
             :invalid_executable_sha256,
             :executable_sha256_too_long
           ),
         {:ok, executable_sha256} <-
           validate_hex64(executable_sha256, :invalid_executable_sha256),
         {:ok, signing} <-
           fetch_required_map(runtime, :signing, :missing_signing, :invalid_signing),
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
         path: path,
         cli_version: cli_version,
         cli_build: cli_build,
         executable_sha256: executable_sha256,
         signing: %{
           identifier: identifier,
           team_id: team_id,
           designated_requirement: designated_requirement,
           verified_against: verified_against,
           status: status
         }
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
             @max_apiserver_version_bytes,
             :missing_apiserver_version,
             :invalid_apiserver_version,
             :apiserver_version_too_long
           ),
         {:ok, apiserver_build} <-
           require_bounded_binary_field(
             service,
             :apiserver_build,
             @max_status_bytes,
             :missing_apiserver_build,
             :invalid_apiserver_build,
             :apiserver_build_too_long
           ) do
      {:ok,
       %{
         status: status,
         install_root: install_root,
         apiserver_version: apiserver_version,
         apiserver_build: apiserver_build
       }}
    end
  end

  defp fetch_image_inspect(evidence) do
    fetch_role_image_inspect(evidence, :image_inspect, :workload)
  end

  defp fetch_vminit_image_inspect(evidence) do
    fetch_role_image_inspect(evidence, :vminit_image_inspect, :vminit)
  end

  # Workload and vminit inspect share the closed configuration/variants surface.
  # Role only selects missing/invalid error atoms and variant config semantics.
  defp fetch_role_image_inspect(evidence, evidence_key, role)
       when role in [:workload, :vminit] do
    {scope, missing_inspect, invalid_inspect, missing_config, invalid_config, missing_descriptor,
     invalid_descriptor, missing_name, invalid_name, name_too_long, missing_variants,
     invalid_variants, too_many_variants} = inspect_error_atoms(role)

    with {:ok, inspect} <-
           fetch_required_map(evidence, evidence_key, missing_inspect, invalid_inspect),
         :ok <-
           validate_closed_keys(
             inspect,
             @allowed_image_inspect_keys,
             @logical_image_inspect_keys,
             scope
           ),
         {:ok, configuration} <-
           fetch_required_map(
             inspect,
             :configuration,
             missing_config,
             invalid_config
           ),
         :ok <-
           validate_closed_keys(
             configuration,
             @allowed_configuration_keys,
             @logical_configuration_keys,
             configuration_scope(role)
           ),
         {:ok, descriptor} <-
           fetch_required_map(
             configuration,
             :descriptor,
             missing_descriptor,
             invalid_descriptor
           ),
         :ok <- validate_descriptor_keys(descriptor),
         {:ok, digest} <- fetch_descriptor_digest(descriptor),
         {:ok, media_type} <- fetch_descriptor_media_type(descriptor),
         {:ok, size} <- fetch_descriptor_size(descriptor),
         {:ok, name} <-
           require_bounded_binary_field(
             configuration,
             :name,
             @max_name_bytes,
             missing_name,
             invalid_name,
             name_too_long
           ),
         {:ok, variants} <-
           fetch_variants(
             inspect,
             role,
             missing_variants,
             invalid_variants,
             too_many_variants
           ) do
      {:ok,
       %{
         configuration: %{
           descriptor: %{digest: digest, media_type: media_type, size: size},
           name: name
         },
         variants: variants
       }}
    end
  end

  defp inspect_error_atoms(:workload) do
    {:image_inspect, :missing_image_inspect, :invalid_image_inspect, :missing_image_configuration,
     :invalid_image_configuration, :missing_image_descriptor, :invalid_image_descriptor,
     :missing_image_name, :invalid_image_name, :image_name_too_long, :missing_variants,
     :invalid_variants, :too_many_variants}
  end

  defp inspect_error_atoms(:vminit) do
    {:vminit_image_inspect, :missing_vminit_image_inspect, :invalid_vminit_image_inspect,
     :missing_vminit_image_configuration, :invalid_vminit_image_configuration,
     :missing_vminit_image_descriptor, :invalid_vminit_image_descriptor,
     :missing_vminit_image_name, :invalid_vminit_image_name, :vminit_image_name_too_long,
     :missing_vminit_variants, :invalid_vminit_variants, :too_many_vminit_variants}
  end

  defp configuration_scope(:workload), do: :image_configuration
  defp configuration_scope(:vminit), do: :vminit_image_configuration

  defp fetch_variants(inspect, role, missing_variants, invalid_variants, too_many_variants) do
    case get_field(inspect, :variants) do
      nil ->
        {:error, missing_variants}

      variants when is_list(variants) ->
        case take_bounded(variants, @max_variants) do
          :too_many ->
            {:error, too_many_variants}

          {:ok, []} ->
            {:error, missing_variants}

          {:ok, bounded} ->
            if Enum.all?(bounded, &is_map/1) do
              Enum.reduce_while(bounded, {:ok, []}, fn variant, {:ok, acc} ->
                case normalize_variant(variant, role) do
                  {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
                  {:error, reason} -> {:halt, {:error, reason}}
                end
              end)
              |> case do
                {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
                error -> error
              end
            else
              {:error, invalid_variants}
            end
        end

      _other ->
        {:error, invalid_variants}
    end
  end

  defp normalize_variant(variant, role) when is_map(variant) and role in [:workload, :vminit] do
    with :ok <-
           validate_closed_keys(variant, @allowed_variant_keys, @logical_variant_keys, :variant),
         {:ok, digest} <- fetch_variant_digest(variant),
         {:ok, platform} <-
           fetch_required_map(
             variant,
             :platform,
             :missing_variant_platform,
             :invalid_variant_platform
           ),
         :ok <- validate_variant_platform_keys(platform),
         {:ok, platform_os} <-
           require_bounded_binary_field(
             platform,
             :os,
             @max_version_bytes,
             :missing_variant_os,
             :invalid_variant_os,
             :variant_os_too_long
           ),
         {:ok, platform_arch} <-
           require_bounded_binary_field(
             platform,
             :architecture,
             @max_version_bytes,
             :missing_variant_architecture,
             :invalid_variant_architecture,
             :variant_architecture_too_long
           ),
         {:ok, platform_variant} <- fetch_optional_oci_variant(platform),
         {:ok, config} <-
           fetch_required_map(variant, :config, :missing_variant_config, :invalid_variant_config),
         :ok <- validate_variant_config_keys(config),
         {:ok, config_os} <-
           require_bounded_binary_field(
             config,
             :os,
             @max_version_bytes,
             :missing_variant_config_os,
             :invalid_variant_config_os,
             :variant_config_os_too_long
           ),
         {:ok, config_arch} <-
           require_bounded_binary_field(
             config,
             :architecture,
             @max_version_bytes,
             :missing_variant_config_architecture,
             :invalid_variant_config_architecture,
             :variant_config_architecture_too_long
           ),
         {:ok, config_variant} <- fetch_optional_oci_variant(config),
         {:ok, role_config} <- normalize_variant_role_config(config, role) do
      {:ok,
       %{
         digest: digest,
         platform: %{os: platform_os, architecture: platform_arch, variant: platform_variant},
         config:
           Map.merge(
             %{
               os: config_os,
               architecture: config_arch,
               variant: config_variant
             },
             role_config
           )
       }}
    end
  end

  # Workload variants carry exact Env/Labels for attestation match.
  # Vminit variants only need platform/digest evidence; nested image config is
  # optional bounded digest evidence and is never workload-attested.
  defp normalize_variant_role_config(config, :workload) do
    with {:ok, image_config} <-
           fetch_required_map(
             config,
             :config,
             :missing_image_config,
             :invalid_image_config
           ),
         :ok <- validate_image_config_keys(image_config),
         {:ok, env} <- fetch_image_config_env(image_config),
         {:ok, labels} <- fetch_image_config_labels(image_config) do
      {:ok, %{env: env, labels: labels}}
    end
  end

  defp normalize_variant_role_config(config, :vminit) do
    case get_field(config, :config) do
      nil ->
        {:ok, %{}}

      image_config when is_map(image_config) ->
        with :ok <- validate_image_config_keys(image_config),
             :ok <- validate_optional_vminit_image_config(image_config) do
          {:ok, %{}}
        end

      _other ->
        {:error, :invalid_image_config}
    end
  end

  # If a vminit inspect carries Env/Labels, accept only closed/bounded shapes
  # as evidence; never match them against workload attestation policy.
  defp validate_optional_vminit_image_config(image_config) do
    with :ok <- maybe_validate_optional_env(image_config),
         :ok <- maybe_validate_optional_labels(image_config) do
      :ok
    end
  end

  defp maybe_validate_optional_env(image_config) do
    case fetch_env_or_labels_field(image_config, :Env, :env) do
      :missing ->
        :ok

      :ambiguous ->
        {:error, :ambiguous_env_alias}

      {:ok, env} ->
        case validate_env_list(env, :invalid_image_env) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp maybe_validate_optional_labels(image_config) do
    case fetch_env_or_labels_field(image_config, :Labels, :labels) do
      :missing ->
        :ok

      :ambiguous ->
        {:error, :ambiguous_labels_alias}

      {:ok, labels} ->
        case validate_labels_map(labels, :invalid_image_labels) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  # Optional OCI platform/config "variant" (e.g. arm64 "v8"). Absent stays nil;
  # present values are small, valid UTF-8, control/whitespace-free binaries only.
  defp fetch_optional_oci_variant(map) when is_map(map) do
    case get_field(map, :variant) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        with :ok <- bounded_string(value, @max_oci_variant_bytes, :variant_too_long),
             :ok <- require_valid_utf8(value),
             :ok <- reject_control_or_whitespace(value, :unsafe_variant) do
          {:ok, value}
        end

      _other ->
        {:error, :invalid_variant}
    end
  end

  defp fetch_variant_digest(variant) do
    fetch_digest_field(
      variant,
      :digest,
      :missing_variant_digest,
      :invalid_variant_digest
    )
  end

  defp fetch_digest_field(map, key, missing, invalid) do
    case get_field(map, key) do
      nil -> {:error, missing}
      value -> validate_digest(value, invalid)
    end
  end

  defp fetch_image_config_env(image_config) do
    case fetch_env_or_labels_field(image_config, :Env, :env) do
      :ambiguous -> {:error, :ambiguous_env_alias}
      :missing -> {:error, :missing_image_env}
      {:ok, env} -> validate_env_list(env, :invalid_image_env)
    end
  end

  defp fetch_image_config_labels(image_config) do
    case fetch_env_or_labels_field(image_config, :Labels, :labels) do
      :ambiguous -> {:error, :ambiguous_labels_alias}
      :missing -> {:error, :missing_image_labels}
      {:ok, labels} -> validate_labels_map(labels, :invalid_image_labels)
    end
  end

  # Env/Labels appear as OCI capital forms; reject dual aliases.
  defp fetch_env_or_labels_field(map, primary, secondary) do
    keys = [
      primary,
      Atom.to_string(primary),
      secondary,
      Atom.to_string(secondary)
    ]

    present = Enum.filter(keys, &Map.has_key?(map, &1))

    case present do
      [] ->
        :missing

      [one] ->
        {:ok, Map.fetch!(map, one)}

      _many ->
        :ambiguous
    end
  end

  # Nested control-plane evidence is passed through to ControlPlane unchanged.
  # Do not accept a caller-provided child receipt as authority.
  defp fetch_control_plane_evidence(evidence) do
    fetch_required_map(
      evidence,
      :control_plane,
      :missing_control_plane,
      :invalid_control_plane
    )
  end

  # Compact baseline receipt only — structure via LinuxDependencyBaselineCore.
  # Provenance still comes from the startup authority; result is evidence only.
  defp fetch_dependency_baseline(evidence) do
    with {:ok, baseline} <-
           fetch_required_map(
             evidence,
             :dependency_baseline,
             :missing_dependency_baseline,
             :invalid_dependency_baseline
           ),
         {:ok, compact} <- LinuxDependencyBaselineCore.normalize_compact_receipt(baseline) do
      {:ok,
       %{
         schema: compact["schema"],
         platform: compact["platform"],
         image_index_digest: compact["image_index_digest"],
         image_manifest_digest: compact["image_manifest_digest"],
         mix_lock_digest: compact["mix_lock_digest"],
         baseline_tree_digest: compact["baseline_tree_digest"],
         toolchain: %{
           erlang: compact["toolchain"]["erlang"],
           elixir: compact["toolchain"]["elixir"]
         },
         entry_count: compact["entry_count"],
         total_bytes: compact["total_bytes"]
       }}
    end
  end

  # --- Validators ---

  defp validate_host_platform(%{os: os, version: version, architecture: architecture}) do
    with :ok <- require_valid_utf8(os),
         :ok <- require_valid_utf8(version),
         :ok <- require_valid_utf8(architecture),
         :ok <- reject_control_or_whitespace(os, :unsafe_host_os),
         :ok <- reject_control_or_whitespace(version, :unsafe_host_version),
         :ok <- reject_control_or_whitespace(architecture, :unsafe_host_architecture) do
      cond do
        os != @required_os ->
          {:error, :platform_os_not_supported}

        architecture != @required_arch ->
          {:error, :platform_architecture_not_supported}

        true ->
          case parse_os_major(version) do
            {:ok, major} when major >= @min_os_major ->
              :ok

            {:ok, _major} ->
              {:error, :platform_os_version_too_old}

            :error ->
              {:error, :invalid_host_version}
          end
      end
    end
  end

  defp validate_runtime_and_service(runtime, service) do
    with :ok <- require_valid_utf8(runtime.path),
         :ok <- require_valid_utf8(runtime.cli_version),
         :ok <- require_valid_utf8(runtime.cli_build),
         :ok <- require_valid_utf8(runtime.signing.identifier),
         :ok <- require_valid_utf8(runtime.signing.team_id),
         :ok <- require_valid_utf8(runtime.signing.designated_requirement),
         :ok <- require_valid_utf8(runtime.signing.verified_against),
         :ok <- require_valid_utf8(runtime.signing.status),
         :ok <- require_valid_utf8(service.status),
         :ok <- require_valid_utf8(service.install_root),
         :ok <- require_valid_utf8(service.apiserver_version),
         :ok <- require_valid_utf8(service.apiserver_build) do
      cond do
        runtime.path != @runtime_path ->
          {:error, :runtime_path_mismatch}

        runtime.cli_build != @required_build ->
          {:error, :non_release_cli_build}

        service.apiserver_build != @required_build ->
          {:error, :non_release_api_build}

        service.status != "running" ->
          {:error, :service_not_running}

        service.install_root != @install_root ->
          {:error, :install_root_mismatch}

        runtime.signing.identifier != @signing_identifier ->
          {:error, :signing_identifier_mismatch}

        runtime.signing.team_id != @team_id ->
          {:error, :signing_team_mismatch}

        runtime.signing.designated_requirement != @designated_requirement ->
          {:error, :designated_requirement_mismatch}

        runtime.signing.verified_against != @designated_requirement ->
          {:error, :verified_against_mismatch}

        # Boolean detached from the requirement is insufficient; status must be
        # bound to verification against the exact designated requirement.
        runtime.signing.status != "valid" ->
          {:error, :codesign_not_verified}

        runtime.signing.verified_against != runtime.signing.designated_requirement ->
          {:error, :codesign_requirement_unbound}

        true ->
          with {:ok, cli_version} <-
                 parse_compat_version(runtime.cli_version, :invalid_cli_version),
               {:ok, api_version} <- parse_apiserver_version(service.apiserver_version) do
            if cli_version == api_version do
              {:ok, cli_version, api_version, runtime.executable_sha256}
            else
              {:error, :cli_api_version_mismatch}
            end
          end
      end
    end
  end

  # Cross-check legacy aggregate runtime/service corroboration against the
  # admitted control-plane child. Aggregate fields never override signed child
  # authority (path, version, build, SHA, signing identity, install root).
  defp cross_check_control_plane(
         runtime,
         service,
         cli_version,
         api_version,
         executable_sha256,
         child
       ) do
    cond do
      runtime.path != child.cli.path ->
        {:error, :aggregate_runtime_path_mismatch}

      runtime.cli_version != child.cli.version or cli_version != child.cli.version ->
        {:error, :aggregate_cli_version_mismatch}

      runtime.cli_build != child.cli.build or child.cli.build != @required_build ->
        {:error, :aggregate_cli_build_mismatch}

      executable_sha256 != child.cli.sha256 or
          runtime.executable_sha256 != child.cli.sha256 ->
        {:error, :aggregate_executable_sha256_mismatch}

      runtime.signing.identifier != child.cli.signing_identifier ->
        {:error, :aggregate_signing_identifier_mismatch}

      runtime.signing.team_id != child.cli.team_id ->
        {:error, :aggregate_signing_team_mismatch}

      runtime.signing.designated_requirement != child.cli.designated_requirement ->
        {:error, :aggregate_designated_requirement_mismatch}

      # Signed API version is authoritative; service self-report + aggregate CLI
      # must not override a different admitted child API version.
      api_version != child.apiserver.version ->
        {:error, :aggregate_api_version_mismatch}

      service.apiserver_build != child.apiserver.build ->
        {:error, :aggregate_api_build_mismatch}

      service.status != child.service.status ->
        {:error, :aggregate_service_status_mismatch}

      service.install_root != child.service.install_root ->
        {:error, :aggregate_install_root_mismatch}

      true ->
        :ok
    end
  end

  # Workload alias inspect: name must equal the derived local execution alias;
  # source reference stays on policy/receipt only. Env/labels remain attested.
  defp validate_workload_image(policy, image_inspect) do
    execution_reference = derive_execution_alias(:workload, policy.index_digest)

    with :ok <-
           validate_role_inspect_surface(
             image_inspect,
             policy.index_digest,
             execution_reference,
             :image_index_digest_mismatch,
             :image_name_digest_mismatch,
             :unsupported_image_media_type
           ),
         {:ok, variant} <-
           select_linux_arm64_variant(
             image_inspect.variants,
             policy.manifest_digest,
             :linux_arm64_variant_missing,
             :duplicate_linux_arm64_variants,
             :manifest_digest_mismatch
           ),
         :ok <- validate_variant_nested_platform(variant),
         :ok <- validate_selected_arm64_variants(variant),
         :ok <- validate_env_match(variant.config.env, policy.env),
         :ok <- validate_labels_match(variant.config.labels, policy.labels) do
      {:ok,
       %{
         reference: policy.image,
         execution_reference: execution_reference,
         index_digest: policy.index_digest,
         manifest_digest: policy.manifest_digest,
         platform: @guest_platform,
         env: policy.env,
         labels: policy.labels
       }}
    end
  end

  # Vminit alias inspect: same closed alias/descriptor/platform surface as
  # workload, but config is only bounded evidence (no Env/Labels attestation).
  defp validate_vminit_image(policy, vminit_inspect) do
    execution_reference = derive_execution_alias(:vminit, policy.vminit_index_digest)

    with :ok <-
           validate_role_inspect_surface(
             vminit_inspect,
             policy.vminit_index_digest,
             execution_reference,
             :vminit_index_digest_mismatch,
             :vminit_name_digest_mismatch,
             :unsupported_vminit_media_type
           ),
         {:ok, variant} <-
           select_linux_arm64_variant(
             vminit_inspect.variants,
             policy.vminit_manifest_digest,
             :vminit_linux_arm64_variant_missing,
             :duplicate_vminit_linux_arm64_variants,
             :vminit_manifest_digest_mismatch
           ),
         :ok <- validate_variant_nested_platform(variant),
         :ok <- validate_selected_arm64_variants(variant) do
      {:ok,
       %{
         reference: policy.vminit_image,
         execution_reference: execution_reference,
         index_digest: policy.vminit_index_digest,
         manifest_digest: policy.vminit_manifest_digest,
         platform: @guest_platform
       }}
    end
  end

  defp validate_role_inspect_surface(
         inspect,
         expected_index_digest,
         expected_execution_reference,
         index_mismatch,
         name_mismatch,
         unsupported_media
       ) do
    with :ok <- require_valid_utf8(inspect.configuration.name),
         :ok <-
           bounded_string(
             inspect.configuration.descriptor.media_type,
             @max_media_type_bytes,
             :media_type_too_long
           ),
         :ok <- validate_descriptor_size(inspect.configuration.descriptor.size) do
      index_digest = inspect.configuration.descriptor.digest
      name = inspect.configuration.name
      media_type = inspect.configuration.descriptor.media_type

      cond do
        not MapSet.member?(@allowed_media_types, media_type) ->
          {:error, unsupported_media}

        index_digest != expected_index_digest ->
          {:error, index_mismatch}

        name != expected_execution_reference ->
          {:error, name_mismatch}

        true ->
          :ok
      end
    end
  end

  defp derive_execution_alias(:workload, index_digest) when is_binary(index_digest) do
    @local_alias_registry <> "/" <> @workload_alias_repository <> "@" <> index_digest
  end

  defp derive_execution_alias(:vminit, index_digest) when is_binary(index_digest) do
    @local_alias_registry <> "/" <> @vminit_alias_repository <> "@" <> index_digest
  end

  defp select_linux_arm64_variant(
         variants,
         expected_manifest_digest,
         missing,
         duplicate,
         digest_mismatch
       ) do
    arm64 =
      Enum.filter(variants, fn variant ->
        variant.platform.os == "linux" and variant.platform.architecture == @required_arch
      end)

    case arm64 do
      [] ->
        {:error, missing}

      [_one, _two | _] ->
        {:error, duplicate}

      [variant] ->
        if variant.digest != expected_manifest_digest do
          {:error, digest_mismatch}
        else
          {:ok, variant}
        end
    end
  end

  defp validate_variant_nested_platform(variant) do
    if variant.config.os == "linux" and variant.config.architecture == @required_arch do
      :ok
    else
      {:error, :variant_config_platform_mismatch}
    end
  end

  # Selected linux/arm64 may omit OCI variant (field is optional). Any declared
  # platform/config variant must be exactly "v8" for Apple container 1.1.0 arm64.
  defp validate_selected_arm64_variants(variant) do
    declared =
      [variant.platform.variant, variant.config.variant]
      |> Enum.reject(&is_nil/1)

    if Enum.all?(declared, &(&1 == @required_arm64_variant)) do
      :ok
    else
      {:error, :unsupported_arm64_variant}
    end
  end

  defp validate_env_match(actual, expected) do
    if actual == expected do
      :ok
    else
      {:error, :env_mismatch}
    end
  end

  defp validate_labels_match(actual, expected) do
    if actual == expected do
      :ok
    else
      {:error, :labels_mismatch}
    end
  end

  # Bind the startup-authority compact baseline receipt to the workload image
  # and every corresponding policy field. Baseline is workload-only; no
  # provisioning/status/mode claims and no materialization readiness.
  defp validate_dependency_baseline(policy, baseline, image_fields) do
    cond do
      # Defense in depth: compact normalizer already requires linux/arm64.
      # Never accept a macOS host deps snapshot as a Linux image baseline.
      baseline.platform in ["macos", "darwin", "macos/arm64", "darwin/arm64", "macos/aarch64"] ->
        {:error, :macos_deps_snapshot_rejected}

      baseline.platform != @guest_platform ->
        {:error, :baseline_platform_mismatch}

      baseline.image_index_digest != image_fields.index_digest ->
        {:error, :baseline_image_index_mismatch}

      baseline.image_manifest_digest != image_fields.manifest_digest ->
        {:error, :baseline_image_manifest_mismatch}

      baseline.mix_lock_digest != policy.mix_lock_digest ->
        {:error, :baseline_mix_lock_digest_mismatch}

      baseline.baseline_tree_digest != policy.baseline_tree_digest ->
        {:error, :baseline_tree_digest_mismatch}

      baseline.toolchain.erlang != policy.toolchain.erlang or
          baseline.toolchain.elixir != policy.toolchain.elixir ->
        {:error, :baseline_toolchain_mismatch}

      true ->
        {:ok,
         %{
           schema: baseline.schema,
           platform: @guest_platform,
           image_index_digest: baseline.image_index_digest,
           image_manifest_digest: baseline.image_manifest_digest,
           mix_lock_digest: baseline.mix_lock_digest,
           baseline_tree_digest: baseline.baseline_tree_digest,
           toolchain: %{
             erlang: baseline.toolchain.erlang,
             elixir: baseline.toolchain.elixir
           },
           entry_count: baseline.entry_count,
           total_bytes: baseline.total_bytes
         }}
    end
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
      # Stable error without echoing/inspecting attacker-controlled key material.
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

  defp validate_descriptor_keys(descriptor) when is_map(descriptor) do
    if map_size(descriptor) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(descriptor)

      if Enum.all?(keys, &MapSet.member?(@allowed_descriptor_keys, &1)) do
        # Reject every duplicate logical media-type representation before fetch:
        # same-spelling atom/string pairs and snake-vs-camel cross aliases.
        with :ok <- reject_duplicate_media_type_aliases(descriptor),
             :ok <- reject_duplicate_key_aliases(keys, [:digest, :size], :descriptor) do
          required =
            Map.has_key?(descriptor, :digest) or Map.has_key?(descriptor, "digest")

          size_present =
            Map.has_key?(descriptor, :size) or Map.has_key?(descriptor, "size")

          media_present =
            Map.has_key?(descriptor, :media_type) or
              Map.has_key?(descriptor, "media_type") or
              Map.has_key?(descriptor, :mediaType) or
              Map.has_key?(descriptor, "mediaType")

          if required and size_present and media_present do
            :ok
          else
            {:error, :partial_image_descriptor}
          end
        end
      else
        {:error, {:unsupported_keys, :descriptor}}
      end
    end
  end

  defp reject_duplicate_media_type_aliases(descriptor) when is_map(descriptor) do
    media_keys = [:media_type, "media_type", :mediaType, "mediaType"]
    present = Enum.count(media_keys, &Map.has_key?(descriptor, &1))

    if present > 1 do
      {:error, {:duplicate_key_alias, :descriptor, :media_type}}
    else
      :ok
    end
  end

  defp validate_variant_platform_keys(platform) when is_map(platform) do
    if map_size(platform) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(platform)

      if Enum.all?(keys, &MapSet.member?(@allowed_variant_platform_keys, &1)) do
        with :ok <-
               reject_duplicate_key_aliases(
                 keys,
                 @logical_variant_platform_keys,
                 :variant_platform
               ),
             :ok <-
               reject_duplicate_key_aliases(
                 keys,
                 @optional_variant_platform_keys,
                 :variant_platform
               ) do
          :ok
        end
      else
        {:error, {:unsupported_keys, :variant_platform}}
      end
    end
  end

  defp validate_variant_config_keys(config) when is_map(config) do
    if map_size(config) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(config)

      if Enum.all?(keys, &MapSet.member?(@allowed_variant_config_keys, &1)) do
        with :ok <-
               reject_duplicate_key_aliases(keys, @logical_variant_config_keys, :variant_config),
             :ok <-
               reject_duplicate_key_aliases(keys, @optional_variant_config_keys, :variant_config) do
          :ok
        end
      else
        {:error, {:unsupported_keys, :variant_config}}
      end
    end
  end

  defp validate_image_config_keys(image_config) when is_map(image_config) do
    if map_size(image_config) > @max_map_keys do
      {:error, :map_too_large}
    else
      keys = Map.keys(image_config)

      if Enum.all?(keys, &MapSet.member?(@allowed_image_config_keys, &1)) do
        :ok
      else
        {:error, {:unsupported_keys, :image_config}}
      end
    end
  end

  defp fetch_descriptor_digest(descriptor) do
    case get_field(descriptor, :digest) do
      nil -> {:error, :missing_descriptor_digest}
      value -> validate_digest(value, :invalid_descriptor_digest)
    end
  end

  defp fetch_descriptor_media_type(descriptor) do
    value =
      cond do
        Map.has_key?(descriptor, :media_type) -> Map.get(descriptor, :media_type)
        Map.has_key?(descriptor, "media_type") -> Map.get(descriptor, "media_type")
        Map.has_key?(descriptor, :mediaType) -> Map.get(descriptor, :mediaType)
        Map.has_key?(descriptor, "mediaType") -> Map.get(descriptor, "mediaType")
        true -> nil
      end

    case value do
      nil ->
        {:error, :missing_media_type}

      media when is_binary(media) ->
        with :ok <- bounded_string(media, @max_media_type_bytes, :media_type_too_long),
             :ok <- require_valid_utf8(media),
             :ok <- reject_control_or_whitespace(media, :unsafe_media_type) do
          cond do
            media == "" ->
              {:error, :empty_media_type}

            not MapSet.member?(@allowed_media_types, media) ->
              {:error, :unsupported_image_media_type}

            true ->
              {:ok, media}
          end
        end

      _other ->
        {:error, :invalid_media_type}
    end
  end

  defp fetch_descriptor_size(descriptor) do
    case get_field(descriptor, :size) do
      size when is_integer(size) and size >= 0 and size <= @max_descriptor_size ->
        {:ok, size}

      size when is_integer(size) ->
        {:error, :invalid_descriptor_size}

      _other ->
        {:error, :invalid_descriptor_size}
    end
  end

  defp validate_descriptor_size(size) when is_integer(size) and size >= 0, do: :ok
  defp validate_descriptor_size(_), do: {:error, :invalid_descriptor_size}

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

  # Operator policy source images must be external fully-qualified digests.
  # Local execution aliases are derived from index digests and never admitted
  # as independent policy fields.
  defp validate_external_source_image(image, invalid)
       when is_binary(image) and is_atom(invalid) do
    case validate_immutable_image(image) do
      {:ok, image} ->
        if local_execution_alias?(image) do
          {:error, :local_alias_not_policy}
        else
          {:ok, image}
        end

      {:error, :invalid_image} ->
        {:error, invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_external_source_image(_, invalid), do: {:error, invalid}

  defp validate_immutable_image(image) when is_binary(image) do
    with :ok <- bounded_string(image, @max_image_bytes, :image_too_long),
         :ok <- require_valid_utf8(image) do
      cond do
        image == "" ->
          {:error, :empty_image}

        has_control_or_whitespace?(image) ->
          {:error, :unsafe_image}

        String.contains?(image, ":") and not String.contains?(image, "@sha256:") ->
          {:error, :mutable_image_reference}

        true ->
          case Regex.run(@image_re, image) do
            [^image, repository, digest] ->
              if fully_qualified_repository?(repository) and
                   byte_size(repository) <= @max_repository_bytes and
                   byte_size(digest) == @max_digest_hex do
                {:ok, image}
              else
                {:error, :malformed_image}
              end

            _other ->
              if String.contains?(image, "@sha256:") do
                {:error, :malformed_image}
              else
                {:error, :mutable_image_reference}
              end
          end
      end
    end
  end

  defp validate_immutable_image(_), do: {:error, :invalid_image}

  defp local_execution_alias?(image) when is_binary(image) do
    String.starts_with?(image, @local_alias_registry <> "/")
  end

  # Require a registry hostname containing '.' so short repo-only refs are rejected.
  defp fully_qualified_repository?(repository) when is_binary(repository) do
    case String.split(repository, "/", parts: 2) do
      [host, path] when host != "" and path != "" ->
        String.contains?(host, ".")

      _other ->
        false
    end
  end

  defp image_digest(image) do
    case Regex.run(@image_re, image) do
      [^image, _repo, digest] -> digest
    end
  end

  defp validate_digest(digest, invalid) when is_binary(digest) do
    with :ok <- bounded_string(digest, 7 + @max_digest_hex, invalid),
         :ok <- require_valid_utf8(digest) do
      cond do
        has_control_or_whitespace?(digest) ->
          {:error, invalid}

        Regex.match?(@digest_re, digest) ->
          {:ok, digest}

        true ->
          {:error, invalid}
      end
    end
  end

  defp validate_digest(_, invalid), do: {:error, invalid}

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

  defp validate_env_list(env, invalid) when is_list(env) do
    case take_bounded(env, @max_env_entries) do
      :too_many ->
        {:error, :too_many_env_entries}

      {:ok, bounded} ->
        if Enum.all?(bounded, &is_binary/1) do
          Enum.reduce_while(bounded, {:ok, []}, fn entry, {:ok, acc} ->
            case validate_env_entry(entry) do
              {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
            error -> error
          end
        else
          {:error, invalid}
        end
    end
  end

  defp validate_env_list(_, invalid), do: {:error, invalid}

  defp validate_env_entry(entry) when is_binary(entry) do
    with :ok <- bounded_string(entry, @max_env_entry_bytes, :env_entry_too_long),
         :ok <- require_valid_utf8(entry) do
      cond do
        has_control_char?(entry) or binary_contains?(entry, <<0>>) ->
          {:error, :unsafe_env_entry}

        not Regex.match?(@env_entry_re, entry) ->
          {:error, :malformed_env_entry}

        true ->
          {:ok, entry}
      end
    end
  end

  defp validate_labels_map(labels, invalid) when is_map(labels) do
    cond do
      map_size(labels) > @max_label_keys ->
        {:error, :too_many_labels}

      not Enum.all?(Map.keys(labels), &is_binary/1) ->
        # Labels must be string-keyed only - atom keys are ambiguous aliases.
        {:error, invalid}

      not Enum.all?(Map.values(labels), &is_binary/1) ->
        {:error, invalid}

      true ->
        Enum.reduce_while(labels, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
          with :ok <- bounded_string(key, @max_label_key_bytes, :label_key_too_long),
               :ok <- bounded_string(value, @max_label_value_bytes, :label_value_too_long),
               :ok <- require_valid_utf8(key),
               :ok <- require_valid_utf8(value),
               :ok <- reject_control_char(key, :unsafe_label_key),
               :ok <- reject_control_char(value, :unsafe_label_value) do
            if key == "" do
              {:halt, {:error, :empty_label_key}}
            else
              {:cont, {:ok, Map.put(acc, key, value)}}
            end
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp validate_labels_map(_, invalid), do: {:error, invalid}

  defp parse_compat_version(version, invalid) do
    with :ok <- bounded_string(version, @max_version_bytes, :cli_version_too_long),
         :ok <- require_valid_utf8(version),
         :ok <- reject_control_or_whitespace(version, invalid) do
      case Regex.run(@version_re, version) do
        [^version, major_s, minor_s, patch_s] ->
          # Components are already bounded by @max_version_bytes and the regex.
          major = String.to_integer(major_s)
          minor = String.to_integer(minor_s)
          _patch = String.to_integer(patch_s)

          if major == @compat_major and minor == @compat_minor do
            {:ok, version}
          else
            {:error, :cli_version_not_supported}
          end

        _other ->
          {:error, invalid}
      end
    end
  end

  defp parse_apiserver_version(version) do
    with :ok <-
           bounded_string(version, @max_apiserver_version_bytes, :apiserver_version_too_long),
         :ok <- require_valid_utf8(version),
         :ok <- reject_control_char(version, :unsafe_apiserver_version) do
      case Regex.run(@apiserver_version_re, version) do
        [^version, semver, _commit] ->
          case parse_compat_version(semver, :invalid_apiserver_version) do
            {:ok, ^semver} -> {:ok, semver}
            {:error, :cli_version_not_supported} -> {:error, :api_version_not_supported}
            {:error, reason} -> {:error, reason}
          end

        _other ->
          # Reject non-release or malformed version strings fail-closed.
          if String.contains?(version, "build: release") do
            {:error, :invalid_apiserver_version}
          else
            {:error, :non_release_api_version}
          end
      end
    end
  end

  defp parse_os_major(version) when is_binary(version) do
    case Regex.run(@os_version_re, version) do
      [^version, major_s | _] ->
        {:ok, String.to_integer(major_s)}

      _other ->
        :error
    end
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
    # Byte-oriented check; avoids regex work on attacker-controlled binaries.
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
