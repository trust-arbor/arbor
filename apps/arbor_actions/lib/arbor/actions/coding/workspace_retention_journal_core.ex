defmodule Arbor.Actions.Coding.WorkspaceRetentionJournalCore do
  @moduledoc """
  Pure CRC core for retained-workspace restart markers.

  Encodes and decodes bounded JSON-clean durable records for retained coding
  worktrees and non-authoritative pre-create intents. Persisted bytes are
  **evidence only** — never deletion or reactivation authority. The GenServer
  shell must revalidate filesystem identity, Git worktree registration, branch,
  and exact task/principal before any cleanup or reactivation.

  Never serializes PIDs, monitor/timer refs, monotonic timestamps, functions,
  tuples, or rich structs. Absolute UTC expiry is preserved; runtime timers and
  monotonic deadlines are reconstructed by the shell.

  Storage trust boundary for this slice: private same-UID `ARBOR_HOME` state
  root plus an exact lifecycle/provenance pair: `creating`/`pending`, an
  identity-bearing `active|retained`/`owned`, or a discard-in-progress
  `discarding`/`owned` marker. Optional `branch_provenance` records whether
  the invocation created the branch (`created`), reused a pre-existing branch
  (`reused`), or lacks evidence (`unknown`). Legacy markers without the field
  hydrate as `unknown` and must preserve the branch. No HMAC/signing envelope
  is required here.
  """

  @schema_version 1
  @max_records 256
  @max_string_bytes 4_096
  @max_workspace_id_bytes 128
  @max_id_bytes 256
  @max_path_bytes 4_096
  @max_branch_bytes 512
  @max_commit_bytes 128
  @max_runtime_id_bytes 128
  @max_snapshot_bytes 1_048_576
  # Aggregate raw journal inventory ceiling (sum of on-disk record file sizes).
  @max_aggregate_inventory_bytes 2_097_152
  @max_json_depth 6
  @max_json_nodes 8_000
  @max_cleanup_retries 8

  @required_record_keys ~w(
    schema_version
    workspace_id
    task_id
    principal_id
    repo_path
    worktree_path
    display_worktree_path
    branch
    base_commit
    ownership
    lifecycle
    runtime_id
    lstat_identity
    worktree_registration
    expires_at
    retry_count
  )

  # Optional closed keys. Missing branch_provenance hydrates as "unknown".
  @optional_record_keys ~w(branch_provenance discard_phase)

  @lstat_keys ~w(type major_device minor_device inode)
  @registration_keys ~w(path head branch)
  @allowed_lifecycles ~w(retained active creating discarding)

  @type durable_record :: %{
          required(:schema_version) => pos_integer(),
          required(:workspace_id) => String.t(),
          required(:task_id) => String.t() | nil,
          required(:principal_id) => String.t() | nil,
          required(:repo_path) => String.t(),
          required(:worktree_path) => String.t(),
          required(:display_worktree_path) => String.t(),
          required(:branch) => String.t(),
          required(:base_commit) => String.t() | nil,
          required(:ownership) => String.t(),
          required(:lifecycle) => String.t(),
          required(:runtime_id) => String.t(),
          required(:lstat_identity) => map() | nil,
          required(:worktree_registration) => map() | nil,
          required(:expires_at) => String.t(),
          required(:retry_count) => non_neg_integer(),
          required(:branch_provenance) => String.t(),
          optional(:discard_phase) => String.t()
        }

  @type encode_input :: %{
          required(:workspace_id) => String.t(),
          required(:repo_path) => String.t(),
          required(:worktree_path) => String.t(),
          required(:branch) => String.t(),
          required(:base_commit) => String.t() | nil,
          required(:lstat_identity) => map() | nil,
          required(:worktree_registration) => map() | nil,
          required(:expires_at) => DateTime.t() | String.t(),
          required(:runtime_id) => String.t(),
          optional(:task_id) => String.t() | nil,
          optional(:principal_id) => String.t() | nil,
          optional(:display_worktree_path) => String.t(),
          optional(:ownership) => String.t() | atom(),
          optional(:lifecycle) => String.t() | atom(),
          optional(:retry_count) => non_neg_integer(),
          optional(:branch_provenance) => String.t() | atom(),
          optional(:discard_phase) => String.t() | atom()
        }

  @doc "Current durable schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Maximum retained durable records admitted from a store."
  @spec max_records() :: pos_integer()
  def max_records, do: @max_records

  @doc "Maximum encoded snapshot/record payload bytes."
  @spec max_snapshot_bytes() :: pos_integer()
  def max_snapshot_bytes, do: @max_snapshot_bytes

  @doc "Maximum automatic retained cleanup / marker-delete retries before dormancy."
  @spec max_cleanup_retries() :: pos_integer()
  def max_cleanup_retries, do: @max_cleanup_retries

  @doc "Maximum sum of raw on-disk journal record bytes admitted as inventory."
  @spec max_aggregate_inventory_bytes() :: pos_integer()
  def max_aggregate_inventory_bytes, do: @max_aggregate_inventory_bytes

  @doc "Maximum JSON nodes admitted during ordered normalize or budget walks."
  @spec max_json_nodes() :: pos_integer()
  def max_json_nodes, do: @max_json_nodes

  @doc """
  Build the Persistence store key for one retained workspace marker.

  Keys are closed-grammar and path-safe for file-backed backends.
  """
  @spec record_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def record_key(workspace_id) when is_binary(workspace_id) do
    with :ok <- validate_workspace_id(workspace_id) do
      {:ok, "retained:" <> workspace_id}
    end
  end

  def record_key(_), do: {:error, :invalid_workspace_id}

  @doc """
  Encode a runtime retained lease into a versioned JSON-clean durable map.

  Rejects reused ownership, blank required fields, oversized values, and
  non-scalar identity maps. Absolute UTC `expires_at` only. Lifecycle and
  provenance are a closed pair: `creating`/`pending` carries no identity;
  `active|retained`/`owned` requires the complete identity;
  `discarding`/`owned` carries identity while the worktree phase is pending
  and drops identity once only branch retirement remains.
  """
  @spec encode_record(encode_input()) :: {:ok, durable_record()} | {:error, term()}
  def encode_record(input) when is_map(input) do
    with :ok <- reject_reused(input),
         {:ok, ownership} <- encode_ownership(Map.get(input, :ownership, :owned)),
         {:ok, lifecycle} <- encode_lifecycle(Map.get(input, :lifecycle, "retained")),
         {:ok, runtime_id} <-
           require_bounded_string(input, :runtime_id, @max_runtime_id_bytes),
         :ok <- validate_runtime_id(runtime_id),
         {:ok, workspace_id} <-
           require_bounded_string(input, :workspace_id, @max_workspace_id_bytes),
         :ok <- validate_workspace_id(workspace_id),
         {:ok, task_id} <- optional_bounded_id(input, :task_id, @max_id_bytes),
         {:ok, principal_id} <- optional_bounded_id(input, :principal_id, @max_id_bytes),
         :ok <- validate_task_principal_pair(task_id, principal_id),
         {:ok, repo_path} <- require_bounded_string(input, :repo_path, @max_path_bytes),
         {:ok, worktree_path} <- require_bounded_string(input, :worktree_path, @max_path_bytes),
         :ok <- reject_non_distinct_worktree(repo_path, worktree_path),
         {:ok, display_path} <-
           optional_or_default_path(input, :display_worktree_path, worktree_path),
         {:ok, branch} <- require_bounded_string(input, :branch, @max_branch_bytes),
         {:ok, base_commit} <- encode_base_commit(input, lifecycle),
         {:ok, discard_phase} <- encode_discard_phase(input, lifecycle),
         {:ok, lstat} <- encode_lstat_for_lifecycle(input, lifecycle, discard_phase),
         {:ok, registration} <-
           encode_registration_for_lifecycle(input, lifecycle, discard_phase),
         :ok <- reject_registration_path_mismatch(worktree_path, registration),
         :ok <-
           validate_ownership_lifecycle(
             ownership,
             lifecycle,
             base_commit,
             lstat,
             registration,
             discard_phase
           ),
         {:ok, branch_provenance} <- encode_branch_provenance(input, lifecycle),
         {:ok, expires_at} <- encode_expires_at(Map.get(input, :expires_at)),
         {:ok, retry_count} <- encode_retry_count(Map.get(input, :retry_count, 0)) do
      record = %{
        schema_version: @schema_version,
        workspace_id: workspace_id,
        task_id: task_id,
        principal_id: principal_id,
        repo_path: repo_path,
        worktree_path: worktree_path,
        display_worktree_path: display_path,
        branch: branch,
        base_commit: base_commit,
        ownership: ownership,
        lifecycle: lifecycle,
        runtime_id: runtime_id,
        lstat_identity: lstat,
        worktree_registration: registration,
        expires_at: expires_at,
        retry_count: retry_count,
        branch_provenance: branch_provenance
      }

      record =
        if is_binary(discard_phase) do
          Map.put(record, :discard_phase, discard_phase)
        else
          record
        end

      with :ok <- assert_encode_budget(record) do
        {:ok, record}
      end
    end
  end

  def encode_record(_), do: {:error, :invalid_retention_record}

  @doc """
  Decode one durable value from Persistence into a closed atom-keyed record.

  Fail-closed on corrupt, wrong version, oversized, or non-JSON-clean shapes.
  Rejects atom/string key aliases and unexpected nested keys.
  """
  @spec decode_record(term()) :: {:ok, durable_record()} | {:error, term()}
  def decode_record(value) when is_map(value) do
    with :ok <- assert_decode_budget(value),
         {:ok, normalized} <- normalize_closed_map(value),
         :ok <- require_closed_keys(normalized, @required_record_keys, @optional_record_keys),
         :ok <- require_schema_version(normalized),
         {:ok, ownership} <- decode_ownership(Map.get(normalized, "ownership")),
         {:ok, lifecycle} <- encode_lifecycle(Map.get(normalized, "lifecycle")),
         {:ok, runtime_id} <-
           require_bounded_string(normalized, "runtime_id", @max_runtime_id_bytes),
         :ok <- validate_runtime_id(runtime_id),
         {:ok, workspace_id} <-
           require_bounded_string(normalized, "workspace_id", @max_workspace_id_bytes),
         :ok <- validate_workspace_id(workspace_id),
         {:ok, task_id} <- optional_bounded_id(normalized, "task_id", @max_id_bytes),
         {:ok, principal_id} <- optional_bounded_id(normalized, "principal_id", @max_id_bytes),
         :ok <- validate_task_principal_pair(task_id, principal_id),
         {:ok, repo_path} <- require_bounded_string(normalized, "repo_path", @max_path_bytes),
         {:ok, worktree_path} <-
           require_bounded_string(normalized, "worktree_path", @max_path_bytes),
         :ok <- reject_non_distinct_worktree(repo_path, worktree_path),
         {:ok, display_path} <-
           require_bounded_string(normalized, "display_worktree_path", @max_path_bytes),
         {:ok, branch} <- require_bounded_string(normalized, "branch", @max_branch_bytes),
         {:ok, base_commit} <- encode_base_commit(normalized, lifecycle),
         {:ok, discard_phase} <- encode_discard_phase(normalized, lifecycle),
         {:ok, lstat} <- encode_lstat_for_lifecycle(normalized, lifecycle, discard_phase),
         {:ok, registration} <-
           encode_registration_for_lifecycle(normalized, lifecycle, discard_phase),
         :ok <- reject_registration_path_mismatch(worktree_path, registration),
         :ok <-
           validate_ownership_lifecycle(
             ownership,
             lifecycle,
             base_commit,
             lstat,
             registration,
             discard_phase
           ),
         {:ok, branch_provenance} <- encode_branch_provenance(normalized, lifecycle),
         {:ok, expires_at} <- encode_expires_at(Map.get(normalized, "expires_at")),
         {:ok, retry_count} <- encode_retry_count(Map.get(normalized, "retry_count")) do
      record = %{
        schema_version: @schema_version,
        workspace_id: workspace_id,
        task_id: task_id,
        principal_id: principal_id,
        repo_path: repo_path,
        worktree_path: worktree_path,
        display_worktree_path: display_path,
        branch: branch,
        base_commit: base_commit,
        ownership: ownership,
        lifecycle: lifecycle,
        runtime_id: runtime_id,
        lstat_identity: lstat,
        worktree_registration: registration,
        expires_at: expires_at,
        retry_count: retry_count,
        branch_provenance: branch_provenance
      }

      {:ok,
       if is_binary(discard_phase) do
         Map.put(record, :discard_phase, discard_phase)
       else
         record
       end}
    end
  end

  def decode_record(_), do: {:error, :corrupt_retention_record}

  @doc """
  Decode file JSON bytes with ordered objects and recursive duplicate rejection.

  Converts to plain maps only after the closed ordered tree has been validated.
  """
  @spec decode_json_bytes(binary()) :: {:ok, map() | list() | term()} | {:error, term()}
  def decode_json_bytes(body) when is_binary(body) do
    cond do
      not String.valid?(body) ->
        {:error, :invalid_utf8}

      byte_size(body) > @max_snapshot_bytes ->
        {:error, :value_too_large}

      true ->
        case Jason.decode(body, objects: :ordered_objects) do
          {:ok, decoded} ->
            normalize_ordered_json_public(decoded, 1, 0)

          {:error, _} ->
            {:error, :corrupt_store_value}
        end
    end
  end

  def decode_json_bytes(_), do: {:error, :corrupt_store_value}

  @doc """
  Decode a Persistence list+get load into ordered durable records.

  Returns `{:error, reason}` when the store inventory is unavailable, oversized,
  or any selected key fails structural decode. Does not delete evidence.
  """
  @spec decode_inventory([String.t()], %{optional(String.t()) => term()}) ::
          {:ok, [durable_record()]} | {:error, term()}
  def decode_inventory(keys, values_by_key)
      when is_list(keys) and is_map(values_by_key) do
    with :ok <- validate_key_list(keys),
         :ok <- validate_record_count(keys) do
      Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
        case Map.fetch(values_by_key, key) do
          {:ok, value} ->
            case decode_record(value) do
              {:ok, record} ->
                expected_key = "retained:" <> record.workspace_id

                if expected_key == key do
                  {:cont, {:ok, [record | acc]}}
                else
                  {:halt, {:error, {:workspace_id_key_mismatch, key}}}
                end

              {:error, reason} ->
                {:halt, {:error, {:corrupt_retention_record, key, reason}}}
            end

          :error ->
            {:halt, {:error, {:missing_retention_value, key}}}
        end
      end)
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        other -> other
      end
    end
  end

  def decode_inventory(_keys, _values), do: {:error, :invalid_retention_inventory}

  @doc """
  Decide whether a decoded durable record may enter hot retained state.

  Structural only — the shell still revalidates live identity before cleanup or
  reactivation. Incomplete task/principal pairs are rejected; both blank is
  allowed for TTL cleanup evidence (reactivation still requires exact
  nonblank task+principal at the registry authority gate because PIDs are
  never durable).
  """
  @spec restore_decision(durable_record()) :: :restore | {:reject, term()}
  def restore_decision(%{task_id: task_id, principal_id: principal_id} = record)
      when is_map(record) do
    cond do
      Map.get(record, :schema_version) != @schema_version ->
        {:reject, :unsupported_schema_version}

      Map.get(record, :lifecycle) not in @allowed_lifecycles ->
        {:reject, :invalid_lifecycle}

      not valid_ownership_lifecycle?(record) ->
        {:reject, :invalid_ownership_lifecycle_pair}

      not valid_nonblank?(Map.get(record, :runtime_id)) ->
        {:reject, :invalid_runtime_id}

      not valid_nonblank?(Map.get(record, :workspace_id)) ->
        {:reject, :invalid_workspace_id}

      not valid_nonblank?(Map.get(record, :repo_path)) ->
        {:reject, :invalid_repo_path}

      not valid_nonblank?(Map.get(record, :worktree_path)) ->
        {:reject, :invalid_worktree_path}

      Map.get(record, :repo_path) == Map.get(record, :worktree_path) ->
        {:reject, :primary_checkout_not_retainable}

      not valid_nonblank?(Map.get(record, :branch)) ->
        {:reject, :invalid_branch}

      (is_nil(task_id) and not is_nil(principal_id)) or
          (not is_nil(task_id) and is_nil(principal_id)) ->
        {:reject, :incomplete_task_principal}

      true ->
        :restore
    end
  end

  def restore_decision(_), do: {:reject, :invalid_retention_record}

  @doc "True when a decoded record is a non-authoritative pre-create intent."
  @spec creating_record?(durable_record()) :: boolean()
  def creating_record?(%{ownership: "pending", lifecycle: "creating"}), do: true
  def creating_record?(_), do: false

  @doc "True when a decoded record is an in-progress discard marker."
  @spec discarding_record?(durable_record()) :: boolean()
  def discarding_record?(%{ownership: "owned", lifecycle: "discarding"}), do: true
  def discarding_record?(_), do: false

  @doc "True when a Persistence key is a retained-workspace marker key."
  @spec retained_key?(term()) :: boolean()
  def retained_key?(key) when is_binary(key) do
    case String.split_at(key, 9) do
      {"retained:", workspace_id} -> match?(:ok, validate_workspace_id(workspace_id))
      _ -> false
    end
  end

  def retained_key?(_), do: false

  # -- ordered JSON ---------------------------------------------------

  # Node count is enforced during ordered normalization so adversarial JSON
  # cannot expand into an unbounded map/list before later budget walks.
  defp normalize_ordered_json(_value, depth, nodes)
       when depth > @max_json_depth or nodes > @max_json_nodes,
       do: {:error, :retention_structure_oversized}

  defp normalize_ordered_json(%Jason.OrderedObject{values: pairs}, depth, nodes)
       when is_list(pairs) and is_integer(depth) and is_integer(nodes) do
    nodes = nodes + 1

    if nodes > @max_json_nodes do
      {:error, :retention_structure_oversized}
    else
      pairs
      |> Enum.reduce_while({:ok, %{}, MapSet.new(), nodes}, fn
        {key, value}, {:ok, acc, seen, n} when is_binary(key) ->
          if MapSet.member?(seen, key) do
            {:halt, {:error, :duplicate_json_member}}
          else
            case normalize_ordered_json(value, depth + 1, n) do
              {:ok, normalized, n2} ->
                {:cont, {:ok, Map.put(acc, key, normalized), MapSet.put(seen, key), n2}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end

        _pair, _acc ->
          {:halt, {:error, :invalid_json_object}}
      end)
      |> case do
        {:ok, map, _seen, n} -> {:ok, map, n}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_ordered_json(list, depth, nodes)
       when is_list(list) and is_integer(depth) and is_integer(nodes) do
    nodes = nodes + 1

    if nodes > @max_json_nodes do
      {:error, :retention_structure_oversized}
    else
      list
      |> Enum.reduce_while({:ok, [], nodes}, fn item, {:ok, acc, n} ->
        case normalize_ordered_json(item, depth + 1, n) do
          {:ok, normalized, n2} -> {:cont, {:ok, [normalized | acc], n2}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, items, n} -> {:ok, Enum.reverse(items), n}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize_ordered_json(value, _depth, nodes)
       when (is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
               is_nil(value)) and is_integer(nodes) do
    nodes = nodes + 1

    if nodes > @max_json_nodes do
      {:error, :retention_structure_oversized}
    else
      {:ok, value, nodes}
    end
  end

  defp normalize_ordered_json(_other, _depth, _nodes), do: {:error, :non_json_clean_term}

  # Public decode returns the value only.
  defp normalize_ordered_json_public(value, depth, nodes) do
    case normalize_ordered_json(value, depth, nodes) do
      {:ok, normalized, _nodes} -> {:ok, normalized}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- encode helpers -------------------------------------------------

  defp reject_reused(%{ownership: :reused}), do: {:error, :reused_not_durable}
  defp reject_reused(%{"ownership" => "reused"}), do: {:error, :reused_not_durable}
  defp reject_reused(%{"ownership" => :reused}), do: {:error, :reused_not_durable}
  defp reject_reused(%{ownership: "reused"}), do: {:error, :reused_not_durable}
  defp reject_reused(_), do: :ok

  defp encode_ownership(:owned), do: {:ok, "owned"}
  defp encode_ownership("owned"), do: {:ok, "owned"}
  defp encode_ownership(:pending), do: {:ok, "pending"}
  defp encode_ownership("pending"), do: {:ok, "pending"}
  defp encode_ownership(_), do: {:error, :invalid_ownership_provenance}

  defp decode_ownership("owned"), do: {:ok, "owned"}
  defp decode_ownership("pending"), do: {:ok, "pending"}
  defp decode_ownership(_), do: {:error, :invalid_ownership_provenance}

  defp encode_lifecycle(:retained), do: {:ok, "retained"}
  defp encode_lifecycle(:active), do: {:ok, "active"}
  defp encode_lifecycle(:creating), do: {:ok, "creating"}
  defp encode_lifecycle(:discarding), do: {:ok, "discarding"}
  defp encode_lifecycle("retained"), do: {:ok, "retained"}
  defp encode_lifecycle("active"), do: {:ok, "active"}
  defp encode_lifecycle("creating"), do: {:ok, "creating"}
  defp encode_lifecycle("discarding"), do: {:ok, "discarding"}
  defp encode_lifecycle(_), do: {:error, :invalid_lifecycle}

  defp encode_base_commit(input, "creating") do
    case Map.get(input, :base_commit) || Map.get(input, "base_commit") do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      _ -> {:error, :creating_intent_has_base_commit}
    end
  end

  defp encode_base_commit(input, _lifecycle),
    do: require_bounded_string(input, :base_commit, @max_commit_bytes)

  defp encode_discard_phase(input, "discarding") do
    case Map.get(input, :discard_phase) || Map.get(input, "discard_phase") do
      phase when phase in [:worktree, "worktree"] -> {:ok, "worktree"}
      phase when phase in [:branch, "branch"] -> {:ok, "branch"}
      nil -> {:error, :missing_discard_phase}
      _ -> {:error, :invalid_discard_phase}
    end
  end

  defp encode_discard_phase(input, _lifecycle) do
    case Map.get(input, :discard_phase) || Map.get(input, "discard_phase") do
      nil -> {:ok, nil}
      _ -> {:error, :discard_phase_not_allowed}
    end
  end

  defp encode_branch_provenance(input, "creating") do
    case Map.get(input, :branch_provenance) || Map.get(input, "branch_provenance") do
      nil -> {:ok, "unknown"}
      phase when phase in [:unknown, "unknown"] -> {:ok, "unknown"}
      _ -> {:error, :creating_intent_has_branch_provenance}
    end
  end

  defp encode_branch_provenance(input, _lifecycle) do
    case Map.get(input, :branch_provenance) || Map.get(input, "branch_provenance") do
      nil -> {:ok, "unknown"}
      phase when phase in [:created, "created"] -> {:ok, "created"}
      phase when phase in [:reused, "reused"] -> {:ok, "reused"}
      phase when phase in [:unknown, "unknown"] -> {:ok, "unknown"}
      _ -> {:error, :invalid_branch_provenance}
    end
  end

  defp encode_lstat_for_lifecycle(input, "creating", _phase) do
    case Map.get(input, :lstat_identity) || Map.get(input, "lstat_identity") do
      nil -> {:ok, nil}
      _ -> {:error, :creating_intent_has_lstat_identity}
    end
  end

  defp encode_lstat_for_lifecycle(input, "discarding", "branch") do
    case Map.get(input, :lstat_identity) || Map.get(input, "lstat_identity") do
      nil -> {:ok, nil}
      _ -> {:error, :discard_branch_phase_has_lstat_identity}
    end
  end

  defp encode_lstat_for_lifecycle(input, _lifecycle, _phase),
    do: encode_lstat_identity(Map.get(input, :lstat_identity) || Map.get(input, "lstat_identity"))

  defp encode_registration_for_lifecycle(input, "creating", _phase) do
    case Map.get(input, :worktree_registration) || Map.get(input, "worktree_registration") do
      nil -> {:ok, nil}
      _ -> {:error, :creating_intent_has_worktree_registration}
    end
  end

  defp encode_registration_for_lifecycle(input, "discarding", "branch") do
    case Map.get(input, :worktree_registration) || Map.get(input, "worktree_registration") do
      nil -> {:ok, nil}
      _ -> {:error, :discard_branch_phase_has_worktree_registration}
    end
  end

  defp encode_registration_for_lifecycle(input, _lifecycle, _phase),
    do:
      encode_worktree_registration(
        Map.get(input, :worktree_registration) || Map.get(input, "worktree_registration")
      )

  defp validate_ownership_lifecycle("pending", "creating", nil, nil, nil, nil), do: :ok

  defp validate_ownership_lifecycle("owned", lifecycle, base_commit, lstat, registration, nil)
       when lifecycle in ["active", "retained"] and is_binary(base_commit) and
              is_map(lstat) and is_map(registration),
       do: :ok

  defp validate_ownership_lifecycle(
         "owned",
         "discarding",
         base_commit,
         lstat,
         registration,
         "worktree"
       )
       when is_binary(base_commit) and is_map(lstat) and is_map(registration),
       do: :ok

  defp validate_ownership_lifecycle("owned", "discarding", base_commit, nil, nil, "branch")
       when is_binary(base_commit),
       do: :ok

  defp validate_ownership_lifecycle(_, _, _, _, _, _),
    do: {:error, :invalid_ownership_lifecycle_pair}

  defp valid_ownership_lifecycle?(%{
         ownership: "pending",
         lifecycle: "creating",
         base_commit: nil,
         lstat_identity: nil,
         worktree_registration: nil
       }),
       do: true

  defp valid_ownership_lifecycle?(%{
         ownership: "owned",
         lifecycle: lifecycle,
         base_commit: base_commit,
         lstat_identity: lstat,
         worktree_registration: registration
       })
       when lifecycle in ["active", "retained"] and is_binary(base_commit) and
              is_map(lstat) and is_map(registration),
       do: true

  defp valid_ownership_lifecycle?(%{
         ownership: "owned",
         lifecycle: "discarding",
         base_commit: base_commit,
         lstat_identity: lstat,
         worktree_registration: registration,
         discard_phase: "worktree"
       })
       when is_binary(base_commit) and is_map(lstat) and is_map(registration),
       do: true

  defp valid_ownership_lifecycle?(%{
         ownership: "owned",
         lifecycle: "discarding",
         base_commit: base_commit,
         lstat_identity: nil,
         worktree_registration: nil,
         discard_phase: "branch"
       })
       when is_binary(base_commit),
       do: true

  defp valid_ownership_lifecycle?(_), do: false

  defp reject_non_distinct_worktree(repo_path, worktree_path)
       when is_binary(repo_path) and is_binary(worktree_path) do
    if repo_path == worktree_path do
      {:error, :primary_checkout_not_retainable}
    else
      :ok
    end
  end

  defp reject_non_distinct_worktree(_, _), do: {:error, :primary_checkout_not_retainable}

  defp reject_registration_path_mismatch(_worktree_path, nil), do: :ok

  defp reject_registration_path_mismatch(worktree_path, %{path: reg_path})
       when is_binary(worktree_path) and is_binary(reg_path) do
    if worktree_path == reg_path do
      :ok
    else
      {:error, :worktree_registration_path_mismatch}
    end
  end

  defp reject_registration_path_mismatch(_, _), do: {:error, :invalid_worktree_registration}

  defp validate_runtime_id(id) when is_binary(id) do
    cond do
      id == "" ->
        {:error, :invalid_runtime_id}

      byte_size(id) > @max_runtime_id_bytes ->
        {:error, :invalid_runtime_id}

      not String.valid?(id) ->
        {:error, :invalid_runtime_id}

      String.contains?(id, <<0>>) ->
        {:error, :invalid_runtime_id}

      not Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,126}\z/, id) ->
        {:error, :invalid_runtime_id}

      true ->
        :ok
    end
  end

  defp validate_runtime_id(_), do: {:error, :invalid_runtime_id}

  defp encode_lstat_identity(identity) when is_map(identity) do
    with {:ok, normalized} <- normalize_closed_map(identity),
         :ok <- require_exact_keys(normalized, @lstat_keys),
         {:ok, type} <- require_bounded_string(normalized, "type", 64),
         {:ok, major} <- require_non_neg_integer(normalized, "major_device"),
         {:ok, minor} <- require_non_neg_integer(normalized, "minor_device"),
         {:ok, inode} <- require_non_neg_integer(normalized, "inode") do
      {:ok,
       %{
         type: type,
         major_device: major,
         minor_device: minor,
         inode: inode
       }}
    end
  end

  defp encode_lstat_identity(_), do: {:error, :invalid_lstat_identity}

  defp encode_worktree_registration(registration) when is_map(registration) do
    with {:ok, normalized} <- normalize_closed_map(registration),
         :ok <- require_exact_keys(normalized, @registration_keys),
         {:ok, path} <- require_bounded_string(normalized, "path", @max_path_bytes),
         {:ok, head} <- require_bounded_string(normalized, "head", @max_commit_bytes),
         {:ok, branch} <- require_bounded_string(normalized, "branch", @max_branch_bytes) do
      {:ok, %{path: path, head: head, branch: branch}}
    end
  end

  defp encode_worktree_registration(_), do: {:error, :invalid_worktree_registration}

  defp encode_expires_at(%DateTime{} = dt) do
    case DateTime.to_iso8601(dt) do
      iso when is_binary(iso) and byte_size(iso) <= 64 -> {:ok, iso}
      _ -> {:error, :invalid_expires_at}
    end
  end

  defp encode_expires_at(iso) when is_binary(iso) do
    with :ok <- bound_string(iso, 64),
         {:ok, dt, _offset} <- DateTime.from_iso8601(iso),
         true <- dt.calendar == Calendar.ISO do
      {:ok, DateTime.to_iso8601(dt)}
    else
      _ -> {:error, :invalid_expires_at}
    end
  end

  defp encode_expires_at(_), do: {:error, :invalid_expires_at}

  defp encode_retry_count(n) when is_integer(n) and n >= 0 and n <= 10_000, do: {:ok, n}
  defp encode_retry_count(_), do: {:error, :invalid_retry_count}

  defp optional_or_default_path(input, key, default) do
    case Map.get(input, key) do
      nil -> require_bounded_binary(default, @max_path_bytes)
      value -> require_bounded_binary(value, @max_path_bytes)
    end
  end

  # -- inventory / key validation -------------------------------------

  defp validate_key_list(keys) do
    cond do
      length(keys) > @max_records * 4 ->
        {:error, :retention_inventory_oversized}

      Enum.any?(keys, &(not retained_key?(&1))) ->
        {:error, :invalid_retention_key}

      length(Enum.uniq(keys)) != length(keys) ->
        {:error, :duplicate_retention_key}

      true ->
        :ok
    end
  end

  defp validate_record_count(keys) do
    if length(keys) > @max_records do
      {:error, :retention_record_limit_exceeded}
    else
      :ok
    end
  end

  defp validate_workspace_id(id) when is_binary(id) do
    cond do
      id == "" ->
        {:error, :invalid_workspace_id}

      byte_size(id) > @max_workspace_id_bytes ->
        {:error, :invalid_workspace_id}

      not String.valid?(id) ->
        {:error, :invalid_workspace_id}

      String.contains?(id, <<0>>) ->
        {:error, :invalid_workspace_id}

      String.contains?(id, "/") or String.contains?(id, "\\") ->
        {:error, :invalid_workspace_id}

      String.contains?(id, "..") ->
        {:error, :invalid_workspace_id}

      not Regex.match?(~r/\A[a-z0-9][a-z0-9._-]{0,126}\z/, id) ->
        {:error, :invalid_workspace_id}

      true ->
        :ok
    end
  end

  defp validate_workspace_id(_), do: {:error, :invalid_workspace_id}

  # -- generic field helpers ------------------------------------------

  defp require_exact_keys(map, required) when is_map(map) do
    require_closed_keys(map, required, [])
  end

  defp require_closed_keys(map, required, optional)
       when is_map(map) and is_list(required) and is_list(optional) do
    keys = Map.keys(map) |> Enum.map(&to_string/1) |> MapSet.new()
    required_set = MapSet.new(required)
    allowed = MapSet.union(required_set, MapSet.new(optional))

    cond do
      not MapSet.subset?(required_set, keys) ->
        {:error, :unexpected_retention_keys}

      not MapSet.subset?(keys, allowed) ->
        {:error, :unexpected_retention_keys}

      true ->
        :ok
    end
  end

  defp require_schema_version(%{"schema_version" => @schema_version}), do: :ok
  defp require_schema_version(%{schema_version: @schema_version}), do: :ok
  defp require_schema_version(_), do: {:error, :unsupported_schema_version}

  defp require_bounded_string(map, key, max) when is_map(map) do
    value =
      case Map.fetch(map, key) do
        {:ok, value} -> value
        :error when is_atom(key) -> Map.get(map, Atom.to_string(key))
        :error -> nil
      end

    case value do
      v when is_atom(v) and not is_nil(v) ->
        require_bounded_binary(Atom.to_string(v), max)

      v ->
        require_bounded_binary(v, max)
    end
  end

  defp require_bounded_binary(value, max) when is_binary(value) do
    with :ok <- bound_string(value, max),
         true <- value != "" do
      {:ok, value}
    else
      _ -> {:error, :invalid_retention_string}
    end
  end

  defp require_bounded_binary(_, _), do: {:error, :invalid_retention_string}

  defp optional_bounded_id(map, key, max) when is_map(map) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      "" ->
        {:ok, nil}

      value when is_binary(value) ->
        with :ok <- bound_string(value, max) do
          {:ok, value}
        end

      _ ->
        {:error, :invalid_optional_id}
    end
  end

  defp validate_task_principal_pair(nil, nil), do: :ok

  defp validate_task_principal_pair(task_id, principal_id)
       when is_binary(task_id) and is_binary(principal_id),
       do: :ok

  defp validate_task_principal_pair(_task_id, _principal_id),
    do: {:error, :incomplete_task_principal}

  defp require_non_neg_integer(map, key) when is_map(map) do
    case Map.get(map, key) do
      n when is_integer(n) and n >= 0 and n <= 9_007_199_254_740_991 ->
        {:ok, n}

      _ ->
        {:error, :invalid_non_neg_integer}
    end
  end

  defp bound_string(value, max) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      String.contains?(value, <<0>>) -> {:error, :nul_byte}
      byte_size(value) > max -> {:error, :string_too_long}
      true -> :ok
    end
  end

  defp bound_string(_, _), do: {:error, :invalid_string}

  defp valid_nonblank?(value) when is_binary(value), do: value != ""
  defp valid_nonblank?(_), do: false

  # Accept pure atom-key or pure string-key maps. Reject mixed aliases that
  # would otherwise overwrite (e.g. both `:ownership` and `"ownership"`).
  defp normalize_closed_map(map) when is_map(map) do
    if map_size(map) > 32 do
      {:error, :map_too_large}
    else
      keys = Map.keys(map)
      atom_keys = Enum.filter(keys, &is_atom/1)
      string_keys = Enum.filter(keys, &is_binary/1)
      other_keys = Enum.reject(keys, fn k -> is_atom(k) or is_binary(k) end)

      cond do
        other_keys != [] ->
          {:error, :invalid_map_key}

        atom_keys != [] and string_keys != [] ->
          atom_as_strings = MapSet.new(Enum.map(atom_keys, &Atom.to_string/1))
          string_set = MapSet.new(string_keys)

          if MapSet.size(MapSet.intersection(atom_as_strings, string_set)) > 0 do
            {:error, :duplicate_key_alias}
          else
            # Mixed non-colliding keys are still rejected: one key form only.
            {:error, :mixed_key_forms}
          end

        true ->
          Enum.reduce_while(map, {:ok, %{}}, fn
            {k, v}, {:ok, acc} when is_atom(k) ->
              {:cont, {:ok, Map.put(acc, Atom.to_string(k), v)}}

            {k, v}, {:ok, acc} when is_binary(k) ->
              with :ok <- bound_string(k, 64) do
                {:cont, {:ok, Map.put(acc, k, v)}}
              else
                err -> {:halt, err}
              end
          end)
      end
    end
  end

  defp normalize_closed_map(_), do: {:error, :invalid_map}

  defp assert_encode_budget(term) do
    case walk_budget(term, 0, 0) do
      {:ok, _nodes, _depth} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp assert_decode_budget(term) do
    case walk_budget(term, 0, 0) do
      {:ok, _nodes, _depth} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp walk_budget(_term, nodes, depth)
       when nodes >= @max_json_nodes or depth > @max_json_depth,
       do: {:error, :retention_structure_oversized}

  defp walk_budget(map, nodes, depth) when is_map(map) do
    Enum.reduce_while(map, {:ok, nodes + 1, depth}, fn {k, v}, {:ok, n, d} ->
      with :ok <- bound_key(k),
           {:ok, n2, _} <- walk_budget(v, n, d + 1) do
        {:cont, {:ok, n2, d}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp walk_budget(list, nodes, depth) when is_list(list) do
    Enum.reduce_while(list, {:ok, nodes + 1, depth}, fn v, {:ok, n, d} ->
      case walk_budget(v, n, d + 1) do
        {:ok, n2, _} -> {:cont, {:ok, n2, d}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp walk_budget(bin, nodes, _depth) when is_binary(bin) do
    if byte_size(bin) > @max_string_bytes do
      {:error, :string_too_long}
    else
      {:ok, nodes + 1, 0}
    end
  end

  defp walk_budget(n, nodes, _depth) when is_integer(n) do
    if abs(n) > 9_007_199_254_740_991 do
      {:error, :integer_too_large}
    else
      {:ok, nodes + 1, 0}
    end
  end

  defp walk_budget(true, nodes, _depth), do: {:ok, nodes + 1, 0}
  defp walk_budget(false, nodes, _depth), do: {:ok, nodes + 1, 0}
  defp walk_budget(nil, nodes, _depth), do: {:ok, nodes + 1, 0}
  defp walk_budget(atom, nodes, _depth) when is_atom(atom), do: {:ok, nodes + 1, 0}
  defp walk_budget(_other, _nodes, _depth), do: {:error, :non_json_clean_term}

  defp bound_key(k) when is_atom(k), do: :ok

  defp bound_key(k) when is_binary(k) do
    if byte_size(k) <= 64 and String.valid?(k), do: :ok, else: {:error, :invalid_map_key}
  end

  defp bound_key(_), do: {:error, :invalid_map_key}
end
