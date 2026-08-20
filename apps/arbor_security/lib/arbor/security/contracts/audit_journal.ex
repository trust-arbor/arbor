defmodule Arbor.Security.Contracts.AuditJournal do
  @moduledoc """
  Security-owned v1 authority-mutation intent and append-record contracts.

  Wire kinds:
  - intent: `arbor.security.authority_mutation_intent.v1`
  - record: `arbor.security.authority_mutation_record.v1`

  Pure only: no IO, time, randomness, processes, ETS, logging, signals, or
  store/facade calls. Time and identifiers enter as validated data.
  """

  @version 1
  @intent_kind "arbor.security.authority_mutation_intent.v1"
  @record_kind "arbor.security.authority_mutation_record.v1"
  @intent_domain "arbor.security.authority_mutation_intent.v1" <> <<0>>
  @record_domain "arbor.security.authority_mutation_record.v1" <> <<0>>

  @operations ["capability_grant", "capability_revoke"]
  @effect_classes ["authority_increase", "authority_reduce"]
  @record_types ["prepared", "effect_applied", "effect_rejected", "delivered"]
  @namespaces ["capability"]
  @rejected_reasons ["before_mismatch", "identity_conflict", "not_found", "cas_conflict"]
  @indeterminate_kinds ["unavailable", "indeterminate", "unknown", "outcome_unknown"]

  @max_intent_bytes 16_384
  @max_record_bytes 32_768
  @hard_entry_cap 48
  @reserve_entries 16
  @soft_entry_cap 32
  @hard_byte_cap 131_072
  @reserve_bytes 32_768
  @soft_byte_cap 98_304
  @max_principal_bytes 256
  @max_resource_bytes 2_048
  @max_record_id_bytes 128
  @max_authority_key_bytes 36
  @max_actor_bytes 256
  @max_correlation_bytes 128
  @max_json_safe_int 9_007_199_254_740_991
  @max_depth 4
  @max_nodes 64

  @intent_required ~w(
    version kind operation effect_class authority_namespace authority_key
    before_fence after_fingerprint audit prepared_at
  )
  @intent_optional ~w(actor_id task_id session_id correlation_id causation_id)
  @intent_keys @intent_required ++ @intent_optional ++ ["operation_id"]
  @intent_max_keys 16

  @intent_fact_order ~w(
    version kind operation effect_class authority_namespace authority_key
    before_fence after_fingerprint audit prepared_at actor_id task_id
    session_id correlation_id causation_id
  )
  @intent_stored_order @intent_fact_order ++ ["operation_id"]

  @prepared_keys ~w(version kind record_type operation_id occurred_at intent)
  @applied_keys ~w(version kind record_type operation_id occurred_at observation)
  @delivered_keys ~w(version kind record_type operation_id occurred_at)
  @record_max_keys 6

  @absent_keys ["kind"]
  @live_keys ~w(kind record_id generation revision capability_digest)
  @tombstone_keys ~w(kind generation)
  @audit_keys ~w(event_type data)
  @grant_data_keys ~w(capability_id principal_id resource_uri expires_at)
  @revoke_data_keys ~w(capability_id principal_id resource_uri)
  @applied_observation_keys ~w(kind after_fingerprint)
  @rejected_observation_keys ~w(kind reason)

  @live_order ~w(kind record_id generation revision capability_digest)
  @tombstone_order ~w(kind generation)
  @audit_order ~w(event_type data)
  @grant_data_order ~w(capability_id principal_id resource_uri expires_at)
  @revoke_data_order ~w(capability_id principal_id resource_uri)
  @prepared_order @prepared_keys
  @applied_order @applied_keys
  @delivered_order @delivered_keys

  @forbidden_names MapSet.new(~w(
    capability token secret password private_key issuer_signature signing_key
    bearer credentials callback metadata terms prose note reason_text
    constraints delegation_chain
  ))

  @capability_id_re ~r/\Acap_[0-9a-f]{32}\z/
  @hex64_re ~r/\A[0-9a-f]{64}\z/
  @timestamp_re ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/
  @control_re ~r/[\x00-\x1F\x7F]/

  @type error ::
          :malformed
          | :invalid_object
          | :struct_not_allowed
          | :atom_key_not_allowed
          | :unknown_field
          | :missing_field
          | :invalid_field
          | {:invalid_field, String.t()}
          | :unsupported_operation
          | :effect_class_mismatch
          | :audit_event_mismatch
          | :unsupported_version
          | :invalid_utf8
          | :integer_out_of_range
          | :float_not_allowed
          | :improper_list
          | :intent_too_large
          | :record_too_large
          | :forbidden_content
          | :before_after_incompatible
          | :operation_id_mismatch
          | :indeterminate_observation
          | :cross_operation

  @spec version() :: 1
  def version, do: @version

  @spec intent_kind() :: String.t()
  def intent_kind, do: @intent_kind

  @spec record_kind() :: String.t()
  def record_kind, do: @record_kind

  @spec intent_domain() :: binary()
  def intent_domain, do: @intent_domain

  @spec record_domain() :: binary()
  def record_domain, do: @record_domain

  @spec operations() :: [String.t()]
  def operations, do: @operations

  @spec effect_classes() :: [String.t()]
  def effect_classes, do: @effect_classes

  @spec record_types() :: [String.t()]
  def record_types, do: @record_types

  @spec namespaces() :: [String.t()]
  def namespaces, do: @namespaces

  @spec rejected_reasons() :: [String.t()]
  def rejected_reasons, do: @rejected_reasons

  @spec enums() :: map()
  def enums do
    %{
      operations: @operations,
      effect_classes: @effect_classes,
      record_types: @record_types,
      namespaces: @namespaces,
      rejected_reasons: @rejected_reasons
    }
  end

  @spec limits() :: map()
  def limits do
    %{
      max_intent_bytes: @max_intent_bytes,
      max_record_bytes: @max_record_bytes,
      hard_entry_cap: @hard_entry_cap,
      reserve_entries: @reserve_entries,
      soft_entry_cap: @soft_entry_cap,
      hard_byte_cap: @hard_byte_cap,
      reserve_bytes: @reserve_bytes,
      soft_byte_cap: @soft_byte_cap,
      max_principal_bytes: @max_principal_bytes,
      max_resource_bytes: @max_resource_bytes,
      max_record_id_bytes: @max_record_id_bytes,
      max_authority_key_bytes: @max_authority_key_bytes,
      max_actor_bytes: @max_actor_bytes,
      max_task_bytes: @max_actor_bytes,
      max_session_bytes: @max_actor_bytes,
      max_correlation_bytes: @max_correlation_bytes,
      max_causation_bytes: @max_correlation_bytes,
      max_json_safe_int: @max_json_safe_int,
      max_depth: @max_depth,
      max_nodes: @max_nodes,
      max_keys: %{
        intent: @intent_max_keys,
        prepared_record: length(@prepared_keys),
        effect_applied_record: length(@applied_keys),
        effect_rejected_record: length(@applied_keys),
        delivered_record: length(@delivered_keys),
        absent: 1,
        live: length(@live_keys),
        tombstone: length(@tombstone_keys),
        audit: length(@audit_keys),
        grant_audit_data: length(@grant_data_keys),
        revoke_audit_data: length(@revoke_data_keys),
        applied_observation: length(@applied_observation_keys),
        rejected_observation: length(@rejected_observation_keys)
      }
    }
  end

  @spec effect_class_for(term()) :: {:ok, String.t()} | {:error, :unsupported_operation}
  def effect_class_for("capability_grant"), do: {:ok, "authority_increase"}
  def effect_class_for("capability_revoke"), do: {:ok, "authority_reduce"}
  def effect_class_for(_operation), do: {:error, :unsupported_operation}

  @spec admit_intent(term()) :: {:ok, map()} | {:error, error()}
  def admit_intent(input) do
    with {:ok, admitted, derived, supplied} <- admit_intent_core(input),
         :ok <- verify_supplied_operation_id(supplied, derived) do
      {:ok, admitted}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec canonical_intent_bytes(term()) :: {:ok, binary()} | {:error, error()}
  def canonical_intent_bytes(input) do
    with {:ok, admitted} <- admit_intent(input) do
      encode_intent_facts(admitted)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec operation_id(term()) :: {:ok, String.t()} | {:error, error()}
  def operation_id(input) do
    with {:ok, admitted} <- admit_intent(input) do
      {:ok, admitted["operation_id"]}
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec admit_record(term()) :: {:ok, map()} | {:error, error()}
  def admit_record(input) do
    do_admit_record(input)
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  @spec canonical_record_bytes(term()) :: {:ok, binary()} | {:error, error()}
  def canonical_record_bytes(input) do
    with {:ok, record} <- admit_record(input) do
      encode_record(record)
    end
  rescue
    _ -> {:error, :malformed}
  catch
    _, _ -> {:error, :malformed}
  end

  # ---------------------------------------------------------------------------
  # Intent
  # ---------------------------------------------------------------------------

  defp admit_intent_core(input) do
    with :ok <- budget_ok(input, 0, 0),
         {:ok, attrs} <- admit_object(input, @intent_keys, @intent_max_keys),
         :ok <- require_keys(attrs, @intent_required),
         {:ok, version} <- admit_version(Map.fetch!(attrs, "version")),
         {:ok, kind} <- admit_exact(Map.fetch!(attrs, "kind"), @intent_kind, "kind"),
         {:ok, operation} <- admit_operation(Map.fetch!(attrs, "operation")),
         {:ok, effect_class} <-
           admit_effect_class(Map.fetch!(attrs, "effect_class"), operation),
         {:ok, namespace} <- admit_namespace(Map.fetch!(attrs, "authority_namespace")),
         {:ok, authority_key} <- admit_authority_key(Map.fetch!(attrs, "authority_key")),
         {:ok, before_fence} <- admit_expectation(Map.fetch!(attrs, "before_fence")),
         {:ok, after_fingerprint} <- admit_expectation(Map.fetch!(attrs, "after_fingerprint")),
         :ok <- compatible_before_after(operation, before_fence, after_fingerprint),
         {:ok, audit} <- admit_audit(Map.fetch!(attrs, "audit"), operation, authority_key),
         {:ok, prepared_at} <- admit_timestamp(Map.fetch!(attrs, "prepared_at"), "prepared_at"),
         {:ok, optionals} <- admit_intent_optionals(attrs) do
      admitted =
        %{
          "version" => version,
          "kind" => kind,
          "operation" => operation,
          "effect_class" => effect_class,
          "authority_namespace" => namespace,
          "authority_key" => authority_key,
          "before_fence" => before_fence,
          "after_fingerprint" => after_fingerprint,
          "audit" => audit,
          "prepared_at" => prepared_at
        }
        |> merge_optionals(optionals)

      with {:ok, fact_bytes} <- encode_intent_facts(admitted) do
        derived = derive_operation_id(fact_bytes)
        supplied = Map.get(attrs, "operation_id", :absent)
        {:ok, Map.put(admitted, "operation_id", derived), derived, supplied}
      end
    end
  end

  defp verify_supplied_operation_id(:absent, _derived), do: :ok
  defp verify_supplied_operation_id(supplied, derived) when supplied == derived, do: :ok
  defp verify_supplied_operation_id(_supplied, _derived), do: {:error, :operation_id_mismatch}

  defp admit_operation(value) when value in @operations, do: {:ok, value}
  defp admit_operation(_value), do: {:error, :unsupported_operation}

  defp admit_effect_class(value, operation) do
    case effect_class_for(operation) do
      {:ok, expected} when value == expected -> {:ok, value}
      {:ok, _expected} -> {:error, :effect_class_mismatch}
      {:error, _} = err -> err
    end
  end

  defp admit_namespace("capability"), do: {:ok, "capability"}
  defp admit_namespace(_value), do: {:error, :unsupported_operation}

  defp admit_authority_key(value) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      byte_size(value) > @max_authority_key_bytes -> {:error, :invalid_field}
      not Regex.match?(@capability_id_re, value) -> {:error, {:invalid_field, "authority_key"}}
      true -> {:ok, value}
    end
  end

  defp admit_authority_key(_value), do: {:error, {:invalid_field, "authority_key"}}

  defp admit_intent_optionals(attrs) do
    with {:ok, actor_id} <- optional_bounded(attrs, "actor_id", @max_actor_bytes),
         {:ok, task_id} <- optional_bounded(attrs, "task_id", @max_actor_bytes),
         {:ok, session_id} <- optional_bounded(attrs, "session_id", @max_actor_bytes),
         {:ok, correlation_id} <-
           optional_bounded(attrs, "correlation_id", @max_correlation_bytes),
         {:ok, causation_id} <- optional_bounded(attrs, "causation_id", @max_correlation_bytes) do
      {:ok,
       %{
         "actor_id" => actor_id,
         "task_id" => task_id,
         "session_id" => session_id,
         "correlation_id" => correlation_id,
         "causation_id" => causation_id
       }}
    end
  end

  defp merge_optionals(map, optionals) do
    Enum.reduce(optionals, map, fn
      {_key, :omit}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp derive_operation_id(fact_bytes) do
    :crypto.hash(:sha256, @intent_domain <> fact_bytes)
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Records
  # ---------------------------------------------------------------------------

  defp do_admit_record(input) do
    with :ok <- budget_ok(input, 0, 0),
         {:ok, attrs} <- admit_object(input, record_allowed_keys(), @record_max_keys),
         :ok <- require_keys(attrs, ~w(version kind record_type operation_id occurred_at)),
         {:ok, version} <- admit_version(Map.fetch!(attrs, "version")),
         {:ok, kind} <- admit_exact(Map.fetch!(attrs, "kind"), @record_kind, "kind"),
         {:ok, record_type} <- admit_record_type(Map.fetch!(attrs, "record_type")),
         :ok <- require_exact_record_keys(attrs, record_type),
         {:ok, operation_id} <- admit_hex64(Map.fetch!(attrs, "operation_id"), "operation_id"),
         {:ok, occurred_at} <- admit_timestamp(Map.fetch!(attrs, "occurred_at"), "occurred_at") do
      admit_record_by_type(attrs, version, kind, record_type, operation_id, occurred_at)
    end
  end

  defp record_allowed_keys do
    Enum.uniq(@prepared_keys ++ @applied_keys ++ @delivered_keys)
  end

  defp admit_record_type(value) when value in @record_types, do: {:ok, value}
  defp admit_record_type(_value), do: {:error, :invalid_field}

  defp require_exact_record_keys(attrs, "prepared"),
    do: require_exact_keys(attrs, @prepared_keys)

  defp require_exact_record_keys(attrs, "effect_applied"),
    do: require_exact_keys(attrs, @applied_keys)

  defp require_exact_record_keys(attrs, "effect_rejected"),
    do: require_exact_keys(attrs, @applied_keys)

  defp require_exact_record_keys(attrs, "delivered"),
    do: require_exact_keys(attrs, @delivered_keys)

  defp admit_record_by_type(attrs, version, kind, "prepared", operation_id, occurred_at) do
    with {:ok, intent, derived, supplied} <- admit_intent_core(Map.fetch!(attrs, "intent")),
         :ok <- occurred_at_matches_prepared(occurred_at, intent["prepared_at"]),
         :ok <- cross_operation_check(operation_id, derived, supplied) do
      {:ok,
       %{
         "version" => version,
         "kind" => kind,
         "record_type" => "prepared",
         "operation_id" => operation_id,
         "occurred_at" => occurred_at,
         "intent" => intent
       }}
    end
  end

  defp admit_record_by_type(attrs, version, kind, "effect_applied", operation_id, occurred_at) do
    with {:ok, observation} <- admit_applied_observation(Map.fetch!(attrs, "observation")) do
      {:ok,
       %{
         "version" => version,
         "kind" => kind,
         "record_type" => "effect_applied",
         "operation_id" => operation_id,
         "occurred_at" => occurred_at,
         "observation" => observation
       }}
    end
  end

  defp admit_record_by_type(attrs, version, kind, "effect_rejected", operation_id, occurred_at) do
    with {:ok, observation} <- admit_rejected_observation(Map.fetch!(attrs, "observation")) do
      {:ok,
       %{
         "version" => version,
         "kind" => kind,
         "record_type" => "effect_rejected",
         "operation_id" => operation_id,
         "occurred_at" => occurred_at,
         "observation" => observation
       }}
    end
  end

  defp admit_record_by_type(_attrs, version, kind, "delivered", operation_id, occurred_at) do
    {:ok,
     %{
       "version" => version,
       "kind" => kind,
       "record_type" => "delivered",
       "operation_id" => operation_id,
       "occurred_at" => occurred_at
     }}
  end

  defp occurred_at_matches_prepared(occurred_at, prepared_at) when occurred_at == prepared_at,
    do: :ok

  defp occurred_at_matches_prepared(_occurred_at, _prepared_at),
    do: {:error, {:invalid_field, "occurred_at"}}

  defp cross_operation_check(record_oid, derived, supplied) do
    intent_oid =
      case supplied do
        :absent -> derived
        value -> value
      end

    if record_oid == derived and intent_oid == derived do
      :ok
    else
      {:error, :cross_operation}
    end
  end

  defp admit_applied_observation(value) do
    with {:ok, attrs} <-
           admit_object(value, @applied_observation_keys, length(@applied_observation_keys)),
         :ok <- require_keys(attrs, @applied_observation_keys),
         {:ok, kind} <- observation_kind(Map.fetch!(attrs, "kind"), "applied"),
         {:ok, after_fingerprint} <- admit_expectation(Map.fetch!(attrs, "after_fingerprint")) do
      {:ok, %{"kind" => kind, "after_fingerprint" => after_fingerprint}}
    end
  end

  defp admit_rejected_observation(value) do
    with {:ok, attrs} <-
           admit_object(value, @rejected_observation_keys, length(@rejected_observation_keys)),
         :ok <- require_keys(attrs, @rejected_observation_keys),
         {:ok, kind} <- observation_kind(Map.fetch!(attrs, "kind"), "rejected"),
         {:ok, reason} <- admit_rejected_reason(Map.fetch!(attrs, "reason")) do
      {:ok, %{"kind" => kind, "reason" => reason}}
    end
  end

  defp observation_kind(kind, expected) when kind == expected, do: {:ok, kind}

  defp observation_kind(kind, _expected) when kind in @indeterminate_kinds,
    do: {:error, :indeterminate_observation}

  defp observation_kind(_kind, _expected), do: {:error, {:invalid_field, "kind"}}

  defp admit_rejected_reason(reason) when reason in @rejected_reasons, do: {:ok, reason}
  defp admit_rejected_reason(_reason), do: {:error, {:invalid_field, "reason"}}

  # ---------------------------------------------------------------------------
  # Expectations and audit
  # ---------------------------------------------------------------------------

  defp admit_expectation(value) do
    with {:ok, attrs} <- admit_object(value, @live_keys, length(@live_keys)),
         {:ok, kind} <- expectation_kind(attrs) do
      admit_expectation_kind(kind, attrs)
    end
  end

  defp expectation_kind(%{"kind" => kind})
       when kind in ["absent", "live", "tombstone"],
       do: {:ok, kind}

  defp expectation_kind(attrs) do
    if Map.has_key?(attrs, "kind"),
      do: {:error, {:invalid_field, "kind"}},
      else: {:error, :missing_field}
  end

  defp admit_expectation_kind("absent", attrs) do
    with :ok <- require_exact_keys(attrs, @absent_keys) do
      {:ok, %{"kind" => "absent"}}
    end
  end

  defp admit_expectation_kind("live", attrs) do
    with :ok <- require_exact_keys(attrs, @live_keys),
         {:ok, record_id} <-
           admit_bounded_id(Map.fetch!(attrs, "record_id"), @max_record_id_bytes, "record_id"),
         {:ok, generation} <- admit_positive_int(Map.fetch!(attrs, "generation"), "generation"),
         {:ok, revision} <- admit_positive_int(Map.fetch!(attrs, "revision"), "revision"),
         {:ok, digest} <-
           admit_hex64(Map.fetch!(attrs, "capability_digest"), "capability_digest") do
      {:ok,
       %{
         "kind" => "live",
         "record_id" => record_id,
         "generation" => generation,
         "revision" => revision,
         "capability_digest" => digest
       }}
    end
  end

  defp admit_expectation_kind("tombstone", attrs) do
    with :ok <- require_exact_keys(attrs, @tombstone_keys),
         {:ok, generation} <- admit_positive_int(Map.fetch!(attrs, "generation"), "generation") do
      {:ok, %{"kind" => "tombstone", "generation" => generation}}
    end
  end

  defp compatible_before_after("capability_grant", %{"kind" => "absent"}, after_fp) do
    grant_live_successor(after_fp, 1)
  end

  defp compatible_before_after(
         "capability_grant",
         %{"kind" => "tombstone", "generation" => generation},
         after_fp
       ) do
    expected = generation + 1

    if expected <= @max_json_safe_int do
      grant_live_successor(after_fp, expected)
    else
      {:error, :integer_out_of_range}
    end
  end

  defp compatible_before_after(
         "capability_revoke",
         %{"kind" => "live", "generation" => generation},
         %{"kind" => "tombstone", "generation" => generation}
       ),
       do: :ok

  defp compatible_before_after(_operation, _before, _after),
    do: {:error, :before_after_incompatible}

  defp grant_live_successor(
         %{"kind" => "live", "generation" => expected, "revision" => 1},
         expected
       ),
       do: :ok

  defp grant_live_successor(_after_fp, _expected), do: {:error, :before_after_incompatible}

  defp admit_audit(value, operation, authority_key) do
    with {:ok, attrs} <- admit_object(value, @audit_keys, length(@audit_keys)),
         :ok <- require_exact_keys(attrs, @audit_keys),
         {:ok, event_type} <- admit_event_type(Map.fetch!(attrs, "event_type"), operation),
         {:ok, data} <- admit_audit_data(Map.fetch!(attrs, "data"), operation, authority_key) do
      {:ok, %{"event_type" => event_type, "data" => data}}
    end
  end

  defp admit_event_type("capability_granted", "capability_grant"),
    do: {:ok, "capability_granted"}

  defp admit_event_type("capability_revoked", "capability_revoke"),
    do: {:ok, "capability_revoked"}

  defp admit_event_type(_event_type, _operation), do: {:error, :audit_event_mismatch}

  defp admit_audit_data(value, "capability_grant", authority_key) do
    with {:ok, attrs} <- admit_object(value, @grant_data_keys, length(@grant_data_keys)),
         :ok <- require_keys(attrs, ~w(capability_id principal_id resource_uri)),
         :ok <- reject_unknown_relative(attrs, @grant_data_keys),
         {:ok, capability_id} <- admit_capability_id(Map.fetch!(attrs, "capability_id")),
         true <- capability_id == authority_key,
         {:ok, principal_id} <-
           admit_bounded_id(
             Map.fetch!(attrs, "principal_id"),
             @max_principal_bytes,
             "principal_id"
           ),
         {:ok, resource_uri} <-
           admit_bounded_id(
             Map.fetch!(attrs, "resource_uri"),
             @max_resource_bytes,
             "resource_uri"
           ),
         {:ok, expires_at} <- optional_timestamp(attrs, "expires_at") do
      data = %{
        "capability_id" => capability_id,
        "principal_id" => principal_id,
        "resource_uri" => resource_uri
      }

      {:ok, put_optional(data, "expires_at", expires_at)}
    else
      false -> {:error, {:invalid_field, "capability_id"}}
      {:error, _} = err -> err
    end
  end

  defp admit_audit_data(value, "capability_revoke", authority_key) do
    with {:ok, attrs} <- admit_object(value, @revoke_data_keys, length(@revoke_data_keys)),
         :ok <- require_exact_keys(attrs, @revoke_data_keys),
         {:ok, capability_id} <- admit_capability_id(Map.fetch!(attrs, "capability_id")),
         true <- capability_id == authority_key,
         {:ok, principal_id} <-
           admit_bounded_id(
             Map.fetch!(attrs, "principal_id"),
             @max_principal_bytes,
             "principal_id"
           ),
         {:ok, resource_uri} <-
           admit_bounded_id(
             Map.fetch!(attrs, "resource_uri"),
             @max_resource_bytes,
             "resource_uri"
           ) do
      {:ok,
       %{
         "capability_id" => capability_id,
         "principal_id" => principal_id,
         "resource_uri" => resource_uri
       }}
    else
      false -> {:error, {:invalid_field, "capability_id"}}
      {:error, _} = err -> err
    end
  end

  defp admit_capability_id(value) when is_binary(value) do
    if Regex.match?(@capability_id_re, value),
      do: {:ok, value},
      else: {:error, {:invalid_field, "capability_id"}}
  end

  defp admit_capability_id(_value), do: {:error, {:invalid_field, "capability_id"}}

  # ---------------------------------------------------------------------------
  # Canonical encoding
  # ---------------------------------------------------------------------------

  defp encode_intent_facts(intent) do
    encode_ordered(intent, @intent_fact_order, @max_intent_bytes, :intent_too_large)
  end

  defp encode_record(%{"record_type" => "prepared"} = record) do
    encode_ordered(record, @prepared_order, @max_record_bytes, :record_too_large)
  end

  defp encode_record(%{"record_type" => type} = record)
       when type in ["effect_applied", "effect_rejected"] do
    encode_ordered(record, @applied_order, @max_record_bytes, :record_too_large)
  end

  defp encode_record(%{"record_type" => "delivered"} = record) do
    encode_ordered(record, @delivered_order, @max_record_bytes, :record_too_large)
  end

  defp encode_ordered(map, order, max_bytes, too_large) do
    encoded = Jason.encode(ordered_object(map, order))

    case encoded do
      {:ok, bytes} when byte_size(bytes) <= max_bytes -> {:ok, bytes}
      {:ok, _bytes} -> {:error, too_large}
      {:error, _reason} -> {:error, :malformed}
    end
  end

  defp ordered_object(map, order) do
    order
    |> Enum.flat_map(fn key ->
      case Map.fetch(map, key) do
        {:ok, value} -> [{key, canonicalize(key, value)}]
        :error -> []
      end
    end)
    |> Jason.OrderedObject.new()
  end

  defp canonicalize("before_fence", value), do: expectation_object(value)
  defp canonicalize("after_fingerprint", value), do: expectation_object(value)
  defp canonicalize("audit", value), do: ordered_object(value, @audit_order)
  defp canonicalize("data", value), do: audit_data_object(value)
  defp canonicalize("intent", value), do: ordered_object(value, @intent_stored_order)
  defp canonicalize("observation", value), do: observation_object(value)
  defp canonicalize(_key, value), do: value

  defp expectation_object(%{"kind" => "absent"}),
    do: ordered_object(%{"kind" => "absent"}, ["kind"])

  defp expectation_object(%{"kind" => "live"} = value),
    do: ordered_object(value, @live_order)

  defp expectation_object(%{"kind" => "tombstone"} = value),
    do: ordered_object(value, @tombstone_order)

  defp audit_data_object(value) do
    if Map.has_key?(value, "expires_at") do
      ordered_object(value, @grant_data_order)
    else
      ordered_object(value, @revoke_data_order)
    end
  end

  defp observation_object(%{"kind" => "applied"} = value) do
    ordered_object(value, @applied_observation_keys)
  end

  defp observation_object(%{"kind" => "rejected"} = value) do
    ordered_object(value, @rejected_observation_keys)
  end

  # ---------------------------------------------------------------------------
  # Envelope, scalars, budget
  # ---------------------------------------------------------------------------

  defp admit_object(%_{}, _allowed, _max), do: {:error, :struct_not_allowed}

  defp admit_object(value, allowed, max) when is_map(value) do
    if map_size(value) > max,
      do: {:error, :malformed},
      else: admit_object_keys(value, allowed)
  end

  defp admit_object(value, _allowed, _max) when is_list(value), do: {:error, :invalid_object}

  defp admit_object(_value, _allowed, _max), do: {:error, :invalid_object}

  defp admit_object_keys(value, allowed) do
    keys = Map.keys(value)

    cond do
      Enum.any?(keys, &is_atom/1) ->
        {:error, :atom_key_not_allowed}

      not Enum.all?(keys, &is_binary/1) ->
        {:error, :invalid_object}

      not Enum.all?(keys, &String.valid?/1) ->
        {:error, :invalid_utf8}

      true ->
        case Enum.find(keys, &(&1 not in allowed)) do
          nil -> {:ok, value}
          extra -> {:error, unknown_key_reason(extra)}
        end
    end
  end

  defp unknown_key_reason(key) do
    if MapSet.member?(@forbidden_names, key), do: :forbidden_content, else: :unknown_field
  end

  defp require_keys(attrs, required) do
    if Enum.all?(required, &Map.has_key?(attrs, &1)),
      do: :ok,
      else: {:error, :missing_field}
  end

  defp require_exact_keys(attrs, exact) do
    keys = Map.keys(attrs) |> Enum.sort()
    expected = Enum.sort(exact)

    cond do
      keys == expected ->
        :ok

      Enum.any?(keys, &(&1 not in exact)) ->
        extra = Enum.find(keys, &(&1 not in exact))
        {:error, unknown_key_reason(extra)}

      true ->
        {:error, :missing_field}
    end
  end

  defp reject_unknown_relative(attrs, allowed) do
    extra = Enum.find(Map.keys(attrs), &(&1 not in allowed))

    if extra, do: {:error, unknown_key_reason(extra)}, else: :ok
  end

  defp admit_version(@version), do: {:ok, @version}
  defp admit_version(value) when is_float(value), do: {:error, :float_not_allowed}

  defp admit_version(value) when is_integer(value) and value >= 0 and value <= @max_json_safe_int,
    do: {:error, :unsupported_version}

  defp admit_version(value) when is_integer(value), do: {:error, :integer_out_of_range}
  defp admit_version(_value), do: {:error, {:invalid_field, "version"}}

  defp admit_exact(value, expected, _field) when value == expected, do: {:ok, value}
  defp admit_exact(_value, _expected, field), do: {:error, {:invalid_field, field}}

  defp admit_positive_int(value, _field)
       when is_integer(value) and value >= 1 and value <= @max_json_safe_int,
       do: {:ok, value}

  defp admit_positive_int(value, _field) when is_float(value), do: {:error, :float_not_allowed}

  defp admit_positive_int(value, _field) when is_integer(value),
    do: {:error, :integer_out_of_range}

  defp admit_positive_int(_value, field), do: {:error, {:invalid_field, field}}

  defp admit_hex64(value, _field) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@hex64_re, value),
      do: {:ok, value},
      else: {:error, :invalid_field}
  end

  defp admit_hex64(_value, field), do: {:error, {:invalid_field, field}}

  defp admit_timestamp(value, field) when is_binary(value) do
    with true <- String.valid?(value),
         true <- Regex.match?(@timestamp_re, value),
         true <- strict_utc_timestamp?(value) do
      {:ok, value}
    else
      _ -> {:error, {:invalid_field, field}}
    end
  end

  defp admit_timestamp(_value, field), do: {:error, {:invalid_field, field}}

  defp strict_utc_timestamp?(
         <<year::binary-size(4), "-", month::binary-size(2), "-", day::binary-size(2), "T",
           hour::binary-size(2), ":", minute::binary-size(2), ":", second::binary-size(2), "Z">>
       ) do
    yi = String.to_integer(year)
    mo = String.to_integer(month)
    da = String.to_integer(day)
    ho = String.to_integer(hour)
    mi = String.to_integer(minute)
    se = String.to_integer(second)

    yi >= 1 and yi <= 9999 and Calendar.ISO.valid_date?(yi, mo, da) and
      Calendar.ISO.valid_time?(ho, mi, se, {0, 0})
  end

  defp strict_utc_timestamp?(_value), do: false

  defp optional_timestamp(attrs, key) do
    case Map.fetch(attrs, key) do
      :error -> {:ok, :omit}
      {:ok, nil} -> {:error, :invalid_field}
      {:ok, value} -> admit_timestamp(value, key)
    end
  end

  defp optional_bounded(attrs, key, max) do
    case Map.fetch(attrs, key) do
      :error -> {:ok, :omit}
      {:ok, nil} -> {:error, :invalid_field}
      {:ok, value} -> admit_bounded_id(value, max, key)
    end
  end

  defp admit_bounded_id(value, max, field) when is_binary(value) do
    cond do
      not String.valid?(value) ->
        {:error, :invalid_utf8}

      byte_size(value) == 0 ->
        {:error, :invalid_field}

      byte_size(value) > max ->
        {:error, :invalid_field}

      String.match?(value, @control_re) ->
        {:error, {:invalid_field, field}}

      true ->
        {:ok, value}
    end
  end

  defp admit_bounded_id(_value, _max, field), do: {:error, {:invalid_field, field}}

  defp put_optional(map, _key, :omit), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp budget_ok(value, depth, nodes) do
    case budget_count(value, depth, nodes) do
      {:ok, _used} -> :ok
      {:error, _} = err -> err
    end
  end

  defp budget_count(_value, depth, _nodes) when depth > @max_depth, do: {:error, :malformed}
  defp budget_count(_value, _depth, nodes) when nodes > @max_nodes, do: {:error, :malformed}

  defp budget_count(%_{}, _depth, _nodes), do: {:error, :struct_not_allowed}

  defp budget_count(map, depth, nodes) when is_map(map) do
    used = nodes + 1

    if used > @max_nodes do
      {:error, :malformed}
    else
      Enum.reduce_while(map, {:ok, used}, &budget_count_entry(&1, &2, depth))
    end
  end

  defp budget_count(list, 0, _nodes) when is_list(list), do: {:error, :invalid_object}

  defp budget_count(list, _depth, _nodes) when is_list(list) do
    if improper_list?(list), do: {:error, :improper_list}, else: {:error, :invalid_field}
  end

  defp budget_count(_value, _depth, nodes) do
    used = nodes + 1

    if used > @max_nodes do
      {:error, :malformed}
    else
      {:ok, used}
    end
  end

  defp budget_count_entry({key, _nested}, {:ok, _acc}, _depth) when is_atom(key),
    do: {:halt, {:error, :atom_key_not_allowed}}

  defp budget_count_entry({key, _nested}, {:ok, _acc}, _depth) when not is_binary(key),
    do: {:halt, {:error, :invalid_object}}

  defp budget_count_entry({_key, nested}, {:ok, acc}, depth) do
    case budget_count(nested, depth + 1, acc) do
      {:ok, next} -> {:cont, {:ok, next}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp improper_list?([]), do: false
  defp improper_list?([_head | tail]) when is_list(tail), do: improper_list?(tail)
  defp improper_list?([_head | _tail]), do: true
  defp improper_list?(_), do: false
end
