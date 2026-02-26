defmodule Arbor.Common.RegistryBase do
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
  """
  defmacro __using__(opts) do
    table_name = Keyword.fetch!(opts, :table_name)
    require_behaviour = Keyword.get(opts, :require_behaviour)
    allow_overwrite = Keyword.get(opts, :allow_overwrite, false)
    max_failures = Keyword.get(opts, :max_failures, 5)

    quote location: :keep do
      use GenServer

      @behaviour Arbor.Contracts.Handler.Registry

      @table_name unquote(table_name)
      @require_behaviour unquote(require_behaviour)
      @allow_overwrite unquote(allow_overwrite)
      @max_failures unquote(max_failures)
      @heir_name Module.concat(__MODULE__, Heir)
      @pt_key {__MODULE__, :core_snapshot}

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

      @impl Arbor.Contracts.Handler.Registry
      def deregister(name) when is_binary(name) do
        GenServer.call(__MODULE__, {:deregister, name})
      end

      @impl Arbor.Contracts.Handler.Registry
      def resolve(name) when is_binary(name) do
        # Fast path: persistent_term snapshot (zero-cost for core entries)
        case pt_lookup(name) do
          {:ok, _module} = ok -> ok
          :miss -> ets_resolve(name)
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

      @doc """
      Resolve an entry, but skip unstable entries (failure count >= max_failures).
      Returns `{:error, :unstable}` if the entry exists but is over the failure threshold.
      """
      def resolve_stable(name) when is_binary(name) do
        # Fast path: persistent_term snapshot only contains healthy core entries.
        # If an entry has failures recorded, it won't be in the snapshot —
        # record_failure invalidates the snapshot.
        case pt_lookup(name) do
          {:ok, _module} = ok -> ok
          :miss -> ets_resolve_stable(name)
        end
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
        GenServer.call(__MODULE__, :lock_core)
      end

      @impl Arbor.Contracts.Handler.Registry
      def core_locked? do
        GenServer.call(__MODULE__, :core_locked?)
      end

      @doc """
      Clear all entries and reset core lock. Primarily for test isolation.
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
      def init(_opts) do
        heir_pid = start_heir()

        table =
          case :ets.whereis(@table_name) do
            :undefined ->
              :ets.new(@table_name, [
                :set,
                :named_table,
                :public,
                {:read_concurrency, true},
                {:heir, heir_pid, @table_name}
              ])

            _ref ->
              # Table exists (held by heir after crash). Claim ownership.
              try do
                :ets.setopts(@table_name, [{:heir, heir_pid, @table_name}])
              rescue
                ArgumentError -> :ok
              end

              @table_name
          end

        {:ok, %{core_locked: false, heir_pid: heir_pid}}
      end

      @impl GenServer
      def handle_call({:register, name, module, metadata}, _from, state) do
        result = do_register(name, module, metadata, state)
        {:reply, result, state}
      end

      def handle_call({:deregister, name}, _from, state) do
        result = do_deregister(name, state)
        {:reply, result, state}
      end

      def handle_call(:lock_core, _from, state) do
        # Mark all current entries as core
        :ets.tab2list(@table_name)
        |> Enum.each(fn {name, module, metadata, failures, _core?} ->
          :ets.insert(@table_name, {name, module, metadata, failures, true})
        end)

        # Snapshot healthy entries to persistent_term for zero-cost reads
        pt_snapshot()

        {:reply, :ok, %{state | core_locked: true}}
      end

      def handle_call(:core_locked?, _from, state) do
        {:reply, state.core_locked, state}
      end

      def handle_call(:reset, _from, state) do
        :ets.delete_all_objects(@table_name)
        pt_invalidate()
        {:reply, :ok, %{state | core_locked: false}}
      end

      def handle_call({:record_failure, name}, _from, state) do
        result =
          case :ets.lookup(@table_name, name) do
            [{^name, module, metadata, failures, core?}] ->
              :ets.insert(@table_name, {name, module, metadata, failures + 1, core?})
              # Invalidate snapshot since this entry is now degraded
              pt_invalidate()
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
              # Re-snapshot since entry is healthy again
              if state.core_locked, do: pt_snapshot()
              :ok

            [] ->
              {:error, :not_found}
          end

        {:reply, result, state}
      end

      def handle_call({:restore, entries, core_locked}, _from, state) do
        :ets.delete_all_objects(@table_name)

        Enum.each(entries, fn entry ->
          :ets.insert(@table_name, entry)
        end)

        # Rebuild snapshot if core was locked
        if core_locked, do: pt_snapshot(), else: pt_invalidate()

        {:reply, :ok, %{state | core_locked: core_locked}}
      end

      @impl GenServer
      def handle_info({:"ETS-TRANSFER", table, _from_pid, _data}, state) do
        # ETS table transferred from dying heir or previous owner
        # Re-establish heir
        heir_pid = start_heir()

        try do
          :ets.setopts(table, [{:heir, heir_pid, @table_name}])
        rescue
          ArgumentError -> :ok
        end

        {:noreply, %{state | heir_pid: heir_pid}}
      end

      def handle_info(_msg, state) do
        {:noreply, state}
      end

      # --- Internal ---

      defp do_register(name, module, metadata, state) do
        with :ok <- validate_not_core_locked(name, state),
             :ok <- validate_plugin_namespace(name, state),
             :ok <- validate_no_overwrite(name),
             :ok <- validate_behaviour(module),
             :ok <- validate_entry(name, module, metadata) do
          :ets.insert(@table_name, {name, module, metadata, 0, false})
          # Rebuild snapshot to include new entry
          if state.core_locked, do: pt_snapshot()
          :ok
        end
      end

      defp do_deregister(name, state) do
        case :ets.lookup(@table_name, name) do
          [{^name, _module, _metadata, _failures, true}] when state.core_locked ->
            {:error, :core_locked}

          [{^name, _module, _metadata, _failures, _core?}] ->
            :ets.delete(@table_name, name)
            # Rebuild snapshot to remove entry
            if state.core_locked, do: pt_snapshot()
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

      defp start_heir do
        {:ok, pid} =
          Task.start(fn ->
            Process.flag(:trap_exit, true)

            receive do
              {:"ETS-TRANSFER", _table, _from, _data} ->
                # Hold the table until the registry restarts and reclaims it
                receive do
                  {:"ETS-TRANSFER", _table, _from, _data} -> :ok
                after
                  60_000 -> :ok
                end

              {:EXIT, _pid, _reason} ->
                :ok
            end
          end)

        pid
      end

      # --- persistent_term fast path ---

      # Lookup in persistent_term snapshot. Returns {:ok, module} or :miss.
      defp pt_lookup(name) do
        case :persistent_term.get(@pt_key, nil) do
          nil ->
            :miss

          map when is_map(map) ->
            case Map.fetch(map, name) do
              {:ok, module} -> {:ok, module}
              :error -> :miss
            end
        end
      end

      # Build persistent_term snapshot from all current ETS entries.
      # Only entries with 0 failures are included.
      defp pt_snapshot do
        map =
          :ets.tab2list(@table_name)
          |> Enum.reduce(%{}, fn {name, module, _meta, failures, _core?}, acc ->
            if failures == 0 and Code.ensure_loaded?(module) do
              Map.put(acc, name, module)
            else
              acc
            end
          end)

        :persistent_term.put(@pt_key, map)
      end

      # Invalidate persistent_term snapshot (e.g., after recording a failure).
      defp pt_invalidate do
        :persistent_term.erase(@pt_key)
      end

      defoverridable validate_entry: 3
    end
  end
end
