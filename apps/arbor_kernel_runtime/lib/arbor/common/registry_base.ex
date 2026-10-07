defmodule Arbor.Common.RegistryBase do
  @allow_test_mutations Application.compile_env(
                          :arbor_kernel_runtime,
                          :expose_test_fixtures,
                          false
                        )

  @moduledoc """
  Standard registry foundation for Arbor.

  Provides a `use`-able module that generates a complete registry with:
  - ETS-backed storage with heir protection (survives registry crash)
  - Two-tier namespace sovereignty (core entries locked after boot)
  - Circuit breaker per entry (failure tracking + unstable flag)
  - Module availability checks via `Code.ensure_loaded?`
  - Snapshot/restore for test isolation
  - Serializable entries for future multi-node sync

  ## Usage

      defmodule MyRegistry do
        use Arbor.Common.RegistryBase,
          table_name: :my_registry,
          require_behaviour: MyBehaviour  # optional

        # Optional: override to customize entry validation
        def validate_entry(name, module, metadata) do
          # custom validation
          :ok
        end
      end

  ## Entry Format

  Each entry is stored as `{name, module, metadata}` where:
  - `name` is a string (the lookup key)
  - `module` is an atom (the implementing module)
  - `metadata` is a plain map (capabilities, cost, etc.)

  All three are JSON-serializable, enabling future multi-node gossip sync.

  ## Namespace Sovereignty

  Core entries are registered during application boot, then `lock_core/0`
  is called. After locking:
  - Core names cannot be overwritten or deregistered
  - Plugin entries must be prefixed (e.g., `"my_plugin.source"`)
  - The `allow_overwrite: true` option is ignored for core entries

  ## Circuit Breaker

  Each entry tracks failure count. After `max_failures` (default 5),
  the entry is marked unstable. Unstable entries are excluded from
  `list_available/0` but still resolvable via `resolve/1` (the caller
  decides whether to use unstable entries).

  Reset failures with `reset_failures/1` or automatic decay (TODO Phase 3).
  """

  @doc """
  Options for `use Arbor.Common.RegistryBase`:

  - `:table_name` — ETS table name (required)
  - `:require_behaviour` — module that registered modules must implement (optional)
  - `:allow_overwrite` — whether re-registration overwrites (default `false`)
  - `:max_failures` — circuit breaker threshold (default `5`)

  A registry started with `:core_registration_authority` also exposes the
  custody-bearing `register_core/4` and `lock_core/2` boot APIs. While such a
  registry is unlocked, ordinary registration and locking fail closed. The
  authority is described by an application supervision path, a registered
  process name, and a protected ETS directory containing only the digest of
  its owner-private custody value.
  """
  defmacro __using__(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    require_behaviour = Keyword.get(opts, :require_behaviour)
    allow_overwrite = Keyword.get(opts, :allow_overwrite, false)
    max_failures = Keyword.get(opts, :max_failures, 5)

    allow_test_mutations =
      Keyword.get(
        opts,
        :allow_test_mutations,
        @allow_test_mutations
      )

    quote location: :keep do
      use GenServer
      require Logger

      @behaviour Arbor.Contracts.Handler.Registry

      @table_name unquote(table_name)
      @require_behaviour unquote(require_behaviour)
      @allow_overwrite unquote(allow_overwrite)
      @max_failures unquote(max_failures)
      @allow_test_mutations unquote(allow_test_mutations)
      @heir_name Module.concat(__MODULE__, Heir)
      @pg_scope :arbor_registry
      @pg_group {:registry, unquote(table_name)}
      @remote_cache_ttl_ms 30_000
      # Fixed, absolute duration the old heir stays in owner state waiting
      # for a claim once it becomes the orphaned table's owner. This is a
      # single deadline computed once at the standby->owner transition —
      # invalid or rejected claims must NOT extend it, and an unclaimed
      # orphan must not be retained past it (see heir_owner/1).
      @heir_claim_window_ms 60_000
      # Total time budget (including retries across an owner-DOWN race) a
      # replacement registry spends trying to claim an orphaned table before
      # giving up and failing closed.
      @claim_retry_deadline_ms 5_000

      # --- Client API ---

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent
        }
      end

      @impl Arbor.Contracts.Handler.Registry
      def register(name, module, metadata \\ %{})

      def register(name, module, metadata) when is_binary(name) and is_atom(module) do
        GenServer.call(__MODULE__, {:register, name, module, metadata})
      end

      @doc false
      def register_core(name, module, metadata, custody)
          when is_binary(name) and is_atom(module) and is_map(metadata) and
                 is_binary(custody) do
        GenServer.call(__MODULE__, {:register_core, name, module, metadata, custody})
      end

      @impl Arbor.Contracts.Handler.Registry
      def deregister(name) when is_binary(name) do
        GenServer.call(__MODULE__, {:deregister, name})
      end

      @impl Arbor.Contracts.Handler.Registry
      def resolve(name) when is_binary(name) do
        ets_resolve(name)
      end

      @doc """
      Resolve an entry with node awareness.

      Options:
      - `node: :local` — local-only lookup (default, same as `resolve/1`)
      - `node: :any` — local first; remote fallback is denied until an
        authenticated registry transport exists
      - `node: node_name` — local lookup for the current node; remote nodes are
        denied until an authenticated registry transport exists

      Trust-zone policy alone does not authenticate the remote registry or its
      module assertion, so remote resolution fails closed at this boundary.
      """
      def resolve(name, opts) when is_binary(name) and is_list(opts) do
        case Keyword.get(opts, :node, :local) do
          :local ->
            resolve(name)

          :any ->
            case resolve(name) do
              {:ok, _module} = ok ->
                ok

              {:error, :not_found} ->
                with :ok <- authorize_remote_resolution(:any) do
                  resolve_remote_any(name)
                end

              other ->
                other
            end

          node_name when is_atom(node_name) ->
            if node_name == node() do
              resolve(name)
            else
              with :ok <- authorize_remote_resolution(node_name) do
                resolve_on_node(name, node_name)
              end
            end
        end
      end

      @doc """
      Resolve and invoke a handler on a remote node.

      Resolves `name` on `target_node`, then calls `function` with `args`
      on the resolved module via `:erpc`. Arguments must be serializable
      (no function refs or pids).

      Returns `{:ok, result}` or `{:error, reason}`.
      """
      def call_remote(name, target_node, {function, args})
          when is_binary(name) and is_atom(target_node) and is_atom(function) and is_list(args) do
        with {:ok, module} <- resolve(name, node: target_node) do
          try do
            result = :erpc.call(target_node, module, function, args, 10_000)
            {:ok, result}
          rescue
            e -> {:error, {:remote_call_failed, Exception.message(e)}}
          catch
            :exit, reason -> {:error, {:remote_call_failed, reason}}
          end
        end
      end

      defp ets_resolve(name) do
        case :ets.lookup(@table_name, name) do
          [{^name, module, _metadata, _failures, _core?}] ->
            if Code.ensure_loaded?(module) do
              {:ok, module}
            else
              {:error, :module_not_loaded}
            end

          [] ->
            {:error, :not_found}
        end
      end

      # A trust-zone comparison says whether one node would be allowed to
      # resolve another; it does not authenticate the peer, registry response,
      # or asserted module. Keep every remote dispatch path closed until a
      # transport supplies cryptographic peer and response authentication.
      defp authorize_remote_resolution(_target_node),
        do: {:error, :unauthenticated_remote_resolution}

      @doc """
      Resolve an entry, but skip unstable entries (failure count >= max_failures).
      Returns `{:error, :unstable}` if the entry exists but is over the failure threshold.
      """
      def resolve_stable(name) when is_binary(name) do
        ets_resolve_stable(name)
      end

      defp ets_resolve_stable(name) do
        case :ets.lookup(@table_name, name) do
          [{^name, module, _metadata, failures, _core?}] ->
            cond do
              failures >= @max_failures -> {:error, :unstable}
              not Code.ensure_loaded?(module) -> {:error, :module_not_loaded}
              true -> {:ok, module}
            end

          [] ->
            {:error, :not_found}
        end
      end

      @impl Arbor.Contracts.Handler.Registry
      def resolve_entry(name) when is_binary(name) do
        case :ets.lookup(@table_name, name) do
          [{^name, module, metadata, _failures, _core?}] ->
            {:ok, {name, module, metadata}}

          [] ->
            {:error, :not_found}
        end
      end

      @impl Arbor.Contracts.Handler.Registry
      def list_all do
        :ets.tab2list(@table_name)
        |> Enum.map(fn {name, module, metadata, _failures, _core?} ->
          {name, module, metadata}
        end)
      end

      @impl Arbor.Contracts.Handler.Registry
      def list_available do
        :ets.tab2list(@table_name)
        |> Enum.filter(fn {_name, module, _metadata, failures, _core?} ->
          failures < @max_failures and Code.ensure_loaded?(module) and
            check_available(module)
        end)
        |> Enum.map(fn {name, module, metadata, _failures, _core?} ->
          {name, module, metadata}
        end)
      end

      @impl Arbor.Contracts.Handler.Registry
      def lock_core do
        lock_core(lock_core_timeout())
      end

      @doc """
      Lock the core registry, allowing an explicit timeout.

      Marking a large registry can legitimately exceed `GenServer.call/2`'s 5s
      default on slower hardware, so this operation has its own timeout.

      Configure with `config :arbor_kernel_runtime, registry_lock_core_timeout: ms`.
      """
      @spec lock_core(timeout()) :: :ok | {:error, term()}
      def lock_core(timeout) do
        GenServer.call(__MODULE__, :lock_core, timeout)
      catch
        :exit, {:timeout, _} = reason ->
          {:error, {:lock_core_timeout, reason}}
      end

      @doc false
      @spec lock_core(binary(), timeout()) :: :ok | {:error, term()}
      def lock_core(custody, timeout) when is_binary(custody) do
        GenServer.call(__MODULE__, {:lock_core, custody}, timeout)
      catch
        :exit, {:timeout, _} = reason ->
          {:error, {:lock_core_timeout, reason}}
      end

      defp lock_core_timeout do
        Application.get_env(:arbor_kernel_runtime, :registry_lock_core_timeout, 60_000)
      end

      @impl Arbor.Contracts.Handler.Registry
      def core_locked? do
        GenServer.call(__MODULE__, :core_locked?)
      end

      @doc """
      Clear all entries and reset core lock. Available only to registries
      compiled with `allow_test_mutations: true` (the default in test builds).
      """
      def reset do
        GenServer.call(__MODULE__, :reset)
      end

      @doc """
      Record a failure for the named entry. Increments the failure counter.
      When failures reach `max_failures`, the entry is marked unstable.
      """
      def record_failure(name) when is_binary(name) do
        GenServer.call(__MODULE__, {:record_failure, name})
      end

      @doc """
      Reset failure count for the named entry.
      """
      def reset_failures(name) when is_binary(name) do
        GenServer.call(__MODULE__, {:reset_failures, name})
      end

      @impl Arbor.Contracts.Handler.Registry
      def snapshot do
        entries = :ets.tab2list(@table_name)
        core_locked = GenServer.call(__MODULE__, :core_locked?)
        {entries, core_locked}
      end

      @impl Arbor.Contracts.Handler.Registry
      def restore({entries, core_locked}) do
        GenServer.call(__MODULE__, {:restore, entries, core_locked})
      end

      # --- Server Callbacks ---

      @impl GenServer
      def init(opts) do
        with {:ok, authority_table} <- init_core_registration_authority(opts) do
          if authority_table != nil, do: Process.flag(:sensitive, true)

          result =
            case :ets.whereis(@table_name) do
              :undefined -> init_fresh_table()
              table_ref -> init_reclaimed_table(table_ref)
            end

          case result do
            {:ok, state} -> {:ok, Map.put(state, :core_registration_authority, authority_table)}
            other -> other
          end
        end
      end

      defp init_core_registration_authority(opts) do
        case Keyword.get(opts, :core_registration_authority) do
          nil ->
            {:ok, nil}

          authority when is_list(authority) ->
            name = Keyword.get(authority, :name)
            directory = Keyword.get(authority, :directory)
            application = Keyword.get(authority, :application)
            child_path = Keyword.get(authority, :child_path)

            if is_atom(name) and not is_nil(name) and is_atom(directory) and
                 not is_nil(directory) and is_atom(application) and not is_nil(application) and
                 is_list(child_path) and child_path != [] do
              table = :ets.new(__MODULE__, [:private, :set])

              true =
                :ets.insert(
                  table,
                  {:authority, name, directory, application, child_path}
                )

              {:ok, table}
            else
              {:stop, :invalid_core_registration_authority}
            end

          _other ->
            {:stop, :invalid_core_registration_authority}
        end
      end

      # Fresh boot: no table exists yet. Create it (owned by us, with a
      # standby heir installed at creation) and prove the invariant holds.
      defp init_fresh_table do
        heir_pid = start_heir()

        with {:ok, table_ref} <- create_table(heir_pid),
             :ok <- verify_ownership_and_heir(table_ref, heir_pid) do
          maybe_join_pg()
          maybe_monitor_pg()
          {:ok, %{core_locked: false, heir_pid: heir_pid, remote_cache: %{}}}
        else
          {:error, reason} ->
            stop_heir(heir_pid)
            {:stop, {:ets_table_init_failed, reason}}
        end
      end

      defp create_table(heir_pid) do
        :ets.new(@table_name, [
          :set,
          :named_table,
          :protected,
          {:read_concurrency, true},
          {:heir, heir_pid, @table_name}
        ])

        # :ets.new/2 on a :named_table returns the name atom itself, not a
        # distinguishing reference — re-derive via :ets.whereis/1 so
        # `table_ref` is always the same kind of exact-generation identity
        # used everywhere else (including the reclaim path).
        {:ok, :ets.whereis(@table_name)}
      rescue
        error -> {:error, error}
      end

      # Replacement boot: the table already exists, orphaned by a crashed
      # predecessor and currently owned by its old heir. `table_ref` is the
      # EXACT current generation captured via :ets.whereis/1 — for a
      # :named_table this is a reference distinct from the (reusable) name
      # atom, and it changes if the table is ever deleted and recreated
      # under the same name. We thread this exact reference through the
      # claim request and the transfer's gift data so a stale or
      # regenerated table can never be silently accepted.
      #
      # We never call :ets.setopts/2 until AFTER claim_table/2 has proven
      # (via :ets.info) that we are the real owner — calling setopts on a
      # table we don't own is the original bug: it silently no-ops instead
      # of reclaiming anything.
      defp init_reclaimed_table(table_ref) do
        deadline = System.monotonic_time(:millisecond) + @claim_retry_deadline_ms

        case claim_table(table_ref, deadline) do
          {:ok, ^table_ref} ->
            heir_pid = start_heir()

            with :ok <- install_heir(table_ref, heir_pid),
                 :ok <- verify_ownership_and_heir(table_ref, heir_pid) do
              maybe_join_pg()
              maybe_monitor_pg()

              core_locked =
                :ets.tab2list(@table_name)
                |> Enum.any?(fn
                  {_name, _module, _metadata, _failures, true} -> true
                  _ -> false
                end)

              {:ok, %{core_locked: core_locked, heir_pid: heir_pid, remote_cache: %{}}}
            else
              {:error, reason} ->
                stop_heir(heir_pid)
                {:stop, {:ets_table_reclaim_failed, reason}}
            end

          {:error, reason} ->
            {:stop, {:ets_table_reclaim_failed, reason}}
        end
      end

      defp install_heir(table_ref, heir_pid) do
        :ets.setopts(table_ref, [{:heir, heir_pid, @table_name}])
        :ok
      rescue
        error -> {:error, error}
      end

      # Fail closed unless we can literally prove, via :ets.info, that we
      # are the table's owner and the table's heir is exactly the process we
      # just spawned. Anything else is an unprovable invariant.
      defp verify_ownership_and_heir(table_ref, heir_pid) do
        self_pid = self()

        case {:ets.whereis(@table_name), :ets.info(table_ref, :owner),
              :ets.info(table_ref, :heir)} do
          {^table_ref, ^self_pid, ^heir_pid} -> :ok
          other -> {:error, {:invariant_violation, other}}
        end
      end

      defp stop_heir(heir_pid) do
        if is_pid(heir_pid) and Process.alive?(heir_pid) do
          Process.exit(heir_pid, :kill)
        end

        :ok
      end

      # Bounded claim loop, addressed to the table's CURRENT OWNER (never
      # the :heir field — after the first ETS-TRANSFER the old heir IS the
      # owner and the heir field may be stale or :none). Re-reads the exact
      # table generation and current owner on every attempt, including
      # after an owner-DOWN race, and keeps retrying the newly-observed
      # owner until `deadline`. A generic, unauthenticated receive can never
      # consume the transfer: await_claim/5 matches the exact table name,
      # exact owner pid, and exact {table_ref, claim_ref} gift data.
      defp claim_table(table_ref, deadline) do
        case current_owner(table_ref) do
          {:ok, owner} when owner == self() -> {:ok, table_ref}
          {:ok, owner} -> attempt_claim(table_ref, owner, deadline)
          {:error, reason} -> {:error, reason}
        end
      end

      defp attempt_claim(table_ref, owner, deadline) do
        now = System.monotonic_time(:millisecond)

        if now >= deadline do
          {:error, :claim_deadline_exceeded}
        else
          claim_ref = make_ref()
          monitor_ref = Process.monitor(owner)
          send(owner, {:claim_ets_table, @table_name, table_ref, claim_ref, self()})

          result = await_claim(table_ref, owner, claim_ref, monitor_ref, deadline)
          Process.demonitor(monitor_ref, [:flush])
          result
        end
      end

      defp await_claim(table_ref, owner, claim_ref, monitor_ref, deadline) do
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {:"ETS-TRANSFER", @table_name, ^owner, {^table_ref, ^claim_ref}} ->
            confirm_ownership(table_ref)

          {:DOWN, ^monitor_ref, :process, ^owner, _reason} ->
            # Owner-DOWN vs. transfer ordering race: re-read the exact table
            # generation and current owner rather than assuming failure —
            # this also correctly handles a transfer that already completed
            # (current_owner/1 would then report us as owner).
            claim_table(table_ref, deadline)
        after
          remaining ->
            {:error, :claim_timeout}
        end
      end

      defp current_owner(table_ref) do
        case :ets.whereis(@table_name) do
          :undefined ->
            {:error, :table_gone}

          ^table_ref ->
            case :ets.info(table_ref, :owner) do
              :undefined -> {:error, :table_gone}
              owner when is_pid(owner) -> {:ok, owner}
            end

          _other_ref ->
            {:error, :table_regenerated}
        end
      end

      defp confirm_ownership(table_ref) do
        if :ets.info(table_ref, :owner) == self() do
          {:ok, table_ref}
        else
          {:error, :ownership_not_proven}
        end
      end

      @impl GenServer
      def handle_call({:resolve_remote, _name}, _from, state) do
        {:reply, {:error, :unauthenticated_remote_resolution}, state}
      end

      def handle_call({:register, name, module, metadata}, _from, state) do
        result =
          if core_registration_pending?(state) do
            {:error, :core_registration_authority_required}
          else
            do_register(name, module, metadata, state)
          end

        {:reply, result, state}
      end

      def handle_call({:register_core, name, module, metadata, custody}, from, state) do
        case authorize_core_registration(state, from, custody) do
          {:ok, state} ->
            {:reply, do_register(name, module, metadata, state), state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      end

      def handle_call({:deregister, name}, _from, state) do
        result = do_deregister(name, state)
        {:reply, result, state}
      end

      def handle_call({:remote_cache_lookup, name, target_node}, _from, state) do
        result = remote_cache_lookup_allowed(state, name, target_node)
        {:reply, result, state}
      end

      def handle_call({:cache_remote, _name, _module, _metadata, _remote_node}, _from, state) do
        {:reply, {:error, :unauthenticated_remote_resolution}, state}
      end

      def handle_call(:lock_core, _from, state) do
        if core_registration_authority_configured?(state) do
          {:reply, {:error, :core_registration_authority_required}, state}
        else
          {:reply, :ok, do_lock_core(state)}
        end
      end

      def handle_call({:lock_core, custody}, from, state) do
        case authorize_core_registration(state, from, custody) do
          {:ok, state} -> {:reply, :ok, do_lock_core(state)}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      end

      defp do_lock_core(state) do
        # Mark all current entries as core
        :ets.tab2list(@table_name)
        |> Enum.each(fn {name, module, metadata, failures, _core?} ->
          :ets.insert(@table_name, {name, module, metadata, failures, true})
        end)

        %{state | core_locked: true}
      end

      def handle_call(:core_locked?, _from, state) do
        {:reply, state.core_locked, state}
      end

      def handle_call(:reset, _from, state) do
        if @allow_test_mutations do
          :ets.delete_all_objects(@table_name)
          {:reply, :ok, %{state | core_locked: false, remote_cache: %{}}}
        else
          {:reply, {:error, :test_only}, state}
        end
      end

      def handle_call({:record_failure, name}, _from, state) do
        result =
          case :ets.lookup(@table_name, name) do
            [{^name, module, metadata, failures, core?}] ->
              :ets.insert(@table_name, {name, module, metadata, failures + 1, core?})
              :ok

            [] ->
              {:error, :not_found}
          end

        {:reply, result, state}
      end

      def handle_call({:reset_failures, name}, _from, state) do
        result =
          case :ets.lookup(@table_name, name) do
            [{^name, module, metadata, _failures, core?}] ->
              :ets.insert(@table_name, {name, module, metadata, 0, core?})
              :ok

            [] ->
              {:error, :not_found}
          end

        {:reply, result, state}
      end

      def handle_call({:restore, entries, core_locked}, _from, state) do
        if @allow_test_mutations and valid_snapshot?(entries, core_locked) do
          :ets.delete_all_objects(@table_name)
          Enum.each(entries, &:ets.insert(@table_name, &1))
          {:reply, :ok, %{state | core_locked: core_locked, remote_cache: %{}}}
        else
          {:reply, {:error, :test_only}, state}
        end
      end

      # No handle_info clause for :"ETS-TRANSFER" here by design: the
      # authenticated handoff is performed synchronously inside init/1 (see
      # claim_table/2 and await_claim/5), which is the only place that knows
      # the exact table generation and claim reference needed to accept a
      # transfer safely. A loosely-matched handle_info clause here would be
      # exactly the kind of generic, unauthenticated consumer this module
      # must avoid — any unsolicited transfer message falls through to the
      # catch-all handle_info/2 below.

      @impl GenServer
      def handle_info({:pg_membership, @pg_scope, @pg_group, _joins, leaves}, state)
          when leaves != [] do
        leaving_nodes = Enum.map(leaves, &node/1) |> Enum.uniq()

        remote_cache =
          Map.reject(state.remote_cache, fn {_key, {_module, remote_node, _expiry}} ->
            remote_node in leaving_nodes
          end)

        {:noreply, %{state | remote_cache: remote_cache}}
      end

      def handle_info(_msg, state) do
        {:noreply, state}
      end

      # --- Internal ---

      defp core_registration_pending?(%{core_locked: false} = state),
        do: core_registration_authority_configured?(state)

      defp core_registration_pending?(_state), do: false

      defp core_registration_authority_configured?(state) do
        case Map.get(state, :core_registration_authority) do
          nil -> false
          table -> private_authority_table?(table)
        end
      end

      defp private_authority_table?(table) do
        :ets.info(table, :owner) == self() and :ets.info(table, :protection) == :private
      rescue
        ArgumentError -> false
      end

      defp authorize_core_registration(state, {caller_pid, _tag}, custody)
           when is_pid(caller_pid) and is_binary(custody) do
        table = Map.get(state, :core_registration_authority)

        with true <- private_authority_table?(table),
             [{:authority, expected_name, directory, application, child_path}] <-
               :ets.lookup(table, :authority),
             ^caller_pid <- Process.whereis(expected_name),
             {:ok, ^caller_pid} <-
               Arbor.Common.supervised_registered_child_pid(
                 application,
                 child_path,
                 expected_name,
                 1_000
               ),
             directory_ref when directory_ref != :undefined <- :ets.whereis(directory),
             ^caller_pid <- :ets.info(directory_ref, :owner),
             :protected <- :ets.info(directory_ref, :protection),
             [{:custody_sha256, expected_digest}] when is_binary(expected_digest) <-
               :ets.lookup(directory_ref, :custody_sha256),
             supplied_digest <- :crypto.hash(:sha256, custody),
             true <- secure_digest_equal?(expected_digest, supplied_digest) do
          {:ok, state}
        else
          _other -> {:error, :invalid_core_registration_authority}
        end
      rescue
        _exception -> {:error, :invalid_core_registration_authority}
      catch
        _kind, _reason -> {:error, :invalid_core_registration_authority}
      end

      defp authorize_core_registration(_state, _from, _custody),
        do: {:error, :invalid_core_registration_authority}

      defp secure_digest_equal?(left, right)
           when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
           do: :crypto.hash_equals(left, right)

      defp secure_digest_equal?(_left, _right), do: false

      defp do_register(name, module, metadata, state) do
        with :ok <- validate_not_core_locked(name, state),
             :ok <- validate_plugin_namespace(name, state),
             :ok <- validate_no_overwrite(name),
             :ok <- validate_behaviour(module),
             :ok <- validate_entry(name, module, metadata) do
          :ets.insert(@table_name, {name, module, metadata, 0, false})
          :ok
        end
      end

      defp do_deregister(name, state) do
        case :ets.lookup(@table_name, name) do
          [{^name, _module, _metadata, _failures, true}] when state.core_locked ->
            {:error, :core_locked}

          [{^name, _module, _metadata, _failures, _core?}] ->
            :ets.delete(@table_name, name)
            :ok

          [] ->
            {:error, :not_found}
        end
      end

      defp validate_not_core_locked(name, %{core_locked: true}) do
        case :ets.lookup(@table_name, name) do
          [{^name, _module, _metadata, _failures, true}] -> {:error, :core_locked}
          _ -> :ok
        end
      end

      defp validate_not_core_locked(_name, _state), do: :ok

      # After core lock, plugin entries must contain a "." prefix separator
      # to prevent namespace collision with core entries.
      defp validate_plugin_namespace(_name, %{core_locked: false}), do: :ok

      defp validate_plugin_namespace(name, %{core_locked: true}) do
        if String.contains?(name, ".") do
          :ok
        else
          {:error, {:plugin_namespace_required, name}}
        end
      end

      defp validate_no_overwrite(name) do
        if @allow_overwrite do
          :ok
        else
          case :ets.lookup(@table_name, name) do
            [] -> :ok
            [{^name, _module, _metadata, _failures, true}] -> {:error, :core_locked}
            _ -> {:error, :already_registered}
          end
        end
      end

      defp valid_snapshot?(entries, core_locked)
           when is_list(entries) and is_boolean(core_locked) do
        Enum.all?(entries, fn
          {name, module, metadata, failures, core?}
          when is_binary(name) and is_atom(module) and is_map(metadata) and
                 is_integer(failures) and failures >= 0 and is_boolean(core?) ->
            true

          _ ->
            false
        end)
      end

      defp valid_snapshot?(_entries, _core_locked), do: false

      defp validate_behaviour(module) do
        case @require_behaviour do
          nil ->
            :ok

          behaviour ->
            if Code.ensure_loaded?(module) do
              behaviours =
                module.module_info(:attributes)
                |> Keyword.get_values(:behaviour)
                |> List.flatten()

              if behaviour in behaviours do
                :ok
              else
                {:error, {:missing_behaviour, behaviour}}
              end
            else
              {:error, :module_not_loaded}
            end
        end
      end

      @doc """
      Override this to add custom entry validation.

      Called during `register/3`. Return `:ok` or `{:error, reason}`.
      """
      def validate_entry(_name, _module, _metadata), do: :ok

      defp check_available(module) do
        if function_exported?(module, :available?, 0) do
          try do
            module.available?()
          rescue
            _ -> false
          end
        else
          true
        end
      end

      # --- Remote Resolution ---

      defp resolve_remote_any(name) do
        case GenServer.call(__MODULE__, {:remote_cache_lookup, name, :any}) do
          {:ok, module, _remote_node} ->
            {:ok, module}

          {:error, {:zone_violation, _, _}} = error ->
            error

          :miss ->
            do_resolve_remote_any(name)
        end
      end

      # Network I/O deliberately runs in the caller, never in the registry
      # owner. Two nodes may resolve each other simultaneously, and a slow
      # peer must not block local registry mutations behind a GenServer call.
      # Only validation and cache mutation cross back into the owner.
      defp do_resolve_remote_any(name) do
        members = safe_pg_members()
        local_pid = Process.whereis(__MODULE__)

        # Filter out self, query remotes
        remote_pids =
          Enum.reject(members, fn pid ->
            pid == local_pid or node(pid) == node()
          end)

        # Check trust zone access for each remote node
        local_zone = safe_local_zone()

        Enum.reduce_while(remote_pids, {:error, :not_found}, fn pid, _result ->
          remote_node = node(pid)
          remote_zone = safe_trust_zone(remote_node)

          if safe_can_resolve?(local_zone, remote_zone) do
            case safe_remote_call(pid, {:resolve_remote, name}) do
              {:ok, module, metadata} ->
                case cache_remote(name, module, metadata, remote_node) do
                  {:ok, _module} = ok -> {:halt, ok}
                  {:error, _reason} -> {:cont, {:error, :not_found}}
                end

              _ ->
                {:cont, {:error, :not_found}}
            end
          else
            {:cont, {:error, :not_found}}
          end
        end)
      end

      defp resolve_on_node(name, target_node) do
        local_zone = safe_local_zone()
        remote_zone = safe_trust_zone(target_node)

        if safe_can_resolve?(local_zone, remote_zone) do
          case GenServer.call(__MODULE__, {:remote_cache_lookup, name, target_node}) do
            {:ok, module, _node} ->
              {:ok, module}

            {:error, {:zone_violation, _, _}} = error ->
              error

            :miss ->
              fetch_from_remote_node(name, target_node)
          end
        else
          {:error, {:zone_violation, local_zone, remote_zone}}
        end
      end

      defp fetch_from_remote_node(name, target_node) do
        members = safe_pg_members()

        case Enum.find(members, fn pid -> node(pid) == target_node end) do
          nil ->
            {:error, :node_not_found}

          pid ->
            case safe_remote_call(pid, {:resolve_remote, name}) do
              {:ok, module, metadata} ->
                cache_remote(name, module, metadata, target_node)

              error ->
                error
            end
        end
      end

      defp cache_remote(name, module, metadata, remote_node) do
        GenServer.call(
          __MODULE__,
          {:cache_remote, name, module, metadata, remote_node}
        )
      end

      defp validate_remote_entry(name, module, metadata)
           when is_binary(name) and is_atom(module) and is_map(metadata) do
        with true <- Code.ensure_loaded?(module),
             :ok <- validate_behaviour(module),
             :ok <- validate_entry(name, module, metadata) do
          :ok
        else
          false -> {:error, :module_not_loaded}
          {:error, _reason} = error -> error
          _ -> {:error, :invalid_entry}
        end
      end

      defp validate_remote_entry(_name, _module, _metadata), do: {:error, :invalid_entry}

      defp safe_remote_call(pid, message) do
        GenServer.call(pid, message, 5_000)
      rescue
        _ -> {:error, :remote_unavailable}
      catch
        :exit, _ -> {:error, :remote_unavailable}
      end

      # --- Remote Cache (owner state, per-entry TTL) ---

      defp remote_cache_lookup_allowed(state, name, target_node) do
        lookup =
          case target_node do
            :any -> remote_cache_lookup(state, name)
            node_name -> remote_cache_lookup(state, name, node_name)
          end

        case lookup do
          {:ok, _module, remote_node} = cached ->
            local_zone = safe_local_zone()
            remote_zone = safe_trust_zone(remote_node)

            if safe_can_resolve?(local_zone, remote_zone) do
              cached
            else
              {:error, {:zone_violation, local_zone, remote_zone}}
            end

          :miss ->
            :miss
        end
      end

      defp remote_cache_lookup(state, name) do
        now = System.monotonic_time(:millisecond)

        Enum.find_value(state.remote_cache, :miss, fn
          {{^name, _node}, {module, remote_node, expiry}} when expiry > now ->
            {:ok, module, remote_node}

          _ ->
            nil
        end)
      end

      defp remote_cache_lookup(state, name, target_node) do
        now = System.monotonic_time(:millisecond)

        case Map.get(state.remote_cache, {name, target_node}) do
          {module, ^target_node, expiry} when expiry > now ->
            {:ok, module, target_node}

          _ ->
            :miss
        end
      end

      defp remote_cache_store(state, name, module, remote_node) do
        expiry = System.monotonic_time(:millisecond) + @remote_cache_ttl_ms
        cache = Map.put(state.remote_cache, {name, remote_node}, {module, remote_node, expiry})
        %{state | remote_cache: cache}
      end

      # --- Trust Zone Bridges (safe, fail-closed) ---

      defp safe_local_zone, do: safe_zone(:local_zone, [])

      defp safe_trust_zone(node_name), do: safe_zone(:trust_zone, [node_name])

      defp safe_zone(callback, args) do
        policy = Arbor.Common.Config.registry_distribution_policy()

        if is_atom(policy) and not is_nil(policy) and Code.ensure_loaded?(policy) and
             function_exported?(policy, callback, length(args)) do
          case apply(policy, callback, args) do
            zone when zone in 0..2 -> zone
            _ -> :unavailable
          end
        else
          :unavailable
        end
      rescue
        _ -> :unavailable
      catch
        _, _ -> :unavailable
      end

      defp safe_can_resolve?(from_zone, entry_zone)
           when from_zone in 0..2 and entry_zone in 0..2 do
        policy = Arbor.Common.Config.registry_distribution_policy()

        if is_atom(policy) and not is_nil(policy) and Code.ensure_loaded?(policy) and
             function_exported?(policy, :can_resolve?, 2) do
          policy.can_resolve?(from_zone, entry_zone) == true
        else
          false
        end
      rescue
        _ -> false
      catch
        _, _ -> false
      end

      defp safe_can_resolve?(_from_zone, _entry_zone), do: false

      defp safe_pg_members do
        :pg.get_members(@pg_scope, @pg_group)
      rescue
        _ -> []
      catch
        :exit, _ -> []
      end

      # --- pg Integration ---

      defp maybe_join_pg do
        :pg.join(@pg_scope, @pg_group, [self()])
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      defp maybe_monitor_pg do
        :pg.monitor(@pg_scope, @pg_group)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end

      # Explicit old-heir state machine.
      #
      # :standby — before the registry has ever crashed. A message that is
      #            merely SHAPED like an ETS-TRANSFER is not proof of
      #            anything — any process can send one. On receipt, we
      #            independently PROVE a real transfer occurred by reading
      #            :ets.info/2 ourselves: only if :ets.whereis/1 resolves to
      #            a live table AND that table's actual owner is us
      #            (self()) do we trust it. A forged message fails this
      #            proof and we loop back to :standby untouched — it cannot
      #            disarm or expire the heir, because we never start the
      #            owner-state deadline without independently-verified
      #            proof. Only a message shaped like an :EXIT is otherwise
      #            handled (kept for parity with the pre-existing
      #            trap_exit behavior).
      #
      # :owner   — entered only after that independent proof, carrying the
      #            exact `table_ref` captured at proof time. It computes ONE
      #            fixed absolute deadline right here and waits for an
      #            authenticated claim until exactly that deadline — an
      #            invalid/rejected claim loops but does NOT push the
      #            deadline out. If nothing valid claims the table within
      #            @heir_claim_window_ms, this process exits; since it is
      #            still its own :heir, Erlang deletes the table rather than
      #            leaving it retained indefinitely.
      #
      #            A claim is honored only when its table generation is
      #            pinned to exactly the stored `table_ref` (not a fresh,
      #            re-derived value — bound against the generation we
      #            already proved) and its claimant pid matches exactly,
      #            and only after re-verifying — immediately before
      #            :ets.give_away/3 — that the table still exists under
      #            that exact generation and that this process is still its
      #            owner. Only the current owner may call give_away; this
      #            process never calls it except in that verified branch.
      #            A valid claimant can still die in the narrow window
      #            between validation and give_away — that call is guarded,
      #            and a failure there leaves this process safely in
      #            :owner (deadline unchanged) rather than crashing and
      #            deleting the orphan early. On success it exits
      #            immediately afterward.
      defp start_heir do
        {:ok, pid} =
          Task.start(fn ->
            Process.flag(:trap_exit, true)
            heir_standby()
          end)

        pid
      end

      defp heir_standby do
        receive do
          {:"ETS-TRANSFER", @table_name, _from_pid, _data} ->
            case proven_transfer_ownership() do
              {:ok, table_ref} ->
                deadline = System.monotonic_time(:millisecond) + @heir_claim_window_ms
                heir_owner(table_ref, deadline)

              :error ->
                heir_standby()
            end

          {:EXIT, _pid, _reason} ->
            :ok
        end
      end

      # Independently prove real ownership rather than trusting that an
      # ETS-TRANSFER-shaped message actually reflects one.
      defp proven_transfer_ownership do
        case :ets.whereis(@table_name) do
          :undefined ->
            :error

          table_ref ->
            if :ets.info(table_ref, :owner) == self() do
              {:ok, table_ref}
            else
              :error
            end
        end
      end

      defp heir_owner(table_ref, deadline) do
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          :ok
        else
          receive do
            {:claim_ets_table, @table_name, ^table_ref, claim_ref, claimant_pid}
            when is_pid(claimant_pid) ->
              if heir_claim_valid?(table_ref, claimant_pid) do
                case give_away_safely(table_ref, claimant_pid, claim_ref) do
                  :ok -> :ok
                  {:error, _reason} -> heir_owner(table_ref, deadline)
                end
              else
                heir_owner(table_ref, deadline)
              end
          after
            remaining ->
              heir_owner(table_ref, deadline)
          end
        end
      end

      # Final invariant proof immediately before acting: the table must
      # still exist under exactly the stored generation, we must still be
      # its owner, and the claimant must be exactly the registered module's
      # live pid.
      defp heir_claim_valid?(table_ref, claimant_pid) do
        claimant_pid == Process.whereis(__MODULE__) and
          :ets.whereis(@table_name) == table_ref and
          :ets.info(table_ref, :owner) == self()
      end

      # A validated claimant can still die between heir_claim_valid?/2 and
      # this call — :ets.give_away/3 then raises ArgumentError (recipient
      # not alive). Catch it so the heir remains safely in :owner (under
      # the unchanged, original deadline) instead of crashing and losing
      # its own-heir table to an unhandled exit.
      defp give_away_safely(table_ref, claimant_pid, claim_ref) do
        :ets.give_away(table_ref, claimant_pid, {table_ref, claim_ref})
        :ok
      rescue
        ArgumentError -> {:error, :give_away_failed}
      end

      defoverridable validate_entry: 3
    end
  end
end
