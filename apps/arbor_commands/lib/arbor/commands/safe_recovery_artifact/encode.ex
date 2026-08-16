defmodule Arbor.Commands.SafeRecoveryArtifact.Encode do
  @moduledoc """
  Strict canonical JSON and domain-separated digests for the E0B2B
  safe-recovery artifact payload. `validate_manifest/1` recomputes derived
  fields from manifest evidence before any public encode or digest.
  """

  alias Arbor.Commands.SafeRecoveryArtifact.Derive

  @schema "arbor.packaging.safe_recovery_artifact.payload.v1"
  @version 1
  @profile_schema "arbor.packaging.safe_recovery_profile.intent.v1"
  @profile_name "safe_recovery"
  @profile_digest "55fda49eb5389dcb7acd8d90ccd3e20961cf5176a563eb75c32f6848e227d2d5"
  @platform_inventory_schema "arbor.packaging.platform_inventory.v1"
  @selected_file_count 303
  @selected_index_digest "2232c36a5ed7c8f3e06e01fabb0fdb20e1579ee25dda2d9d8df34b5cc494afde"
  @entries_digest "ec219b075dfb941f213df9feb46f248f05aa1f61259a402cde4250165bad0156"
  @review_digest "f674935bc507568df3cb701f097becff7299287de13772b0d8fbd63e4aac2c7a"

  @build_inputs_domain "arbor.packaging.safe_recovery_artifact.build_inputs.v1\0"
  @applications_domain "arbor.packaging.safe_recovery_artifact.applications.v1\0"
  @payload_tree_domain "arbor.packaging.safe_recovery_artifact.payload_tree.v1\0"
  @manifest_domain "arbor.packaging.safe_recovery_artifact.manifest.v1\0"

  @target "aarch64-apple-darwin"
  @erlang "28.4.1"
  @erts "16.3"
  @elixir "1.19.5"
  @mix "1.19.5"
  @environment "prod"
  @release_name "arbor_trust"
  @release_version "0.1.0"
  @logical_root "rel/arbor_trust"
  @repro_rule "remove_exact_releases_cookie_before_scan"

  # Classification is E0B2 evidence. Runtime membership does not waive
  # E0B1 forbidden-facility policy; forbidden names stay class runtime
  # and still produce blocker findings.
  @selected_first_party MapSet.new([
                          "arbor_kernel",
                          "arbor_kernel_runtime",
                          "arbor_security",
                          "arbor_trust"
                        ])

  @forbidden_runtime MapSet.new([
                       "os_mon",
                       "observer",
                       "wx",
                       "debugger",
                       "et",
                       "percept",
                       "reltool",
                       "dialyzer",
                       "typer",
                       "megaco",
                       "snmp",
                       "eunit",
                       "common_test",
                       "ftp",
                       "tftp",
                       "ssh",
                       "inets",
                       "jinterface",
                       "odbc",
                       "mnesia",
                       "iex",
                       "mix",
                       "ex_unit",
                       "runtime_tools"
                     ])

  @runtime_applications MapSet.union(
                          MapSet.new([
                            "kernel",
                            "stdlib",
                            "compiler",
                            "elixir",
                            "eex",
                            "logger",
                            "sasl",
                            "crypto",
                            "asn1",
                            "public_key",
                            "ssl",
                            "syntax_tools"
                          ]),
                          @forbidden_runtime
                        )

  @digest_re ~r/\A[0-9a-f]{64}\z/
  @oid_sha1_re ~r/\A[0-9a-f]{40}\z/
  @oid_sha256_re ~r/\A[0-9a-f]{64}\z/

  @start_types MapSet.new(["permanent", "transient", "temporary", "load", "none"])
  @classes MapSet.new([
             "selected_first_party",
             "unexpected_first_party",
             "runtime",
             "third_party"
           ])
  @kinds MapSet.new([
           "beam",
           "app_spec",
           "native",
           "executable",
           "private_asset",
           "release_metadata",
           "other"
         ])
  @finding_ids MapSet.new([
                 "unexpected_first_party_applications",
                 "third_party_applications",
                 "forbidden_runtime_applications",
                 "unsafe_native_or_executable_ownership"
               ])
  @statuses MapSet.new(["identical", "different"])

  @manifest_keys [
    "schema",
    "version",
    "profile",
    "source",
    "toolchain",
    "release",
    "applications",
    "entries",
    "findings",
    "reproducibility"
  ]

  @profile_keys ["architecture_status", "digest", "evidence_status", "name", "schema"]
  @source_keys [
    "build_inputs",
    "build_inputs_digest",
    "commit",
    "object_format",
    "platform_inventory",
    "tree"
  ]
  @inventory_keys [
    "entries_digest",
    "platform_inventory_schema",
    "review_digest",
    "selected_file_count",
    "selected_index_digest"
  ]
  @toolchain_keys [
    "elixir",
    "environment",
    "erlang",
    "erts",
    "mix",
    "mix_lock_sha256",
    "target",
    "tool_versions_sha256"
  ]
  @release_keys [
    "application_count",
    "applications_digest",
    "entry_count",
    "logical_root",
    "name",
    "payload_tree_digest",
    "total_bytes",
    "version"
  ]
  @application_keys [
    "app_spec_path",
    "app_spec_sha256",
    "class",
    "declared_applications",
    "name",
    "start_type",
    "version"
  ]
  @declared_keys ["included", "optional", "required"]
  @entry_keys ["content_kind", "mode", "owner_application", "path", "sha256", "size"]
  @finding_keys ["applications", "blocker_owner", "id", "paths", "severity"]
  @repro_keys ["differing_paths", "payload_tree_digests", "rule", "status"]
  @build_input_keys ["path", "sha256"]

  @max_map_keys 16
  @max_key_bytes 256
  @max_path_bytes 4_096
  @max_component_bytes 255
  @max_path_depth 48
  @max_build_inputs 5_000
  @max_applications 4_096
  @max_entries 50_000
  @max_findings 8
  @max_deps 4_096
  @max_short 256
  @max_total_bytes 512 * 1024 * 1024
  @max_canonical_bytes 512 * 1024 * 1024
  @max_mode 0o7777

  @type validation_error :: {:error, term()}

  @doc "Closed payload schema identifier."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc "Closed payload version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Reviewed OTP/Elixir runtime names, including the forbidden subset."
  @spec runtime_application_names() :: MapSet.t(String.t())
  def runtime_application_names, do: @runtime_applications

  @doc "Forbidden-runtime subset; still class runtime and always a finding."
  @spec forbidden_runtime_application_names() :: MapSet.t(String.t())
  def forbidden_runtime_application_names, do: @forbidden_runtime

  @doc "The four E0B1 selected first-party application names."
  @spec selected_first_party_names() :: MapSet.t(String.t())
  def selected_first_party_names, do: @selected_first_party

  @doc "Domain tag for build_inputs_digest, including trailing NUL."
  @spec build_inputs_domain() :: binary()
  def build_inputs_domain, do: @build_inputs_domain

  @doc "Domain tag for applications_digest, including trailing NUL."
  @spec applications_domain() :: binary()
  def applications_domain, do: @applications_domain

  @doc "Domain tag for payload_tree_digest, including trailing NUL."
  @spec payload_tree_domain() :: binary()
  def payload_tree_domain, do: @payload_tree_domain

  @doc "Domain tag for the external manifest_digest, including trailing NUL."
  @spec manifest_domain() :: binary()
  def manifest_domain, do: @manifest_domain

  @doc false
  @spec profile_digest_value() :: String.t()
  def profile_digest_value, do: @profile_digest

  @doc false
  @spec selected_file_count() :: pos_integer()
  def selected_file_count, do: @selected_file_count

  @doc false
  @spec e0a_index_digest() :: String.t()
  def e0a_index_digest, do: @selected_index_digest

  @doc false
  @spec e0a_entries_digest() :: String.t()
  def e0a_entries_digest, do: @entries_digest

  @doc false
  @spec e0a_review_digest() :: String.t()
  def e0a_review_digest, do: @review_digest

  @doc false
  @spec platform_inventory_schema() :: String.t()
  def platform_inventory_schema, do: @platform_inventory_schema

  @doc false
  @spec profile_schema() :: String.t()
  def profile_schema, do: @profile_schema

  @doc false
  @spec profile_name() :: String.t()
  def profile_name, do: @profile_name

  @doc false
  @spec release_name() :: String.t()
  def release_name, do: @release_name

  @doc false
  @spec release_version() :: String.t()
  def release_version, do: @release_version

  @doc false
  @spec logical_root() :: String.t()
  def logical_root, do: @logical_root

  @doc false
  @spec toolchain_constants() :: map()
  def toolchain_constants do
    %{
      "target" => @target,
      "erlang" => @erlang,
      "erts" => @erts,
      "elixir" => @elixir,
      "mix" => @mix,
      "environment" => @environment
    }
  end

  @doc "Strictly validate the canonical string-keyed manifest."
  @spec validate_manifest(map()) :: :ok | validation_error()
  def validate_manifest(manifest) when is_map(manifest) and not is_struct(manifest) do
    with :ok <- validate_closed_map(manifest, @manifest_keys),
         :ok <- validate_identity(manifest),
         :ok <- validate_collections(manifest) do
      recompute_derived(manifest)
    end
  end

  def validate_manifest(_), do: {:error, :invalid_manifest}

  @doc "Validate then encode compact canonical JSON."
  @spec encode_manifest(map()) :: {:ok, binary()} | validation_error()
  def encode_manifest(manifest) do
    case validate_manifest(manifest) do
      :ok -> canonical_json(manifest)
      error -> error
    end
  end

  @doc "Validate then return the lowercase 64-hex SHA-256 of the framed bytes."
  @spec manifest_digest(map()) :: {:ok, String.t()} | validation_error()
  def manifest_digest(manifest) do
    case encode_manifest(manifest) do
      {:ok, bytes} -> {:ok, framed_digest(@manifest_domain, bytes)}
      error -> error
    end
  end

  @doc false
  @spec build_inputs_digest(term()) :: {:ok, String.t()} | validation_error()
  def build_inputs_digest(inputs) when is_list(inputs) do
    digest_list(@build_inputs_domain, inputs)
  end

  def build_inputs_digest(_), do: {:error, :not_a_list}

  @doc false
  @spec applications_digest(term()) :: {:ok, String.t()} | validation_error()
  def applications_digest(apps) when is_list(apps) do
    digest_list(@applications_domain, apps)
  end

  def applications_digest(_), do: {:error, :not_a_list}

  @doc false
  @spec payload_tree_digest(term()) :: {:ok, String.t()} | validation_error()
  def payload_tree_digest(entries) when is_list(entries) do
    digest_list(@payload_tree_domain, entries)
  end

  def payload_tree_digest(_), do: {:error, :not_a_list}

  @doc false
  @spec canonical_json(term()) :: {:ok, binary()} | validation_error()
  def canonical_json(value) do
    case order_value(value) do
      {:ok, ordered} -> encode_capped(ordered)
      error -> error
    end
  end

  @doc false
  @spec framed_digest(binary(), binary()) :: String.t()
  def framed_digest(domain, json) when is_binary(domain) and is_binary(json) do
    :crypto.hash(:sha256, [domain, <<byte_size(json)::unsigned-big-64>>, json])
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec valid_path?(term()) :: :ok | {:error, atom()}
  def valid_path?(path) when is_binary(path), do: admit_path(path)
  def valid_path?(_), do: {:error, :not_a_string}

  @doc false
  @spec valid_digest?(term()) :: :ok | {:error, atom()}
  def valid_digest?(value) when is_binary(value) do
    if Regex.match?(@digest_re, value), do: :ok, else: {:error, :invalid_digest}
  end

  def valid_digest?(_), do: {:error, :not_a_string}

  @doc false
  @spec take_proper_list(term(), non_neg_integer()) :: {:ok, list()} | {:error, atom()}
  def take_proper_list(list, max), do: take_list(list, max)

  @doc false
  @spec admit_closed_map(term(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def admit_closed_map(map, keys) do
    case validate_closed_map(map, keys) do
      :ok -> {:ok, map}
      error -> error
    end
  end

  @doc false
  @spec validate_closed_map(term(), [String.t()]) :: :ok | {:error, term()}
  def validate_closed_map(map, keys) when is_map(map) and not is_struct(map) do
    if map_size(map) > @max_map_keys do
      {:error, :unbounded}
    else
      validate_map_keys(map, keys)
    end
  end

  def validate_closed_map(_, _), do: {:error, :invalid_map}

  defp digest_list(domain, items) do
    case canonical_json(items) do
      {:ok, json} -> {:ok, framed_digest(domain, json)}
      error -> error
    end
  end

  defp validate_identity(manifest) do
    with :ok <- exact_string(manifest, "schema", @schema, :invalid_schema),
         :ok <- exact_int(manifest, "version", @version, :invalid_version),
         :ok <- validate_profile(Map.fetch!(manifest, "profile")),
         :ok <- validate_source_shape(Map.fetch!(manifest, "source")),
         :ok <- validate_toolchain(Map.fetch!(manifest, "toolchain")) do
      validate_release_shape(Map.fetch!(manifest, "release"))
    end
  end

  defp validate_collections(manifest) do
    with {:ok, apps} <-
           take_named_list(manifest, "applications", @max_applications, &validate_application/1),
         :ok <- require_sorted_unique(apps, "name"),
         {:ok, entries} <-
           take_named_list(manifest, "entries", @max_entries, &validate_entry/1),
         :ok <- require_sorted_unique(entries, "path"),
         {:ok, findings} <-
           take_named_list(manifest, "findings", @max_findings, &validate_finding/1),
         :ok <- require_sorted_unique(findings, "id") do
      _ = {entries, findings}
      validate_reproducibility_shape(Map.fetch!(manifest, "reproducibility"))
    end
  end

  defp recompute_derived(manifest) do
    source = Map.fetch!(manifest, "source")
    release = Map.fetch!(manifest, "release")
    apps = Map.fetch!(manifest, "applications")
    entries = Map.fetch!(manifest, "entries")
    findings = Map.fetch!(manifest, "findings")
    repro = Map.fetch!(manifest, "reproducibility")

    with :ok <- require_classes(apps),
         :ok <- Derive.applications_consistent?(apps, entries),
         :ok <- require_findings(apps, entries, findings),
         {:ok, facts} <- Derive.release_facts(apps, entries),
         :ok <- require_release_facts(release, facts),
         {:ok, inputs_digest} <- build_inputs_digest(Map.fetch!(source, "build_inputs")),
         :ok <- require_equal(source["build_inputs_digest"], inputs_digest) do
      Derive.reproducibility_consistent?(repro, facts)
    end
  end

  defp require_classes(apps) do
    Enum.reduce_while(apps, :ok, fn app, :ok ->
      observed = app["class"]

      case Derive.application_class(app["name"]) do
        {:error, reason} ->
          {:halt, {:error, {:invalid_field, "class", reason}}}

        expected when observed == expected ->
          {:cont, :ok}

        _other ->
          {:halt, {:error, {:invalid_field, "class", :derived_mismatch}}}
      end
    end)
  end

  defp require_findings(apps, entries, findings) do
    case Derive.findings(apps, entries) do
      {:error, reason} ->
        {:error, {:invalid_field, "findings", reason}}

      expected when findings == expected ->
        :ok

      _other ->
        {:error, {:invalid_field, "findings", :derived_mismatch}}
    end
  end

  defp require_release_facts(release, facts) do
    cond do
      release["entry_count"] != facts["entry_count"] ->
        {:error, {:invalid_field, "entry_count", :derived_mismatch}}

      release["total_bytes"] != facts["total_bytes"] ->
        {:error, {:invalid_field, "total_bytes", :derived_mismatch}}

      release["application_count"] != facts["application_count"] ->
        {:error, {:invalid_field, "application_count", :derived_mismatch}}

      release["payload_tree_digest"] != facts["payload_tree_digest"] ->
        {:error, {:invalid_field, "payload_tree_digest", :derived_mismatch}}

      release["applications_digest"] != facts["applications_digest"] ->
        {:error, {:invalid_field, "applications_digest", :derived_mismatch}}

      true ->
        :ok
    end
  end

  defp require_equal(value, value), do: :ok

  defp require_equal(_, _),
    do: {:error, {:invalid_field, "build_inputs_digest", :derived_mismatch}}

  defp validate_profile(profile) do
    with :ok <- validate_closed_map(profile, @profile_keys),
         :ok <- exact_string(profile, "schema", @profile_schema, :invalid_schema),
         :ok <- exact_string(profile, "name", @profile_name, :profile_mismatch),
         :ok <- exact_string(profile, "digest", @profile_digest, :digest_mismatch),
         :ok <- exact_string(profile, "evidence_status", "conformant", :profile_mismatch) do
      exact_string(profile, "architecture_status", "blocked", :profile_mismatch)
    end
  end

  defp validate_source_shape(source) do
    with :ok <- validate_closed_map(source, @source_keys),
         :ok <- validate_git(source),
         :ok <- validate_platform_inventory(Map.fetch!(source, "platform_inventory")),
         :ok <- valid_digest?(Map.fetch!(source, "build_inputs_digest")) do
      validate_build_inputs(Map.fetch!(source, "build_inputs"))
    end
  end

  defp validate_git(source) do
    format = Map.fetch!(source, "object_format")
    commit = Map.fetch!(source, "commit")
    tree = Map.fetch!(source, "tree")

    case format do
      "sha1" ->
        admit_oids(commit, tree, @oid_sha1_re)

      "sha256" ->
        admit_oids(commit, tree, @oid_sha256_re)

      value when is_binary(value) ->
        {:error, {:invalid_field, "object_format", :invalid_object_format}}

      _ ->
        {:error, {:invalid_field, "object_format", :not_a_string}}
    end
  end

  defp admit_oids(commit, tree, regex) do
    case match_oid(commit, regex, "commit") do
      :ok -> match_oid(tree, regex, "tree")
      error -> error
    end
  end

  defp match_oid(value, regex, field) when is_binary(value) do
    if Regex.match?(regex, value) do
      :ok
    else
      {:error, {:invalid_field, field, :invalid_object_format}}
    end
  end

  defp match_oid(_, _, field), do: {:error, {:invalid_field, field, :not_a_string}}

  defp validate_platform_inventory(inventory) do
    with :ok <- validate_closed_map(inventory, @inventory_keys),
         :ok <-
           exact_string(
             inventory,
             "platform_inventory_schema",
             @platform_inventory_schema,
             :invalid_schema
           ),
         :ok <-
           exact_int(inventory, "selected_file_count", @selected_file_count, :count_mismatch),
         :ok <-
           exact_string(
             inventory,
             "selected_index_digest",
             @selected_index_digest,
             :digest_mismatch
           ),
         :ok <- exact_string(inventory, "entries_digest", @entries_digest, :digest_mismatch) do
      exact_string(inventory, "review_digest", @review_digest, :digest_mismatch)
    end
  end

  defp validate_build_inputs(list) do
    with {:ok, items} <- take_list(list, @max_build_inputs),
         :ok <- validate_each(items, &validate_build_input/1) do
      require_sorted_unique(items, "path")
    end
  end

  defp validate_build_input(item) do
    with :ok <- validate_closed_map(item, @build_input_keys),
         :ok <- valid_path?(Map.fetch!(item, "path")) do
      valid_digest?(Map.fetch!(item, "sha256"))
    end
  end

  defp validate_toolchain(toolchain) do
    constants = toolchain_constants()

    with :ok <- validate_closed_map(toolchain, @toolchain_keys),
         :ok <- exact_string(toolchain, "target", constants["target"], :profile_mismatch),
         :ok <- exact_string(toolchain, "erlang", constants["erlang"], :profile_mismatch),
         :ok <- exact_string(toolchain, "erts", constants["erts"], :profile_mismatch),
         :ok <- exact_string(toolchain, "elixir", constants["elixir"], :profile_mismatch),
         :ok <- exact_string(toolchain, "mix", constants["mix"], :profile_mismatch),
         :ok <-
           exact_string(toolchain, "environment", constants["environment"], :profile_mismatch),
         :ok <- valid_digest?(Map.fetch!(toolchain, "tool_versions_sha256")) do
      valid_digest?(Map.fetch!(toolchain, "mix_lock_sha256"))
    end
  end

  defp validate_release_shape(release) do
    with :ok <- validate_closed_map(release, @release_keys),
         :ok <- exact_string(release, "name", @release_name, :release_mismatch),
         :ok <- exact_string(release, "version", @release_version, :release_mismatch),
         :ok <- exact_string(release, "logical_root", @logical_root, :release_mismatch),
         :ok <- nonneg_bound(release, "entry_count", @max_entries),
         :ok <- nonneg_bound(release, "total_bytes", @max_total_bytes),
         :ok <- nonneg_bound(release, "application_count", @max_applications),
         :ok <- valid_digest?(Map.fetch!(release, "payload_tree_digest")) do
      valid_digest?(Map.fetch!(release, "applications_digest"))
    end
  end

  defp validate_application(app) do
    with :ok <- validate_closed_map(app, @application_keys),
         :ok <- short_name(Map.fetch!(app, "name")),
         :ok <- short_name(Map.fetch!(app, "version")),
         :ok <- member_field(app, "start_type", @start_types, :invalid_start_type),
         :ok <- member_field(app, "class", @classes, :derived_mismatch),
         :ok <- valid_path?(Map.fetch!(app, "app_spec_path")),
         :ok <- valid_digest?(Map.fetch!(app, "app_spec_sha256")) do
      validate_declared(Map.fetch!(app, "declared_applications"))
    end
  end

  defp validate_declared(declared) do
    with :ok <- validate_closed_map(declared, @declared_keys),
         :ok <- name_list(declared, "required"),
         :ok <- name_list(declared, "included") do
      name_list(declared, "optional")
    end
  end

  defp name_list(map, key) do
    with {:ok, items} <- take_list(Map.fetch!(map, key), @max_deps),
         :ok <- validate_each(items, &short_name/1) do
      require_sorted_unique_strings(items)
    end
  end

  defp validate_entry(entry) do
    with :ok <- validate_closed_map(entry, @entry_keys),
         :ok <- valid_path?(Map.fetch!(entry, "path")),
         :ok <- owner_field(Map.fetch!(entry, "owner_application")),
         :ok <- mode_field(Map.fetch!(entry, "mode")),
         :ok <- size_field(Map.fetch!(entry, "size")),
         :ok <- valid_digest?(Map.fetch!(entry, "sha256")) do
      member_value(Map.fetch!(entry, "content_kind"), @kinds, :malformed_signature)
    end
  end

  defp validate_finding(finding) do
    with :ok <- validate_closed_map(finding, @finding_keys),
         :ok <- member_field(finding, "id", @finding_ids, :derived_mismatch),
         :ok <- exact_string(finding, "severity", "blocker", :derived_mismatch),
         :ok <-
           exact_string(finding, "blocker_owner", "p1e_release_separation", :derived_mismatch),
         :ok <- name_list(%{"required" => Map.fetch!(finding, "applications")}, "required") do
      path_list(Map.fetch!(finding, "paths"))
    end
  end

  defp validate_reproducibility_shape(repro) do
    with :ok <- validate_closed_map(repro, @repro_keys),
         :ok <- member_field(repro, "status", @statuses, :inconsistent_reproducibility),
         :ok <- exact_string(repro, "rule", @repro_rule, :inconsistent_reproducibility),
         :ok <- digest_pair(Map.fetch!(repro, "payload_tree_digests")) do
      path_list(Map.fetch!(repro, "differing_paths"))
    end
  end

  defp digest_pair([first, second]) do
    case valid_digest?(first) do
      :ok -> valid_digest?(second)
      error -> error
    end
  end

  defp digest_pair(list) when is_list(list), do: {:error, :inconsistent_reproducibility}
  defp digest_pair(_), do: {:error, :not_a_list}

  defp path_list(list) do
    with {:ok, items} <- take_list(list, @max_entries),
         :ok <- validate_each(items, &valid_path?/1) do
      require_sorted_unique_strings(items)
    end
  end

  defp owner_field(nil), do: :ok
  defp owner_field(name) when is_binary(name), do: short_name(name)
  defp owner_field(_), do: {:error, :not_a_string}

  defp mode_field(mode) when is_integer(mode) and mode >= 0 and mode <= @max_mode, do: :ok
  defp mode_field(mode) when is_integer(mode), do: {:error, :unbounded}
  defp mode_field(_), do: {:error, :not_an_integer}

  defp size_field(size) when is_integer(size) and size >= 0 and size <= @max_total_bytes, do: :ok
  defp size_field(size) when is_integer(size) and size < 0, do: {:error, :negative}
  defp size_field(size) when is_integer(size), do: {:error, :unbounded}
  defp size_field(_), do: {:error, :not_an_integer}

  defp nonneg_bound(map, key, max) do
    value = Map.fetch!(map, key)

    cond do
      not is_integer(value) -> {:error, {:invalid_field, key, :not_an_integer}}
      value < 0 -> {:error, {:invalid_field, key, :negative}}
      value > max -> {:error, {:invalid_field, key, :unbounded}}
      true -> :ok
    end
  end

  defp short_name(value) when is_binary(value) do
    cond do
      byte_size(value) > @max_short -> {:error, :unbounded}
      value == "" -> {:error, :blank}
      not String.valid?(value) -> {:error, :invalid_utf8}
      control_bearing?(value) -> {:error, :control_character}
      true -> :ok
    end
  end

  defp short_name(_), do: {:error, :not_a_string}

  defp member_field(map, key, set, tag) do
    member_value(Map.fetch!(map, key), set, tag)
  end

  defp member_value(value, set, tag) when is_binary(value) do
    case short_name(value) do
      :ok -> if MapSet.member?(set, value), do: :ok, else: {:error, tag}
      error -> error
    end
  end

  defp member_value(_, _, _), do: {:error, :not_a_string}

  defp exact_string(map, key, expected, tag) do
    case Map.fetch!(map, key) do
      ^expected -> :ok
      value when is_binary(value) -> {:error, {:invalid_field, key, tag}}
      _ -> {:error, {:invalid_field, key, :not_a_string}}
    end
  end

  defp exact_int(map, key, expected, tag) do
    case Map.fetch!(map, key) do
      ^expected -> :ok
      value when is_integer(value) -> {:error, {:invalid_field, key, tag}}
      _ -> {:error, {:invalid_field, key, :not_an_integer}}
    end
  end

  defp take_named_list(map, key, max, validator) do
    case take_list(Map.fetch!(map, key), max) do
      {:ok, items} ->
        case validate_each(items, validator) do
          :ok -> {:ok, items}
          error -> wrap_field(key, error)
        end

      {:error, reason} ->
        {:error, {:invalid_field, key, reason}}
    end
  end

  defp wrap_field(_key, {:error, {:invalid_field, _, _}} = error), do: error
  defp wrap_field(key, {:error, reason}), do: {:error, {:invalid_field, key, reason}}

  defp validate_each([], _fun), do: :ok

  defp validate_each([item | rest], fun) do
    case fun.(item) do
      :ok -> validate_each(rest, fun)
      {:error, _} = error -> error
    end
  end

  defp require_sorted_unique(items, key) do
    names = Enum.map(items, &Map.fetch!(&1, key))
    require_sorted_unique_strings(names)
  end

  defp require_sorted_unique_strings(items) do
    cond do
      items != Enum.sort(items) -> {:error, :inventory_not_sorted}
      length(Enum.uniq(items)) != length(items) -> {:error, :duplicate_path}
      true -> :ok
    end
  end

  defp validate_map_keys(map, expected) do
    keys = Map.keys(map)

    cond do
      Enum.any?(keys, &is_atom/1) and Enum.any?(keys, &is_binary/1) ->
        {:error, :mixed_keys}

      not Enum.all?(keys, &is_binary/1) ->
        classify_key_types(keys)

      true ->
        admit_string_keys(map, keys, expected)
    end
  end

  defp classify_key_types(keys) do
    if Enum.any?(keys, &is_atom/1),
      do: {:error, :non_string_keys},
      else: {:error, :invalid_map_keys}
  end

  defp admit_string_keys(_map, keys, expected) do
    case admit_key_bytes(keys) do
      :ok -> exact_key_set(keys, expected)
      error -> error
    end
  end

  defp admit_key_bytes(keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      cond do
        byte_size(key) > @max_key_bytes -> {:halt, {:error, :unbounded}}
        not String.valid?(key) -> {:halt, {:error, :invalid_map_keys}}
        true -> {:cont, :ok}
      end
    end)
  end

  defp exact_key_set(keys, expected) do
    if MapSet.new(keys) == MapSet.new(expected) do
      :ok
    else
      missing = Enum.reject(expected, &(&1 in keys))
      extra_count = Enum.count(keys, &(&1 not in MapSet.new(expected)))
      {:error, {:field_mismatch, %{missing: missing, extra_count: extra_count}}}
    end
  end

  defp take_list(list, max) when is_list(list) do
    take_list(list, max, 0, [])
  end

  defp take_list(_, _), do: {:error, :not_a_list}

  defp take_list([], _max, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_list([head | tail], max, count, acc) do
    if count >= max do
      {:error, :unbounded}
    else
      take_list(tail, max, count + 1, [head | acc])
    end
  end

  defp take_list(_, _, _, _), do: {:error, :improper_list}

  defp admit_path(path) do
    segments = String.split(path, "/", trim: false)

    cond do
      path == "" -> {:error, :unsafe_path}
      String.starts_with?(path, "/") -> {:error, :unsafe_path}
      String.contains?(path, "\\") -> {:error, :unsafe_path}
      String.contains?(path, <<0>>) -> {:error, :unsafe_path}
      not String.valid?(path) -> {:error, :invalid_utf8}
      control_bearing?(path) -> {:error, :control_character}
      byte_size(path) > @max_path_bytes -> {:error, :unbounded}
      length(segments) > @max_path_depth -> {:error, :unbounded}
      Enum.any?(segments, &(&1 in ["", ".", ".."])) -> {:error, :unsafe_path}
      Enum.any?(segments, &(byte_size(&1) > @max_component_bytes)) -> {:error, :unbounded}
      true -> :ok
    end
  end

  defp control_bearing?(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(fn code ->
      code <= 0x1F or code == 0x7F or (code >= 0x80 and code <= 0x9F)
    end)
  end

  defp order_value(map) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)

    cond do
      not Enum.all?(keys, &is_binary/1) ->
        {:error, :non_string_keys}

      not Enum.all?(keys, &String.valid?/1) ->
        {:error, :invalid_utf8}

      true ->
        order_map_pairs(Enum.sort(keys), map, [])
    end
  end

  defp order_value(list) when is_list(list), do: order_list(list, [])

  defp order_value(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_utf8}
  end

  defp order_value(value) when is_integer(value), do: {:ok, value}
  defp order_value(value) when is_boolean(value), do: {:ok, value}
  defp order_value(nil), do: {:ok, nil}
  defp order_value(value) when is_atom(value), do: {:error, :non_string_keys}
  defp order_value(value) when is_float(value), do: {:error, :unsupported_syntax}
  defp order_value(_), do: {:error, :invalid_map}

  defp order_map_pairs([], _map, acc) do
    {:ok, Jason.OrderedObject.new(Enum.reverse(acc))}
  end

  defp order_map_pairs([key | rest], map, acc) do
    case order_value(Map.fetch!(map, key)) do
      {:ok, ordered} -> order_map_pairs(rest, map, [{key, ordered} | acc])
      error -> error
    end
  end

  defp order_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp order_list([head | tail], acc) do
    case order_value(head) do
      {:ok, ordered} -> order_list(tail, [ordered | acc])
      error -> error
    end
  end

  defp order_list(_, _), do: {:error, :improper_list}

  defp encode_capped(ordered) do
    case Jason.encode(ordered) do
      {:ok, bytes} when byte_size(bytes) > @max_canonical_bytes ->
        {:error, :unbounded}

      {:ok, bytes} ->
        {:ok, bytes}

      {:error, %Jason.EncodeError{}} ->
        {:error, :invalid_utf8}

      {:error, _} ->
        {:error, :invalid_map}
    end
  end
end
