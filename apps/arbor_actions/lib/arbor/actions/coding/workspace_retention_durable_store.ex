defmodule Arbor.Actions.Coding.WorkspaceRetentionDurableStore do
  @moduledoc """
  Node-restart durable file backend for retained-workspace markers.

  Implements `Arbor.Contracts.Persistence.Store` so the registry uses only the
  public `Arbor.Persistence` facade (`put`/`get`/`delete`/`list`). Values are
  written as exclusive temp + rename under an operator-configured root.

  Durability class: `:node_restart` (survives BEAM restart; process/BEAM crash
  consistency via atomic rename — not a power-loss fsync claim).

  Production path comes from `Arbor.Actions.Config.workspace_retention_journal_path/0`
  (stable `ARBOR_HOME`-based default). The store binds the canonical parent and
  private root directory (mode `0o700`), retains both inode identities, and
  revalidates them before every file side effect. The parent must be owned by
  the current process UID and not group/world writable. Existing roots must
  already be process-owned with exact mode `0o700`; startup never repairs a
  previously exposed or foreign-owned root.

  Malformed or oversized inventory fails closed into a poisoned/degraded state
  rather than crashing the entire Actions application, so unknown retained
  evidence cannot be silently ignored by admitting fresh workspaces.

  Refreshes intentionally scan every bounded record file to verify the raw
  digest and detect additions/deletions. Unchanged digests reuse the cached
  decoded value, avoiding repeated JSON normalization while preserving the
  full inventory drift check required by the single-writer scope.

  Trust boundary: one live store writer and a bound, same-UID parent/root are
  assumed. Pathname and inode revalidation detects ordinary replacement and
  drift, but does not claim protection from a malicious same-UID actor able to
  perform atomic double-swaps between checks. `File.ls/1` materializes names
  before the 1,024-name ceiling is checked because the BEAM exposes no portable
  bounded directory iterator; avoiding that residual would require platform
  shell or NIF glue outside this store's portability boundary.
  """

  use GenServer

  require Logger

  @behaviour Arbor.Contracts.Persistence.Store

  alias Arbor.Actions.Coding.WorkspaceRetentionJournalCore, as: Core
  alias Arbor.Common.SafePath

  @max_entries Core.max_records()
  @max_inventory_names Core.max_records() * 4
  @max_value_bytes Core.max_snapshot_bytes()
  @max_aggregate_inventory_bytes Core.max_aggregate_inventory_bytes()
  @temp_prefix ".arbor-retention-tmp-"
  @owner_probe_prefix ".arbor-retention-owner-probe-"
  @temp_name_pattern ~r/\A\.arbor-retention-tmp-[0-9a-f]{32}\.json\z/
  @temp_name_retries 8
  @root_mode 0o700
  @record_mode 0o600
  @max_input_depth 6
  @max_input_nodes Core.max_json_nodes()
  @max_input_binary_bytes @max_value_bytes
  @max_json_safe_integer 9_007_199_254_740_991
  @max_finite_float 1.7976931348623157e308

  @doc false
  def child_spec(opts) do
    opts = List.wrap(opts)
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Start the durable store owner.

  Options:
  * `:name` — registered name (default `__MODULE__`)
  * `:path` — absolute journal root directory (defaults to Config)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # -- Store behaviour (called via Arbor.Persistence) -----------------

  @impl true
  def put(key, value, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:put, key, value})
  end

  @impl true
  def get(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:get, key})
  end

  @impl true
  def delete(key, opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, {:delete, key})
  end

  @impl true
  def list(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.call(name, :list)
  end

  @impl true
  def exists?(key, opts) do
    case get(key, opts) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @impl true
  def durability_class(_opts), do: :node_restart

  # -- GenServer ------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || Arbor.Actions.Config.workspace_retention_journal_path()

    case bind_root(path) do
      {:ok, binding} ->
        case load_inventory(binding) do
          {:ok, inventory, total_bytes} ->
            {:ok,
             Map.merge(binding, %{
               status: :ready,
               inventory: inventory,
               total_bytes: total_bytes,
               reason: nil
             })}

          {:error, reason} ->
            Logger.warning(
              "workspace retention durable store load failed; starting poisoned",
              detail: inspect(reason)
            )

            {:ok,
             Map.merge(binding, %{
               status: :poisoned,
               inventory: %{},
               total_bytes: 0,
               reason: reason
             })}
        end

      {:error, reason} ->
        Logger.warning(
          "workspace retention durable store root unavailable; starting poisoned",
          detail: inspect(reason)
        )

        {:ok,
         %{
           status: :poisoned,
           parent: nil,
           parent_identity: nil,
           process_uid: nil,
           root: nil,
           root_identity: nil,
           inventory: %{},
           total_bytes: 0,
           reason: reason
         }}
    end
  end

  @impl true
  def handle_call(_msg, _from, %{status: :poisoned} = state) do
    {:reply, {:error, {:retention_store_poisoned, state.reason}}, state}
  end

  def handle_call({:put, key, value}, _from, state) do
    with :ok <- validate_key(key),
         {:ok, state} <- refresh_state(state),
         {:ok, encoded} <- encode_value(value),
         {:ok, normalized} <- decode_input_json(encoded),
         :ok <- ensure_capacity(state, key, byte_size(encoded)),
         :ok <- publish_file(state, key, encoded) do
      case load_inventory(state, state.inventory) do
        {:ok, inventory, total_bytes} ->
          case verify_put_result(state, key, normalized, encoded, inventory) do
            :ok ->
              {:reply, :ok, %{state | inventory: inventory, total_bytes: total_bytes}}

            {:error, reason} ->
              {:reply, {:error, reason}, maybe_poison(state, reason)}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, maybe_poison(state, reason)}
      end
    else
      {:error, {:retention_capacity_exceeded, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, {:retention_input_rejected, reason}} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, maybe_poison(state, reason)}
    end
  end

  def handle_call({:get, key}, _from, state) do
    with {:ok, state} <- refresh_state(state),
         :ok <- validate_key(key) do
      case Map.fetch(state.inventory, key) do
        {:ok, snapshot} ->
          {:reply, {:ok, snapshot.value}, state}

        :error ->
          {:reply, {:error, :not_found}, state}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, maybe_poison(state, reason)}
    end
  end

  def handle_call({:delete, key}, _from, state) do
    with {:ok, state} <- refresh_state(state),
         :ok <- validate_key(key),
         {:ok, _existed} <- remove_key_file(state, key),
         {:ok, inventory, total_bytes} <-
           load_inventory(state, state.inventory),
         :ok <- verify_delete_result(state, key, inventory) do
      {:reply, :ok, %{state | inventory: inventory, total_bytes: total_bytes}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, maybe_poison(state, reason)}
    end
  end

  def handle_call(:list, _from, state) do
    case refresh_state(state) do
      {:ok, state} ->
        keys =
          state.inventory
          |> Map.keys()
          |> Enum.sort()

        {:reply, {:ok, keys}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, maybe_poison(state, reason)}
    end
  end

  # -- root binding ---------------------------------------------------

  defp bind_root(path) when is_binary(path) and path != "" do
    if Path.type(path) == :absolute do
      expanded = Path.expand(path)

      with {:ok, parent_binding, leaf} <- bind_parent(expanded) do
        bind_leaf(parent_binding, leaf)
      end
    else
      {:error, :relative_journal_path}
    end
  end

  defp bind_root(_), do: {:error, :invalid_journal_path}

  defp bind_parent(expanded) do
    requested_parent = Path.dirname(expanded)
    basename = Path.basename(expanded)

    with :ok <- validate_root_basename(basename),
         :ok <- ensure_parent_exists(requested_parent),
         {:ok, %File.Stat{type: :directory} = initial_stat} <- File.stat(requested_parent),
         {:ok, real_parent, real_stat} <- resolve_bound_parent(requested_parent, initial_stat),
         :ok <- require_safe_parent_mode(real_stat),
         parent_binding = %{
           parent: real_parent,
           parent_identity: root_identity(real_stat)
         },
         :ok <- revalidate_parent(parent_binding),
         {:ok, process_uid} <- probe_process_owner(parent_binding),
         :ok <- verify_parent_owner(real_stat.uid, process_uid),
         parent_binding = Map.put(parent_binding, :process_uid, process_uid),
         :ok <- revalidate_parent(parent_binding),
         {:ok, leaf} <- SafePath.safe_join(real_parent, basename) do
      {:ok, parent_binding, leaf}
    else
      {:ok, _stat} -> {:error, :parent_not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_root_basename(basename)
       when is_binary(basename) and basename not in ["", ".", "..", "/"],
       do: :ok

  defp validate_root_basename(_basename), do: {:error, :invalid_journal_path}

  defp ensure_parent_exists(requested_parent) do
    case File.stat(requested_parent) do
      {:ok, _stat} -> :ok
      {:error, :enoent} -> File.mkdir_p(requested_parent)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_bound_parent(requested_parent, expected_stat) do
    with {:ok, real_parent} <- SafePath.resolve_real(requested_parent),
         {:ok, %File.Stat{type: :directory} = real_stat} <- File.lstat(real_parent),
         true <- filesystem_identity(expected_stat) == filesystem_identity(real_stat) do
      {:ok, real_parent, real_stat}
    else
      false -> {:error, :parent_identity_mismatch}
      {:ok, _stat} -> {:error, :parent_not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_leaf(parent_binding, leaf) do
    with :ok <- revalidate_parent(parent_binding) do
      case File.lstat(leaf) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :root_symlink}

        {:ok, %File.Stat{type: :directory} = stat} ->
          bind_existing_root(parent_binding, leaf, stat)

        {:ok, _stat} ->
          {:error, :not_a_directory}

        {:error, :enoent} ->
          create_and_bind_root(parent_binding, leaf)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp bind_existing_root(parent_binding, leaf, initial_stat) do
    with :ok <- revalidate_parent(parent_binding),
         :ok <- require_private_root_mode(initial_stat),
         {:ok, real, real_stat} <- resolve_bound_root(leaf, initial_stat),
         true <- Path.dirname(real) == parent_binding.parent,
         :ok <- require_private_root_mode(real_stat),
         :ok <- verify_root_owner(real_stat.uid, parent_binding.process_uid),
         binding =
           Map.merge(parent_binding, %{root: real, root_identity: root_identity(real_stat)}),
         :ok <- revalidate_storage(binding) do
      {:ok, binding}
    else
      false -> {:error, :root_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_and_bind_root(parent_binding, leaf) do
    with :ok <- revalidate_parent(parent_binding) do
      case File.mkdir(leaf) do
        :ok -> secure_new_root(parent_binding, leaf)
        {:error, :eexist} -> {:error, :root_creation_race}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp secure_new_root(parent_binding, leaf) do
    with :ok <- revalidate_parent(parent_binding),
         {:ok, %File.Stat{type: :directory} = created_stat} <- File.lstat(leaf),
         {:ok, real, real_stat} <- resolve_bound_root(leaf, created_stat),
         true <- Path.dirname(real) == parent_binding.parent,
         :ok <- verify_root_owner(real_stat.uid, parent_binding.process_uid),
         binding_before_chmod =
           Map.merge(parent_binding, %{root: real, root_identity: root_identity(real_stat)}),
         :ok <- revalidate_storage(binding_before_chmod),
         :ok <- File.chmod(real, @root_mode),
         :ok <- revalidate_parent(parent_binding),
         {:ok, %File.Stat{type: :directory} = final_stat} <- File.lstat(real),
         true <- filesystem_identity(final_stat) == filesystem_identity(real_stat),
         true <- final_stat.uid == parent_binding.process_uid,
         :ok <- require_private_root_mode(final_stat),
         binding =
           Map.merge(parent_binding, %{root: real, root_identity: root_identity(final_stat)}),
         :ok <- revalidate_storage(binding) do
      {:ok, binding}
    else
      false -> {:error, :root_creation_race}
      {:ok, _stat} -> {:error, :not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_bound_root(expanded, expected_stat) do
    with {:ok, real} <- SafePath.resolve_real(expanded),
         {:ok, %File.Stat{type: :directory} = real_stat} <- File.lstat(real),
         true <- filesystem_identity(expected_stat) == filesystem_identity(real_stat) do
      {:ok, real, real_stat}
    else
      false -> {:error, :root_identity_mismatch}
      {:ok, _stat} -> {:error, :not_a_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_private_root_mode(%File.Stat{mode: mode}) do
    if permission_mode(mode) == @root_mode,
      do: :ok,
      else: {:error, :root_permissions_not_private}
  end

  defp require_safe_parent_mode(%File.Stat{mode: mode}) do
    if Bitwise.band(permission_mode(mode), 0o022) == 0,
      do: :ok,
      else: {:error, :parent_permissions_unsafe}
  end

  defp probe_process_owner(parent_binding) do
    path = Path.join(parent_binding.parent, new_owner_probe_name())

    with :ok <- revalidate_parent(parent_binding) do
      case :file.open(String.to_charlist(path), [:write, :exclusive, :raw, :binary]) do
        {:ok, fd} ->
          result =
            with :ok <- revalidate_parent(parent_binding) do
              case File.lstat(path) do
                {:ok, %File.Stat{type: :regular, uid: uid}} -> {:ok, uid}
                {:ok, _stat} -> {:error, :owner_probe_not_regular}
                {:error, reason} -> {:error, {:owner_probe_stat_failed, reason}}
              end
            end

          _ = :file.close(fd)
          cleanup_result = remove_parent_probe(parent_binding, path)

          case {result, cleanup_result} do
            {{:ok, uid}, :ok} -> {:ok, uid}
            {{:error, reason}, _cleanup} -> {:error, reason}
            {{:ok, _uid}, {:error, reason}} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, {:owner_probe_failed, reason}}
      end
    end
  end

  defp remove_parent_probe(parent_binding, path) do
    with :ok <- revalidate_parent(parent_binding) do
      case File.rm(path) do
        :ok -> :ok
        {:error, reason} -> {:error, {:owner_probe_cleanup_failed, reason}}
      end
    end
  end

  defp new_owner_probe_name do
    @owner_probe_prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  defp verify_parent_owner(parent_uid, process_uid) when parent_uid == process_uid, do: :ok
  defp verify_parent_owner(_parent_uid, _process_uid), do: {:error, :parent_owner_mismatch}

  defp verify_root_owner(root_uid, owner_uid) when root_uid == owner_uid, do: :ok
  defp verify_root_owner(_root_uid, _owner_uid), do: {:error, :root_owner_mismatch}

  defp root_identity(%File.Stat{} = stat) do
    %{
      type: stat.type,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      uid: stat.uid,
      mode: permission_mode(stat.mode)
    }
  end

  defp filesystem_identity(%File.Stat{} = stat) do
    {stat.type, stat.major_device, stat.minor_device, stat.inode}
  end

  defp permission_mode(mode), do: Bitwise.band(mode, 0o777)

  defp revalidate_parent(%{parent: nil}), do: {:error, :parent_unbound}

  defp revalidate_parent(%{parent: parent, parent_identity: expected}) do
    case File.lstat(parent) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        cond do
          filesystem_identity(stat) !=
              {expected.type, expected.major_device, expected.minor_device, expected.inode} ->
            {:error, :parent_identity_changed}

          stat.uid != expected.uid ->
            {:error, :parent_owner_changed}

          permission_mode(stat.mode) != expected.mode ->
            {:error, :parent_permissions_changed}

          true ->
            :ok
        end

      {:ok, _stat} ->
        {:error, :parent_not_a_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_root(%{root: nil}), do: {:error, :root_unbound}

  defp revalidate_root(%{root: root, root_identity: expected}) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        cond do
          filesystem_identity(stat) !=
              {expected.type, expected.major_device, expected.minor_device, expected.inode} ->
            {:error, :root_identity_changed}

          stat.uid != expected.uid ->
            {:error, :root_owner_changed}

          permission_mode(stat.mode) != expected.mode ->
            {:error, :root_permissions_changed}

          true ->
            :ok
        end

      {:ok, _} ->
        {:error, :not_a_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_storage(state) do
    with :ok <- revalidate_parent(state),
         :ok <- revalidate_root(state) do
      :ok
    end
  end

  defp maybe_poison(state, reason) do
    if poison_reason?(reason) do
      Logger.warning(
        "workspace retention durable store poisoned",
        detail: inspect(reason)
      )

      %{state | status: :poisoned, reason: reason, inventory: %{}, total_bytes: 0}
    else
      state
    end
  end

  defp poison_reason?(reason)
       when reason in [
              :parent_identity_changed,
              :parent_unbound,
              :parent_owner_changed,
              :parent_permissions_changed,
              :parent_not_a_directory,
              :root_identity_changed,
              :root_unbound,
              :root_owner_changed,
              :root_permissions_changed,
              :root_symlink,
              :retention_inventory_oversized,
              :retention_aggregate_bytes_exceeded,
              :retention_record_limit_exceeded,
              :invalid_retention_inventory_filename,
              :not_a_regular_file,
              :not_a_directory,
              :record_owner_mismatch,
              :record_permissions_not_private,
              :value_too_large,
              :corrupt_store_value,
              :duplicate_json_member,
              :retention_structure_oversized
            ],
       do: true

  defp poison_reason?({:corrupt_store_entry, _, _}), do: true
  defp poison_reason?({:retention_inventory_drift, _}), do: true
  defp poison_reason?(_), do: false

  # -- inventory load -------------------------------------------------

  defp load_inventory(state, previous_inventory \\ %{}) do
    root = state.root

    with :ok <- revalidate_storage(state),
         {:ok, names} <- File.ls(root),
         :ok <- bound_inventory_names(names),
         {:ok, temps, records} <- partition_names(names),
         :ok <- bound_record_names(records),
         :ok <- clear_stale_temps(state, temps),
         {:ok, raw_stats, total_bytes} <-
           scan_raw_inventory(root, state.root_identity.uid, records) do
      Enum.reduce_while(records, {:ok, %{}}, fn name, {:ok, acc} ->
        key = String.replace_suffix(name, ".json", "")
        cached = Map.get(previous_inventory, key)

        case read_inventory_file(root, key, Map.fetch!(raw_stats, key), cached) do
          {:ok, snapshot} ->
            {:cont, {:ok, Map.put(acc, key, snapshot)}}

          {:error, reason} ->
            {:halt, {:error, {:corrupt_store_entry, key, reason}}}
        end
      end)
      |> case do
        {:ok, inventory} -> {:ok, inventory, total_bytes}
        other -> other
      end
    end
  end

  # Stat all records before decoding so a hostile inventory cannot force full
  # JSON parse work past the aggregate ceiling.
  defp scan_raw_inventory(root, root_uid, records) when is_list(records) do
    Enum.reduce_while(records, {:ok, %{}, 0}, fn name, {:ok, stats, total} ->
      path = Path.join(root, name)
      key = String.replace_suffix(name, ".json", "")

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size} = stat} ->
          cond do
            stat.uid != root_uid ->
              {:halt, {:error, :record_owner_mismatch}}

            permission_mode(stat.mode) != @record_mode ->
              {:halt, {:error, :record_permissions_not_private}}

            not is_integer(size) or size < 0 or size > @max_value_bytes ->
              {:halt, {:error, :value_too_large}}

            total + size > @max_aggregate_inventory_bytes ->
              {:halt, {:error, :retention_aggregate_bytes_exceeded}}

            true ->
              {:cont,
               {:ok, Map.put(stats, key, %{size: size, identity: file_identity(stat)}),
                total + size}}
          end

        {:ok, _} ->
          {:halt, {:error, :not_a_regular_file}}

        {:error, :enoent} ->
          {:halt, {:error, {:retention_inventory_drift, {:missing, key}}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp bound_inventory_names(names) when is_list(names) do
    if length(names) > @max_inventory_names do
      {:error, :retention_inventory_oversized}
    else
      :ok
    end
  end

  defp partition_names(names) do
    Enum.reduce_while(names, {:ok, [], []}, fn name, {:ok, temps, records} ->
      cond do
        is_binary(name) and Regex.match?(@temp_name_pattern, name) ->
          {:cont, {:ok, [name | temps], records}}

        is_binary(name) and String.ends_with?(name, ".json") and
            Core.retained_key?(String.replace_suffix(name, ".json", "")) ->
          {:cont, {:ok, temps, [name | records]}}

        true ->
          {:halt, {:error, :invalid_retention_inventory_filename}}
      end
    end)
    |> case do
      {:ok, temps, records} -> {:ok, Enum.sort(temps), Enum.sort(records)}
      other -> other
    end
  end

  defp bound_record_names(records) do
    if length(records) > @max_entries do
      {:error, :retention_record_limit_exceeded}
    else
      :ok
    end
  end

  defp clear_stale_temps(state, temps) do
    Enum.reduce_while(temps, :ok, fn name, :ok ->
      path = Path.join(state.root, name)

      result =
        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} -> remove_bound_file(state, path)
          {:ok, _} -> {:error, :not_a_regular_file}
          {:error, reason} -> {:error, {:retention_inventory_drift, {:temp, name, reason}}}
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # -- key / value helpers --------------------------------------------

  defp validate_key(key) when is_binary(key) do
    if Core.retained_key?(key) do
      :ok
    else
      {:error, :invalid_store_key}
    end
  end

  defp validate_key(_), do: {:error, :invalid_store_key}

  defp ensure_capacity(state, key, new_size) do
    existing_size =
      case Map.get(state.inventory, key) do
        %{raw_size: size} -> size
        nil -> 0
      end

    next_total = state.total_bytes - existing_size + new_size

    cond do
      not Map.has_key?(state.inventory, key) and map_size(state.inventory) >= @max_entries ->
        {:error, {:retention_capacity_exceeded, :store_full}}

      next_total > @max_aggregate_inventory_bytes ->
        {:error, {:retention_capacity_exceeded, :retention_aggregate_bytes_exceeded}}

      true ->
        :ok
    end
  end

  defp encode_value(value) do
    with :ok <- validate_input_budget(value) do
      try do
        json = Jason.encode!(value)

        if byte_size(json) > @max_value_bytes do
          {:error, {:retention_input_rejected, :value_too_large}}
        else
          {:ok, json}
        end
      rescue
        _ -> {:error, {:retention_input_rejected, :encode_failed}}
      end
    end
  end

  defp decode_input_json(encoded) do
    case Core.decode_json_bytes(encoded) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, {:retention_input_rejected, reason}}
    end
  end

  defp validate_input_budget(value) do
    case walk_input(value, 1, {0, 0}) do
      {:ok, _budget} -> :ok
      {:error, reason} -> {:error, {:retention_input_rejected, reason}}
    end
  end

  defp walk_input(_value, depth, _budget) when depth > @max_input_depth,
    do: {:error, :retention_structure_oversized}

  defp walk_input(value, _depth, _budget) when is_struct(value),
    do: {:error, :encode_failed}

  defp walk_input(value, depth, budget) when is_map(value) do
    with {:ok, budget} <- add_input_node(budget) do
      walk_input_map(:maps.iterator(value), depth, budget)
    end
  end

  defp walk_input(value, depth, budget) when is_list(value) do
    with {:ok, budget} <- add_input_node(budget) do
      walk_input_list(value, depth, budget)
    end
  end

  defp walk_input(value, _depth, budget) when is_binary(value) do
    with {:ok, budget} <- add_input_node(budget),
         {:ok, budget} <- add_input_binary_bytes(budget, byte_size(value)) do
      {:ok, budget}
    end
  end

  defp walk_input(value, _depth, budget)
       when is_integer(value) and value >= -@max_json_safe_integer and
              value <= @max_json_safe_integer,
       do: add_input_node(budget)

  defp walk_input(value, _depth, _budget) when is_integer(value),
    do: {:error, :numeric_value_out_of_range}

  defp walk_input(value, _depth, budget) when is_float(value) do
    if value == value and value >= -@max_finite_float and value <= @max_finite_float,
      do: add_input_node(budget),
      else: {:error, :numeric_value_out_of_range}
  end

  defp walk_input(value, _depth, budget) when is_boolean(value) or is_nil(value),
    do: add_input_node(budget)

  defp walk_input(value, _depth, budget) when is_atom(value) do
    with {:ok, budget} <- add_input_node(budget) do
      add_input_binary_bytes(budget, byte_size(Atom.to_string(value)))
    end
  end

  defp walk_input(_value, _depth, _budget), do: {:error, :encode_failed}

  defp walk_input_map(iterator, depth, budget) do
    case :maps.next(iterator) do
      :none ->
        {:ok, budget}

      {key, value, next} ->
        with {:ok, budget} <- add_input_key_bytes(key, budget),
             {:ok, budget} <- walk_input(value, depth + 1, budget) do
          walk_input_map(next, depth, budget)
        end
    end
  end

  defp walk_input_list([], _depth, budget), do: {:ok, budget}

  defp walk_input_list([head | tail], depth, budget) do
    with {:ok, budget} <- walk_input(head, depth + 1, budget) do
      walk_input_list(tail, depth, budget)
    end
  end

  defp walk_input_list(_improper, _depth, _budget), do: {:error, :encode_failed}

  defp add_input_key_bytes(key, budget) when is_binary(key),
    do: add_input_binary_bytes(budget, byte_size(key))

  defp add_input_key_bytes(key, budget) when is_atom(key),
    do: add_input_binary_bytes(budget, byte_size(Atom.to_string(key)))

  defp add_input_key_bytes(key, budget)
       when is_integer(key) and key >= -@max_json_safe_integer and key <= @max_json_safe_integer,
       do: {:ok, budget}

  defp add_input_key_bytes(key, _budget) when is_integer(key),
    do: {:error, :numeric_value_out_of_range}

  defp add_input_key_bytes(_key, _budget), do: {:error, :encode_failed}

  defp add_input_node({nodes, binary_bytes}) when nodes < @max_input_nodes,
    do: {:ok, {nodes + 1, binary_bytes}}

  defp add_input_node(_budget), do: {:error, :retention_structure_oversized}

  defp add_input_binary_bytes({nodes, binary_bytes}, size)
       when size <= @max_input_binary_bytes - binary_bytes,
       do: {:ok, {nodes, binary_bytes + size}}

  defp add_input_binary_bytes(_budget, _size), do: {:error, :value_too_large}

  defp refresh_state(state) do
    with :ok <- revalidate_storage(state),
         {:ok, inventory, total_bytes} <- load_inventory(state, state.inventory),
         :ok <- compare_inventory(state.inventory, inventory) do
      {:ok, %{state | inventory: inventory, total_bytes: total_bytes}}
    end
  end

  defp compare_inventory(expected, actual) when expected == actual, do: :ok

  defp compare_inventory(_expected, _actual),
    do: {:error, {:retention_inventory_drift, :snapshot_mismatch}}

  defp verify_put_result(state, key, normalized, encoded, inventory) do
    expected_keys = Map.keys(state.inventory) |> MapSet.new() |> MapSet.put(key)
    actual_keys = Map.keys(inventory) |> MapSet.new()

    case Map.get(inventory, key) do
      nil ->
        {:error, {:retention_inventory_drift, :written_key_missing}}

      snapshot ->
        cond do
          expected_keys != actual_keys ->
            {:error, {:retention_inventory_drift, :keys_changed}}

          Enum.any?(Map.keys(state.inventory), fn old_key ->
            old_key != key and Map.get(state.inventory, old_key) != Map.get(inventory, old_key)
          end) ->
            {:error, {:retention_inventory_drift, :other_file_changed}}

          snapshot.value != normalized ->
            {:error, {:retention_inventory_drift, :written_value_changed}}

          snapshot.raw_size != byte_size(encoded) ->
            {:error, {:retention_inventory_drift, :written_size_changed}}

          snapshot.raw_digest != raw_digest(encoded) ->
            {:error, {:retention_inventory_drift, :written_digest_changed}}

          true ->
            :ok
        end
    end
  end

  defp verify_delete_result(state, key, inventory) do
    expected = Map.delete(state.inventory, key)

    if expected == inventory do
      :ok
    else
      {:error, {:retention_inventory_drift, :delete_result_mismatch}}
    end
  end

  defp publish_file(state, key, json) do
    with {:ok, target} <- key_path(state.root, key),
         :ok <- revalidate_storage(state),
         {:ok, temp} <- exclusive_temp(state, json),
         :ok <- revalidate_storage(state) do
      case File.rename(temp, target) do
        :ok ->
          :ok

        {:error, reason} ->
          cleanup_temp_error(state, temp, reason)
      end
    end
  end

  defp exclusive_temp(state, json) do
    root = state.root

    Enum.reduce_while(1..@temp_name_retries, {:error, :temp_create_failed}, fn _, _acc ->
      name = new_temp_name()
      path = Path.join(root, name)

      case revalidate_storage(state) do
        :ok ->
          open_exclusive_temp(state, path, json)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp open_exclusive_temp(state, path, json) do
    case :file.open(String.to_charlist(path), [:write, :exclusive, :raw, :binary]) do
      {:ok, fd} ->
        result = write_private_temp(fd, path, state, json)
        _ = :file.close(fd)

        case result do
          :ok ->
            case validate_published_temp(state, path) do
              :ok -> {:halt, {:ok, path}}
              {:error, reason} -> {:halt, cleanup_temp_error(state, path, reason)}
            end

          {:error, reason} ->
            {:halt, cleanup_temp_error(state, path, reason)}
        end

      {:error, :eexist} ->
        {:cont, {:error, :temp_create_failed}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp write_private_temp(fd, path, state, json) do
    with :ok <- revalidate_storage(state),
         :ok <- File.chmod(path, @record_mode),
         :ok <- revalidate_storage(state),
         {:ok, %File.Stat{} = stat} <- File.lstat(path),
         :ok <- validate_private_record_stat(stat, state.root_identity.uid),
         :ok <- revalidate_storage(state),
         :ok <- :file.write(fd, json),
         :ok <- revalidate_storage(state),
         :ok <- :file.sync(fd) do
      :ok
    else
      {:ok, _stat} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :temp_write_failed}
  end

  defp validate_published_temp(state, path) do
    with :ok <- revalidate_storage(state) do
      case File.lstat(path) do
        {:ok, %File.Stat{} = stat} ->
          validate_private_record_stat(stat, state.root_identity.uid)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp cleanup_temp_error(state, path, reason) do
    case remove_bound_file(state, path) do
      :ok -> {:error, reason}
      {:error, cleanup_reason} -> {:error, cleanup_reason}
    end
  end

  defp validate_private_record_stat(%File.Stat{type: :regular, uid: uid, mode: mode}, root_uid) do
    cond do
      uid != root_uid -> {:error, :record_owner_mismatch}
      permission_mode(mode) != @record_mode -> {:error, :record_permissions_not_private}
      true -> :ok
    end
  end

  defp validate_private_record_stat(%File.Stat{}, _root_uid),
    do: {:error, :not_a_regular_file}

  defp new_temp_name do
    @temp_prefix <>
      Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".json"
  end

  defp read_inventory_file(
         root,
         key,
         %{size: expected_size, identity: expected_identity},
         cached
       ) do
    with {:ok, path} <- key_path(root, key),
         {:ok, %File.Stat{type: :regular, size: size} = before} <- File.lstat(path),
         true <- size == expected_size,
         true <- file_identity(before) == expected_identity,
         {:ok, body} <- File.read(path),
         {:ok, %File.Stat{type: :regular, size: after_size} = after_stat} <- File.lstat(path),
         true <- after_size == byte_size(body),
         true <- file_identity(after_stat) == expected_identity do
      digest = raw_digest(body)

      value_result =
        if is_map(cached) and cached.raw_digest == digest do
          {:ok, cached.value}
        else
          Core.decode_json_bytes(body)
        end

      with {:ok, value} <- value_result do
        {:ok,
         %{
           value: value,
           raw_size: byte_size(body),
           raw_digest: digest,
           file_identity: file_identity(after_stat)
         }}
      end
    else
      {:error, :enoent} -> {:error, {:retention_inventory_drift, {:missing, key}}}
      {:error, reason} -> {:error, reason}
      false -> {:error, {:retention_inventory_drift, {:changed, key}}}
      _ -> {:error, :not_a_regular_file}
    end
  end

  defp remove_key_file(state, key) do
    with {:ok, path} <- key_path(state.root, key),
         :ok <- revalidate_storage(state) do
      expected = Map.get(state.inventory, key)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular} = stat} when is_map(expected) ->
          if file_identity(stat) == expected.file_identity do
            case remove_bound_file(state, path) do
              :ok -> {:ok, true}
              {:error, :enoent} -> {:error, {:retention_inventory_drift, {:missing, key}}}
              {:error, reason} -> {:error, reason}
            end
          else
            {:error, {:retention_inventory_drift, {:changed, key}}}
          end

        {:ok, _stat} when is_nil(expected) ->
          {:error, {:retention_inventory_drift, {:unexpected, key}}}

        {:ok, _stat} ->
          {:error, {:retention_inventory_drift, {:changed, key}}}

        {:error, :enoent} when is_nil(expected) ->
          {:ok, false}

        {:error, :enoent} ->
          {:error, {:retention_inventory_drift, {:missing, key}}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp remove_bound_file(state, path) do
    with :ok <- revalidate_storage(state) do
      File.rm(path)
    end
  end

  defp file_identity(%File.Stat{} = stat) do
    %{
      type: stat.type,
      major_device: stat.major_device,
      minor_device: stat.minor_device,
      inode: stat.inode,
      size: stat.size,
      uid: stat.uid,
      mode: permission_mode(stat.mode)
    }
  end

  defp raw_digest(body), do: :crypto.hash(:sha256, body)

  defp key_path(root, key) do
    # Keys are closed-grammar; join under root and require containment.
    SafePath.safe_join(root, key <> ".json")
  end
end
