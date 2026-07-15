defmodule Arbor.Shell.AppleContainerUnitJournal do
  @moduledoc """
  Imperative single-writer owner of the durable Apple Container unit-intent journal.

  Interprets pure `AppleContainerUnitJournalCore` reserve/complete effects into
  one process/BEAM-crash-consistent JSON snapshot on disk *before* a future unit
  worker may issue `container create`. Publication is atomic via exclusive temp
  + rename with descriptor-bound identity and SHA-256 payload digests. This
  claims **process/BEAM crash consistency only** — not power-loss durability
  (no directory fsync). The module owns filesystem IO only: it never launches
  containers and never emits signals.

  Wired permanently under `Arbor.Shell.Application` after `PortSessionSupervisor`
  and before `AppleContainerUnitRecoverySupervisor` so journal authority outlives
  unit-supervisor and drain-coordinator failures under rest_for_one.
  """

  use GenServer

  import Bitwise

  alias Arbor.Common.SafePath
  alias Arbor.Shell.AppleContainerUnitJournalCore, as: Core
  alias Arbor.Shell.Config
  alias Arbor.Shell.ExecutablePolicy
  alias Arbor.Shell.Executor

  @max_snapshot_bytes 1_048_576
  # The fixed schema nests root -> active[] -> record -> scalar. The lexical
  # preflight rejects deeper inputs before Jason allocates their decode tree;
  # the ordered-object reducer enforces the same boundary while converting.
  @max_json_depth 4
  @temp_name_retries 8
  @temp_prefix ".arbor-unit-journal-tmp-"
  # Exact exclusive-temp grammar: .arbor-unit-journal-tmp-<32 lowercase hex>.json
  @temp_name_regex ~r/\A\.arbor-unit-journal-tmp-[0-9a-f]{32}\.json\z/
  # Fixed bound on reserved-prefix parent entries at startup. Overflow fails
  # closed without deleting any candidate.
  @max_startup_stale_temp_candidates 64

  # Cross-BEAM singleton ownership. shlock is startup-pinned via ExecutablePolicy
  # at the exact absolute path below — never PATH-resolved or caller-selected.
  @shlock_path "/usr/bin/shlock"
  @shlock_timeout_ms 5_000
  @shlock_max_output_bytes 256
  @lock_suffix ".lock"
  @max_lock_bytes 32

  @allowed_start_keys MapSet.new([:name, :path])

  @type status :: :disabled | :ready | :poisoned

  # Private filesystem binding. Paths and identities never appear in public
  # status or format_status; only the owner process retains them.
  @type parent_identity :: %{
          type: :directory,
          major_device: non_neg_integer(),
          inode: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          mode: non_neg_integer()
        }

  # File identity from lstat/fstat. Content is bound separately as SHA-256.
  @type target_file_identity :: %{
          type: :regular,
          major_device: non_neg_integer(),
          inode: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          mode: non_neg_integer(),
          links: pos_integer(),
          size: non_neg_integer()
        }

  # Bound published target: exact file identity plus descriptor-read digest.
  @type target_identity :: %{
          type: :regular,
          major_device: non_neg_integer(),
          inode: non_neg_integer(),
          uid: non_neg_integer(),
          gid: non_neg_integer(),
          mode: non_neg_integer(),
          links: pos_integer(),
          size: non_neg_integer(),
          digest: String.t()
        }

  @type binding :: %{
          path: String.t(),
          parent_path: String.t(),
          parent: parent_identity(),
          target: :missing | target_identity()
        }

  # In-flight exclusive temp before rename. Digest is proven from the open FD.
  @type temp_publication :: %{
          path: String.t(),
          identity: target_file_identity(),
          digest: String.t(),
          payload_size: non_neg_integer()
        }

  @type state :: %{
          status: status(),
          reason: term() | nil,
          binding: binding() | nil,
          journal: Core.state() | nil
        }

  @type public_status :: %{
          required(String.t()) => String.t() | integer() | nil
        }

  @doc """
  Start the unit-intent journal owner.

  Production callers pass no options: the journal path is read only from
  `Config.apple_container_unit_journal_path/0` and the process registers as
  `#{inspect(__MODULE__)}`.

  Absent configuration starts a live **disabled** owner so Shell can still boot
  on hosts that do not configure durable unit journaling. Invalid configured
  paths and corrupt existing journal files fail process start and never
  replace or delete the existing file.

  Direct-start tests may inject only `:name` and/or `:path`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    with {:ok, start} <- prepare_start(opts) do
      GenServer.start_link(__MODULE__, start.init, name: start.name)
    end
  end

  @doc """
  Child specification for `Arbor.Shell.Application` (permanent worker).
  """
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts = List.wrap(opts)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  Reserve a unit intent for the exact `unit_name` + `execution_id`.

  Generates a 32-byte cryptorandom token (64 lowercase hex) and a millisecond
  wall-clock timestamp, asks the pure core to reserve, and persists the exact
  core snapshot before replying the token. Same single reservation transaction
  as `reserve_record/3`; only the successful reply shape differs.
  """
  @spec reserve(String.t(), String.t(), GenServer.server()) ::
          {:ok, String.t()} | {:error, term()}
  def reserve(unit_name, execution_id, server \\ __MODULE__) do
    call(server, {:reserve, unit_name, execution_id, :token})
  end

  @doc """
  Reserve a unit intent and return the exact normalized core record.

  Uses the same single reservation transaction as `reserve/3` (generate token
  + timestamp, core reserve, durable publish). Replies `{:ok, record}` only
  after the snapshot is published, with the committed `unit_name`,
  `execution_id`, `token`, and `reserved_at_ms` from the next journal state —
  never a reserve-then-reread path.
  """
  @spec reserve_record(String.t(), String.t(), GenServer.server()) ::
          {:ok, Core.record()} | {:error, term()}
  def reserve_record(unit_name, execution_id, server \\ __MODULE__) do
    call(server, {:reserve, unit_name, execution_id, :record})
  end

  @doc """
  Complete an active intent only when both `unit_name` and `token` match.

  Persists removal before returning `:ok`. Wrong/unknown/replay results do not
  mutate memory or disk.
  """
  @spec complete(String.t(), String.t(), GenServer.server()) :: :ok | {:error, term()}
  def complete(unit_name, token, server \\ __MODULE__) do
    call(server, {:complete, unit_name, token})
  end

  @doc """
  List active intent records for recovery. Never claims absence or safe delete.
  """
  @spec recovery_entries(GenServer.server()) ::
          {:ok, [Core.record()]} | {:error, term()}
  def recovery_entries(server \\ __MODULE__) do
    call(server, :recovery_entries)
  end

  @doc """
  Redacted public status. Never includes path, tokens, or raw journal state.
  """
  @spec status(GenServer.server()) :: public_status()
  def status(server \\ __MODULE__) do
    case call(server, :status) do
      {:ok, status} when is_map(status) -> status
      _other -> unavailable_public_status(:journal_unavailable)
    end
  end

  @impl true
  def init({:disabled, reason}) do
    {:ok,
     %{
       status: :disabled,
       reason: reason,
       binding: nil,
       journal: nil
     }}
  end

  def init({:active, path}) when is_binary(path) do
    case bootstrap_active(path) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:stop, {:apple_container_unit_journal_start_failed, reason}}
    end
  end

  def init(_other) do
    {:stop, {:apple_container_unit_journal_start_failed, :invalid_start_arg}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, render_public_status(state)}, state}
  end

  def handle_call(:recovery_entries, _from, %{status: :disabled} = state) do
    {:reply, {:error, :apple_container_unit_journal_disabled}, state}
  end

  def handle_call(:recovery_entries, _from, %{status: :poisoned} = state) do
    # Recovery listing remains available so operators can inspect retained
    # evidence after poison. New reserves stay blocked.
    case state.journal do
      journal when is_map(journal) ->
        case Core.recovery_entries(journal) do
          entries when is_list(entries) ->
            {:reply, {:ok, entries}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :apple_container_unit_journal_poisoned}, state}
    end
  end

  def handle_call(:recovery_entries, _from, %{status: :ready, journal: journal} = state)
      when is_map(journal) do
    case Core.recovery_entries(journal) do
      entries when is_list(entries) ->
        {:reply, {:ok, entries}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:reserve, _unit_name, _execution_id, reply_mode},
        _from,
        %{status: :disabled} = state
      )
      when reply_mode in [:token, :record] do
    {:reply, {:error, :apple_container_unit_journal_disabled}, state}
  end

  def handle_call(
        {:reserve, _unit_name, _execution_id, reply_mode},
        _from,
        %{status: :poisoned} = state
      )
      when reply_mode in [:token, :record] do
    {:reply, {:error, :apple_container_unit_journal_poisoned}, state}
  end

  def handle_call(
        {:reserve, unit_name, execution_id, reply_mode},
        _from,
        %{status: :ready, journal: journal, binding: binding} = state
      )
      when reply_mode in [:token, :record] and is_map(journal) and is_map(binding) do
    perform_reserve(state, journal, binding, unit_name, execution_id, reply_mode)
  end

  def handle_call({:reserve, _unit_name, _execution_id, _reply_mode}, _from, state) do
    {:reply, {:error, :unsupported_apple_container_unit_journal_reserve_reply_mode}, state}
  end

  def handle_call({:complete, _unit_name, _token}, _from, %{status: :disabled} = state) do
    {:reply, {:error, :apple_container_unit_journal_disabled}, state}
  end

  def handle_call({:complete, _unit_name, _token}, _from, %{status: :poisoned} = state) do
    {:reply, {:error, :apple_container_unit_journal_poisoned}, state}
  end

  def handle_call(
        {:complete, unit_name, token},
        _from,
        %{status: :ready, journal: journal, binding: binding} = state
      )
      when is_map(journal) and is_map(binding) do
    case Core.complete(journal, unit_name, token) do
      {:ok, next_state, effects} ->
        case interpret_and_persist(binding, next_state, effects) do
          {:ok, next_binding} ->
            {:reply, :ok, %{state | journal: next_state, binding: next_binding}}

          {:error, :journal_post_rename_uncertain} ->
            reply =
              {:error,
               {:apple_container_unit_journal_persist_failed, :journal_post_rename_uncertain}}

            {:stop,
             {:apple_container_unit_journal_post_rename_uncertain, :identity_unestablished},
             reply, state}

          {:error, reason} ->
            # Completion write failure may leave a stale active record on disk.
            # Do not claim success; poison new reserves while retaining evidence.
            poisoned = poison_state(state, reason)
            {:reply, {:error, {:apple_container_unit_journal_persist_failed, reason}}, poisoned}
        end

      {:error, reason} ->
        # Wrong/unknown/replay fail closed without mutating state or disk.
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(_request, _from, state) do
    {:reply, {:error, :unsupported_apple_container_unit_journal_request}, state}
  end

  @impl true
  def format_status(status) when is_map(status) do
    state = Map.get(status, :state, %{})

    status
    |> Map.put(:message, :redacted)
    |> Map.put(:state, redact_state(state))
    |> redact_status_field(:reason)
    |> redact_status_field(:log)
  end

  def format_status(status), do: status

  @impl true
  def terminate(_reason, _state) do
    # Intentionally do not remove the OS lock file. A full BEAM exit makes the
    # PID stale for later reclaim; deleting on child restart would reopen a
    # race between stop and the replacement start. In-BEAM path claims are
    # process-bound and auto-release when this process dies.
    :ok
  end

  # --- Start preparation ------------------------------------------------------

  defp prepare_start(opts) when is_list(opts) do
    with :ok <- reject_unknown_start_keys(opts),
         {:ok, name} <- start_name(opts),
         {:ok, path_result} <- resolve_path(opts) do
      case path_result do
        :absent ->
          {:ok, %{name: name, init: {:disabled, :apple_container_unit_journal_path_absent}}}

        {:path, path} ->
          {:ok, %{name: name, init: {:active, path}}}
      end
    end
  end

  defp prepare_start(_opts), do: {:error, :apple_container_unit_journal_start_malformed}

  defp reject_unknown_start_keys(opts) do
    unknown =
      opts
      |> Keyword.keys()
      |> Enum.reject(&MapSet.member?(@allowed_start_keys, &1))

    if unknown == [] do
      :ok
    else
      {:error, {:unsupported_apple_container_unit_journal_start_keys, unknown}}
    end
  end

  defp start_name(opts) do
    case Keyword.fetch(opts, :name) do
      :error ->
        {:ok, __MODULE__}

      {:ok, name} when is_atom(name) or is_tuple(name) ->
        {:ok, name}

      {:ok, _other} ->
        {:error, :invalid_apple_container_unit_journal_name}
    end
  end

  defp resolve_path(opts) do
    case Keyword.fetch(opts, :path) do
      :error ->
        case Config.apple_container_unit_journal_path() do
          {:ok, path} ->
            {:ok, {:path, path}}

          {:error, :apple_container_unit_journal_path_absent} ->
            {:ok, :absent}

          {:error, reason} ->
            {:error, reason}
        end

      {:ok, path} ->
        case Config.validate_unit_journal_path(path) do
          {:ok, validated} ->
            {:ok, {:path, validated}}

          {:error, :invalid_path} ->
            {:error, :apple_container_unit_journal_path_malformed}

          {:error, reason} when is_atom(reason) ->
            {:error, {:invalid_apple_container_unit_journal_path, reason}}
        end
    end
  end

  # --- Bootstrap --------------------------------------------------------------

  defp bootstrap_active(path) do
    with {:ok, binding0} <- bind_journal_path(path),
         :ok <- claim_canonical_path(binding0.path),
         :ok <- acquire_os_lock(binding0.path),
         # Bounded startup stale-temp cleanup only after claim + OS lock, and
         # only before any journal target load or empty-state construction.
         :ok <- cleanup_startup_stale_temps(binding0),
         {:ok, journal, binding} <- load_or_empty(binding0) do
      {:ok,
       %{
         status: :ready,
         reason: nil,
         binding: binding,
         journal: journal
       }}
    end
  end

  # --- Startup stale-temp cleanup ---------------------------------------------
  #
  # After path claim + OS lock, before load_or_empty:
  # 1. Revalidate bound parent, list parent, scan reserved-prefix names
  # 2. Fail closed (delete nothing) on overflow (>64 prefix entries),
  #    prefix-bearing malformed names, or any admit failure
  # 3. Validate every exact-grammar candidate (sorted) before any delete
  # 4. Delete admitted temps with repeated exact inode/path checks
  # 5. Revalidate parent and rescan to prove no reserved-prefix residue
  # Unrelated non-prefix names are ignored. Never follow links. Errors are
  # bounded atoms/tuples without path/name/content leakage.

  defp cleanup_startup_stale_temps(binding) when is_map(binding) do
    with :ok <- revalidate_bound_parent(binding),
         {:ok, names} <- list_startup_parent_names(binding),
         {:ok, candidates} <- collect_startup_stale_temp_candidates(names),
         {:ok, admitted} <- admit_all_startup_stale_temps(binding, candidates),
         :ok <- delete_admitted_startup_stale_temps(binding, admitted),
         :ok <- revalidate_bound_parent(binding),
         :ok <- assert_no_startup_stale_temp_residue(binding),
         :ok <- revalidate_bound_parent(binding) do
      :ok
    end
  end

  defp list_startup_parent_names(%{parent_path: parent}) when is_binary(parent) do
    case File.ls(parent) do
      {:ok, names} when is_list(names) ->
        if Enum.all?(names, &is_binary/1) do
          {:ok, names}
        else
          {:error, :journal_startup_temp_list_failed}
        end

      {:error, reason} ->
        {:error, {:journal_startup_temp_list_failed, bound_reason(reason)}}
    end
  end

  # Deterministic sorted scan. Non-prefix names are ignored. All reserved-prefix
  # entries count toward the fixed overflow bound. Prefix-bearing malformed
  # grammar fails closed without deletion.
  defp collect_startup_stale_temp_candidates(names) when is_list(names) do
    prefix_names =
      names
      |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, @temp_prefix)))
      |> Enum.sort()

    cond do
      length(prefix_names) > @max_startup_stale_temp_candidates ->
        {:error, :journal_startup_temp_candidate_overflow}

      true ->
        collect_exact_startup_temp_names(prefix_names, [])
    end
  end

  defp collect_exact_startup_temp_names([], acc), do: {:ok, Enum.reverse(acc)}

  defp collect_exact_startup_temp_names([name | rest], acc) when is_binary(name) do
    if exact_reserved_temp_name?(name) do
      collect_exact_startup_temp_names(rest, [name | acc])
    else
      {:error, :journal_startup_temp_name_malformed}
    end
  end

  defp exact_reserved_temp_name?(name) when is_binary(name) do
    Regex.match?(@temp_name_regex, name)
  end

  defp admit_all_startup_stale_temps(binding, names)
       when is_map(binding) and is_list(names) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case admit_startup_stale_temp(binding, name) do
        {:ok, admitted} ->
          {:cont, {:ok, [admitted | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, admitted} -> {:ok, Enum.reverse(admitted)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Admit one exact-name candidate without deleting. Requires private 0600,
  # single-link, same-parent-UID regular file with stable descriptor/path
  # identity across repeated checks. Never follows links.
  defp admit_startup_stale_temp(binding, name)
       when is_map(binding) and is_binary(name) do
    path = Path.join(binding.parent_path, name)

    with :ok <- revalidate_bound_parent(binding),
         :ok <- require_exact_reserved_temp_name(name),
         :ok <- require_temp_in_parent(path, binding.parent_path),
         {:ok, pre} <- lstat_startup_stale_temp(path),
         {:ok, identity} <- admit_startup_stale_temp_stat(pre, binding.parent.uid),
         :ok <- prove_startup_stale_temp_identity(path, identity),
         :ok <- prove_startup_stale_temp_identity(path, identity) do
      {:ok, %{path: path, identity: identity}}
    else
      {:error, reason} ->
        {:error, map_startup_stale_temp_error(reason)}
    end
  end

  defp require_exact_reserved_temp_name(name) when is_binary(name) do
    if exact_reserved_temp_name?(name) do
      :ok
    else
      {:error, :journal_startup_temp_name_malformed}
    end
  end

  defp lstat_startup_stale_temp(path) when is_binary(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, :journal_startup_temp_identity_unstable}

      {:error, reason} ->
        {:error, {:journal_startup_temp_stat_failed, bound_reason(reason)}}
    end
  end

  defp admit_startup_stale_temp_stat(%File.Stat{type: :symlink}, _expected_uid),
    do: {:error, :journal_startup_temp_symlink_rejected}

  defp admit_startup_stale_temp_stat(%File.Stat{type: type}, _expected_uid)
       when type != :regular,
       do: {:error, :journal_startup_temp_not_regular}

  defp admit_startup_stale_temp_stat(%File.Stat{type: :regular} = stat, expected_uid)
       when is_integer(expected_uid) do
    with :ok <- assert_startup_stale_temp_single_link(stat),
         :ok <- assert_startup_stale_temp_uid(stat, expected_uid),
         :ok <- assert_startup_stale_temp_mode_0600(stat) do
      {:ok, target_file_identity(stat)}
    end
  end

  defp assert_startup_stale_temp_single_link(%File.Stat{links: 1}), do: :ok

  defp assert_startup_stale_temp_single_link(%File.Stat{}),
    do: {:error, :journal_startup_temp_hardlink_rejected}

  defp assert_startup_stale_temp_uid(%File.Stat{uid: uid}, expected_uid)
       when is_integer(uid) and is_integer(expected_uid) do
    if uid == expected_uid do
      :ok
    else
      {:error, :journal_startup_temp_uid_mismatch}
    end
  end

  defp assert_startup_stale_temp_uid(_stat, _expected_uid),
    do: {:error, :journal_startup_temp_uid_mismatch}

  # Startup cleanup requires exact private mode 0600 (not merely no group/other).
  defp assert_startup_stale_temp_mode_0600(%File.Stat{mode: mode, type: :regular}) do
    if (mode &&& 0o777) == 0o600 do
      :ok
    else
      {:error, :journal_startup_temp_not_private}
    end
  end

  defp assert_startup_stale_temp_mode_0600(_),
    do: {:error, :journal_startup_temp_not_regular}

  # One descriptor-bound identity proof: lstat → open → fstat → close → lstat.
  defp prove_startup_stale_temp_identity(path, identity)
       when is_binary(path) and is_map(identity) do
    with {:ok, pre} <- lstat_startup_stale_temp(path),
         :ok <- require_exact_temp_file_identity(identity, pre),
         {:ok, io} <- open_journal_read(path) do
      try do
        with {:ok, opened} <- fstat_journal_io(io),
             :ok <- match_bound_target(identity, opened),
             :ok <- close_io(io),
             {:ok, post} <- lstat_startup_stale_temp(path),
             :ok <- require_exact_temp_file_identity(identity, post) do
          :ok
        else
          {:error, reason} ->
            {:error, reason}
        end
      after
        _ = close_io_silent(io)
      end
    end
  end

  # Delete only after every candidate was admitted. Revalidate parent before
  # each delete; each unlink re-proves exact name and full file identity.
  defp delete_admitted_startup_stale_temps(_binding, []), do: :ok

  defp delete_admitted_startup_stale_temps(binding, admitted)
       when is_map(binding) and is_list(admitted) do
    Enum.reduce_while(admitted, :ok, fn temp, :ok ->
      case delete_one_admitted_startup_stale_temp(binding, temp) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp delete_one_admitted_startup_stale_temp(binding, %{path: path, identity: identity})
       when is_map(binding) and is_binary(path) and is_map(identity) do
    with :ok <- revalidate_bound_parent(binding),
         :ok <- require_temp_in_parent(path, binding.parent_path),
         :ok <- require_exact_reserved_temp_name(Path.basename(path)),
         :ok <- safe_unlink_admitted_startup_stale_temp(path, identity) do
      :ok
    else
      {:error, reason} ->
        {:error, map_startup_stale_temp_error(reason)}
    end
  end

  # Full identity (mode/size/links/inode) must remain stable through repeated
  # checks. Never delete by name/mode alone; never follow links.
  defp safe_unlink_admitted_startup_stale_temp(path, expected_identity)
       when is_binary(path) and is_map(expected_identity) do
    with {:ok, pre} <- lstat_startup_stale_temp(path),
         :ok <- require_exact_temp_file_identity(expected_identity, pre),
         :ok <- assert_startup_stale_temp_mode_0600(pre),
         {:ok, io} <- open_journal_read(path) do
      try do
        with {:ok, opened} <- fstat_journal_io(io),
             :ok <- match_bound_target(expected_identity, opened),
             :ok <- close_io(io),
             {:ok, post} <- lstat_startup_stale_temp(path),
             :ok <- require_exact_temp_file_identity(expected_identity, post),
             :ok <- assert_startup_stale_temp_mode_0600(post) do
          unlink_if_exact_startup_stale_temp(path, expected_identity)
        else
          {:error, reason} ->
            {:error, reason}
        end
      after
        _ = close_io_silent(io)
      end
    end
  end

  defp unlink_if_exact_startup_stale_temp(path, expected_identity)
       when is_binary(path) and is_map(expected_identity) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        with :ok <- require_exact_temp_file_identity(expected_identity, stat),
             :ok <- assert_startup_stale_temp_mode_0600(stat) do
          case :file.delete(String.to_charlist(path)) do
            :ok ->
              :ok

            {:error, :enoent} ->
              {:error, :journal_startup_temp_identity_unstable}

            {:error, reason} ->
              {:error, {:journal_startup_temp_cleanup_failed, bound_reason(reason)}}
          end
        end

      {:error, :enoent} ->
        {:error, :journal_startup_temp_identity_unstable}

      {:error, reason} ->
        {:error, {:journal_startup_temp_cleanup_failed, bound_reason(reason)}}
    end
  end

  defp assert_no_startup_stale_temp_residue(binding) when is_map(binding) do
    with :ok <- revalidate_bound_parent(binding),
         {:ok, names} <- list_startup_parent_names(binding) do
      residue? =
        Enum.any?(names, fn name ->
          is_binary(name) and String.starts_with?(name, @temp_prefix)
        end)

      if residue? do
        {:error, :journal_startup_temp_residue}
      else
        :ok
      end
    end
  end

  defp map_startup_stale_temp_error(:journal_startup_temp_symlink_rejected),
    do: :journal_startup_temp_symlink_rejected

  defp map_startup_stale_temp_error(:journal_startup_temp_hardlink_rejected),
    do: :journal_startup_temp_hardlink_rejected

  defp map_startup_stale_temp_error(:journal_startup_temp_not_regular),
    do: :journal_startup_temp_not_regular

  defp map_startup_stale_temp_error(:journal_startup_temp_uid_mismatch),
    do: :journal_startup_temp_uid_mismatch

  defp map_startup_stale_temp_error(:journal_startup_temp_not_private),
    do: :journal_startup_temp_not_private

  defp map_startup_stale_temp_error(:journal_startup_temp_name_malformed),
    do: :journal_startup_temp_name_malformed

  defp map_startup_stale_temp_error(:journal_startup_temp_identity_unstable),
    do: :journal_startup_temp_identity_unstable

  defp map_startup_stale_temp_error(:journal_startup_temp_candidate_overflow),
    do: :journal_startup_temp_candidate_overflow

  defp map_startup_stale_temp_error(:journal_startup_temp_residue),
    do: :journal_startup_temp_residue

  defp map_startup_stale_temp_error(:journal_temp_replaced),
    do: :journal_startup_temp_identity_unstable

  defp map_startup_stale_temp_error(:journal_target_replaced),
    do: :journal_startup_temp_identity_unstable

  defp map_startup_stale_temp_error(:journal_target_missing),
    do: :journal_startup_temp_identity_unstable

  defp map_startup_stale_temp_error(:journal_symlink_rejected),
    do: :journal_startup_temp_symlink_rejected

  defp map_startup_stale_temp_error(:journal_not_regular_file),
    do: :journal_startup_temp_not_regular

  defp map_startup_stale_temp_error(:journal_temp_outside_parent),
    do: :journal_startup_temp_outside_parent

  defp map_startup_stale_temp_error(:journal_parent_not_private),
    do: :journal_parent_not_private

  defp map_startup_stale_temp_error(:journal_parent_replaced),
    do: :journal_parent_replaced

  defp map_startup_stale_temp_error(:journal_parent_missing),
    do: :journal_parent_missing

  defp map_startup_stale_temp_error(:journal_parent_symlink_rejected),
    do: :journal_parent_symlink_rejected

  defp map_startup_stale_temp_error(:journal_parent_not_directory),
    do: :journal_parent_not_directory

  defp map_startup_stale_temp_error(:journal_parent_identity_mismatch),
    do: :journal_parent_identity_mismatch

  defp map_startup_stale_temp_error({:journal_open_failed, reason}),
    do: {:journal_startup_temp_open_failed, bound_reason(reason)}

  defp map_startup_stale_temp_error({:journal_fstat_failed, reason}),
    do: {:journal_startup_temp_stat_failed, bound_reason(reason)}

  defp map_startup_stale_temp_error({:journal_startup_temp_stat_failed, reason}),
    do: {:journal_startup_temp_stat_failed, bound_reason(reason)}

  defp map_startup_stale_temp_error({:journal_startup_temp_cleanup_failed, reason}),
    do: {:journal_startup_temp_cleanup_failed, bound_reason(reason)}

  defp map_startup_stale_temp_error({:journal_startup_temp_list_failed, reason}),
    do: {:journal_startup_temp_list_failed, bound_reason(reason)}

  defp map_startup_stale_temp_error({:journal_parent_stat_failed, reason}),
    do: {:journal_parent_stat_failed, bound_reason(reason)}

  defp map_startup_stale_temp_error(reason) when is_atom(reason),
    do: :journal_startup_temp_identity_unstable

  defp map_startup_stale_temp_error({tag, detail}) when is_atom(tag),
    do: {tag, bound_reason(detail)}

  defp map_startup_stale_temp_error(_), do: :journal_startup_temp_identity_unstable

  # Bind the caller-spelled journal path to a private canonical parent identity
  # and a provisional target of :missing. Target identity is filled by load or
  # the first successful publish. Mutable directory times are never bound.
  defp bind_journal_path(path) when is_binary(path) do
    parent = Path.dirname(path)
    base = Path.basename(path)

    with :ok <- reject_reserved_temp_target_name(base),
         {:ok, caller_stat} <- lstat_parent(parent),
         :ok <- require_parent_directory(caller_stat),
         {:ok, canonical_parent} <- resolve_existing_parent(parent),
         {:ok, canonical_stat} <- lstat_parent(canonical_parent),
         :ok <- require_parent_directory(canonical_stat),
         :ok <- assert_private_directory(canonical_stat),
         :ok <- same_parent_identity(caller_stat, canonical_stat) do
      {:ok,
       %{
         path: Path.join(canonical_parent, base),
         parent_path: canonical_parent,
         parent: parent_identity(canonical_stat),
         target: :missing
       }}
    end
  end

  defp reject_reserved_temp_target_name(base) when is_binary(base) do
    if String.starts_with?(base, @temp_prefix) do
      {:error, :journal_target_uses_reserved_temp_namespace}
    else
      :ok
    end
  end

  defp lstat_parent(parent) when is_binary(parent) do
    case File.lstat(parent, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, :journal_parent_missing}

      {:error, reason} ->
        {:error, {:journal_parent_stat_failed, reason}}
    end
  end

  defp require_parent_directory(%File.Stat{type: :directory}), do: :ok

  defp require_parent_directory(%File.Stat{type: :symlink}),
    do: {:error, :journal_parent_symlink_rejected}

  defp require_parent_directory(%File.Stat{}), do: {:error, :journal_parent_not_directory}

  defp same_parent_identity(%File.Stat{} = left, %File.Stat{} = right) do
    if parent_identity(left) == parent_identity(right) do
      :ok
    else
      {:error, :journal_parent_identity_mismatch}
    end
  end

  defp parent_identity(%File.Stat{type: :directory} = stat) do
    %{
      type: :directory,
      major_device: stat.major_device,
      inode: stat.inode,
      uid: stat.uid,
      gid: stat.gid,
      mode: stat.mode
    }
  end

  defp resolve_existing_parent(parent) when is_binary(parent) do
    case SafePath.resolve_real(parent) do
      {:ok, canonical_parent} when is_binary(canonical_parent) ->
        {:ok, canonical_parent}

      {:error, :not_found} ->
        {:error, :journal_parent_missing}

      {:error, reason} ->
        {:error, {:journal_parent_resolve_failed, reason}}
    end
  end

  defp assert_private_parent(parent) when is_binary(parent) do
    case File.lstat(parent, time: :posix) do
      {:ok, %File.Stat{type: :directory} = stat} ->
        assert_private_directory(stat)

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :journal_parent_symlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :journal_parent_not_directory}

      {:error, :enoent} ->
        {:error, :journal_parent_missing}

      {:error, reason} ->
        {:error, {:journal_parent_stat_failed, reason}}
    end
  end

  defp revalidate_bound_parent(%{parent_path: parent_path, parent: expected, path: path})
       when is_binary(parent_path) and is_map(expected) and is_binary(path) do
    if Path.dirname(path) != parent_path do
      {:error, :journal_parent_identity_mismatch}
    else
      case File.lstat(parent_path, time: :posix) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          with :ok <- assert_private_directory(stat),
               :ok <- match_bound_parent(expected, stat) do
            :ok
          end

        {:ok, %File.Stat{type: :symlink}} ->
          {:error, :journal_parent_symlink_rejected}

        {:ok, %File.Stat{}} ->
          {:error, :journal_parent_not_directory}

        {:error, :enoent} ->
          {:error, :journal_parent_missing}

        {:error, reason} ->
          {:error, {:journal_parent_stat_failed, reason}}
      end
    end
  end

  defp match_bound_parent(expected, %File.Stat{} = stat) when is_map(expected) do
    if parent_identity(stat) == expected do
      :ok
    else
      {:error, :journal_parent_replaced}
    end
  end

  # Process-bound unique claim on the canonical journal path. The global name is
  # the tuple `{__MODULE__, binary_path}` — never create atoms from paths, and
  # never start a child process. Released automatically when this process exits.
  defp claim_canonical_path(path) when is_binary(path) do
    case :global.register_name({__MODULE__, path}, self()) do
      :yes ->
        :ok

      :no ->
        {:error, :journal_path_already_claimed}
    end
  end

  defp owns_canonical_path_claim?(path) when is_binary(path) do
    :global.whereis_name({__MODULE__, path}) == self()
  end

  defp acquire_os_lock(canonical_path) when is_binary(canonical_path) do
    lock_path = lock_path_for(canonical_path)
    os_pid = System.pid()
    parent = Path.dirname(canonical_path)

    with {:ok, expected_uid} <- expected_uid_from_parent(parent),
         :ok <- preflight_existing_lock(lock_path, expected_uid),
         {:ok, executable} <- resolve_shlock_executable(),
         {:ok, result} <- run_shlock(executable, lock_path, os_pid),
         :ok <- interpret_shlock_result(result, lock_path, canonical_path, os_pid, expected_uid),
         :ok <- finalize_lock_file(lock_path, canonical_path, os_pid, expected_uid) do
      :ok
    end
  end

  defp lock_path_for(canonical_path) when is_binary(canonical_path),
    do: canonical_path <> @lock_suffix

  # Same-UID reference for lock files: the private canonical parent already
  # admitted for this journal. Never shell out to `id` and never trust caller data.
  defp expected_uid_from_parent(parent) when is_binary(parent) do
    case File.lstat(parent, time: :posix) do
      {:ok, %File.Stat{type: :directory, uid: uid}} when is_integer(uid) and uid >= 0 ->
        {:ok, uid}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :journal_parent_symlink_rejected}

      {:ok, %File.Stat{}} ->
        {:error, :journal_parent_not_directory}

      {:error, :enoent} ->
        {:error, :journal_parent_missing}

      {:error, reason} ->
        {:error, {:journal_parent_stat_failed, reason}}
    end
  end

  # Missing lock is fine (shlock will create). An existing target is admitted only
  # when it is already a same-UID private regular single-link file with bounded
  # valid decimal PID content and stable descriptor-bound identity. Symlinks,
  # hardlinks, wrong owner/mode/type, and malformed content fail before shlock.
  defp preflight_existing_lock(lock_path, expected_uid)
       when is_binary(lock_path) and is_integer(expected_uid) do
    case File.lstat(lock_path, time: :posix) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{}} ->
        case read_lock_pid_descriptor_bound(lock_path, expected_uid) do
          {:ok, _pid} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:journal_lock_stat_failed, reason}}
    end
  end

  defp resolve_shlock_executable do
    case ExecutablePolicy.resolve(@shlock_path) do
      {:ok, executable} ->
        {:ok, executable}

      {:error, :executable_policy_unavailable} ->
        {:error, :journal_lock_executable_unavailable}

      {:error, :executable_not_found} ->
        {:error, :journal_lock_executable_unavailable}

      {:error, reason} ->
        {:error, {:journal_lock_executable_unavailable, reason}}
    end
  end

  defp run_shlock(executable, lock_path, os_pid)
       when is_binary(lock_path) and is_binary(os_pid) do
    Executor.run_bound(
      executable,
      ["-f", lock_path, "-p", os_pid],
      clear_env: true,
      env: %{},
      cwd: "/",
      timeout: @shlock_timeout_ms,
      max_output_bytes: @shlock_max_output_bytes
    )
  end

  # Only an exact clean exit 0 may acquire. Exact clean exit 1 may adopt only
  # when this process owns the path claim and the lock names this OS PID.
  # Every Executor containment anomaly (timeout, cancel, output limit, kill,
  # containment failure) fails closed — never treat a polluted result as success.
  defp interpret_shlock_result(result, lock_path, canonical_path, os_pid, expected_uid)
       when is_map(result) and is_binary(lock_path) and is_binary(canonical_path) and
              is_binary(os_pid) and is_integer(expected_uid) do
    cond do
      executor_result_unclean?(result) ->
        interpret_unclean_shlock_result(result)

      Map.get(result, :exit_code) == 0 ->
        :ok

      Map.get(result, :exit_code) == 1 ->
        adopt_existing_lock(lock_path, canonical_path, os_pid, expected_uid)

      true ->
        {:error, :journal_lock_failed}
    end
  end

  defp interpret_shlock_result(_result, _lock_path, _canonical_path, _os_pid, _expected_uid),
    do: {:error, :journal_lock_failed}

  defp adopt_existing_lock(lock_path, canonical_path, os_pid, expected_uid) do
    if owns_canonical_path_claim?(canonical_path) do
      case read_lock_pid_descriptor_bound(lock_path, expected_uid) do
        {:ok, ^os_pid} ->
          :ok

        {:ok, _other_pid} ->
          {:error, :journal_lock_held}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :journal_lock_held}
    end
  end

  defp executor_result_unclean?(result) when is_map(result) do
    flag_true?(result, :timed_out) or flag_true?(result, :killed) or
      flag_true?(result, :output_truncated) or flag_true?(result, :output_limit_exceeded) or
      flag_true?(result, :cancelled) or flag_true?(result, :containment_failure)
  end

  defp flag_true?(map, key), do: Map.get(map, key) == true

  defp interpret_unclean_shlock_result(result) when is_map(result) do
    cond do
      flag_true?(result, :timed_out) ->
        {:error, :journal_lock_timeout}

      flag_true?(result, :cancelled) ->
        {:error, :journal_lock_cancelled}

      flag_true?(result, :output_limit_exceeded) or flag_true?(result, :output_truncated) ->
        {:error, :journal_lock_output_limit}

      flag_true?(result, :containment_failure) ->
        {:error, :journal_lock_containment_failure}

      true ->
        {:error, :journal_lock_failed}
    end
  end

  defp finalize_lock_file(lock_path, canonical_path, os_pid, expected_uid)
       when is_binary(lock_path) and is_binary(canonical_path) and is_binary(os_pid) and
              is_integer(expected_uid) do
    with :ok <- chmod_lock_private(lock_path),
         :ok <- verify_lock_file(lock_path, canonical_path, os_pid, expected_uid) do
      :ok
    end
  end

  defp chmod_lock_private(lock_path) when is_binary(lock_path) do
    case File.chmod(lock_path, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, {:journal_lock_chmod_failed, reason}}
    end
  end

  defp verify_lock_file(lock_path, canonical_path, os_pid, expected_uid)
       when is_binary(lock_path) and is_binary(canonical_path) and is_binary(os_pid) and
              is_integer(expected_uid) do
    parent = Path.dirname(canonical_path)
    expected_lock = lock_path_for(canonical_path)

    with :ok <- require_exact_lock_path(lock_path, expected_lock),
         :ok <- assert_private_parent(parent),
         :ok <- assert_lock_in_parent(lock_path, parent),
         {:ok, pid} <- read_lock_pid_descriptor_bound(lock_path, expected_uid) do
      if pid == os_pid do
        :ok
      else
        {:error, :journal_lock_pid_mismatch}
      end
    end
  end

  defp require_exact_lock_path(lock_path, expected) do
    if lock_path == expected do
      :ok
    else
      {:error, :journal_lock_path_mismatch}
    end
  end

  defp assert_lock_in_parent(lock_path, parent) do
    if Path.dirname(lock_path) == parent do
      :ok
    else
      {:error, :journal_lock_outside_parent}
    end
  end

  defp lstat_lock(lock_path) when is_binary(lock_path) do
    case File.lstat(lock_path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, :journal_lock_missing}

      {:error, reason} ->
        {:error, {:journal_lock_stat_failed, reason}}
    end
  end

  defp assert_lock_regular_single_link(%File.Stat{type: :regular, links: links})
       when is_integer(links) do
    if links == 1 do
      :ok
    else
      {:error, :journal_lock_hardlink_rejected}
    end
  end

  defp assert_lock_regular_single_link(%File.Stat{type: :symlink}),
    do: {:error, :journal_lock_symlink_rejected}

  defp assert_lock_regular_single_link(%File.Stat{}),
    do: {:error, :journal_lock_not_regular}

  defp assert_lock_uid(%File.Stat{uid: uid}, expected_uid)
       when is_integer(uid) and is_integer(expected_uid) do
    if uid == expected_uid do
      :ok
    else
      {:error, :journal_lock_uid_mismatch}
    end
  end

  defp assert_lock_uid(_stat, _expected_uid), do: {:error, :journal_lock_uid_mismatch}

  defp assert_lock_size_bound(size) when is_integer(size) do
    cond do
      size < 1 -> {:error, :journal_lock_malformed}
      size > @max_lock_bytes -> {:error, :journal_lock_malformed}
      true -> :ok
    end
  end

  # Descriptor-bound lock read: lstat → open → fstat → exact bounded read →
  # fstat → lstat. Identity (device/inode/type/uid/mode/links/size) must be
  # stable throughout. Fail closed on replacement races. Errors are bounded
  # atoms/tuples without path or token leakage.
  defp read_lock_pid_descriptor_bound(lock_path, expected_uid)
       when is_binary(lock_path) and is_integer(expected_uid) do
    with {:ok, pre} <- lstat_lock(lock_path),
         :ok <- assert_lock_regular_single_link(pre),
         :ok <- assert_private_regular_file(pre),
         :ok <- assert_lock_uid(pre, expected_uid),
         :ok <- assert_lock_size_bound(pre.size),
         {:ok, io} <- open_lock_read(lock_path) do
      try do
        with {:ok, opened} <- fstat_lock_io(io),
             :ok <- match_lock_identity(pre, opened),
             {:ok, bytes} <- read_exact_lock_bytes(io, pre.size),
             {:ok, after_fd} <- fstat_lock_io(io),
             :ok <- match_lock_identity(pre, after_fd),
             {:ok, post} <- lstat_lock(lock_path),
             :ok <- match_lock_stat_identity(pre, post) do
          parse_lock_pid(bytes)
        end
      after
        _ = :file.close(io)
      end
    end
  end

  defp open_lock_read(lock_path) when is_binary(lock_path) do
    case :file.open(String.to_charlist(lock_path), [:read, :raw, :binary]) do
      {:ok, io} ->
        {:ok, io}

      {:error, :enoent} ->
        {:error, :journal_lock_missing}

      {:error, reason} ->
        {:error, {:journal_lock_open_failed, reason}}
    end
  end

  defp fstat_lock_io(io) do
    case :file.read_file_info(io, [{:time, :posix}]) do
      {:ok,
       {:file_info, size, type, _access, _atime, _mtime, _ctime, mode, links, major, _minor,
        inode, uid, _gid}}
      when is_integer(size) and is_atom(type) and is_integer(mode) and is_integer(links) and
             is_integer(major) and is_integer(inode) and is_integer(uid) ->
        {:ok,
         %{
           size: size,
           type: type,
           mode: mode,
           links: links,
           major_device: major,
           inode: inode,
           uid: uid
         }}

      {:error, reason} ->
        {:error, {:journal_lock_fstat_failed, reason}}

      _other ->
        {:error, :journal_lock_fstat_failed}
    end
  end

  defp match_lock_identity(%File.Stat{} = pre, opened) when is_map(opened) do
    cond do
      opened.type != :regular ->
        {:error, :journal_lock_replaced}

      opened.type != pre.type ->
        {:error, :journal_lock_replaced}

      opened.size != pre.size ->
        {:error, :journal_lock_replaced}

      opened.mode != pre.mode ->
        {:error, :journal_lock_replaced}

      opened.major_device != pre.major_device ->
        {:error, :journal_lock_replaced}

      opened.inode != pre.inode ->
        {:error, :journal_lock_replaced}

      opened.links != pre.links ->
        {:error, :journal_lock_replaced}

      opened.links != 1 ->
        {:error, :journal_lock_hardlink_rejected}

      opened.uid != pre.uid ->
        {:error, :journal_lock_replaced}

      true ->
        :ok
    end
  end

  defp match_lock_stat_identity(%File.Stat{} = pre, %File.Stat{} = post) do
    cond do
      post.type != pre.type ->
        {:error, :journal_lock_replaced}

      post.size != pre.size ->
        {:error, :journal_lock_replaced}

      post.mode != pre.mode ->
        {:error, :journal_lock_replaced}

      post.major_device != pre.major_device ->
        {:error, :journal_lock_replaced}

      post.inode != pre.inode ->
        {:error, :journal_lock_replaced}

      post.links != pre.links ->
        {:error, :journal_lock_replaced}

      post.uid != pre.uid ->
        {:error, :journal_lock_replaced}

      true ->
        :ok
    end
  end

  defp read_exact_lock_bytes(io, size) when is_integer(size) and size >= 1 do
    case :file.read(io, size + 1) do
      {:ok, data} when is_binary(data) and byte_size(data) == size ->
        {:ok, data}

      {:ok, data} when is_binary(data) and byte_size(data) > size ->
        {:error, :journal_lock_replaced}

      {:ok, data} when is_binary(data) ->
        {:error, :journal_lock_malformed}

      :eof ->
        {:error, :journal_lock_malformed}

      {:error, reason} ->
        {:error, {:journal_lock_read_failed, reason}}
    end
  end

  defp read_exact_lock_bytes(_io, _size), do: {:error, :journal_lock_malformed}

  # Exact decimal PID: optional single trailing newline only. No spaces, signs,
  # or extra trailing content. Bounded by @max_lock_bytes above.
  defp parse_lock_pid(bytes) when is_binary(bytes) do
    case :binary.split(bytes, "\n", [:global]) do
      [digits] ->
        parse_decimal_pid(digits)

      [digits, <<>>] ->
        # Exactly one trailing newline and nothing after it.
        parse_decimal_pid(digits)

      _other ->
        {:error, :journal_lock_malformed}
    end
  end

  defp parse_decimal_pid(digits) when is_binary(digits) do
    if digits != "" and decimal_pid?(digits) do
      {:ok, digits}
    else
      {:error, :journal_lock_malformed}
    end
  end

  defp decimal_pid?(<<>>), do: false

  defp decimal_pid?(<<char, rest::binary>>) when char >= ?0 and char <= ?9 do
    decimal_pid_rest?(rest)
  end

  defp decimal_pid?(_), do: false

  defp decimal_pid_rest?(<<>>), do: true

  defp decimal_pid_rest?(<<char, rest::binary>>) when char >= ?0 and char <= ?9 do
    decimal_pid_rest?(rest)
  end

  defp decimal_pid_rest?(_), do: false

  defp load_or_empty(binding) when is_map(binding) do
    with :ok <- revalidate_bound_parent(binding) do
      case File.lstat(binding.path, time: :posix) do
        {:error, :enoent} ->
          with {:ok, journal} <- Core.new() do
            {:ok, journal, %{binding | target: :missing}}
          end

        {:ok, %File.Stat{} = stat} ->
          with {:ok, file_id} <- admit_existing_target(stat, binding.parent),
               {:ok, bytes} <- read_snapshot_descriptor_bound(binding.path, file_id),
               {:ok, snapshot} <- decode_snapshot(bytes),
               {:ok, journal} <- Core.new(snapshot) do
            target = bind_target_with_digest(file_id, bytes)
            {:ok, journal, %{binding | target: target}}
          end

        {:error, reason} ->
          {:error, {:journal_stat_failed, reason}}
      end
    end
  end

  # Existing journal target admission: same UID as the bound parent, private
  # regular mode, exactly one hard link, bounded size. Identity excludes times
  # and content digest (digest is bound only after a descriptor-bound read).
  defp admit_existing_target(%File.Stat{type: :symlink}, _parent),
    do: {:error, :journal_symlink_rejected}

  defp admit_existing_target(%File.Stat{type: type}, _parent) when type != :regular,
    do: {:error, :journal_not_regular_file}

  defp admit_existing_target(%File.Stat{type: :regular} = stat, parent)
       when is_map(parent) do
    with :ok <- assert_target_single_link(stat),
         :ok <- assert_target_uid(stat, parent),
         :ok <- assert_private_regular_file(stat),
         :ok <- assert_target_size_bound(stat.size) do
      {:ok, target_file_identity(stat)}
    end
  end

  defp target_file_identity(%File.Stat{type: :regular} = stat) do
    %{
      type: :regular,
      major_device: stat.major_device,
      inode: stat.inode,
      uid: stat.uid,
      gid: stat.gid,
      mode: stat.mode,
      links: stat.links,
      size: stat.size
    }
  end

  defp bind_target_with_digest(file_id, bytes)
       when is_map(file_id) and is_binary(bytes) do
    Map.put(file_id, :digest, sha256_hex(bytes))
  end

  defp sha256_hex(bytes) when is_binary(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp file_identity_only(target) when is_map(target) do
    Map.take(target, [
      :type,
      :major_device,
      :inode,
      :uid,
      :gid,
      :mode,
      :links,
      :size
    ])
  end

  defp assert_target_single_link(%File.Stat{links: 1}), do: :ok
  defp assert_target_single_link(%File.Stat{}), do: {:error, :journal_hardlink_rejected}

  defp assert_target_uid(%File.Stat{uid: uid}, %{uid: parent_uid})
       when is_integer(uid) and is_integer(parent_uid) do
    if uid == parent_uid do
      :ok
    else
      {:error, :journal_file_uid_mismatch}
    end
  end

  defp assert_target_uid(_stat, _parent), do: {:error, :journal_file_uid_mismatch}

  defp assert_target_size_bound(size) when is_integer(size) and size >= 0 do
    if size > @max_snapshot_bytes do
      {:error, :journal_snapshot_too_large}
    else
      :ok
    end
  end

  defp assert_target_size_bound(_), do: {:error, :journal_invalid_size}

  defp assert_private_directory(%File.Stat{mode: mode}) do
    if (mode &&& 0o077) == 0 do
      :ok
    else
      {:error, :journal_parent_not_private}
    end
  end

  defp assert_private_regular_file(%File.Stat{mode: mode, type: :regular}) do
    if (mode &&& 0o077) == 0 do
      :ok
    else
      {:error, :journal_file_not_private}
    end
  end

  defp assert_private_regular_file(_), do: {:error, :journal_not_regular_file}

  # Descriptor-bound snapshot load: lstat → open → fstat → exact bounded read
  # through EOF → fstat → lstat. Full target identity must be stable.
  defp read_snapshot_descriptor_bound(path, expected)
       when is_binary(path) and is_map(expected) do
    with {:ok, pre} <- lstat_journal_target(path),
         :ok <- match_bound_target(expected, pre),
         {:ok, io} <- open_journal_read(path) do
      try do
        with {:ok, opened} <- fstat_journal_io(io),
             :ok <- match_bound_target(expected, opened),
             {:ok, bytes} <- read_exact_snapshot_bytes(io, expected.size),
             :ok <- require_journal_eof(io),
             {:ok, after_fd} <- fstat_journal_io(io),
             :ok <- match_bound_target(expected, after_fd),
             {:ok, post} <- lstat_journal_target(path),
             :ok <- match_bound_target(expected, post) do
          {:ok, bytes}
        end
      after
        _ = :file.close(io)
      end
    end
  end

  defp lstat_journal_target(path) when is_binary(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        {:ok, stat}

      {:error, :enoent} ->
        {:error, :journal_target_missing}

      {:error, reason} ->
        {:error, {:journal_stat_failed, reason}}
    end
  end

  defp open_journal_read(path) when is_binary(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :binary]) do
      {:ok, io} ->
        {:ok, io}

      {:error, :enoent} ->
        {:error, :journal_target_missing}

      {:error, reason} ->
        {:error, {:journal_open_failed, reason}}
    end
  end

  defp fstat_journal_io(io) do
    case :file.read_file_info(io, time: :posix) do
      {:ok, info} ->
        {:ok, File.Stat.from_record(info)}

      {:error, reason} ->
        {:error, {:journal_fstat_failed, reason}}
    end
  end

  # Compare lstat/fstat identity only. Digest is content-bound separately.
  defp match_bound_target(expected, %File.Stat{type: :regular} = stat) when is_map(expected) do
    if target_file_identity(stat) == file_identity_only(expected) do
      :ok
    else
      {:error, :journal_target_replaced}
    end
  end

  defp match_bound_target(_expected, %File.Stat{type: :symlink}),
    do: {:error, :journal_symlink_rejected}

  defp match_bound_target(_expected, %File.Stat{}), do: {:error, :journal_not_regular_file}

  defp require_digest(bytes, expected_digest)
       when is_binary(bytes) and is_binary(expected_digest) do
    actual = sha256_hex(bytes)

    if actual == expected_digest and Regex.match?(~r/\A[0-9a-f]{64}\z/, expected_digest) do
      :ok
    else
      {:error, :journal_target_digest_mismatch}
    end
  end

  defp require_digest(_bytes, _expected_digest), do: {:error, :journal_target_digest_mismatch}

  defp require_exact_payload(bytes, expected)
       when is_binary(bytes) and is_binary(expected) do
    if bytes === expected do
      :ok
    else
      {:error, :journal_payload_mismatch}
    end
  end

  # Read exactly `size` declared bytes via a bounded short-read loop, never more.
  defp read_exact_snapshot_bytes(_io, 0), do: {:ok, <<>>}

  defp read_exact_snapshot_bytes(io, size)
       when is_integer(size) and size > 0 and size <= @max_snapshot_bytes do
    read_exact_snapshot_loop(io, size, [])
  end

  defp read_exact_snapshot_bytes(_io, size) when is_integer(size) and size > @max_snapshot_bytes,
    do: {:error, :journal_snapshot_too_large}

  defp read_exact_snapshot_bytes(_io, _size), do: {:error, :journal_invalid_size}

  defp read_exact_snapshot_loop(_io, 0, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp read_exact_snapshot_loop(io, remaining, acc) when remaining > 0 do
    chunk_size = min(remaining, 65_536)

    case :file.read(io, chunk_size) do
      {:ok, chunk}
      when is_binary(chunk) and byte_size(chunk) > 0 and byte_size(chunk) <= remaining ->
        read_exact_snapshot_loop(io, remaining - byte_size(chunk), [chunk | acc])

      {:ok, _chunk} ->
        {:error, :journal_target_replaced}

      :eof ->
        {:error, :journal_read_short}

      {:error, reason} ->
        {:error, {:journal_read_failed, reason}}
    end
  end

  defp require_journal_eof(io) do
    case :file.read(io, 1) do
      :eof ->
        :ok

      {:ok, <<>>} ->
        :ok

      {:ok, _extra} ->
        {:error, :journal_target_replaced}

      {:error, reason} ->
        {:error, {:journal_read_failed, reason}}
    end
  end

  # Missing target: path must still be absent. Present target: descriptor-bound
  # reread must match the exact prior file identity and content digest so
  # same-size in-place mutation is detected before any temp is created.
  defp revalidate_bound_target(%{path: path, target: :missing}) when is_binary(path) do
    case File.lstat(path, time: :posix) do
      {:error, :enoent} ->
        :ok

      {:ok, %File.Stat{}} ->
        {:error, :journal_target_replaced}

      {:error, reason} ->
        {:error, {:journal_stat_failed, reason}}
    end
  end

  defp revalidate_bound_target(%{path: path, target: expected, parent: parent} = binding)
       when is_binary(path) and is_map(expected) and is_map(parent) do
    file_id = file_identity_only(expected)

    with :ok <- require_bound_digest(expected),
         {:ok, bytes} <- read_snapshot_descriptor_bound(path, file_id),
         :ok <- require_digest(bytes, expected.digest),
         :ok <- revalidate_parent_still_bound(binding) do
      :ok
    end
  end

  defp require_bound_digest(%{digest: digest}) when is_binary(digest) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      :ok
    else
      {:error, :journal_target_digest_mismatch}
    end
  end

  defp require_bound_digest(_), do: {:error, :journal_target_digest_mismatch}

  defp revalidate_parent_still_bound(binding), do: revalidate_bound_parent(binding)

  defp decode_snapshot(bytes) when is_binary(bytes) do
    cond do
      not String.valid?(bytes) ->
        {:error, :journal_invalid_utf8}

      true ->
        trimmed = String.trim_trailing(bytes, "\n")

        with :ok <- preflight_json_nesting(trimmed) do
          case Jason.decode(trimmed, objects: :ordered_objects) do
            {:ok, %Jason.OrderedObject{} = ordered} ->
              normalize_journal_json(ordered, 1)

            {:ok, _other} ->
              {:error, :journal_invalid_schema}

            {:error, _reason} ->
              {:error, :journal_invalid_json}
          end
        end
    end
  end

  # Bound container nesting before decode. Delimiters inside JSON strings are
  # ignored; Jason remains responsible for complete syntax validation.
  defp preflight_json_nesting(bytes), do: scan_json_nesting(bytes, 0, false, false)

  defp scan_json_nesting(<<>>, _depth, _in_string, _escaped), do: :ok

  defp scan_json_nesting(<<char, rest::binary>>, depth, true, true) do
    _ = char
    scan_json_nesting(rest, depth, true, false)
  end

  defp scan_json_nesting(<<?\\, rest::binary>>, depth, true, false),
    do: scan_json_nesting(rest, depth, true, true)

  defp scan_json_nesting(<<?\", rest::binary>>, depth, true, false),
    do: scan_json_nesting(rest, depth, false, false)

  defp scan_json_nesting(<<_char, rest::binary>>, depth, true, false),
    do: scan_json_nesting(rest, depth, true, false)

  defp scan_json_nesting(<<?\", rest::binary>>, depth, false, false),
    do: scan_json_nesting(rest, depth, true, false)

  defp scan_json_nesting(<<char, rest::binary>>, depth, false, false)
       when char in [?{, ?[] do
    next_depth = depth + 1

    if next_depth > @max_json_depth do
      {:error, :journal_json_too_deep}
    else
      scan_json_nesting(rest, next_depth, false, false)
    end
  end

  defp scan_json_nesting(<<char, rest::binary>>, depth, false, false)
       when char in [?}, ?]] do
    scan_json_nesting(rest, max(depth - 1, 0), false, false)
  end

  defp scan_json_nesting(<<_char, rest::binary>>, depth, false, false),
    do: scan_json_nesting(rest, depth, false, false)

  # Convert ordered decode trees only after duplicate-key and depth checks.
  # Map conversion before this reducer would silently collapse duplicates.
  defp normalize_journal_json(_value, depth) when depth > @max_json_depth,
    do: {:error, :journal_json_too_deep}

  defp normalize_journal_json(%Jason.OrderedObject{values: pairs}, depth)
       when is_list(pairs) and is_integer(depth) do
    pairs
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {key, value}, {:ok, acc, seen} when is_binary(key) ->
        if MapSet.member?(seen, key) do
          {:halt, {:error, :journal_duplicate_key}}
        else
          case normalize_journal_json(value, depth + 1) do
            {:ok, normalized} ->
              {:cont, {:ok, Map.put(acc, key, normalized), MapSet.put(seen, key)}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end

      _pair, _acc ->
        {:halt, {:error, :journal_invalid_json}}
    end)
    |> case do
      {:ok, map, _seen} -> {:ok, map}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_journal_json(list, depth) when is_list(list) and is_integer(depth) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize_journal_json(item, depth + 1) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_journal_json(value, _depth)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: {:ok, value}

  defp normalize_journal_json(_value, _depth), do: {:error, :journal_invalid_json}

  # --- Effect interpretation --------------------------------------------------

  # Single reservation transaction shared by reserve/3 (:token) and
  # reserve_record/3 (:record). Token + timestamp are generated once; core
  # reserve and durable publish run once; only the success reply shape differs.
  defp perform_reserve(state, journal, binding, unit_name, execution_id, reply_mode)
       when is_map(state) and is_map(journal) and is_map(binding) and
              reply_mode in [:token, :record] do
    token = generate_token()
    reserved_at_ms = System.system_time(:millisecond)

    attrs = %{
      unit_name: unit_name,
      execution_id: execution_id,
      token: token,
      reserved_at_ms: reserved_at_ms
    }

    case Core.reserve(journal, attrs) do
      {:ok, next_state, effects} ->
        case interpret_and_persist(binding, next_state, effects) do
          {:ok, next_binding} ->
            next_owner = %{state | journal: next_state, binding: next_binding}

            case reserve_success_reply(reply_mode, next_state, token) do
              {:ok, _payload} = reply ->
                {:reply, reply, next_owner}

              {:error, reason} ->
                # Snapshot is already published; retain committed evidence and
                # poison so a missing projection cannot look like success.
                poisoned = poison_state(next_owner, reason)

                {:reply, {:error, {:apple_container_unit_journal_persist_failed, reason}},
                 poisoned}
            end

          {:error, :journal_post_rename_uncertain} ->
            # Rename may have published bytes, but the new target identity could
            # not be established. Never continue with the prior binding/journal.
            reply =
              {:error,
               {:apple_container_unit_journal_persist_failed, :journal_post_rename_uncertain}}

            {:stop,
             {:apple_container_unit_journal_post_rename_uncertain, :identity_unestablished},
             reply, state}

          {:error, reason} ->
            poisoned = poison_state(state, reason)
            {:reply, {:error, {:apple_container_unit_journal_persist_failed, reason}}, poisoned}
        end

      {:error, reason} ->
        # Core rejections leave memory and disk unchanged.
        {:reply, {:error, reason}, state}
    end
  end

  # Project success only from the committed next journal state. Never reread
  # disk or invent fields after publish.
  defp reserve_success_reply(:token, _next_state, token) when is_binary(token) do
    {:ok, token}
  end

  defp reserve_success_reply(:record, next_state, token)
       when is_map(next_state) and is_binary(token) do
    case committed_reserve_record(next_state, token) do
      {:ok, record} ->
        {:ok, record}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reserve_success_reply(_mode, _next_state, _token) do
    {:error, :unsupported_apple_container_unit_journal_reserve_reply_mode}
  end

  defp committed_reserve_record(%{by_name: by_name}, token)
       when is_map(by_name) and is_binary(token) do
    found =
      Enum.find_value(by_name, fn
        {_name, %{token: found_token} = record}
        when found_token == token and is_map(record) ->
          record

        _other ->
          nil
      end)

    case found do
      %{
        unit_name: unit_name,
        execution_id: execution_id,
        token: found_token,
        reserved_at_ms: reserved_at_ms
      }
      when found_token == token and is_binary(unit_name) and is_binary(execution_id) and
             is_integer(reserved_at_ms) and reserved_at_ms >= 0 ->
        # Exact normalized Core.record shape from committed state only.
        {:ok,
         %{
           unit_name: unit_name,
           execution_id: execution_id,
           token: found_token,
           reserved_at_ms: reserved_at_ms
         }}

      _other ->
        {:error, :journal_reserve_record_missing}
    end
  end

  defp committed_reserve_record(_next_state, _token),
    do: {:error, :journal_reserve_record_missing}

  defp interpret_and_persist(binding, next_state, effects) when is_map(binding) do
    with :ok <- require_exact_persist_effect(effects),
         {:ok, snapshot} <- shown_snapshot(next_state),
         :ok <- verify_effect_snapshot(effects, snapshot),
         {:ok, payload} <- encode_snapshot(snapshot),
         {:ok, next_binding} <- persist_snapshot_atomic(binding, payload) do
      {:ok, next_binding}
    end
  end

  defp shown_snapshot(next_state) do
    case Core.show(next_state) do
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_journal_state}
    end
  end

  defp require_exact_persist_effect([{:persist_snapshot, snapshot}]) when is_map(snapshot) do
    :ok
  end

  defp require_exact_persist_effect(effects) do
    {:error, {:unexpected_journal_effect, bound_effect_shape(effects)}}
  end

  defp verify_effect_snapshot([{:persist_snapshot, snapshot}], expected) do
    if snapshot == expected do
      :ok
    else
      {:error, :journal_effect_snapshot_mismatch}
    end
  end

  defp encode_snapshot(snapshot) when is_map(snapshot) do
    case Jason.encode(snapshot) do
      {:ok, json} ->
        payload = json <> "\n"

        if byte_size(payload) > @max_snapshot_bytes do
          {:error, :journal_snapshot_too_large}
        else
          {:ok, payload}
        end

      {:error, reason} ->
        {:error, {:journal_encode_failed, reason}}
    end
  end

  # Process/BEAM crash-consistent atomic publication:
  # 1. Revalidate bound parent + existing target identity/digest (descriptor-bound)
  # 2. Exclusive temp in the bound parent; mode 0600 before any content write
  # 3. Write + fsync + descriptor-read proof of exact payload/digest
  # 4. Final parent/target/temp revalidation, then rename with no other ops
  # 5. Post-rename prove published path is the temp inode + exact payload
  # Pre-rename cleanup deletes only the exact owned temp inode; post-rename
  # uncertainty fails as :journal_post_rename_uncertain (owner stops).
  # No directory fsync — power-loss durability is not claimed.
  defp persist_snapshot_atomic(binding, payload)
       when is_map(binding) and is_binary(payload) do
    with :ok <- revalidate_bound_parent(binding),
         :ok <- revalidate_bound_target(binding),
         {:ok, io, pre_write} <- open_exclusive_temp(binding) do
      case prepare_temp_publication(io, pre_write, binding, payload) do
        {:ok, temp} ->
          publish_prepared_temp(binding, temp, payload)

        {:error, reason} ->
          _ = close_io_silent(io)
          _ = cleanup_owned_temp(pre_write)
          {:error, reason}
      end
    end
  end

  defp prepare_temp_publication(io, pre_write, binding, payload)
       when is_map(pre_write) and is_map(binding) and is_binary(payload) do
    try do
      with :ok <- write_temp_payload(io, payload),
           :ok <- :file.sync(io),
           {:ok, temp} <- prove_temp_payload(io, pre_write, binding, payload),
           :ok <- close_io(io) do
        {:ok, temp}
      else
        {:error, reason} ->
          _ = close_io_silent(io)
          {:error, reason}
      end
    rescue
      e ->
        _ = close_io_silent(io)
        {:error, {:journal_persist_failed, Exception.message(e)}}
    catch
      kind, reason ->
        _ = close_io_silent(io)
        {:error, {:journal_persist_failed, {kind, reason}}}
    end
  end

  defp publish_prepared_temp(binding, temp, payload)
       when is_map(binding) and is_map(temp) and is_binary(payload) do
    # Final validation immediately before rename. The only allowed subsequent
    # filesystem mutation is the rename itself.
    case final_pre_rename_validate(binding, temp, payload) do
      :ok ->
        case File.rename(temp.path, binding.path) do
          :ok ->
            case prove_published_target(binding, temp, payload) do
              {:ok, target} ->
                {:ok, %{binding | target: target}}

              {:error, _reason} ->
                # Rename may have published; never continue with a stale binding.
                {:error, :journal_post_rename_uncertain}
            end

          {:error, reason} ->
            _ = cleanup_owned_temp(temp)
            {:error, {:journal_persist_failed, reason}}
        end

      {:error, reason} ->
        _ = cleanup_owned_temp(temp)
        {:error, reason}
    end
  end

  defp final_pre_rename_validate(binding, temp, payload) do
    with :ok <- revalidate_bound_parent(binding),
         :ok <- revalidate_bound_target(binding),
         :ok <- revalidate_temp_publication(binding, temp, payload) do
      :ok
    end
  end

  defp prove_published_target(binding, temp, payload)
       when is_map(binding) and is_map(temp) and is_binary(payload) do
    with :ok <- revalidate_bound_parent(binding),
         {:ok, stat} <- lstat_journal_target(binding.path),
         {:ok, file_id} <- admit_existing_target(stat, binding.parent),
         :ok <- require_same_inode(file_id, temp.identity),
         :ok <- require_file_identity_match(file_id, temp.identity),
         {:ok, bytes} <- read_snapshot_descriptor_bound(binding.path, file_id),
         :ok <- require_exact_payload(bytes, payload),
         :ok <- require_digest(bytes, temp.digest) do
      {:ok, bind_target_with_digest(file_id, bytes)}
    else
      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :journal_post_rename_uncertain}
    end
  end

  defp require_same_inode(%{major_device: d, inode: i}, %{major_device: d, inode: i}), do: :ok
  defp require_same_inode(_left, _right), do: {:error, :journal_post_rename_inode_mismatch}

  defp require_file_identity_match(left, right)
       when is_map(left) and is_map(right) do
    if file_identity_only(left) == file_identity_only(right) do
      :ok
    else
      {:error, :journal_post_rename_identity_mismatch}
    end
  end

  # Exclusive cryptorandom temp in the already-bound parent.
  # Name form: .arbor-unit-journal-tmp-<32 lowercase hex>.json
  #
  # Order is load-bearing:
  # 1. exclusive open
  # 2. bind open FD identity to the pathname (fstat + lstat) before any path
  #    mutation or deletion
  # 3. path-based chmod 0600 only while the pathname still names that exact
  #    inode (verify before and after)
  # 4. re-admit private/single-link/UID shape on the post-chmod identity
  #
  # If identity cannot be established after open, close the FD and leave the
  # pathname untouched — never delete by path/name/mode alone.
  defp open_exclusive_temp(binding) when is_map(binding) do
    open_exclusive_temp_attempt(binding, @temp_name_retries)
  end

  defp open_exclusive_temp_attempt(_binding, 0), do: {:error, :journal_temp_create_failed}

  defp open_exclusive_temp_attempt(binding, remaining) when remaining > 0 do
    parent = binding.parent_path
    expected_uid = binding.parent.uid

    name =
      @temp_prefix <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower) <> ".json"

    unless exact_reserved_temp_name?(name) do
      {:error, :journal_temp_name_invalid}
    else
      tmp = Path.join(parent, name)

      # RDWR so the same descriptor can write, fsync, then prove the payload.
      case :file.open(String.to_charlist(tmp), [:read, :write, :raw, :binary, :exclusive]) do
        {:ok, io} ->
          case bind_open_temp_identity(io, tmp, binding, expected_uid) do
            {:ok, pre_write} ->
              case chmod_bound_temp_path(tmp, pre_write.identity) do
                {:ok, private_identity} ->
                  {:ok, io, %{pre_write | identity: private_identity}}

                {:error, reason} ->
                  # Identity was established: cleanup may unlink only that inode.
                  _ = close_io_silent(io)
                  _ = cleanup_owned_temp(pre_write)
                  {:error, reason}
              end

            {:error, reason} ->
              # No proven pathname↔inode ownership: close FD, leave path alone.
              _ = close_io_silent(io)
              {:error, reason}
          end

        {:error, :eexist} ->
          open_exclusive_temp_attempt(binding, remaining - 1)

        {:error, reason} ->
          {:error, {:journal_temp_open_failed, reason}}
      end
    end
  end

  # Bind the exclusive-open FD to the pathname before chmod or cleanup.
  # Does not require private mode yet (umask may leave group bits until chmod).
  defp bind_open_temp_identity(io, tmp, binding, expected_uid)
       when is_binary(tmp) and is_map(binding) and is_integer(expected_uid) do
    with :ok <- revalidate_bound_parent(binding),
         :ok <- require_temp_in_parent(tmp, binding.parent_path),
         {:ok, opened} <- fstat_journal_io(io),
         {:ok, path_stat} <- lstat_journal_target(tmp),
         :ok <- match_temp_fd_and_path(opened, path_stat),
         {:ok, identity} <- admit_temp_stat_pre_chmod(path_stat, expected_uid) do
      {:ok, %{path: tmp, identity: identity, digest: nil, payload_size: 0}}
    end
  end

  # Path-based chmod is only safe while the pathname still names the bound
  # inode. Verify exact identity immediately before and the same inode (mode
  # may change) immediately after; then re-admit private shape.
  defp chmod_bound_temp_path(path, expected_identity)
       when is_binary(path) and is_map(expected_identity) do
    with {:ok, pre} <- lstat_journal_target(path),
         :ok <- require_exact_temp_file_identity(expected_identity, pre),
         :ok <- path_chmod_temp_private(path),
         {:ok, post} <- lstat_journal_target(path),
         :ok <- require_same_temp_inode_after_chmod(expected_identity, post),
         {:ok, private_identity} <- admit_temp_stat(post, expected_identity.uid) do
      {:ok, private_identity}
    end
  end

  defp path_chmod_temp_private(path) when is_binary(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> {:error, {:journal_temp_chmod_failed, reason}}
    end
  end

  defp require_exact_temp_file_identity(expected, %File.Stat{type: :regular} = stat)
       when is_map(expected) do
    if target_file_identity(stat) == file_identity_only(expected) do
      :ok
    else
      {:error, :journal_temp_replaced}
    end
  end

  defp require_exact_temp_file_identity(_expected, %File.Stat{}),
    do: {:error, :journal_temp_replaced}

  # After path chmod, device/inode/type/uid/gid/links/size must still match the
  # bound open inode; mode is allowed to change to the private value.
  defp require_same_temp_inode_after_chmod(expected, %File.Stat{type: :regular} = stat)
       when is_map(expected) do
    cond do
      stat.major_device != expected.major_device ->
        {:error, :journal_temp_replaced}

      stat.inode != expected.inode ->
        {:error, :journal_temp_replaced}

      stat.uid != expected.uid ->
        {:error, :journal_temp_replaced}

      stat.gid != expected.gid ->
        {:error, :journal_temp_replaced}

      stat.links != expected.links ->
        {:error, :journal_temp_replaced}

      stat.links != 1 ->
        {:error, :journal_temp_hardlink_rejected}

      stat.size != expected.size ->
        {:error, :journal_temp_replaced}

      true ->
        :ok
    end
  end

  defp require_same_temp_inode_after_chmod(_expected, %File.Stat{type: :symlink}),
    do: {:error, :journal_temp_symlink_rejected}

  defp require_same_temp_inode_after_chmod(_expected, %File.Stat{}),
    do: {:error, :journal_temp_not_regular}

  defp require_temp_in_parent(tmp, parent) do
    if Path.dirname(tmp) == parent and String.starts_with?(Path.basename(tmp), @temp_prefix) do
      :ok
    else
      {:error, :journal_temp_outside_parent}
    end
  end

  defp match_temp_fd_and_path(%File.Stat{} = opened, %File.Stat{} = path_stat) do
    if target_file_identity(opened) == target_file_identity(path_stat) do
      :ok
    else
      {:error, :journal_temp_identity_mismatch}
    end
  end

  # Pre-chmod admission: regular, single link, same UID as parent. Mode may
  # still carry umask bits; private mode is enforced only after bound chmod.
  defp admit_temp_stat_pre_chmod(%File.Stat{type: :symlink}, _uid),
    do: {:error, :journal_temp_symlink_rejected}

  defp admit_temp_stat_pre_chmod(%File.Stat{type: type}, _uid) when type != :regular,
    do: {:error, :journal_temp_not_regular}

  defp admit_temp_stat_pre_chmod(%File.Stat{type: :regular} = stat, expected_uid)
       when is_integer(expected_uid) do
    with :ok <- assert_target_single_link(stat),
         :ok <- assert_temp_uid(stat, expected_uid) do
      {:ok, target_file_identity(stat)}
    else
      {:error, :journal_hardlink_rejected} ->
        {:error, :journal_temp_hardlink_rejected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp admit_temp_stat(%File.Stat{type: :symlink}, _uid),
    do: {:error, :journal_temp_symlink_rejected}

  defp admit_temp_stat(%File.Stat{type: type}, _uid) when type != :regular,
    do: {:error, :journal_temp_not_regular}

  defp admit_temp_stat(%File.Stat{type: :regular} = stat, expected_uid)
       when is_integer(expected_uid) do
    with :ok <- assert_target_single_link(stat),
         :ok <- assert_temp_uid(stat, expected_uid),
         :ok <- assert_private_regular_file(stat) do
      {:ok, target_file_identity(stat)}
    else
      {:error, :journal_hardlink_rejected} ->
        {:error, :journal_temp_hardlink_rejected}

      {:error, :journal_file_not_private} ->
        {:error, :journal_temp_not_private}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assert_temp_uid(%File.Stat{uid: uid}, expected_uid)
       when is_integer(uid) and is_integer(expected_uid) do
    if uid == expected_uid do
      :ok
    else
      {:error, :journal_temp_uid_mismatch}
    end
  end

  defp assert_temp_uid(_stat, _expected_uid), do: {:error, :journal_temp_uid_mismatch}

  defp write_temp_payload(io, payload) when is_binary(payload) do
    case :file.write(io, payload) do
      :ok -> :ok
      {:error, reason} -> {:error, {:journal_temp_write_failed, reason}}
    end
  end

  # Prove the open descriptor holds the exact payload: byte count, EOF, SHA-256.
  # Then require stable lstat/fstat identity at the post-write size.
  defp prove_temp_payload(io, pre_write, binding, payload)
       when is_map(pre_write) and is_map(binding) and is_binary(payload) do
    size = byte_size(payload)
    expected_digest = sha256_hex(payload)

    with :ok <- position_temp_bof(io),
         {:ok, bytes} <- read_exact_snapshot_bytes(io, size),
         :ok <- require_journal_eof(io),
         :ok <- require_exact_payload(bytes, payload),
         :ok <- require_digest(bytes, expected_digest),
         {:ok, opened} <- fstat_journal_io(io),
         {:ok, path_stat} <- lstat_journal_target(pre_write.path),
         :ok <- match_temp_fd_and_path(opened, path_stat),
         {:ok, identity} <- admit_temp_stat(path_stat, binding.parent.uid),
         :ok <- require_temp_inode_stable(pre_write.identity, identity),
         :ok <- require_temp_size(identity, size) do
      {:ok,
       %{
         path: pre_write.path,
         identity: identity,
         digest: expected_digest,
         payload_size: size
       }}
    end
  end

  defp position_temp_bof(io) do
    case :file.position(io, :bof) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:journal_temp_seek_failed, reason}}
    end
  end

  defp require_temp_inode_stable(pre, post)
       when is_map(pre) and is_map(post) do
    if pre.major_device == post.major_device and pre.inode == post.inode and
         pre.uid == post.uid and pre.mode == post.mode and pre.links == post.links and
         pre.type == post.type do
      :ok
    else
      {:error, :journal_temp_replaced}
    end
  end

  defp require_temp_size(%{size: size}, expected)
       when is_integer(size) and is_integer(expected) do
    if size == expected do
      :ok
    else
      {:error, :journal_temp_size_mismatch}
    end
  end

  defp revalidate_temp_publication(binding, temp, payload)
       when is_map(binding) and is_map(temp) and is_binary(payload) do
    with :ok <- require_temp_in_parent(temp.path, binding.parent_path),
         {:ok, path_stat} <- lstat_journal_target(temp.path),
         {:ok, identity} <- admit_temp_stat(path_stat, binding.parent.uid),
         :ok <- require_file_identity_match(identity, temp.identity),
         {:ok, io} <- open_journal_read(temp.path) do
      try do
        with {:ok, opened} <- fstat_journal_io(io),
             :ok <- match_bound_target(temp.identity, opened),
             {:ok, bytes} <- read_exact_snapshot_bytes(io, temp.payload_size),
             :ok <- require_journal_eof(io),
             {:ok, after_fd} <- fstat_journal_io(io),
             :ok <- match_bound_target(temp.identity, after_fd),
             {:ok, post} <- lstat_journal_target(temp.path),
             :ok <- match_bound_target(temp.identity, post),
             :ok <- require_exact_payload(bytes, payload),
             :ok <- require_digest(bytes, temp.digest) do
          :ok
        end
      after
        _ = close_io_silent(io)
      end
    end
  end

  defp close_io(io) do
    case :file.close(io) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp close_io_silent(io) do
    _ = :file.close(io)
    :ok
  end

  # Pre-rename cleanup may remove only the exact temp inode this process created
  # and bound after exclusive open. Match by stable inode identity
  # (device/inode/type/uid/links), not size or mode: size changes after a
  # successful write and mode changes after chmod even when the inode is still
  # ours. If the path was replaced, leave the replacement untouched.
  # There is no path/name/mode-only cleanup fallback.
  defp cleanup_owned_temp(%{path: path, identity: identity} = temp)
       when is_binary(path) and is_map(identity) do
    _ = maybe_test_only_replace_temp_at_cleanup(temp)

    case safe_unlink_owned_temp(path, identity) do
      :ok -> :ok
      {:error, :journal_temp_replaced} -> :ok
      {:error, :journal_target_missing} -> :ok
      {:error, _} -> :ok
    end
  end

  defp cleanup_owned_temp(_), do: :ok

  # Test-only sealed seam at the cleanup boundary. Production never installs
  # this key; it is readable only when Mix.env is :test. The callback may
  # replace the active temp pathname with an unrelated private file so tests
  # prove identity-bound cleanup never claims or deletes the replacement.
  @test_only_temp_cleanup_replace_key :__test_only_apple_container_unit_journal_temp_cleanup_replace

  defp maybe_test_only_replace_temp_at_cleanup(%{path: path, identity: identity} = temp)
       when is_binary(path) and is_map(identity) do
    if test_only_env?() do
      case Application.get_env(:arbor_shell, @test_only_temp_cleanup_replace_key) do
        fun when is_function(fun, 1) ->
          Application.delete_env(:arbor_shell, @test_only_temp_cleanup_replace_key)

          try do
            _ = fun.(temp)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end

          :ok

        _other ->
          :ok
      end
    else
      :ok
    end
  end

  defp test_only_env? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp safe_unlink_owned_temp(path, expected_identity)
       when is_binary(path) and is_map(expected_identity) do
    with {:ok, pre} <- lstat_journal_target(path),
         :ok <- match_owned_temp_inode(expected_identity, pre),
         {:ok, io} <- open_journal_read(path) do
      try do
        with {:ok, opened} <- fstat_journal_io(io),
             :ok <- match_owned_temp_inode(expected_identity, opened),
             :ok <- close_io(io),
             {:ok, post} <- lstat_journal_target(path),
             :ok <- match_owned_temp_inode(expected_identity, post) do
          unlink_if_still_owned(path, expected_identity)
        else
          {:error, reason} ->
            {:error, reason}
        end
      after
        _ = close_io_silent(io)
      end
    end
  end

  # Inode ownership only — deliberately ignores size/mode bit churn after write
  # and chmod. A replacement at the same path has a different inode.
  defp match_owned_temp_inode(expected, %File.Stat{} = stat) when is_map(expected) do
    cond do
      stat.type != :regular ->
        {:error, :journal_temp_replaced}

      stat.links != 1 ->
        {:error, :journal_temp_replaced}

      stat.major_device != expected.major_device ->
        {:error, :journal_temp_replaced}

      stat.inode != expected.inode ->
        {:error, :journal_temp_replaced}

      stat.uid != expected.uid ->
        {:error, :journal_temp_replaced}

      true ->
        :ok
    end
  end

  defp match_owned_temp_inode(_expected, _stat), do: {:error, :journal_temp_replaced}

  defp unlink_if_still_owned(path, expected_identity) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{} = stat} ->
        case match_owned_temp_inode(expected_identity, stat) do
          :ok ->
            case :file.delete(String.to_charlist(path)) do
              :ok ->
                :ok

              {:error, :enoent} ->
                :ok

              {:error, reason} ->
                {:error, {:journal_temp_cleanup_failed, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:journal_temp_cleanup_failed, reason}}
    end
  end

  defp generate_token do
    Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
  end

  defp poison_state(state, reason) do
    %{
      state
      | status: :poisoned,
        reason: bound_reason(reason)
        # journal and binding retained as evidence; never deleted/replaced
    }
  end

  # --- Public status / redaction ---------------------------------------------

  defp render_public_status(%{status: :disabled} = state) do
    %{
      "status" => "disabled",
      "reason" => reason_string(state.reason),
      "active_count" => nil,
      "generation" => nil
    }
  end

  defp render_public_status(%{status: :poisoned} = state) do
    {active_count, generation} = journal_counts(state.journal)

    %{
      "status" => "poisoned",
      "reason" => reason_string(state.reason),
      "active_count" => active_count,
      "generation" => generation
    }
  end

  defp render_public_status(%{status: :ready} = state) do
    {active_count, generation} = journal_counts(state.journal)

    %{
      "status" => "ready",
      "reason" => nil,
      "active_count" => active_count,
      "generation" => generation
    }
  end

  defp journal_counts(%{generation: generation, by_name: by_name})
       when is_integer(generation) and is_map(by_name) do
    {map_size(by_name), generation}
  end

  defp journal_counts(_), do: {nil, nil}

  defp unavailable_public_status(reason) do
    %{
      "status" => "unavailable",
      "reason" => reason_string(reason),
      "active_count" => nil,
      "generation" => nil
    }
  end

  defp redact_state(state) when is_map(state) do
    %{
      status: Map.get(state, :status),
      reason: bound_reason(Map.get(state, :reason)),
      binding: :redacted,
      path: :redacted,
      lock_path: :redacted,
      os_pid: :redacted,
      journal: :redacted,
      active_count: elem(journal_counts(Map.get(state, :journal)), 0),
      generation: elem(journal_counts(Map.get(state, :journal)), 1)
    }
  end

  defp redact_state(_), do: :redacted

  defp redact_status_field(status, field) when is_map(status) do
    if Map.has_key?(status, field) do
      Map.put(status, field, :redacted)
    else
      status
    end
  end

  defp reason_string(nil), do: nil
  defp reason_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_string(reason) when is_binary(reason), do: truncate_binary(reason, 128)

  defp reason_string(reason) do
    reason
    |> bound_reason()
    |> inspect()
    |> truncate_binary(128)
  end

  defp bound_reason(reason) when is_atom(reason), do: reason
  defp bound_reason(reason) when is_binary(reason), do: truncate_binary(reason, 128)

  defp bound_reason({tag, detail}) when is_atom(tag) do
    {tag, bound_reason(detail)}
  end

  defp bound_reason(reason) when is_tuple(reason) do
    reason
    |> Tuple.to_list()
    |> Enum.take(4)
    |> Enum.map(&bound_reason/1)
    |> List.to_tuple()
  end

  defp bound_reason(_), do: :redacted

  defp bound_effect_shape(effects) when is_list(effects) do
    Enum.map(effects, fn
      {:persist_snapshot, snapshot} when is_map(snapshot) ->
        {:persist_snapshot, :map}

      other ->
        bound_reason(other)
    end)
  end

  defp bound_effect_shape(other), do: bound_reason(other)

  defp truncate_binary(value, max) when is_binary(value) and is_integer(max) and max > 0 do
    if byte_size(value) <= max do
      value
    else
      binary_part(value, 0, max)
    end
  end

  defp call(server, request) do
    GenServer.call(server, request)
  catch
    :exit, {:noproc, _} ->
      {:error, :apple_container_unit_journal_unavailable}

    :exit, {:normal, _} ->
      {:error, :apple_container_unit_journal_unavailable}

    :exit, {:shutdown, _} ->
      {:error, :apple_container_unit_journal_unavailable}

    :exit, {{:apple_container_unit_journal_start_failed, _}, _} ->
      {:error, :apple_container_unit_journal_unavailable}

    :exit, reason ->
      {:error, {:apple_container_unit_journal_call_failed, bound_reason(reason)}}
  end
end
