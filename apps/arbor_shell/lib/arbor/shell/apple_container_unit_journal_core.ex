defmodule Arbor.Shell.AppleContainerUnitJournalCore do
  @moduledoc """
  Pure CRC reducer for a durable Apple Container unit-intent journal (schema v2).

  Before a production worker may issue `container create`, Shell durably
  persists a reserved unit name bound to source-owned validation lineage.
  Schema v1 snapshots load as owner-unknown v2 records without inventing
  provenance. New reserves require complete known owner binding.
  `normalize_existing_record/1` accepts known or unknown rows for recovery;
  `reserve/2` is strict known-only.

  All functions are pure: no File/IO, GenServer, ETS, Application config,
  Logger, System time, DateTime, randomness, process references, crypto
  hashing/generation, or other library facades. Time and tokens are injected
  by the caller. Digest hashing stays at the imperative journal boundary.
  """

  # Durable writes are always schema 2. Schema 1 is accepted only on load.
  @schema_version 2
  @legacy_schema_version 1
  @max_active 1_024
  # JSON-safe integer ceiling (2^53 - 1). Larger generation values fail closed
  # before arithmetic so huge decoded JSON integers cannot overflow counters.
  @max_generation 9_007_199_254_740_991
  @max_map_keys 16
  @max_execution_id_bytes 256
  @max_owner_id_bytes 128
  @token_hex_bytes 64
  @default_inventory_max_items 256
  @digest_domain_tag "arbor.shell.apple_container_unit_journal.record.v2"
  @resource_id_prefix "acu_v1_"
  @resource_id_re ~r/\Aacu_v1_[0-9a-f]{32}\z/
  @token_re ~r/\A[0-9a-f]{64}\z/

  alias Arbor.Shell.AppleContainerUnitName

  # Closed journal surface (atom form). String aliases accepted only when the
  # atom form is absent — never both.
  @logical_journal_keys [:schema_version, :generation, :active]
  @allowed_journal_keys MapSet.new(
                          @logical_journal_keys ++
                            Enum.map(@logical_journal_keys, &Atom.to_string/1)
                        )

  @logical_state_keys [:schema_version, :generation, :by_name]

  # Exact v2 key set for every durable/in-memory record (known and unknown).
  @logical_record_keys [
    :unit_name,
    :execution_id,
    :token,
    :reserved_at_ms,
    :owner_status,
    :validation_resource_id,
    :workspace_id,
    :task_id,
    :principal_id
  ]
  @allowed_record_keys MapSet.new(
                         @logical_record_keys ++
                           Enum.map(@logical_record_keys, &Atom.to_string/1)
                       )

  @logical_owner_keys [
    :validation_resource_id,
    :workspace_id,
    :task_id,
    :principal_id
  ]
  @allowed_owner_keys MapSet.new(
                        @logical_owner_keys ++ Enum.map(@logical_owner_keys, &Atom.to_string/1)
                      )

  @logical_reserve_keys [
    :unit_name,
    :execution_id,
    :token,
    :reserved_at_ms,
    :validation_resource_id,
    :workspace_id,
    :task_id,
    :principal_id
  ]
  @allowed_reserve_keys MapSet.new(
                          @logical_reserve_keys ++
                            Enum.map(@logical_reserve_keys, &Atom.to_string/1)
                        )

  @logical_v1_record_keys [:unit_name, :execution_id, :token, :reserved_at_ms]
  @allowed_v1_record_keys MapSet.new(
                            @logical_v1_record_keys ++
                              Enum.map(@logical_v1_record_keys, &Atom.to_string/1)
                          )

  @type owner_status :: :known | :unknown

  @type record :: %{
          unit_name: String.t(),
          execution_id: String.t(),
          token: String.t(),
          reserved_at_ms: non_neg_integer(),
          owner_status: owner_status(),
          validation_resource_id: String.t() | nil,
          workspace_id: String.t() | nil,
          task_id: String.t() | nil,
          principal_id: String.t() | nil
        }

  @type state :: %{
          schema_version: 2,
          generation: non_neg_integer(),
          by_name: %{optional(String.t()) => record()}
        }

  @type effect :: {:persist_snapshot, map()}

  @type inventory_projection :: %{
          filter: String.t(),
          matched_count: non_neg_integer(),
          returned_count: non_neg_integer(),
          max_items: pos_integer(),
          truncated: boolean(),
          records: [record()]
        }

  @doc false
  @spec limits() :: map()
  def limits do
    %{
      max_active: @max_active,
      max_generation: @max_generation,
      max_owner_id_bytes: @max_owner_id_bytes,
      default_inventory_max_items: @default_inventory_max_items,
      digest_domain_tag: @digest_domain_tag
    }
  end

  @doc "Fixed domain-separation tag for schema-v2 record digests."
  @spec digest_domain_tag() :: String.t()
  def digest_domain_tag, do: @digest_domain_tag

  @doc "Default inventory page size when `:max_items` is omitted."
  @spec default_inventory_max_items() :: pos_integer()
  def default_inventory_max_items, do: @default_inventory_max_items

  @doc """
  Construct an empty journal (`schema_version` 2, `generation` 0, no actives).
  """
  @spec new() :: {:ok, state()}
  def new, do: {:ok, empty_state()}

  @doc """
  Construct journal state from a closed external snapshot.

  Accepts schema v2 or canonical schema v1 (migrated in-memory to owner-unknown
  v2 without inventing provenance). Rejects unknown keys, duplicate aliases,
  malformed records, unsupported schema versions, and over-capacity actives.
  Durable `show/1` always emits schema 2.
  """
  @spec new(term()) :: {:ok, state()} | {:error, term()}
  def new(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(
             input,
             @allowed_journal_keys,
             @logical_journal_keys,
             :journal
           ),
         {:ok, loaded_schema} <- fetch_schema_version(input),
         {:ok, generation} <- fetch_generation(input),
         {:ok, active_list} <- fetch_active_list(input),
         {:ok, by_name} <- normalize_active_records_for_schema(active_list, loaded_schema),
         :ok <- validate_generation_consistency(generation, by_name) do
      {:ok,
       %{
         schema_version: @schema_version,
         generation: generation,
         by_name: by_name
       }}
    end
  end

  def new(_), do: {:error, :invalid_journal}

  @doc """
  Normalize one existing journal record (known or unknown).

  Used by recovery, worker ownership, and reconciler paths. Distinct from
  strict `reserve/2` which requires known owner binding.
  """
  @spec normalize_existing_record(term()) :: {:ok, record()} | {:error, term()}
  def normalize_existing_record(input), do: normalize_v2_record(input)

  @doc """
  Normalize an existing record only when it carries complete known ownership.

  Normal execution admission uses this stricter path. Recovery may use
  `normalize_existing_record/1` so legacy owner-unknown rows can be cleaned.
  """
  @spec normalize_known_record(term()) :: {:ok, record()} | {:error, term()}
  def normalize_known_record(input) do
    case normalize_existing_record(input) do
      {:ok, %{owner_status: :known} = record} -> {:ok, record}
      {:ok, %{owner_status: :unknown}} -> {:error, :apple_container_unit_owner_required}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Normalize an exact, complete known-owner binding.

  The map is closed over the four owner keys. Atom or string keys are accepted,
  but aliases, extras, missing values, and malformed IDs fail closed.
  """
  @spec normalize_known_owner(term()) :: {:ok, map()} | {:error, term()}
  def normalize_known_owner(input) when is_map(input) do
    result =
      with :ok <-
             validate_closed_keys(
               input,
               @allowed_owner_keys,
               @logical_owner_keys,
               :unit_owner
             ),
           {:ok, owner_ids} <- fetch_owner_ids_for_status(input, :known) do
        {:ok, owner_ids}
      end

    case result do
      {:error, reason}
      when reason in [
             :missing_validation_resource_id,
             :missing_workspace_id,
             :missing_task_id,
             :missing_principal_id
           ] ->
        {:error, :incomplete_unit_owner}

      {:error, {:unsupported_keys, :unit_owner}} ->
        {:error, :invalid_apple_container_unit_owner}

      {:error, {:duplicate_key_alias, :unit_owner, _key}} ->
        {:error, :invalid_apple_container_unit_owner}

      {:error, :map_too_large} ->
        {:error, :invalid_apple_container_unit_owner}

      other ->
        other
    end
  end

  def normalize_known_owner(_), do: {:error, :invalid_apple_container_unit_owner}

  @doc """
  Return true only when both inputs normalize to the same complete v2 record.

  Owner status and all four owner identifiers are part of exact identity.
  """
  @spec same_record?(term(), term()) :: boolean()
  def same_record?(left, right) do
    with {:ok, normalized_left} <- normalize_existing_record(left),
         {:ok, normalized_right} <- normalize_existing_record(right) do
      normalized_left == normalized_right
    else
      _ -> false
    end
  end

  @doc """
  Strict reserve of a unit intent with complete known owner binding.

  Requires closed attrs: `unit_name`, `execution_id`, `token`,
  `reserved_at_ms`, and the four owner IDs. Rejects partial/malformed owner,
  duplicates, and capacity. On success increments `generation` once and
  returns a schema-v2 persist snapshot.
  """
  @spec reserve(state(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def reserve(state, attrs) do
    with :ok <- require_state(state),
         :ok <-
           validate_closed_keys(
             attrs,
             @allowed_reserve_keys,
             @logical_reserve_keys,
             :reserve
           ),
         {:ok, record} <- normalize_reserve_attrs(attrs),
         :ok <- reject_capacity(state),
         :ok <- reject_generation_ceiling(state),
         :ok <- reject_duplicate_name(state, record.unit_name),
         :ok <- reject_duplicate_execution_id(state, record.execution_id),
         :ok <- reject_duplicate_token(state, record.token) do
      new_state = %{
        state
        | generation: state.generation + 1,
          by_name: Map.put(state.by_name, record.unit_name, record)
      }

      {:ok, new_state, persist_effect(new_state)}
    end
  end

  @doc """
  Complete (remove) an active intent only when both `unit_name` and `token`
  match exactly.

  Unknown name, wrong token, malformed inputs, and replay fail closed without
  changing state. Successful completion increments `generation` exactly once
  and returns the exact persist-snapshot effect.
  """
  @spec complete(state(), term(), term()) ::
          {:ok, state(), [effect()]} | {:error, term()}
  def complete(state, unit_name, token) do
    with :ok <- require_state(state),
         {:ok, unit_name} <- validate_unit_name(unit_name),
         {:ok, token} <- validate_token(token),
         {:ok, existing} <- fetch_active(state, unit_name),
         :ok <- match_token(existing.token, token),
         :ok <- reject_generation_ceiling(state) do
      new_state = %{
        state
        | generation: state.generation + 1,
          by_name: Map.delete(state.by_name, unit_name)
      }

      {:ok, new_state, persist_effect(new_state)}
    end
  end

  @doc """
  Return all active intent records sorted by `unit_name` bytewise.

  Never decides that an entry is absent or safe to delete — recovery listing
  only; absence proof remains an imperative shell concern.
  """
  @spec recovery_entries(state()) :: [record()] | {:error, term()}
  def recovery_entries(state) do
    with :ok <- require_state(state) do
      sorted_records(state)
    end
  end

  @doc """
  Convert journal state to a deterministic JSON-clean canonical schema-v2 snapshot.

  Keys are strings; `active` is sorted by `unit_name` bytewise. Suitable for
  durable persistence and round-trip through `new/1`.
  """
  @spec show(term()) :: map() | {:error, :invalid_journal_state}
  def show(state) do
    with :ok <- require_state(state) do
      snapshot(state)
    end
  end

  @doc """
  Canonical secret-bearing string-keyed record for domain-separated digests.
  """
  @spec canonical_record(term()) :: map() | {:error, term()}
  def canonical_record(record) do
    case normalize_existing_record(record) do
      {:ok, normalized} -> show_record(normalized)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Segment-safe non-authority resource id: `acu_v1_<32hex>` from `arbor-v1-<32hex>`.
  """
  @spec resource_id_from_unit_name(term()) ::
          {:ok, String.t()} | {:error, :invalid_unit_name}
  def resource_id_from_unit_name(unit_name) do
    with {:ok, name} <- validate_unit_name(unit_name),
         "arbor-v1-" <> hex32 <- name,
         true <- byte_size(hex32) == 32 do
      {:ok, @resource_id_prefix <> hex32}
    else
      _ -> {:error, :invalid_unit_name}
    end
  end

  @doc """
  Reverse `acu_v1_<32hex>` to the exact canonical `arbor-v1-<32hex>` unit name.
  """
  @spec unit_name_from_resource_id(term()) ::
          {:ok, String.t()} | {:error, :invalid_resource_id}
  def unit_name_from_resource_id(resource_id) when is_binary(resource_id) do
    if String.valid?(resource_id) and Regex.match?(@resource_id_re, resource_id) do
      "acu_v1_" <> hex32 = resource_id

      case AppleContainerUnitName.validate("arbor-v1-" <> hex32) do
        {:ok, name} -> {:ok, name}
        {:error, _} -> {:error, :invalid_resource_id}
      end
    else
      {:error, :invalid_resource_id}
    end
  end

  def unit_name_from_resource_id(_), do: {:error, :invalid_resource_id}

  @doc """
  Pure inventory projection with closed filters.

  Global (both task_id and principal_id absent/nil): includes owner-unknown.
  Scoped (both non-blank): only known rows with exact task+principal match;
  never infers ownership for unknown rows. One-sided filters fail closed.
  Returns secret-bearing matched records for the imperative shell to digest
  and redact; does not hash.
  """
  @spec project_inventory(state(), term()) ::
          {:ok, inventory_projection()} | {:error, term()}
  def project_inventory(state, filters) do
    with :ok <- require_state(state),
         {:ok, mode, task_id, principal_id, max_items} <- normalize_inventory_filters(filters) do
      matched =
        state
        |> sorted_records()
        |> Enum.filter(&inventory_match?(&1, mode, task_id, principal_id))

      matched_count = length(matched)
      returned = Enum.take(matched, max_items)
      returned_count = length(returned)
      truncated = matched_count > returned_count

      {:ok,
       %{
         filter: mode,
         matched_count: matched_count,
         returned_count: returned_count,
         max_items: max_items,
         truncated: truncated,
         records: returned
       }}
    end
  end

  # --- Construction helpers ---------------------------------------------------

  defp empty_state do
    %{
      schema_version: @schema_version,
      generation: 0,
      by_name: %{}
    }
  end

  defp require_state(
         %{
           schema_version: @schema_version,
           generation: generation,
           by_name: by_name
         } = state
       )
       when is_integer(generation) and generation >= 0 and generation <= @max_generation and
              is_map(by_name) do
    with true <- Map.keys(state) |> MapSet.new() |> MapSet.equal?(MapSet.new(@logical_state_keys)),
         true <- map_size(by_name) <= @max_active,
         {:ok, normalized_by_name} <-
           normalize_active_records_for_schema(Map.values(by_name), @schema_version),
         true <- normalized_by_name == by_name,
         :ok <- validate_generation_consistency(generation, by_name) do
      :ok
    else
      _ -> {:error, :invalid_journal_state}
    end
  end

  defp require_state(_), do: {:error, :invalid_journal_state}

  defp fetch_schema_version(input) do
    case fetch_field(input, :schema_version) do
      :error ->
        {:error, :missing_schema_version}

      {:ok, @schema_version} ->
        {:ok, @schema_version}

      {:ok, @legacy_schema_version} ->
        {:ok, @legacy_schema_version}

      {:ok, version} when is_integer(version) ->
        {:error, {:unsupported_schema_version, version}}

      {:ok, _other} ->
        {:error, :invalid_schema_version}
    end
  end

  defp fetch_generation(input) do
    case fetch_field(input, :generation) do
      :error ->
        {:error, :missing_generation}

      {:ok, generation}
      when is_integer(generation) and generation >= 0 and generation <= @max_generation ->
        {:ok, generation}

      {:ok, generation} when is_integer(generation) and generation > @max_generation ->
        {:error, :generation_too_large}

      {:ok, _other} ->
        {:error, :invalid_generation}
    end
  end

  defp fetch_active_list(input) do
    case fetch_field(input, :active) do
      :error ->
        {:error, :missing_active}

      {:ok, active} when is_list(active) ->
        if length(active) > @max_active do
          {:error, :journal_at_capacity}
        else
          {:ok, active}
        end

      {:ok, _other} ->
        {:error, :invalid_active}
    end
  end

  defp validate_generation_consistency(generation, by_name) do
    if generation >= map_size(by_name) do
      :ok
    else
      {:error, :invalid_generation}
    end
  end

  defp normalize_active_records_for_schema(active_list, @legacy_schema_version) do
    reduce_active_records(active_list, &normalize_v1_record_as_unknown/1)
  end

  defp normalize_active_records_for_schema(active_list, @schema_version) do
    reduce_active_records(active_list, &normalize_v2_record/1)
  end

  defp reduce_active_records(active_list, normalize_fun) do
    active_list
    |> Enum.reduce_while({:ok, %{}, MapSet.new(), MapSet.new()}, fn
      entry, {:ok, by_name, execution_ids, tokens} ->
        case normalize_fun.(entry) do
          {:ok, record} ->
            cond do
              Map.has_key?(by_name, record.unit_name) ->
                {:halt, {:error, :duplicate_unit_name}}

              MapSet.member?(execution_ids, record.execution_id) ->
                {:halt, {:error, :duplicate_execution_id}}

              MapSet.member?(tokens, record.token) ->
                {:halt, {:error, :duplicate_token}}

              true ->
                {:cont,
                 {:ok, Map.put(by_name, record.unit_name, record),
                  MapSet.put(execution_ids, record.execution_id),
                  MapSet.put(tokens, record.token)}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      _entry, acc ->
        {:halt, acc}
    end)
    |> case do
      {:ok, by_name, _execution_ids, _tokens} -> {:ok, by_name}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_v1_record_as_unknown(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(
             input,
             @allowed_v1_record_keys,
             @logical_v1_record_keys,
             :record
           ),
         {:ok, unit_name} <- fetch_unit_name(input),
         {:ok, execution_id} <- fetch_execution_id(input),
         {:ok, token} <- fetch_token(input),
         {:ok, reserved_at_ms} <- fetch_reserved_at_ms(input) do
      {:ok, unknown_record(unit_name, execution_id, token, reserved_at_ms)}
    end
  end

  defp normalize_v1_record_as_unknown(_), do: {:error, :invalid_record}

  defp normalize_v2_record(input) when is_map(input) do
    with :ok <-
           validate_closed_keys(
             input,
             @allowed_record_keys,
             @logical_record_keys,
             :record
           ),
         {:ok, unit_name} <- fetch_unit_name(input),
         {:ok, execution_id} <- fetch_execution_id(input),
         {:ok, token} <- fetch_token(input),
         {:ok, reserved_at_ms} <- fetch_reserved_at_ms(input),
         {:ok, owner_status} <- fetch_owner_status(input),
         {:ok, owner_ids} <- fetch_owner_ids_for_status(input, owner_status) do
      {:ok,
       %{
         unit_name: unit_name,
         execution_id: execution_id,
         token: token,
         reserved_at_ms: reserved_at_ms,
         owner_status: owner_status,
         validation_resource_id: owner_ids.validation_resource_id,
         workspace_id: owner_ids.workspace_id,
         task_id: owner_ids.task_id,
         principal_id: owner_ids.principal_id
       }}
    end
  end

  defp normalize_v2_record(_), do: {:error, :invalid_record}

  defp normalize_reserve_attrs(input) when is_map(input) do
    with {:ok, unit_name} <- fetch_unit_name(input),
         {:ok, execution_id} <- fetch_execution_id(input),
         {:ok, token} <- fetch_token(input),
         {:ok, reserved_at_ms} <- fetch_reserved_at_ms(input),
         {:ok, owner_ids} <- fetch_owner_ids_for_status(input, :known) do
      {:ok,
       %{
         unit_name: unit_name,
         execution_id: execution_id,
         token: token,
         reserved_at_ms: reserved_at_ms,
         owner_status: :known,
         validation_resource_id: owner_ids.validation_resource_id,
         workspace_id: owner_ids.workspace_id,
         task_id: owner_ids.task_id,
         principal_id: owner_ids.principal_id
       }}
    end
  end

  defp normalize_reserve_attrs(_), do: {:error, :invalid_record}

  defp unknown_record(unit_name, execution_id, token, reserved_at_ms) do
    %{
      unit_name: unit_name,
      execution_id: execution_id,
      token: token,
      reserved_at_ms: reserved_at_ms,
      owner_status: :unknown,
      validation_resource_id: nil,
      workspace_id: nil,
      task_id: nil,
      principal_id: nil
    }
  end

  defp fetch_unit_name(input) do
    case fetch_field(input, :unit_name) do
      :error -> {:error, :missing_unit_name}
      {:ok, value} -> validate_unit_name(value)
    end
  end

  defp fetch_execution_id(input) do
    case fetch_field(input, :execution_id) do
      :error -> {:error, :missing_execution_id}
      {:ok, value} -> validate_execution_id(value)
    end
  end

  defp fetch_token(input) do
    case fetch_field(input, :token) do
      :error -> {:error, :missing_token}
      {:ok, value} -> validate_token(value)
    end
  end

  defp fetch_reserved_at_ms(input) do
    case fetch_field(input, :reserved_at_ms) do
      :error -> {:error, :missing_reserved_at_ms}
      {:ok, value} -> validate_reserved_at_ms(value)
    end
  end

  defp fetch_owner_status(input) do
    case fetch_field(input, :owner_status) do
      :error ->
        {:error, :missing_owner_status}

      {:ok, status} when status in [:known, "known"] ->
        {:ok, :known}

      {:ok, status} when status in [:unknown, "unknown"] ->
        {:ok, :unknown}

      {:ok, _other} ->
        {:error, :invalid_owner_status}
    end
  end

  defp fetch_owner_ids_for_status(input, :known) do
    with {:ok, validation_resource_id} <- fetch_required_owner_id(input, :validation_resource_id),
         {:ok, workspace_id} <- fetch_required_owner_id(input, :workspace_id),
         {:ok, task_id} <- fetch_required_owner_id(input, :task_id),
         {:ok, principal_id} <- fetch_required_owner_id(input, :principal_id) do
      {:ok,
       %{
         validation_resource_id: validation_resource_id,
         workspace_id: workspace_id,
         task_id: task_id,
         principal_id: principal_id
       }}
    end
  end

  defp fetch_owner_ids_for_status(input, :unknown) do
    with :ok <- require_nil_owner_id(input, :validation_resource_id),
         :ok <- require_nil_owner_id(input, :workspace_id),
         :ok <- require_nil_owner_id(input, :task_id),
         :ok <- require_nil_owner_id(input, :principal_id) do
      {:ok,
       %{
         validation_resource_id: nil,
         workspace_id: nil,
         task_id: nil,
         principal_id: nil
       }}
    end
  end

  defp fetch_required_owner_id(input, key) do
    case fetch_field(input, key) do
      :error ->
        {:error, missing_owner_error(key)}

      {:ok, nil} ->
        {:error, :incomplete_unit_owner}

      {:ok, value} ->
        validate_owner_id(value, key)
    end
  end

  defp require_nil_owner_id(input, key) do
    case fetch_field(input, key) do
      :error ->
        {:error, missing_owner_error(key)}

      {:ok, nil} ->
        :ok

      {:ok, _value} ->
        {:error, :owner_unknown_must_have_nil_ids}
    end
  end

  defp missing_owner_error(:validation_resource_id), do: :missing_validation_resource_id
  defp missing_owner_error(:workspace_id), do: :missing_workspace_id
  defp missing_owner_error(:task_id), do: :missing_task_id
  defp missing_owner_error(:principal_id), do: :missing_principal_id

  # --- Field validators -------------------------------------------------------

  defp validate_unit_name(name), do: AppleContainerUnitName.validate(name)

  defp validate_execution_id(id) when is_binary(id) do
    size = byte_size(id)

    cond do
      not String.valid?(id) ->
        {:error, :invalid_execution_id}

      size < 1 or size > @max_execution_id_bytes ->
        {:error, :invalid_execution_id}

      String.contains?(id, ["/", "\\", <<0>>]) ->
        {:error, :invalid_execution_id}

      has_control_char?(id) ->
        {:error, :invalid_execution_id}

      has_whitespace?(id) ->
        {:error, :invalid_execution_id}

      true ->
        {:ok, id}
    end
  end

  defp validate_execution_id(_), do: {:error, :invalid_execution_id}

  defp validate_owner_id(id, key) when is_binary(id) do
    size = byte_size(id)

    cond do
      not String.valid?(id) ->
        {:error, invalid_owner_error(key)}

      size < 1 or size > @max_owner_id_bytes ->
        {:error, invalid_owner_error(key)}

      String.contains?(id, ["/", "\\", <<0>>]) ->
        {:error, invalid_owner_error(key)}

      has_control_char?(id) ->
        {:error, invalid_owner_error(key)}

      has_whitespace?(id) ->
        {:error, invalid_owner_error(key)}

      true ->
        {:ok, id}
    end
  end

  defp validate_owner_id(_id, key), do: {:error, invalid_owner_error(key)}

  defp invalid_owner_error(:validation_resource_id), do: :invalid_validation_resource_id
  defp invalid_owner_error(:workspace_id), do: :invalid_workspace_id
  defp invalid_owner_error(:task_id), do: :invalid_task_id
  defp invalid_owner_error(:principal_id), do: :invalid_principal_id

  defp validate_token(token) when is_binary(token) do
    cond do
      not String.valid?(token) ->
        {:error, :invalid_token}

      byte_size(token) != @token_hex_bytes ->
        {:error, :invalid_token}

      not Regex.match?(@token_re, token) ->
        {:error, :invalid_token}

      true ->
        {:ok, token}
    end
  end

  defp validate_token(_), do: {:error, :invalid_token}

  defp validate_reserved_at_ms(ms) when is_integer(ms) and ms >= 0, do: {:ok, ms}
  defp validate_reserved_at_ms(_), do: {:error, :invalid_reserved_at_ms}

  # --- Inventory filters ------------------------------------------------------

  defp normalize_inventory_filters(filters) when is_map(filters) do
    allowed =
      MapSet.new([
        :task_id,
        :principal_id,
        :max_items,
        "task_id",
        "principal_id",
        "max_items"
      ])

    with :ok <- reject_unknown_filter_keys(filters, allowed),
         :ok <- reject_duplicate_inventory_aliases(filters),
         {:ok, task_id} <- optional_filter_id(filters, :task_id),
         {:ok, principal_id} <- optional_filter_id(filters, :principal_id),
         {:ok, max_items} <- optional_max_items(filters),
         {:ok, mode} <- inventory_mode(task_id, principal_id) do
      {:ok, mode, task_id, principal_id, max_items}
    end
  end

  defp normalize_inventory_filters(filters) when is_list(filters) do
    if Keyword.keyword?(filters) and unique_keyword_keys?(filters) do
      normalize_inventory_filters(Map.new(filters))
    else
      {:error, :invalid_unit_inventory_filters}
    end
  end

  defp normalize_inventory_filters(_), do: {:error, :invalid_unit_inventory_filters}

  defp reject_unknown_filter_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &MapSet.member?(allowed, &1)) do
      :ok
    else
      {:error, :invalid_unit_inventory_filters}
    end
  end

  defp reject_duplicate_inventory_aliases(map) do
    case reject_duplicate_key_aliases(
           Map.keys(map),
           [:task_id, :principal_id, :max_items],
           :unit_inventory
         ) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_unit_inventory_filters}
    end
  end

  defp unique_keyword_keys?(filters) do
    keys = Keyword.keys(filters)
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp optional_filter_id(map, key) do
    case fetch_field(map, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case validate_owner_id(value, key) do
          {:ok, id} -> {:ok, id}
          {:error, _} -> {:error, :invalid_unit_inventory_filters}
        end

      {:ok, _other} ->
        {:error, :invalid_unit_inventory_filters}
    end
  end

  defp optional_max_items(map) do
    case fetch_field(map, :max_items) do
      :error ->
        {:ok, @default_inventory_max_items}

      {:ok, n} when is_integer(n) and n > 0 and n <= @max_active ->
        {:ok, n}

      {:ok, _} ->
        {:error, :invalid_unit_inventory_filters}
    end
  end

  defp inventory_mode(nil, nil), do: {:ok, "global"}

  defp inventory_mode(task_id, principal_id)
       when is_binary(task_id) and is_binary(principal_id),
       do: {:ok, "scoped"}

  defp inventory_mode(_, _), do: {:error, :invalid_unit_inventory_filters}

  defp inventory_match?(_record, "global", _task_id, _principal_id), do: true

  defp inventory_match?(
         %{
           owner_status: :known,
           task_id: task_id,
           principal_id: principal_id
         },
         "scoped",
         want_task,
         want_principal
       )
       when is_binary(task_id) and is_binary(principal_id) and is_binary(want_task) and
              is_binary(want_principal) do
    task_id == want_task and principal_id == want_principal
  end

  defp inventory_match?(_record, "scoped", _task_id, _principal_id), do: false

  # --- Transition guards ------------------------------------------------------

  defp reject_capacity(%{by_name: by_name}) do
    if map_size(by_name) >= @max_active do
      {:error, :journal_at_capacity}
    else
      :ok
    end
  end

  defp reject_generation_ceiling(%{generation: generation})
       when is_integer(generation) and generation >= @max_generation do
    {:error, :generation_too_large}
  end

  defp reject_generation_ceiling(%{generation: generation})
       when is_integer(generation) and generation >= 0 do
    :ok
  end

  defp reject_generation_ceiling(_), do: {:error, :invalid_generation}

  defp reject_duplicate_name(%{by_name: by_name}, unit_name) do
    if Map.has_key?(by_name, unit_name) do
      {:error, :duplicate_unit_name}
    else
      :ok
    end
  end

  defp reject_duplicate_execution_id(%{by_name: by_name}, execution_id) do
    if Enum.any?(by_name, fn {_name, record} -> record.execution_id == execution_id end) do
      {:error, :duplicate_execution_id}
    else
      :ok
    end
  end

  defp reject_duplicate_token(%{by_name: by_name}, token) do
    if Enum.any?(by_name, fn {_name, record} -> record.token == token end) do
      {:error, :duplicate_token}
    else
      :ok
    end
  end

  defp fetch_active(%{by_name: by_name}, unit_name) do
    case Map.fetch(by_name, unit_name) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :unknown_unit_name}
    end
  end

  defp match_token(expected, expected), do: :ok
  defp match_token(_expected, _actual), do: {:error, :token_mismatch}

  # --- Projection -------------------------------------------------------------

  defp persist_effect(state), do: [{:persist_snapshot, snapshot(state)}]

  defp snapshot(state) do
    %{
      "schema_version" => @schema_version,
      "generation" => state.generation,
      "active" => Enum.map(sorted_records(state), &show_record/1)
    }
  end

  defp sorted_records(%{by_name: by_name}) do
    by_name
    |> Map.values()
    |> Enum.sort_by(& &1.unit_name)
  end

  defp show_record(%{
         unit_name: unit_name,
         execution_id: execution_id,
         token: token,
         reserved_at_ms: reserved_at_ms,
         owner_status: owner_status,
         validation_resource_id: validation_resource_id,
         workspace_id: workspace_id,
         task_id: task_id,
         principal_id: principal_id
       }) do
    %{
      "unit_name" => unit_name,
      "execution_id" => execution_id,
      "token" => token,
      "reserved_at_ms" => reserved_at_ms,
      "owner_status" => owner_status_string(owner_status),
      "validation_resource_id" => validation_resource_id,
      "workspace_id" => workspace_id,
      "task_id" => task_id,
      "principal_id" => principal_id
    }
  end

  defp owner_status_string(:known), do: "known"
  defp owner_status_string(:unknown), do: "unknown"

  # --- Closed-map discipline --------------------------------------------------

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

  defp validate_closed_keys(_, _allowed, _logical, _scope), do: {:error, :invalid_record}

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

  # Distinguishes absent keys from present-but-nil values so callers can
  # return :missing_* vs :invalid_*.
  defp fetch_field(map, key) when is_atom(key) and is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case Map.fetch(map, Atom.to_string(key)) do
          {:ok, value} -> {:ok, value}
          :error -> :error
        end
    end
  end

  defp has_control_char?(value) when is_binary(value), do: has_control_char_bytes?(value)

  defp has_control_char_bytes?(<<>>), do: false
  defp has_control_char_bytes?(<<c, _rest::binary>>) when c < 32 or c == 127, do: true
  defp has_control_char_bytes?(<<_c, rest::binary>>), do: has_control_char_bytes?(rest)

  defp has_whitespace?(value) when is_binary(value) do
    :binary.match(value, [" ", "\t", "\n", "\r", "\f", "\v"]) != :nomatch or
      String.match?(value, ~r/[[:space:]]/)
  end
end
