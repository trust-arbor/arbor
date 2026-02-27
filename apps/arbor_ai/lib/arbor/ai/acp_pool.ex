defmodule Arbor.AI.AcpPool do
  @moduledoc """
  Session pool for ACP agent connections.

  Manages a pool of `AcpSession` processes across multiple providers (Claude,
  Gemini, Codex, etc.). Provides checkout/checkin semantics with automatic
  cleanup of idle sessions and crash recovery.

  ## Usage

      {:ok, session} = AcpPool.checkout(:claude)
      {:ok, result} = AcpSession.send_message(session, "Hello")
      :ok = AcpPool.checkin(session)

  ## Configuration

      config :arbor_ai,
        enable_acp_pool: true,
        acp_pool_config: [
          providers: %{
            claude: %{max: 3, idle_timeout_ms: 300_000},
            gemini: %{max: 3, idle_timeout_ms: 300_000}
          },
          default_max: 2,
          default_idle_timeout_ms: 300_000,
          cleanup_interval_ms: 60_000
        ]
  """

  use GenServer

  require Logger

  alias Arbor.AI.AcpSession

  @default_max 2
  @default_idle_timeout_ms 300_000
  @default_cleanup_interval_ms 60_000

  defstruct [
    :cleanup_ref,
    sessions: %{},
    by_provider: %{},
    monitors: %{},
    config: %{}
  ]

  # Session entry in the sessions map
  defmodule Entry do
    @moduledoc false
    defstruct [:pid, :provider, :ref, :checked_out_by, status: :idle, last_active: nil]
  end

  # -- Public API --

  @doc "Start the pool GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checkout an idle session for the given provider.

  Returns `{:ok, session_pid}` or spawns a new session if below max.
  Returns `{:error, :pool_exhausted}` when at capacity.

  ## Options

  - `:model` — model override for the session
  - `:cwd` — working directory for the session
  - `:timeout` — checkout timeout (default: 30_000)
  """
  @spec checkout(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def checkout(provider, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(__MODULE__, {:checkout, provider, opts}, timeout)
  end

  @doc """
  Return a session to the pool for reuse.
  """
  @spec checkin(pid()) :: :ok | {:error, :not_found}
  def checkin(session_pid) do
    GenServer.call(__MODULE__, {:checkin, session_pid})
  end

  @doc """
  Close and remove a specific session from the pool.
  """
  @spec close_session(pid()) :: :ok
  def close_session(session_pid) do
    GenServer.call(__MODULE__, {:close_session, session_pid})
  end

  @doc """
  Get pool status for all providers.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    config = build_config(opts)
    cleanup_ms = Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval_ms)
    cleanup_ref = Process.send_after(self(), :cleanup_idle, cleanup_ms)

    {:ok,
     %__MODULE__{
       config: config,
       cleanup_ref: cleanup_ref
     }}
  end

  @impl true
  def handle_call({:checkout, provider, opts}, {caller_pid, _tag}, state) do
    case find_idle_session(state, provider) do
      {:ok, entry} ->
        # Reuse idle session
        state = checkout_session(state, entry.ref, caller_pid)
        {:reply, {:ok, entry.pid}, state}

      :none ->
        # Try to spawn a new one
        max = max_for_provider(state.config, provider)
        current = count_for_provider(state, provider)

        if current < max do
          case spawn_session(provider, opts) do
            {:ok, pid} ->
              {state, _ref} = register_session(state, pid, provider, caller_pid)
              {:reply, {:ok, pid}, state}

            {:error, reason} ->
              {:reply, {:error, {:spawn_failed, reason}}, state}
          end
        else
          {:reply, {:error, :pool_exhausted}, state}
        end
    end
  end

  def handle_call({:checkin, session_pid}, _from, state) do
    case find_session_by_pid(state, session_pid) do
      {:ok, ref, entry} ->
        state = checkin_session(state, ref, entry)
        {:reply, :ok, state}

      :not_found ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:close_session, session_pid}, _from, state) do
    case find_session_by_pid(state, session_pid) do
      {:ok, ref, _entry} ->
        state = remove_session(state, ref)
        safe_close(session_pid)
        {:reply, :ok, state}

      :not_found ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:status, _from, state) do
    status =
      state.by_provider
      |> Enum.map(fn {provider, refs} ->
        entries = Enum.map(refs, &Map.get(state.sessions, &1))
        idle = Enum.count(entries, &(&1 && &1.status == :idle))
        checked_out = Enum.count(entries, &(&1 && &1.status == :checked_out))
        max = max_for_provider(state.config, provider)
        {provider, %{idle: idle, checked_out: checked_out, total: idle + checked_out, max: max}}
      end)
      |> Map.new()

    {:reply, status, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    case Map.get(state.monitors, monitor_ref) do
      {:session, session_ref} ->
        # Session process died — remove from pool
        Logger.debug("AcpPool: session #{inspect(pid)} died, removing from pool")
        state = remove_session_by_monitor(state, monitor_ref, session_ref)
        {:noreply, state}

      {:caller, session_ref} ->
        # Caller died while holding a session — auto-checkin
        Logger.debug("AcpPool: caller #{inspect(pid)} died, auto-checkin session")
        state = auto_checkin(state, monitor_ref, session_ref)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:cleanup_idle, state) do
    now = System.monotonic_time(:millisecond)
    state = cleanup_idle_sessions(state, now)

    cleanup_ms =
      get_in(state.config, [:cleanup_interval_ms]) || @default_cleanup_interval_ms

    cleanup_ref = Process.send_after(self(), :cleanup_idle, cleanup_ms)
    {:noreply, %{state | cleanup_ref: cleanup_ref}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Close all sessions on shutdown
    Enum.each(state.sessions, fn {_ref, entry} ->
      safe_close(entry.pid)
    end)

    :ok
  end

  # -- Private --

  defp build_config(opts) do
    app_config = Application.get_env(:arbor_ai, :acp_pool_config, [])
    merged = Keyword.merge(app_config, opts)

    %{
      providers: Keyword.get(merged, :providers, %{}),
      default_max: Keyword.get(merged, :default_max, @default_max),
      default_idle_timeout_ms:
        Keyword.get(merged, :default_idle_timeout_ms, @default_idle_timeout_ms),
      cleanup_interval_ms: Keyword.get(merged, :cleanup_interval_ms, @default_cleanup_interval_ms)
    }
  end

  defp max_for_provider(config, provider) do
    case get_in(config, [:providers, provider, :max]) do
      nil -> config.default_max
      max -> max
    end
  end

  defp idle_timeout_for_provider(config, provider) do
    case get_in(config, [:providers, provider, :idle_timeout_ms]) do
      nil -> config.default_idle_timeout_ms
      timeout -> timeout
    end
  end

  defp find_idle_session(state, provider) do
    refs = Map.get(state.by_provider, provider, MapSet.new())

    refs
    |> Enum.find_value(fn ref ->
      case Map.get(state.sessions, ref) do
        %Entry{status: :idle, pid: pid} = entry ->
          if Process.alive?(pid), do: entry, else: nil

        _ ->
          nil
      end
    end)
    |> case do
      nil -> :none
      entry -> {:ok, entry}
    end
  end

  defp find_session_by_pid(state, pid) do
    Enum.find_value(state.sessions, :not_found, fn {ref, entry} ->
      if entry.pid == pid, do: {:ok, ref, entry}
    end)
  end

  defp count_for_provider(state, provider) do
    state.by_provider
    |> Map.get(provider, MapSet.new())
    |> MapSet.size()
  end

  defp spawn_session(provider, opts) do
    session_opts =
      opts
      |> Keyword.put(:provider, provider)
      |> Keyword.put_new(:client_opts, Keyword.get(opts, :client_opts))

    # Remove pool-specific opts before passing to AcpSession
    session_opts = Keyword.drop(session_opts, [:timeout])

    case DynamicSupervisor.start_child(
           Arbor.AI.AcpPool.Supervisor,
           {AcpSession, session_opts}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_session(state, pid, provider, caller_pid) do
    ref = make_ref()
    now = System.monotonic_time(:millisecond)

    # Monitor the session process
    session_mon = Process.monitor(pid)
    # Monitor the caller so we can auto-checkin if they crash
    caller_mon = Process.monitor(caller_pid)

    entry = %Entry{
      pid: pid,
      provider: provider,
      ref: ref,
      status: :checked_out,
      checked_out_by: caller_pid,
      last_active: now
    }

    state = %{
      state
      | sessions: Map.put(state.sessions, ref, entry),
        by_provider:
          Map.update(state.by_provider, provider, MapSet.new([ref]), &MapSet.put(&1, ref)),
        monitors:
          state.monitors
          |> Map.put(session_mon, {:session, ref})
          |> Map.put(caller_mon, {:caller, ref})
    }

    {state, ref}
  end

  defp checkout_session(state, ref, caller_pid) do
    now = System.monotonic_time(:millisecond)
    caller_mon = Process.monitor(caller_pid)

    state = %{
      state
      | sessions:
          Map.update!(state.sessions, ref, fn entry ->
            %{entry | status: :checked_out, checked_out_by: caller_pid, last_active: now}
          end),
        monitors: Map.put(state.monitors, caller_mon, {:caller, ref})
    }

    state
  end

  defp checkin_session(state, ref, _entry) do
    now = System.monotonic_time(:millisecond)

    # Remove caller monitor
    {_caller_mon, monitors} =
      Enum.reduce(state.monitors, {nil, state.monitors}, fn
        {mon_ref, {:caller, ^ref}}, {_found, acc} ->
          Process.demonitor(mon_ref, [:flush])
          {mon_ref, Map.delete(acc, mon_ref)}

        _, acc ->
          acc
      end)

    state = %{
      state
      | sessions:
          Map.update!(state.sessions, ref, fn entry ->
            %{entry | status: :idle, checked_out_by: nil, last_active: now}
          end),
        monitors: monitors
    }

    state
  end

  defp auto_checkin(state, monitor_ref, session_ref) do
    monitors = Map.delete(state.monitors, monitor_ref)

    case Map.get(state.sessions, session_ref) do
      %Entry{status: :checked_out} ->
        now = System.monotonic_time(:millisecond)

        sessions =
          Map.update!(state.sessions, session_ref, fn entry ->
            %{entry | status: :idle, checked_out_by: nil, last_active: now}
          end)

        %{state | sessions: sessions, monitors: monitors}

      _ ->
        %{state | monitors: monitors}
    end
  end

  defp remove_session(state, ref) do
    entry = Map.get(state.sessions, ref)

    # Clean up monitors for this session
    monitors =
      Enum.reduce(state.monitors, state.monitors, fn
        {mon_ref, {_type, ^ref}}, acc ->
          Process.demonitor(mon_ref, [:flush])
          Map.delete(acc, mon_ref)

        _, acc ->
          acc
      end)

    provider = entry && entry.provider

    by_provider =
      if provider do
        Map.update(state.by_provider, provider, MapSet.new(), &MapSet.delete(&1, ref))
      else
        state.by_provider
      end

    %{
      state
      | sessions: Map.delete(state.sessions, ref),
        by_provider: by_provider,
        monitors: monitors
    }
  end

  defp remove_session_by_monitor(state, monitor_ref, session_ref) do
    state
    |> remove_session(session_ref)
    |> Map.update!(:monitors, &Map.delete(&1, monitor_ref))
  end

  defp cleanup_idle_sessions(state, now) do
    refs_to_close =
      Enum.filter(state.sessions, fn {_ref, entry} ->
        entry.status == :idle &&
          now - entry.last_active > idle_timeout_for_provider(state.config, entry.provider)
      end)
      |> Enum.map(fn {ref, entry} -> {ref, entry.pid} end)

    Enum.reduce(refs_to_close, state, fn {ref, pid}, acc ->
      Logger.debug("AcpPool: closing idle session #{inspect(pid)}")
      safe_close(pid)
      remove_session(acc, ref)
    end)
  end

  defp safe_close(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        AcpSession.close(pid)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp safe_close(_), do: :ok
end
