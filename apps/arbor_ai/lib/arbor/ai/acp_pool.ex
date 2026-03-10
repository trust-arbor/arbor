defmodule Arbor.AI.AcpPool do
  @moduledoc """
  Session pool for ACP agent connections.

  Manages a pool of `AcpSession` processes across multiple providers (Claude,
  Gemini, Codex, etc.). Uses `SessionProfile` for capability-based matching:
  sessions are matched by profile hash (provider + tool set), trust domain,
  and agent identity.

  ## Usage

      # Simple checkout (backward compatible)
      {:ok, session} = AcpPool.checkout(:claude)
      {:ok, result} = AcpSession.send_message(session, "Hello")
      :ok = AcpPool.checkin(session)

      # Profile-based checkout
      {:ok, session} = AcpPool.checkout(:claude,
        agent_id: "interviewer",
        tool_modules: [Arbor.Actions.Trust.ListPresets],
        trust_domain: :internal
      )

      # Sticky affinity (always same session for this key)
      {:ok, session} = AcpPool.checkout(:claude,
        affinity_key: "interviewer_main"
      )

  ## Matching Rules

  1. If `affinity_key` matches an existing session → return that exact session
  2. Same `profile_hash` + same `trust_domain` + same `agent_id` → reuse
  3. Different `agent_id` → never reuse (mint fresh)
  4. No match → spawn new session if below capacity

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
  alias Arbor.AI.AcpPool.SessionProfile

  @default_max 2
  @default_idle_timeout_ms 300_000
  @default_cleanup_interval_ms 60_000

  defstruct [
    :cleanup_ref,
    sessions: %{},
    by_provider: %{},
    by_profile_hash: %{},
    by_affinity: %{},
    monitors: %{},
    config: %{}
  ]

  # Session entry in the sessions map
  defmodule Entry do
    @moduledoc false

    defstruct [
      :pid,
      :provider,
      :ref,
      :profile,
      :checked_out_by,
      status: :idle,
      last_active: nil,
      checkout_count: 0
    ]
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
  - `:agent_id` — owning Arbor agent ID
  - `:tool_modules` — list of Jido action modules for this session
  - `:trust_domain` — security boundary (sessions never cross domains)
  - `:affinity_key` — sticky routing key (same key → same session)
  - `:trust_tier` — agent's trust level
  - `:name` — human-readable session name
  - `:tags` — arbitrary metadata map
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

  Returns a map keyed by provider with counts, plus session details.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get detailed info about all sessions including their profiles.
  """
  @spec sessions() :: [map()]
  def sessions do
    GenServer.call(__MODULE__, :sessions)
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    config = build_config(opts)
    cleanup_ms = Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval_ms)
    cleanup_ref = Process.send_after(self(), :cleanup_idle, cleanup_ms)

    # Clear the cached UnifiedLLM Client so it re-discovers adapters
    # (including ACP now that the pool is running).
    client_mod = Arbor.Orchestrator.UnifiedLLM.Client

    if Code.ensure_loaded?(client_mod) and
         function_exported?(client_mod, :clear_default_client, 0) do
      apply(client_mod, :clear_default_client, [])
    end

    {:ok,
     %__MODULE__{
       config: config,
       cleanup_ref: cleanup_ref
     }}
  end

  @impl true
  def handle_call({:checkout, provider, opts}, {caller_pid, _tag}, state) do
    profile = SessionProfile.from_opts(provider, opts)

    case find_by_affinity(state, profile) do
      {:ok, entry, state} ->
        # Hard affinity match
        state = checkout_session(state, entry.ref, caller_pid)
        {:reply, {:ok, entry.pid}, state}

      :no_affinity ->
        case find_compatible_session(state, profile) do
          {:ok, entry, state} ->
            # Profile-compatible reuse
            state = checkout_session(state, entry.ref, caller_pid)
            {:reply, {:ok, entry.pid}, state}

          {:none, state} ->
            # Mint fresh session
            max = max_for_provider(state.config, provider)
            current = count_for_provider(state, provider)

            if current < max do
              case spawn_session(provider, opts) do
                {:ok, pid} ->
                  {state, _ref} = register_session(state, pid, profile, caller_pid)
                  Logger.debug("AcpPool: minted #{profile.name} (#{SessionProfile.urn(profile)})")
                  {:reply, {:ok, pid}, state}

                {:error, reason} ->
                  {:reply, {:error, {:spawn_failed, reason}}, state}
              end
            else
              {:reply, {:error, :pool_exhausted}, state}
            end
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

  def handle_call(:sessions, _from, state) do
    session_list =
      Enum.map(state.sessions, fn {_ref, entry} ->
        %{
          pid: entry.pid,
          provider: entry.provider,
          status: entry.status,
          name: entry.profile && entry.profile.name,
          urn: entry.profile && SessionProfile.urn(entry.profile),
          agent_id: entry.profile && entry.profile.agent_id,
          tool_count: entry.profile && length(entry.profile.tool_modules),
          trust_domain: entry.profile && entry.profile.trust_domain,
          checkout_count: entry.checkout_count,
          checked_out_by: entry.checked_out_by,
          last_active: entry.last_active
        }
      end)

    {:reply, session_list, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, _reason}, state) do
    case Map.get(state.monitors, monitor_ref) do
      {:session, session_ref} ->
        Logger.debug("AcpPool: session #{inspect(pid)} died, removing from pool")
        state = remove_session_by_monitor(state, monitor_ref, session_ref)
        {:noreply, state}

      {:caller, session_ref} ->
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
    Enum.each(state.sessions, fn {_ref, entry} ->
      safe_close(entry.pid)
    end)

    :ok
  end

  # -- Private: Matching --

  # Hard affinity: if the request has an affinity_key, find the exact session
  defp find_by_affinity(_state, %SessionProfile{affinity_key: nil}), do: :no_affinity

  defp find_by_affinity(state, %SessionProfile{affinity_key: key}) do
    case Map.get(state.by_affinity, key) do
      nil ->
        :no_affinity

      ref ->
        case Map.get(state.sessions, ref) do
          %Entry{status: :idle, pid: pid} = entry ->
            case validate_session(pid) do
              :ok -> {:ok, entry, state}
              {:error, _} ->
                safe_close(pid)
                {:no_affinity, remove_session(state, ref)}
            end

          %Entry{status: :checked_out} ->
            # Session exists but is busy — don't mint a duplicate, wait
            :no_affinity

          nil ->
            :no_affinity
        end
    end
  end

  # Profile-compatible matching: same hash + trust domain + agent_id
  defp find_compatible_session(state, %SessionProfile{} = requested) do
    refs =
      Map.get(state.by_profile_hash, requested.profile_hash, MapSet.new())
      |> Enum.to_list()

    try_compatible_refs(state, refs, requested)
  end

  defp try_compatible_refs(state, [], _requested), do: {:none, state}

  defp try_compatible_refs(state, [ref | rest], requested) do
    case Map.get(state.sessions, ref) do
      %Entry{status: :idle, pid: pid, profile: profile} = entry ->
        # Skip sessions reserved by an affinity key — they belong to their owner
        affinity_reserved = profile && profile.affinity_key != nil

        if not affinity_reserved and SessionProfile.compatible?(requested, profile) do
          case validate_session(pid) do
            :ok ->
              {:ok, entry, state}

            {:error, _reason} ->
              Logger.debug("AcpPool: removing unhealthy session #{inspect(pid)}")
              safe_close(pid)
              state = remove_session(state, ref)
              try_compatible_refs(state, rest, requested)
          end
        else
          try_compatible_refs(state, rest, requested)
        end

      _ ->
        try_compatible_refs(state, rest, requested)
    end
  end

  # -- Private: Session lifecycle --

  defp validate_session(pid) do
    if Process.alive?(pid) do
      try do
        status = GenServer.call(pid, :status, 2_000)

        if status.status in [:ready] do
          :ok
        else
          {:error, :not_ready}
        end
      catch
        :exit, _ -> {:error, :dead}
      end
    else
      {:error, :dead}
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
      |> Keyword.put_new(:workspace, Keyword.get(opts, :workspace))
      |> Keyword.put_new(:agent_id, Keyword.get(opts, :agent_id))

    # Remove pool-specific opts before passing to AcpSession
    pool_keys = [:timeout, :tool_modules, :trust_domain, :affinity_key, :trust_tier, :name, :tags]
    session_opts = Keyword.drop(session_opts, pool_keys)

    case DynamicSupervisor.start_child(
           Arbor.AI.AcpPool.Supervisor,
           {AcpSession, session_opts}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_session(state, pid, %SessionProfile{} = profile, caller_pid) do
    ref = make_ref()
    now = System.monotonic_time(:millisecond)

    session_mon = Process.monitor(pid)
    caller_mon = Process.monitor(caller_pid)

    entry = %Entry{
      pid: pid,
      provider: profile.provider,
      ref: ref,
      profile: profile,
      status: :checked_out,
      checked_out_by: caller_pid,
      last_active: now,
      checkout_count: 1
    }

    state = %{
      state
      | sessions: Map.put(state.sessions, ref, entry),
        by_provider:
          Map.update(state.by_provider, profile.provider, MapSet.new([ref]), &MapSet.put(&1, ref)),
        by_profile_hash:
          Map.update(
            state.by_profile_hash,
            profile.profile_hash,
            MapSet.new([ref]),
            &MapSet.put(&1, ref)
          ),
        by_affinity: maybe_put_affinity(state.by_affinity, profile.affinity_key, ref),
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

    %{
      state
      | sessions:
          Map.update!(state.sessions, ref, fn entry ->
            %{
              entry
              | status: :checked_out,
                checked_out_by: caller_pid,
                last_active: now,
                checkout_count: entry.checkout_count + 1
            }
          end),
        monitors: Map.put(state.monitors, caller_mon, {:caller, ref})
    }
  end

  defp checkin_session(state, ref, _entry) do
    now = System.monotonic_time(:millisecond)

    {_caller_mon, monitors} =
      Enum.reduce(state.monitors, {nil, state.monitors}, fn
        {mon_ref, {:caller, ^ref}}, {_found, acc} ->
          Process.demonitor(mon_ref, [:flush])
          {mon_ref, Map.delete(acc, mon_ref)}

        _, acc ->
          acc
      end)

    %{
      state
      | sessions:
          Map.update!(state.sessions, ref, fn entry ->
            %{entry | status: :idle, checked_out_by: nil, last_active: now}
          end),
        monitors: monitors
    }
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

    monitors =
      Enum.reduce(state.monitors, state.monitors, fn
        {mon_ref, {_type, ^ref}}, acc ->
          Process.demonitor(mon_ref, [:flush])
          Map.delete(acc, mon_ref)

        _, acc ->
          acc
      end)

    provider = entry && entry.provider
    profile_hash = entry && entry.profile && entry.profile.profile_hash
    affinity_key = entry && entry.profile && entry.profile.affinity_key

    by_provider =
      if provider do
        Map.update(state.by_provider, provider, MapSet.new(), &MapSet.delete(&1, ref))
      else
        state.by_provider
      end

    by_profile_hash =
      if profile_hash do
        Map.update(state.by_profile_hash, profile_hash, MapSet.new(), &MapSet.delete(&1, ref))
      else
        state.by_profile_hash
      end

    by_affinity =
      if affinity_key do
        Map.delete(state.by_affinity, affinity_key)
      else
        state.by_affinity
      end

    %{
      state
      | sessions: Map.delete(state.sessions, ref),
        by_provider: by_provider,
        by_profile_hash: by_profile_hash,
        by_affinity: by_affinity,
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
      |> Enum.map(fn {ref, entry} -> {ref, entry.pid, entry.profile} end)

    Enum.reduce(refs_to_close, state, fn {ref, pid, profile}, acc ->
      name = (profile && profile.name) || inspect(pid)
      Logger.debug("AcpPool: closing idle session #{name}")
      safe_close(pid)
      remove_session(acc, ref)
    end)
  end

  defp safe_close(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Task.start(fn ->
        try do
          AcpSession.close(pid)
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end)
    end
  end

  defp safe_close(_), do: :ok

  # -- Private: Config --

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

  defp maybe_put_affinity(by_affinity, nil, _ref), do: by_affinity
  defp maybe_put_affinity(by_affinity, key, ref), do: Map.put(by_affinity, key, ref)
end
