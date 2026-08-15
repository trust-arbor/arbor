defmodule Arbor.Commands.SafeRecoveryProfile.Encode do
  @moduledoc """
  Strict canonical JSON and a domain-separated digest for the E0B1
  safe-recovery profile intent.

  Every validator rejects missing, extra, duplicate, malformed, unbounded,
  or non-JSON-safe fields. It never fills a silent default and never falls
  back to `inspect/1`. The digest is computed over canonical bytes and is
  not embedded in the candidate. Pure: no filesystem or process access.
  """

  @schema "arbor.packaging.safe_recovery_profile.intent.v1"
  @intent_domain "arbor.packaging.safe_recovery_profile.intent.v1\0"
  @profile_name "safe_recovery"
  @version 1
  @platform_inventory_schema "arbor.packaging.platform_inventory.v1"
  @selected_file_count 303

  @selected_index_digest "2232c36a5ed7c8f3e06e01fabb0fdb20e1579ee25dda2d9d8df34b5cc494afde"
  @entries_digest "ec219b075dfb941f213df9feb46f248f05aa1f61259a402cde4250165bad0156"
  @review_digest "f674935bc507568df3cb701f097becff7299287de13772b0d8fbd63e4aac2c7a"

  @digest_re ~r/\A[0-9a-f]{64}\z/

  @evidence_statuses MapSet.new(["conformant"])
  @architecture_statuses MapSet.new(["blocked"])

  @application_pairs [
    {"arbor_kernel", "stage_zero"},
    {"arbor_kernel_runtime", "runtime_mechanism"},
    {"arbor_security", "trusted_host"},
    {"arbor_trust", "trusted_host"}
  ]

  @responsibility_pairs [
    {"activation_transaction_mechanics", "arbor_kernel_runtime"},
    {"artifact_verification_and_revocation", "platform_host"},
    {"boot_manifest_verification", "arbor_kernel"},
    {"identity_and_capability_reference_monitor", "arbor_security"},
    {"isolation_and_effect_enforcement", "platform_host"},
    {"lifecycle_security_audit", "platform_host"},
    {"minimal_boot_and_artifact_state", "platform_host"},
    {"safe_mode_management", "platform_host"},
    {"system_ceiling_policy_integration", "arbor_trust"}
  ]

  @facility_ids [
    "dashboard_voice_gateway_and_cognition",
    "dynamic_compile_eval_and_reload",
    "full_signals_monitor_and_os_mon",
    "llm_and_model_calls",
    "oauth_and_network_pools",
    "postgres_sqlite_and_vector_providers",
    "remote_provider_rpc_before_authorization",
    "shell_execution_backends",
    "skill_plugin_scan_and_git_fetch",
    "unverified_or_third_party_in_vm_code"
  ]

  @dependency_pairs [
    {"cryptographic_entropy_and_clock", "host_service"},
    {"host_os_and_installer", "stage_zero"},
    {"local_durable_filesystem", "host_service"},
    {"protected_public_trust_roots", "protected_configuration"}
  ]

  @blocker_pairs [
    {"activation_invocation_contracts_unratified", "e0c_activation_and_invocation_contracts"},
    {"activation_only_runtime_profile_missing", "p1a_safe_profile_closure"},
    {"authenticated_security_sync_transport_missing", "p1b_reference_monitor"},
    {"exact_artifact_payload_manifest_missing", "e0b2_exact_artifact_payload"},
    {"extension_effect_proxy_gaps", "p1d_effect_proxies"},
    {"fixed_host_provider_separation_missing", "p1b_reference_monitor"},
    {"fresh_vm_executable_closure_missing", "e0b3_fresh_vm_executable_closure"},
    {"mandatory_pre_effect_audit_missing", "p1c_authority_state_and_audit"},
    {"mutable_application_env_authority", "p1b_reference_monitor"},
    {"public_ets_authority", "e1a_protected_registry_and_lifecycle_transaction"},
    {"safe_management_surface_missing", "p1a_safe_profile_closure"},
    {"safe_release_payload_not_separated", "p1e_release_separation"},
    {"security_persistence_boot_cycle", "p1c_authority_state_and_audit"}
  ]

  @application_names MapSet.new(Enum.map(@application_pairs, &elem(&1, 0)))
  @application_pair_set MapSet.new(@application_pairs)
  @application_roles MapSet.new(Enum.map(@application_pairs, &elem(&1, 1)))

  @responsibility_ids MapSet.new(Enum.map(@responsibility_pairs, &elem(&1, 0)))
  @responsibility_pair_set MapSet.new(@responsibility_pairs)
  @responsibility_owners MapSet.new(Enum.map(@responsibility_pairs, &elem(&1, 1)))

  @facility_id_set MapSet.new(@facility_ids)

  @dependency_ids MapSet.new(Enum.map(@dependency_pairs, &elem(&1, 0)))
  @dependency_pair_set MapSet.new(@dependency_pairs)
  @dependency_kinds MapSet.new(Enum.map(@dependency_pairs, &elem(&1, 1)))

  @blocker_ids MapSet.new(Enum.map(@blocker_pairs, &elem(&1, 0)))
  @blocker_pair_set MapSet.new(@blocker_pairs)
  @blocker_owners MapSet.new(Enum.map(@blocker_pairs, &elem(&1, 1)))

  @profile_key_order [
    "schema",
    "version",
    "profile",
    "evidence_status",
    "architecture_status",
    "source_inventory",
    "selected_applications",
    "mandatory_host_responsibilities",
    "forbidden_facilities",
    "expected_external_dependencies",
    "blockers"
  ]

  @inventory_key_order [
    "platform_inventory_schema",
    "selected_file_count",
    "selected_index_digest",
    "entries_digest",
    "review_digest"
  ]

  @application_key_order ["name", "role", "rationale"]
  @responsibility_key_order ["id", "owner", "rationale"]
  @facility_key_order ["id", "rationale"]
  @dependency_key_order ["id", "kind", "rationale"]
  @blocker_key_order ["id", "owner", "rationale"]

  @max_map_keys 16
  @max_list_items 32
  @max_key_bytes 256
  @max_short_bytes 256
  @max_rationale_bytes 4000
  @max_file_count 5_000

  @type validation_error :: {:error, term()}

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec profile_name() :: String.t()
  def profile_name, do: @profile_name

  @spec intent_domain() :: binary()
  def intent_domain, do: @intent_domain

  @spec profile_key_order() :: [String.t()]
  def profile_key_order, do: @profile_key_order

  @doc "Strictly validate the canonical string-keyed profile."
  @spec validate_profile(map()) :: :ok | validation_error()
  def validate_profile(profile) when is_map(profile) and not is_struct(profile) do
    with :ok <- bounded_map(profile),
         :ok <- validate_fields(profile, profile_field_specs()),
         :ok <-
           validate_fields(Map.fetch!(profile, "source_inventory"), inventory_field_specs()),
         :ok <-
           validate_named_list(
             Map.fetch!(profile, "selected_applications"),
             application_entry_specs(),
             "name",
             @application_names,
             @application_pair_set,
             &application_pair/1,
             "selected_applications"
           ),
         :ok <-
           validate_named_list(
             Map.fetch!(profile, "mandatory_host_responsibilities"),
             responsibility_entry_specs(),
             "id",
             @responsibility_ids,
             @responsibility_pair_set,
             &responsibility_pair/1,
             "mandatory_host_responsibilities"
           ),
         :ok <-
           validate_id_list(
             Map.fetch!(profile, "forbidden_facilities"),
             facility_entry_specs(),
             @facility_id_set,
             "forbidden_facilities"
           ),
         :ok <-
           validate_named_list(
             Map.fetch!(profile, "expected_external_dependencies"),
             dependency_entry_specs(),
             "id",
             @dependency_ids,
             @dependency_pair_set,
             &dependency_pair/1,
             "expected_external_dependencies"
           ) do
      validate_blockers(
        Map.fetch!(profile, "architecture_status"),
        Map.fetch!(profile, "blockers")
      )
    end
  end

  def validate_profile(_), do: {:error, :invalid_profile}

  @doc "Strictly validate and canonically encode the profile as compact JSON."
  @spec encode_profile(map()) :: {:ok, binary()} | validation_error()
  def encode_profile(profile) do
    with :ok <- validate_profile(profile) do
      {:ok, profile |> sort_profile() |> order_profile() |> Jason.encode!()}
    end
  end

  @doc """
  Validate, then return the lowercase 64-hex SHA-256 of the domain-prefixed
  canonical bytes. The digest is not stored on the candidate.
  """
  @spec profile_digest(map()) :: {:ok, String.t()} | validation_error()
  def profile_digest(profile) do
    with {:ok, bytes} <- encode_profile(profile) do
      digest =
        :crypto.hash(:sha256, [@intent_domain, bytes])
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  defp profile_field_specs do
    [
      {"schema", &valid_schema?/1},
      {"version", &valid_version?/1},
      {"profile", &valid_profile_name?/1},
      {"evidence_status",
       fn value -> member_or_error(value, @evidence_statuses, :unknown_evidence_status) end},
      {"architecture_status",
       fn value ->
         member_or_error(value, @architecture_statuses, :unknown_architecture_status)
       end},
      {"source_inventory", &valid_map?/1},
      {"selected_applications", &valid_bounded_list?/1},
      {"mandatory_host_responsibilities", &valid_bounded_list?/1},
      {"forbidden_facilities", &valid_bounded_list?/1},
      {"expected_external_dependencies", &valid_bounded_list?/1},
      {"blockers", &valid_bounded_list?/1}
    ]
  end

  defp inventory_field_specs do
    [
      {"platform_inventory_schema", &valid_platform_inventory_schema?/1},
      {"selected_file_count", &valid_selected_file_count?/1},
      {"selected_index_digest",
       fn value -> valid_frozen_digest?(@selected_index_digest, value) end},
      {"entries_digest", fn value -> valid_frozen_digest?(@entries_digest, value) end},
      {"review_digest", fn value -> valid_frozen_digest?(@review_digest, value) end}
    ]
  end

  defp application_entry_specs do
    [
      {"name", fn value -> member_or_error(value, @application_names, :unknown_name) end},
      {"role", fn value -> member_or_error(value, @application_roles, :unknown_role) end},
      {"rationale", &valid_rationale?/1}
    ]
  end

  defp responsibility_entry_specs do
    [
      {"id", fn value -> member_or_error(value, @responsibility_ids, :unknown_id) end},
      {"owner", fn value -> member_or_error(value, @responsibility_owners, :unknown_owner) end},
      {"rationale", &valid_rationale?/1}
    ]
  end

  defp facility_entry_specs do
    [
      {"id", fn value -> member_or_error(value, @facility_id_set, :unknown_id) end},
      {"rationale", &valid_rationale?/1}
    ]
  end

  defp dependency_entry_specs do
    [
      {"id", fn value -> member_or_error(value, @dependency_ids, :unknown_id) end},
      {"kind", fn value -> member_or_error(value, @dependency_kinds, :unknown_kind) end},
      {"rationale", &valid_rationale?/1}
    ]
  end

  defp blocker_entry_specs do
    [
      {"id", fn value -> member_or_error(value, @blocker_ids, :unknown_id) end},
      {"owner", fn value -> member_or_error(value, @blocker_owners, :unknown_owner) end},
      {"rationale", &valid_rationale?/1}
    ]
  end

  defp application_pair(entry), do: {entry["name"], entry["role"]}
  defp responsibility_pair(entry), do: {entry["id"], entry["owner"]}
  defp dependency_pair(entry), do: {entry["id"], entry["kind"]}
  defp blocker_pair(entry), do: {entry["id"], entry["owner"]}

  defp validate_blockers("blocked", blockers) do
    case take_proper_list(blockers, @max_list_items) do
      {:ok, []} ->
        {:error, {:invalid_field, "architecture_status", :inconsistent_status}}

      {:ok, items} ->
        validate_named_items(
          items,
          blocker_entry_specs(),
          "id",
          @blocker_ids,
          @blocker_pair_set,
          &blocker_pair/1,
          "blockers"
        )

      {:error, reason} ->
        {:error, {:invalid_field, "blockers", reason}}
    end
  end

  defp validate_blockers(_status, _blockers) do
    {:error, {:invalid_field, "architecture_status", :unknown_architecture_status}}
  end

  defp validate_named_list(list, specs, id_key, id_set, pair_set, pair_fun, field) do
    case take_proper_list(list, @max_list_items) do
      {:ok, items} ->
        validate_named_items(items, specs, id_key, id_set, pair_set, pair_fun, field)

      {:error, reason} ->
        {:error, {:invalid_field, field, reason}}
    end
  end

  defp validate_id_list(list, specs, id_set, field) do
    case take_proper_list(list, @max_list_items) do
      {:ok, items} ->
        with :ok <- validate_entry_items(items, specs, "id", field) do
          ids = Enum.map(items, &Map.fetch!(&1, "id"))

          if MapSet.new(ids) == id_set do
            :ok
          else
            {:error, {:invalid_field, field, :set_mismatch}}
          end
        end

      {:error, reason} ->
        {:error, {:invalid_field, field, reason}}
    end
  end

  defp validate_named_items(items, specs, id_key, id_set, pair_set, pair_fun, field) do
    with :ok <- validate_entry_items(items, specs, id_key, field) do
      ids = Enum.map(items, &Map.fetch!(&1, id_key))
      pairs = MapSet.new(Enum.map(items, pair_fun))

      cond do
        MapSet.new(ids) != id_set ->
          {:error, {:invalid_field, field, :set_mismatch}}

        pairs != pair_set ->
          {:error, {:invalid_field, field, :pairing_mismatch}}

        true ->
          :ok
      end
    end
  end

  defp validate_entry_items(items, specs, id_key, field) do
    Enum.reduce_while(items, {:ok, MapSet.new()}, fn item, {:ok, seen} ->
      with :ok <- bounded_map(item),
           :ok <- validate_fields(item, specs) do
        id = Map.fetch!(item, id_key)

        if MapSet.member?(seen, id) do
          {:halt, {:error, {:invalid_field, field, :duplicate_ids}}}
        else
          {:cont, {:ok, MapSet.put(seen, id)}}
        end
      else
        {:error, {:invalid_field, _, _}} = error ->
          {:halt, error}

        {:error, reason} ->
          {:halt, {:error, {:invalid_field, field, reason}}}
      end
    end)
    |> case do
      {:ok, _seen} -> :ok
      {:error, _} = error -> error
    end
  end

  defp validate_fields(map, specs) when is_map(map) and not is_struct(map) do
    keys = Map.keys(map)
    expected_keys = Enum.map(specs, &elem(&1, 0))

    cond do
      map_size(map) > @max_map_keys ->
        {:error, :unbounded}

      not Enum.all?(keys, &is_binary/1) ->
        if Enum.any?(keys, &is_atom/1) and Enum.any?(keys, &is_binary/1) do
          {:error, :mixed_keys}
        else
          {:error, :non_string_keys}
        end

      true ->
        with :ok <- admit_map_keys(keys) do
          if MapSet.new(keys) != MapSet.new(expected_keys) do
            field_mismatch(keys, expected_keys)
          else
            Enum.reduce_while(specs, :ok, fn {key, validator}, :ok ->
              case validator.(Map.fetch!(map, key)) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, {:invalid_field, key, reason}}}
              end
            end)
          end
        end
    end
  end

  defp validate_fields(_, _), do: {:error, :invalid_map}

  defp admit_map_keys(keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case admit_map_key(key) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp admit_map_key(key) when is_binary(key) do
    cond do
      byte_size(key) > @max_key_bytes -> {:error, :unbounded}
      not String.valid?(key) -> {:error, :invalid_map_keys}
      true -> :ok
    end
  end

  defp admit_map_key(_), do: {:error, :invalid_map_keys}

  defp field_mismatch(keys, expected_keys) do
    expected_set = MapSet.new(expected_keys)
    missing = Enum.reject(expected_keys, &(&1 in keys))
    extra_count = Enum.count(keys, &(&1 not in expected_set))

    {:error, {:field_mismatch, %{missing: missing, extra_count: extra_count}}}
  end

  defp bounded_map(map) when is_map(map) and not is_struct(map) do
    if map_size(map) > @max_map_keys, do: {:error, :unbounded}, else: :ok
  end

  defp bounded_map(_), do: {:error, :invalid_map}

  defp valid_map?(value) when is_map(value) and not is_struct(value), do: bounded_map(value)
  defp valid_map?(_), do: {:error, :not_a_map}

  defp valid_bounded_list?(list), do: bounded_list_result(take_proper_list(list, @max_list_items))

  defp bounded_list_result({:ok, _items}), do: :ok
  defp bounded_list_result({:error, reason}), do: {:error, reason}

  defp take_proper_list([], _max), do: {:ok, []}

  defp take_proper_list([head | tail], max) do
    take_proper_list(tail, max, 1, [head])
  end

  defp take_proper_list(_, _), do: {:error, :not_a_list}

  defp take_proper_list([], _max, _count, acc), do: {:ok, Enum.reverse(acc)}

  defp take_proper_list([head | tail], max, count, acc) do
    if count >= max do
      {:error, :unbounded}
    else
      take_proper_list(tail, max, count + 1, [head | acc])
    end
  end

  defp take_proper_list(_, _, _, _), do: {:error, :improper_list}

  defp valid_schema?(value) when is_binary(value) do
    if value == @schema, do: :ok, else: {:error, :invalid_schema}
  end

  defp valid_schema?(_), do: {:error, :not_a_string}

  defp valid_version?(@version), do: :ok
  defp valid_version?(value) when is_integer(value), do: {:error, :invalid_version}
  defp valid_version?(_), do: {:error, :not_an_integer}

  defp valid_profile_name?(value) when is_binary(value) do
    if value == @profile_name, do: :ok, else: {:error, :invalid_profile}
  end

  defp valid_profile_name?(_), do: {:error, :not_a_string}

  defp valid_platform_inventory_schema?(value) when is_binary(value) do
    if value == @platform_inventory_schema, do: :ok, else: {:error, :invalid_schema}
  end

  defp valid_platform_inventory_schema?(_), do: {:error, :not_a_string}

  defp valid_selected_file_count?(@selected_file_count), do: :ok

  defp valid_selected_file_count?(value) when is_integer(value) do
    cond do
      value < 0 -> {:error, :negative}
      value > @max_file_count -> {:error, :unbounded}
      true -> {:error, :count_mismatch}
    end
  end

  defp valid_selected_file_count?(_), do: {:error, :not_an_integer}

  defp valid_frozen_digest?(expected, value) when is_binary(value) do
    cond do
      byte_size(value) != 64 -> {:error, :invalid_digest}
      not Regex.match?(@digest_re, value) -> {:error, :invalid_digest}
      value != expected -> {:error, :digest_mismatch}
      true -> :ok
    end
  end

  defp valid_frozen_digest?(_expected, _), do: {:error, :not_a_string}

  defp valid_rationale?(value), do: valid_text(value, @max_rationale_bytes)

  defp member_or_error(value, set, tag) when is_binary(value) do
    with :ok <- valid_text(value, @max_short_bytes) do
      if MapSet.member?(set, value), do: :ok, else: {:error, tag}
    end
  end

  defp member_or_error(_, _, _), do: {:error, :not_a_string}

  defp valid_text(value, max_bytes) when is_binary(value) do
    cond do
      byte_size(value) > max_bytes -> {:error, :unbounded}
      not String.valid?(value) -> {:error, :invalid_utf8}
      String.trim(value) == "" -> {:error, :blank}
      control_bearing?(value) -> {:error, :control_character}
      true -> :ok
    end
  end

  defp valid_text(_, _), do: {:error, :not_a_string}

  defp control_bearing?(value) do
    value
    |> String.to_charlist()
    |> Enum.any?(fn codepoint ->
      codepoint <= 0x1F or codepoint == 0x7F or (codepoint >= 0x80 and codepoint <= 0x9F)
    end)
  end

  defp sort_profile(profile) do
    %{
      profile
      | "selected_applications" =>
          Enum.sort_by(Map.fetch!(profile, "selected_applications"), & &1["name"]),
        "mandatory_host_responsibilities" =>
          Enum.sort_by(Map.fetch!(profile, "mandatory_host_responsibilities"), & &1["id"]),
        "forbidden_facilities" =>
          Enum.sort_by(Map.fetch!(profile, "forbidden_facilities"), & &1["id"]),
        "expected_external_dependencies" =>
          Enum.sort_by(Map.fetch!(profile, "expected_external_dependencies"), & &1["id"]),
        "blockers" => Enum.sort_by(Map.fetch!(profile, "blockers"), & &1["id"])
    }
  end

  defp order_profile(profile) do
    Jason.OrderedObject.new(
      Enum.map(@profile_key_order, fn
        "source_inventory" ->
          {"source_inventory",
           order_fields(Map.fetch!(profile, "source_inventory"), @inventory_key_order)}

        "selected_applications" ->
          {"selected_applications",
           Enum.map(
             Map.fetch!(profile, "selected_applications"),
             &order_fields(&1, @application_key_order)
           )}

        "mandatory_host_responsibilities" ->
          {"mandatory_host_responsibilities",
           Enum.map(
             Map.fetch!(profile, "mandatory_host_responsibilities"),
             &order_fields(&1, @responsibility_key_order)
           )}

        "forbidden_facilities" ->
          {"forbidden_facilities",
           Enum.map(
             Map.fetch!(profile, "forbidden_facilities"),
             &order_fields(&1, @facility_key_order)
           )}

        "expected_external_dependencies" ->
          {"expected_external_dependencies",
           Enum.map(
             Map.fetch!(profile, "expected_external_dependencies"),
             &order_fields(&1, @dependency_key_order)
           )}

        "blockers" ->
          {"blockers",
           Enum.map(Map.fetch!(profile, "blockers"), &order_fields(&1, @blocker_key_order))}

        key ->
          {key, Map.fetch!(profile, key)}
      end)
    )
  end

  defp order_fields(map, key_order) do
    Jason.OrderedObject.new(Enum.map(key_order, &{&1, Map.fetch!(map, &1)}))
  end
end
