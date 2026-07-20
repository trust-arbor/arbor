defmodule Arbor.AI.AcpPool do
  @moduledoc """
  Session pool for ACP agent connections.

  Manages a pool of `AcpSession` processes across multiple providers (Claude,
  Gemini, Codex, etc.). Uses `SessionProfile` for fail-closed matching over
  every immutable reuse boundary: provider, tools, agent identity, trust
  domain, model, canonical cwd/workspace, task scope, and a deterministic
  fingerprint of immutable startup configuration.

  ## Usage

      # Simple checkout (backward compatible)
      {:ok, session} = AcpPool.checkout(:claude)
      {:ok, result} = AcpSession.send_message(session, "Hello")
      :ok = AcpPool.checkin(session)

      # Profile-based checkout
      {:ok, session} = AcpPool.checkout(:claude,
        agent_id: "interviewer",
        tool_modules: [Arbor.Actions.Trust.ListPresets],
        trust_domain: :internal,
        task_id: "task_123",
        cwd: "/path/to/worktree"
      )

      # Sticky affinity (same key → same session only when profile matches)
      {:ok, session} = AcpPool.checkout(:claude,
        affinity_key: "interviewer_main"
      )

  ## Matching Rules

  1. If `affinity_key` matches an existing session and the full profile is
     compatible → return that exact session. Incompatible affinity returns
     `{:error, :affinity_conflict}`; a busy affinity session returns
     `{:error, :affinity_busy}` (never mint a duplicate or overwrite affinity).
  2. Same complete `SessionProfile` (including task scope and cwd) → reuse a
     compatible idle local process
  3. Different task/cwd/model/agent/trust/startup config → never reuse
  4. Tool-enabled sessions are closed on checkin (provider MCP registration is
     immutable); the next checkout mints a fresh `AcpSession` + ToolServer
  5. Explicit cross-task provider continuity is only via managed
     `resume_provider` + `resume_session_id` (fresh local process + load)
  6. No match → spawn new session if below capacity. At capacity, idle sessions
     are an LRU-evictable cache: an incompatible miss reclaims the least-recently
     active idle entry (indexes + process fully cleaned) and mints. Busy
     (checked-out) sessions are never evicted and still return `:pool_exhausted`.

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

  alias Arbor.AI.AcpManaged.Supervisor, as: ManagedSupervisor
  alias Arbor.AI.AcpPool.SessionProfile
  alias Arbor.AI.AcpPool.ToolServer
  alias Arbor.AI.AcpSession
  alias Arbor.AI.AcpSession.GrokSandbox

  @default_max 2
  @default_idle_timeout_ms 300_000
  @default_cleanup_interval_ms 60_000
  # Post-deadline GenServer.call budget for force-confirm + reply after the
  # shared settlement close deadline is exhausted.
  @settlement_reply_slack_ms 2_000

  defstruct [
    :cleanup_ref,
    sessions: %{},
    by_provider: %{},
    by_profile_hash: %{},
    by_affinity: %{},
    monitors: %{},
    # Exact task+agent settlements still owning detached (possibly live) pids.
    # Keyed by {task_id, agent_id}. Prevents false no-match success while any
    # detached process may still be alive, and keeps cleanup independent of the
    # original caller's mailbox/lifetime.
    settlements: %{},
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
      :tool_server,
      status: :idle,
      taint: :clean,
      last_active: nil,
      checkout_count: 0
    ]
  end

  # In-progress exact task+agent settlement tracked on the pool GenServer.
  defmodule Settlement do
    @moduledoc false

    defstruct [
      :task_id,
      :agent_id,
      :pids,
      :detached_count,
      :worker_pid,
      :worker_ref,
      callers: []
    ]
  end

  # -- Public API --

  @pg_scope :acp_pool
  @pg_group :all_pools

  @doc "Start the pool GenServer."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checkout an idle session for the given provider.

  Returns `{:ok, session_pid}` or spawns a new session if below max.
  Returns `{:error, :pool_exhausted}` when at capacity.

  ## Options

  - `:model` — model override for the session (immutable reuse boundary)
  - `:cwd` — explicit session working directory (canonicalized; immutable).
    Non-`nil` values take precedence over a binary `:workspace` alias.
  - `:workspace` — one of:
    - **binary path** — pool-only alias for session `:cwd` (when `:cwd` is
      absent/`nil`) and ToolServer filesystem scope; never forwarded to
      `AcpSession` as `:workspace`
    - **`{:directory, path}`** — structured session directory plan (existing
      `AcpSession` shape); path is canonicalized and plan identity is hashed
    - **`{:worktree, opts}`** — structured session worktree plan with optional
      `:branch` / `:base_dir` only; plan identity is hashed
  - `:timeout` — checkout timeout (default: 30_000)
  - `:agent_id` — owning Arbor agent ID (`nil` matches only `nil`)
  - `:task_id` — coding task scope; same task may reuse a compatible process,
    different tasks never inherit provider conversation or cwd implicitly
  - `:tool_modules` — list of Jido action modules for this session
  - `:trust_domain` — security boundary (sessions never cross domains)
  - `:adapter_opts` / `:client_opts` / `:capabilities` — immutable startup
    configuration (fingerprinted; secrets never stored on the profile)
  - `:affinity_key` — sticky routing key (never bypasses profile compatibility)
  - `:name` — human-readable session name
  - `:tags` — arbitrary metadata map

  Pool-only options such as `:task_id`, `:principal_id`, `:tool_modules`,
  `:trust_domain`, `:affinity_key`, `:name`, and `:tags` are not forwarded to
  `AcpSession.start`.
  """
  @spec checkout(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def checkout(provider, opts \\ []) do
    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, 30_000),
         {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts),
         # Fail closed on malformed identity/scope before the pool GenServer so
         # blank/non-binary values never normalize into an unscoped match.
         {:ok, profile} <- SessionProfile.from_opts(provider, opts) do
      safe_pool_call({:checkout, provider, opts, profile}, remaining)
    end
  end

  @doc """
  Return a session to the pool for reuse.

  Tool-enabled sessions are closed on checkin rather than returned idle:
  provider MCP registration is immutable at create time, so the per-session
  ToolServer cannot be reattached for reuse. Non-tool sessions are returned
  idle and marked tainted.
  """
  @spec checkin(pid(), keyword()) :: :ok | {:error, term()}
  def checkin(session_pid, opts \\ []) do
    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, 5_000),
         {:ok, _opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      safe_pool_call({:checkin, session_pid}, remaining)
    end
  end

  @doc """
  Close and remove a specific session from the pool.
  """
  @spec close_session(pid(), keyword()) :: :ok | {:error, term()}
  def close_session(session_pid, opts \\ []) do
    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, 5_000),
         {:ok, _opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
      safe_pool_call({:close_session, session_pid}, remaining)
    end
  end

  @doc """
  Settle every idle pool session owned by an exact `task_id` + `agent_id` pair.

  Authority is the nonblank exact pair only — opaque session PIDs are never
  accepted. Matching uses `SessionProfile.task_id` and `SessionProfile.agent_id`
  equality (never prefix/wildcard). The second identity is the SessionProfile
  agent/principal; receipts use the single canonical field `agent_id`.

  Checked-out matches refuse atomically without detaching any matching entry.
  When all exact matches are idle they are detached from pool indexes first,
  then closed off the pool GenServer under one shared deadline so unrelated
  checkout/checkin/status calls stay responsive. Settlement continues if the
  original caller exits or times out, and an in-progress settlement for the
  same pair cannot report no-match success while any detached process may
  still be alive. Prefer graceful `AcpSession.close`; survivors are
  force-terminated and positively confirmed down before success.

  No matches (and no in-progress settlement) is idempotent success
  (`settled_count: 0`). Generic pool reuse is unchanged outside this explicit
  settlement path.

  Returns a JSON-clean receipt with `task_id`, `agent_id`, `settled_count`,
  and `status` — never PIDs.
  """
  @spec settle_task_sessions(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def settle_task_sessions(task_id, agent_id, opts \\ [])

  def settle_task_sessions(task_id, agent_id, opts)
      when is_binary(task_id) and is_binary(agent_id) and is_list(opts) do
    task_id = String.trim(task_id)
    agent_id = String.trim(agent_id)

    if task_id == "" or agent_id == "" or String.contains?(task_id, <<0>>) or
         String.contains?(agent_id, <<0>>) do
      {:error, :invalid_task_agent}
    else
      with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, 30_000),
           {:ok, opts, remaining} <- Arbor.AI.Timeout.remaining(opts) do
        # Settlement work uses `remaining` as the shared close deadline. The
        # GenServer.call budget is slightly larger so force-confirm + reply can
        # complete after graceful attempts exhaust the shared deadline.
        call_timeout = settlement_call_timeout(remaining)
        safe_pool_call({:settle_task_sessions, task_id, agent_id, opts}, call_timeout)
      end
    end
  end

  def settle_task_sessions(_task_id, _agent_id, _opts), do: {:error, :invalid_task_agent}

  defp settlement_call_timeout(:infinity), do: :infinity

  defp settlement_call_timeout(remaining) when is_integer(remaining) and remaining >= 0 do
    remaining + @settlement_reply_slack_ms
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

  Each entry includes at least `pid`, `provider`, `status`, `name`, `urn`,
  `agent_id`, `task_id`, `cwd`, `model`, `tool_count`, `trust_domain`,
  `tool_server_port`, `taint`, `checkout_count`, `checked_out_by`, and
  `last_active`.
  """
  @spec sessions() :: [map()]
  def sessions do
    GenServer.call(__MODULE__, :sessions)
  end

  @doc """
  Get aggregated status across all nodes in the cluster.

  Returns a map of `%{node => provider_status}` for every node
  running an AcpPool.
  """
  @spec cluster_status() :: map()
  def cluster_status do
    local = %{Node.self() => safe_call(:status)}

    remote_nodes()
    |> Enum.reduce(local, fn node, acc ->
      case :rpc.call(node, __MODULE__, :status, [], 5_000) do
        {:badrpc, _} -> acc
        result -> Map.put(acc, node, result)
      end
    end)
  end

  @doc """
  Get all sessions across all nodes in the cluster.
  """
  @spec cluster_sessions() :: [map()]
  def cluster_sessions do
    local =
      safe_call(:sessions)
      |> Enum.map(&Map.put(&1, :node, Node.self()))

    remote =
      remote_nodes()
      |> Enum.flat_map(fn node ->
        case :rpc.call(node, __MODULE__, :sessions, [], 5_000) do
          {:badrpc, _} -> []
          sessions -> Enum.map(sessions, &Map.put(&1, :node, node))
        end
      end)

    local ++ remote
  end

  @doc """
  Checkout a session, optionally routing to a remote node.

  ## Node options

  - `:local` (default) — only check local pool
  - `:any` — try local first, then search remote nodes
  - `node_atom` — checkout on a specific remote node
  """
  @spec cluster_checkout(atom(), keyword()) :: {:ok, pid(), node()} | {:error, term()}
  def cluster_checkout(provider, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)

    with {:ok, opts, timeout} <- Arbor.AI.Timeout.start_deadline(opts, 30_000) do
      do_cluster_checkout(provider, opts, timeout, started_at)
    end
  end

  defp do_cluster_checkout(provider, opts, timeout, started_at) do
    {node_pref, opts} = Keyword.pop(opts, :node, :local)

    case node_pref do
      :local ->
        case checkout_before_deadline(provider, opts, timeout, started_at) do
          {:ok, pid} -> {:ok, pid, Node.self()}
          error -> error
        end

      :any ->
        # Try local first
        case checkout_before_deadline(provider, opts, timeout, started_at) do
          {:ok, pid} ->
            {:ok, pid, Node.self()}

          {:error, :pool_exhausted} ->
            # Try remote nodes
            find_remote_session(provider, opts, timeout, started_at)

          error ->
            error
        end

      target_node when is_atom(target_node) ->
        if target_node == Node.self() do
          case checkout_before_deadline(provider, opts, timeout, started_at) do
            {:ok, pid} -> {:ok, pid, Node.self()}
            error -> error
          end
        else
          remote_checkout_before_deadline(target_node, provider, opts, timeout, started_at)
        end
    end
  end

  @doc """
  Send a message to a session, handling remote sessions transparently.
  """
  @spec cluster_send_message(pid(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def cluster_send_message(session_pid, content, opts \\ []) do
    with {:ok, opts, _timeout} <- Arbor.AI.Timeout.start_deadline(opts, :infinity),
         {:ok, operation_opts, timeout} <- Arbor.AI.Timeout.remaining(opts) do
      if node(session_pid) == Node.self() do
        AcpSession.send_message(session_pid, content, operation_opts)
      else
        remote_opts = remote_deadline_opts(operation_opts)

        result =
          :rpc.call(
            node(session_pid),
            AcpSession,
            :send_message,
            [session_pid, content, remote_opts],
            timeout
          )

        case result do
          {:badrpc, reason} ->
            {:error, {:remote_call_failed, Arbor.LLM.sanitize_external_reason(reason)}}

          result ->
            case Arbor.AI.Timeout.ensure_active(opts) do
              :ok -> result
              {:error, reason} -> {:error, reason}
            end
        end
      end
    end
  end

  @doc """
  Checkin a session, handling remote sessions transparently.
  """
  @spec cluster_checkin(pid()) :: :ok | {:error, term()}
  def cluster_checkin(session_pid) do
    if node(session_pid) == Node.self() do
      checkin(session_pid)
    else
      case :rpc.call(node(session_pid), __MODULE__, :checkin, [session_pid], 5_000) do
        {:badrpc, reason} -> {:error, {:remote_call_failed, reason}}
        result -> result
      end
    end
  end

  # -- GenServer Callbacks --

  @impl true
  def init(opts) do
    config = build_config(opts)
    cleanup_ms = Keyword.get(opts, :cleanup_interval_ms, @default_cleanup_interval_ms)
    cleanup_ref = Process.send_after(self(), :cleanup_idle, cleanup_ms)

    # Join :pg group for cross-node pool discovery
    pg_join()

    # Clear the cached UnifiedLLM Client so it re-discovers adapters
    # (including ACP now that the pool is running). arbor_llm is a direct dep.
    Arbor.LLM.Client.clear_default_client()

    {:ok,
     %__MODULE__{
       config: config,
       cleanup_ref: cleanup_ref
     }}
  end

  @impl true
  def handle_call({:checkout, provider, opts, profile}, {caller_pid, _tag}, state) do
    case Arbor.AI.Timeout.ensure_active(opts) do
      :ok -> do_checkout(provider, opts, profile, caller_pid, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Backward-compatible clause if an older node still sends 3-tuples.
  def handle_call({:checkout, provider, opts}, {caller_pid, _tag}, state) do
    case Arbor.AI.Timeout.ensure_active(opts) do
      :ok ->
        case SessionProfile.from_opts(provider, opts) do
          {:ok, profile} -> do_checkout(provider, opts, profile, caller_pid, state)
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkin, session_pid}, _from, state) do
    case find_session_by_pid(state, session_pid) do
      {:ok, ref, entry} ->
        cond do
          tool_bound_session?(entry) ->
            # Provider MCP registration is immutable at create time. After the
            # per-session ToolServer is torn down the process must not be reused.
            Logger.debug("AcpPool: closing tool-enabled session #{inspect(entry.pid)} on checkin")

            state = remove_session(state, ref)
            safe_close(entry.pid)
            {:reply, :ok, state}

          true ->
            case validate_session(entry.pid) do
              :ok ->
                state = checkin_session(state, ref, entry)
                {:reply, :ok, state}

              {:error, reason} ->
                Logger.debug(
                  "AcpPool: removing non-ready session #{inspect(entry.pid)} on checkin (#{inspect(reason)})"
                )

                state = remove_session(state, ref)
                safe_close(entry.pid)
                {:reply, :ok, state}
            end
        end

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

  def handle_call({:settle_task_sessions, task_id, agent_id, opts}, from, state) do
    case Arbor.AI.Timeout.ensure_active(opts) do
      :ok ->
        settle_task_sessions_call(state, from, task_id, agent_id, opts)

      {:error, reason} ->
        # Expired preflight: leave every indexed session untouched.
        {:reply, {:error, reason}, state}
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
          task_id: entry.profile && entry.profile.task_id,
          cwd: entry.profile && entry.profile.cwd,
          model: entry.profile && entry.profile.model,
          tool_count: entry.profile && length(entry.profile.tool_modules || []),
          trust_domain: entry.profile && entry.profile.trust_domain,
          tool_server_port: entry.tool_server && entry.tool_server.port,
          taint: entry.taint,
          checkout_count: entry.checkout_count,
          checked_out_by: entry.checked_out_by,
          last_active: entry.last_active
        }
      end)

    {:reply, session_list, state}
  end

  defp do_checkout(provider, opts, %SessionProfile{} = profile, caller_pid, state) do
    case find_by_affinity(state, profile) do
      {:ok, entry, state} ->
        case checkout_compatible_session(state, entry, caller_pid) do
          {:ok, state, entry} ->
            finalize_existing_checkout(state, entry, opts)

          {:stale_closed, state} ->
            # Closed a tool-bound/stale idle entry; mint rather than reuse.
            mint_session(provider, opts, caller_pid, state, profile)
        end

      {:conflict, state} ->
        {:reply, {:error, :affinity_conflict}, state}

      {:busy, state} ->
        {:reply, {:error, :affinity_busy}, state}

      {:no_affinity, state} ->
        case find_compatible_session(state, profile) do
          {:ok, entry, state} ->
            case checkout_compatible_session(state, entry, caller_pid) do
              {:ok, state, entry} ->
                finalize_existing_checkout(state, entry, opts)

              {:stale_closed, state} ->
                mint_session(provider, opts, caller_pid, state, profile)
            end

          {:none, state} ->
            mint_session(provider, opts, caller_pid, state, profile)
        end
    end
  end

  defp mint_session(provider, opts, caller_pid, state, profile) do
    max = max_for_provider(state.config, provider)
    current = count_for_provider(state, provider)

    cond do
      current < max ->
        do_mint_session(provider, opts, caller_pid, state, profile)

      true ->
        # Idle pool entries are a capacity cache, not a permanent reservation.
        # On an incompatible miss at max, reclaim the LRU idle entry so a new
        # task/profile can progress. Checked-out sessions stay busy.
        case evict_lru_idle_for_capacity(state, provider) do
          {:ok, state} ->
            do_mint_session(provider, opts, caller_pid, state, profile)

          :none ->
            {:reply, {:error, :pool_exhausted}, state}
        end
    end
  end

  defp do_mint_session(provider, opts, caller_pid, state, profile) do
    case spawn_session(provider, opts, caller_pid, profile) do
      {:ok, pid, tool_server} ->
        case Arbor.AI.Timeout.ensure_active(opts) do
          :ok ->
            {state, _ref} = register_session(state, pid, profile, caller_pid, tool_server)

            Logger.debug("AcpPool: minted #{profile.name} (#{SessionProfile.urn(profile)})")

            {:reply, {:ok, pid}, state}

          {:error, reason} ->
            cleanup_expired_spawn(pid, tool_server)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:spawn_failed, reason}}, state}
    end
  end

  # Reclaim one idle session for `provider` using least-recently-active order.
  # Logical pool indexes/monitors may be reclaimed immediately; the process is
  # closed through the bounded graceful path (AcpSession.close via safe_close)
  # so terminate/2 still runs provider settlement, client disconnect, and any
  # session-owned worktree cleanup. Busy sessions are never candidates — their
  # presence at capacity remains `:pool_exhausted`.
  defp evict_lru_idle_for_capacity(state, provider) do
    idle =
      state.by_provider
      |> Map.get(provider, MapSet.new())
      |> Enum.reduce([], fn ref, acc ->
        case Map.get(state.sessions, ref) do
          %Entry{status: :idle} = entry ->
            [{ref, entry} | acc]

          _ ->
            acc
        end
      end)

    case idle do
      [] ->
        :none

      candidates ->
        {ref, entry} =
          Enum.min_by(candidates, fn {_ref, e} ->
            e.last_active || 0
          end)

        name = (entry.profile && entry.profile.name) || inspect(entry.pid)

        Logger.debug("AcpPool: evicting idle session #{name} for capacity (provider=#{provider})")

        # Reclaim capacity indexes first, then graceful close (not Process.exit kill).
        state = remove_session(state, ref)
        safe_close(entry.pid)

        {:ok, state}
    end
  end

  defp finalize_existing_checkout(state, entry, opts) do
    case Arbor.AI.Timeout.ensure_active(opts) do
      :ok -> {:reply, {:ok, entry.pid}, state}
      {:error, reason} -> {:reply, {:error, reason}, rollback_checkout(state, entry.ref)}
    end
  end

  defp rollback_checkout(state, ref) do
    {caller_refs, monitors} =
      Enum.reduce(state.monitors, {[], state.monitors}, fn
        {monitor, {:caller, ^ref}}, {refs, acc} ->
          {[monitor | refs], Map.delete(acc, monitor)}

        _entry, acc ->
          acc
      end)

    Enum.each(caller_refs, &Process.demonitor(&1, [:flush]))

    sessions =
      Map.update!(state.sessions, ref, fn entry ->
        stop_tool_server_async(entry.tool_server)

        %{
          entry
          | status: :idle,
            checked_out_by: nil,
            tool_server: nil,
            taint: :tainted,
            last_active: System.monotonic_time(:millisecond)
        }
      end)

    %{state | sessions: sessions, monitors: monitors}
  end

  # Post-spawn deadline / await_ready failure: same graceful close path as
  # eviction/idle cleanup so AcpSession.terminate/2 still disconnects the client
  # and cleans session-owned workspaces. Never Process.exit(:kill) here.
  defp cleanup_expired_spawn(pid, tool_server) do
    safe_close(pid)
    if tool_server, do: stop_tool_server_async(tool_server)

    :ok
  end

  defp stop_tool_server_async(nil), do: :ok

  defp stop_tool_server_async(tool_server) do
    Task.start(fn -> ToolServer.stop(tool_server.ref) end)
    :ok
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
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
        case find_settlement_by_worker_ref(state, monitor_ref) do
          {:ok, key, settlement} ->
            # Worker crashed before reporting. Force-confirm survivors so we
            # never forget a live detached process, then reply to waiters.
            result = finalize_orphaned_settlement(settlement, reason)
            state = complete_settlement(state, key, settlement, result)
            {:noreply, state}

          :not_found ->
            {:noreply, state}
        end
    end
  end

  def handle_info({:settlement_finished, key, result}, state) do
    case Map.get(state.settlements, key) do
      %Settlement{} = settlement ->
        # Drop the worker monitor; normal exit may still race a DOWN.
        if is_reference(settlement.worker_ref) do
          Process.demonitor(settlement.worker_ref, [:flush])
        end

        state = complete_settlement(state, key, settlement, result)
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
      if entry.tool_server, do: ToolServer.stop(entry.tool_server.ref)
      safe_close(entry.pid)
    end)

    # Best-effort force of any detached settlement survivors so terminate does
    # not strand live processes outside the pool indexes.
    Enum.each(state.settlements, fn {_key, %Settlement{pids: pids}} ->
      force_terminate_pids(pids)
    end)

    :ok
  end

  # -- Private: Matching --

  # Hard affinity: if the request has an affinity_key, find the exact session.
  # Affinity never bypasses SessionProfile.compatible?/2.
  defp find_by_affinity(state, %SessionProfile{affinity_key: nil}), do: {:no_affinity, state}

  defp find_by_affinity(state, %SessionProfile{affinity_key: key} = requested) do
    case Map.get(state.by_affinity, key) do
      nil ->
        {:no_affinity, state}

      ref ->
        case Map.get(state.sessions, ref) do
          %Entry{status: :idle, pid: pid, profile: profile} = entry ->
            if SessionProfile.compatible?(requested, profile) do
              case validate_session(pid) do
                :ok ->
                  {:ok, entry, state}

                {:error, _} ->
                  safe_close(pid)
                  {:no_affinity, remove_session(state, ref)}
              end
            else
              {:conflict, state}
            end

          %Entry{status: :checked_out, profile: profile} ->
            if SessionProfile.compatible?(requested, profile) do
              # Busy same-affinity checkout must not mint a duplicate or overwrite.
              {:busy, state}
            else
              {:conflict, state}
            end

          %Entry{status: :checked_out} ->
            {:busy, state}

          nil ->
            # Stale affinity index — drop it and treat as no affinity.
            {:no_affinity, %{state | by_affinity: Map.delete(state.by_affinity, key)}}
        end
    end
  end

  # Profile-compatible matching: full immutable SessionProfile must match.
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

        cond do
          tool_bound_session?(entry) ->
            # Idle tool-bound entry is always stale; close and keep searching.
            Logger.debug("AcpPool: removing stale tool-bound session #{inspect(pid)}")
            safe_close(pid)
            state = remove_session(state, ref)
            try_compatible_refs(state, rest, requested)

          not affinity_reserved and SessionProfile.compatible?(requested, profile) ->
            case validate_session(pid) do
              :ok ->
                {:ok, entry, state}

              {:error, _reason} ->
                Logger.debug("AcpPool: removing unhealthy session #{inspect(pid)}")
                safe_close(pid)
                state = remove_session(state, ref)
                try_compatible_refs(state, rest, requested)
            end

          true ->
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

  # Spawn using validated SessionProfile bindings for cwd/model/workspace so the
  # session process identity matches profile_hash (no independent re-expand of
  # raw opts). ToolServer FS scope comes from profile.tool_workspace only.
  defp spawn_session(provider, opts, caller_pid, %SessionProfile{} = profile) do
    with {:ok, opts} <- adopt_grok_sandbox_authority(provider, caller_pid, opts) do
      do_spawn_session(provider, opts, profile)
    end
  end

  defp do_spawn_session(provider, opts, %SessionProfile{} = profile) do
    tool_modules = profile.tool_modules || []
    agent_id = profile.agent_id
    tool_workspace = profile.tool_workspace

    # Start a ToolServer if the session needs action tools
    {tool_server, mcp_servers} = maybe_start_tool_server(tool_modules, agent_id, tool_workspace)

    # Pool always owns pooled session lifecycle — never adopt caller-supplied owner.
    session_opts =
      opts
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:owner, self())
      |> Keyword.put_new(:client_opts, Keyword.get(opts, :client_opts))
      |> Keyword.put(:agent_id, agent_id)

    # Pass mcp_servers so AcpSession can include them in create_session
    session_opts =
      if mcp_servers do
        Keyword.put(session_opts, :mcp_servers, mcp_servers)
      else
        session_opts
      end

    # Drop pool/matching keys and raw cwd/model/workspace — re-bind from the
    # profile so AcpSession receives the exact canonical values used for reuse
    # identity. Managed-only keys (server, session_id, create_session) are
    # stripped by AcpManaged before checkout — not silently dropped here.
    pool_only_keys = [
      :tool_modules,
      :trust_domain,
      :affinity_key,
      :name,
      :tags,
      :task_id,
      :principal_id,
      :cwd,
      :model,
      :workspace,
      :owner
    ]

    session_opts =
      session_opts
      |> Keyword.drop(pool_only_keys)
      |> Keyword.merge(SessionProfile.session_binding(profile))
      |> Keyword.put(:owner, self())

    deadline = Keyword.fetch!(opts, :deadline_ms)

    case ManagedSupervisor.start_session(AcpSession, session_opts,
           supervisor: Arbor.AI.AcpPool.Supervisor,
           deadline_ms: deadline
         ) do
      {:ok, pid} ->
        case AcpSession.await_ready(pid, opts) do
          :ok ->
            {:ok, pid, tool_server}

          {:error, reason} ->
            cleanup_expired_spawn(pid, tool_server)
            {:error, reason}
        end

      {:error, reason} ->
        # Clean up ToolServer if session failed to start
        if tool_server, do: ToolServer.stop(tool_server.ref)
        {:error, reason}
    end
  end

  defp adopt_grok_sandbox_authority(:grok, caller_pid, opts) do
    case Keyword.get(opts, :grok_sandbox_authority) do
      nil ->
        {:ok, opts}

      authority ->
        with {:ok, authority} <- GrokSandbox.adopt_authority(caller_pid, authority) do
          {:ok, Keyword.put(opts, :grok_sandbox_authority, authority)}
        end
    end
  end

  defp adopt_grok_sandbox_authority(_provider, _caller_pid, opts), do: {:ok, opts}

  defp maybe_start_tool_server([], _agent_id, _workspace), do: {nil, nil}

  defp maybe_start_tool_server(tool_modules, agent_id, workspace)
       when is_list(tool_modules) do
    start_opts =
      [agent_id: agent_id || "anonymous"]
      |> maybe_put(:workspace, workspace)

    case ToolServer.start(tool_modules, start_opts) do
      {:ok, %{port: port} = info} ->
        {info, ToolServer.mcp_servers_entry(port)}

      {:error, reason} ->
        Logger.warning(
          "AcpPool: failed to start ToolServer: #{Arbor.LLM.inspect_external_reason(reason)}"
        )

        {nil, nil}
    end
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp register_session(state, pid, %SessionProfile{} = profile, caller_pid, tool_server) do
    ref = make_ref()
    now = System.monotonic_time(:millisecond)

    session_mon = Process.monitor(pid)
    caller_mon = Process.monitor(caller_pid)

    entry = %Entry{
      pid: pid,
      provider: profile.provider,
      ref: ref,
      profile: profile,
      tool_server: tool_server,
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

  # Compatible idle reuse only for non-tool sessions. Tool-bound or stale
  # tool-profile entries must never be checked out (provider MCP is immutable).
  defp checkout_compatible_session(state, entry, caller_pid) do
    if tool_bound_session?(entry) do
      Logger.debug(
        "AcpPool: refusing tool-bound/stale session #{inspect(entry.pid)}; closing and minting"
      )

      state = remove_session(state, entry.ref)
      safe_close(entry.pid)
      {:stale_closed, state}
    else
      state = checkout_session(state, entry.ref, caller_pid, nil)
      entry = Map.fetch!(state.sessions, entry.ref)
      {:ok, state, entry}
    end
  end

  defp checkout_session(state, ref, caller_pid, tool_server) do
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
                tool_server: tool_server,
                last_active: now,
                checkout_count: entry.checkout_count + 1
            }
          end),
        monitors: Map.put(state.monitors, caller_mon, {:caller, ref})
    }
  end

  defp checkin_session(state, ref, _entry) do
    now = System.monotonic_time(:millisecond)
    monitors = demonitor_callers(state.monitors, ref)

    %{
      state
      | sessions:
          Map.update!(state.sessions, ref, fn entry ->
            if entry.tool_server do
              ToolServer.stop(entry.tool_server.ref)
            end

            %{
              entry
              | status: :idle,
                checked_out_by: nil,
                tool_server: nil,
                taint: :tainted,
                last_active: now
            }
          end),
        monitors: monitors
    }
  end

  defp auto_checkin(state, monitor_ref, session_ref) do
    monitors = Map.delete(state.monitors, monitor_ref)

    case Map.get(state.sessions, session_ref) do
      %Entry{status: :checked_out} = entry ->
        if tool_bound_session?(entry) do
          Logger.debug(
            "AcpPool: closing tool-enabled session #{inspect(entry.pid)} on auto-checkin"
          )

          state = %{state | monitors: monitors}
          state = remove_session(state, session_ref)
          safe_close(entry.pid)
          state
        else
          now = System.monotonic_time(:millisecond)

          if entry.tool_server do
            ToolServer.stop(entry.tool_server.ref)
          end

          sessions =
            Map.update!(state.sessions, session_ref, fn e ->
              %{
                e
                | status: :idle,
                  checked_out_by: nil,
                  tool_server: nil,
                  taint: :tainted,
                  last_active: now
              }
            end)

          %{state | sessions: sessions, monitors: monitors}
        end

      _ ->
        %{state | monitors: monitors}
    end
  end

  defp tool_bound_session?(%Entry{tool_server: tool_server}) when not is_nil(tool_server),
    do: true

  defp tool_bound_session?(%Entry{profile: %SessionProfile{} = profile}),
    do: SessionProfile.tool_enabled?(profile)

  defp tool_bound_session?(_), do: false

  defp demonitor_callers(monitors, ref) do
    Enum.reduce(monitors, monitors, fn
      {mon_ref, {:caller, ^ref}}, acc ->
        Process.demonitor(mon_ref, [:flush])
        Map.delete(acc, mon_ref)

      _, acc ->
        acc
    end)
  end

  defp remove_session(state, ref) do
    entry = Map.get(state.sessions, ref)

    # Stop fate-shared ToolServer if present
    if entry && entry.tool_server do
      ToolServer.stop(entry.tool_server.ref)
    end

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

  # Exact task+agent settlement:
  # 1. Join any in-progress settlement for the same pair (never false no-match).
  # 2. Refuse busy matches without mutation.
  # 3. Atomically detach only when every exact match is idle.
  # 4. Close off-GenServer under one shared deadline; reply when confirmed.
  defp settle_task_sessions_call(state, from, task_id, agent_id, opts) do
    key = settlement_key(task_id, agent_id)

    case Map.get(state.settlements, key) do
      %Settlement{worker_ref: nil} = settlement ->
        # Detached survivors remain tracked without an active worker. Re-arm
        # force cleanup rather than reporting no-match success.
        state = start_force_settlement_worker(state, key, settlement, from, opts)
        {:noreply, state}

      %Settlement{} = settlement ->
        settlement = %{settlement | callers: settlement.callers ++ [from]}
        settlements = Map.put(state.settlements, key, settlement)
        {:noreply, %{state | settlements: settlements}}

      nil ->
        matches =
          Enum.filter(state.sessions, fn {_ref, entry} ->
            profile = entry.profile

            match?(%SessionProfile{}, profile) and profile.task_id == task_id and
              profile.agent_id == agent_id
          end)

        busy? = Enum.any?(matches, fn {_ref, entry} -> entry.status == :checked_out end)

        cond do
          busy? ->
            {:reply, {:error, :sessions_busy}, state}

          matches == [] ->
            {:reply, {:ok, settlement_receipt(task_id, agent_id, 0)}, state}

          true ->
            {detached, state} =
              Enum.reduce(matches, {[], state}, fn {ref, entry}, {pids, acc} ->
                {[entry.pid | pids], remove_session(acc, ref)}
              end)

            pids = Enum.reverse(detached)

            settlement = %Settlement{
              task_id: task_id,
              agent_id: agent_id,
              pids: pids,
              detached_count: length(pids),
              worker_pid: nil,
              worker_ref: nil,
              callers: [from]
            }

            state = start_settlement_worker(state, key, settlement, opts, :full)
            {:noreply, state}
        end
    end
  end

  defp settlement_key(task_id, agent_id), do: {task_id, agent_id}

  defp settlement_receipt(task_id, agent_id, settled_count) do
    %{
      "agent_id" => agent_id,
      "settled_count" => settled_count,
      "status" => "settled",
      "task_id" => task_id
    }
  end

  defp normalize_settlement_result(:ok, task_id, agent_id, settled_count) do
    {:ok, settlement_receipt(task_id, agent_id, settled_count)}
  end

  defp normalize_settlement_result({:error, reason}, _task_id, _agent_id, _settled_count) do
    {:error, reason}
  end

  defp start_settlement_worker(state, key, %Settlement{} = settlement, opts, mode) do
    pool = self()
    pids = settlement.pids
    task_id = settlement.task_id
    agent_id = settlement.agent_id
    count = settlement.detached_count

    {worker_pid, worker_ref} =
      spawn_monitor(fn ->
        result =
          case mode do
            :full -> settle_detached_sessions(pids, opts)
            :force -> force_only_settlement(pids)
          end

        reply = normalize_settlement_result(result, task_id, agent_id, count)
        send(pool, {:settlement_finished, key, reply})
      end)

    settlement = %{settlement | worker_pid: worker_pid, worker_ref: worker_ref}
    %{state | settlements: Map.put(state.settlements, key, settlement)}
  end

  defp start_force_settlement_worker(state, key, settlement, from, opts) do
    settlement = %{settlement | callers: settlement.callers ++ [from]}
    start_settlement_worker(state, key, settlement, opts, :force)
  end

  defp force_only_settlement(pids) do
    case force_terminate_and_confirm(pids, 1_000) do
      :ok ->
        :ok

      {:error, failures} ->
        {:error, {:settlement_close_failed, sanitize_close_failures(failures)}}
    end
  end

  # Reply to waiters. Clear the settlement only when every detached process is
  # confirmed down — otherwise keep survivors tracked so a later retry cannot
  # report false no-match success while a live process remains unindexed.
  defp complete_settlement(state, key, %Settlement{} = settlement, result) do
    Enum.each(settlement.callers, fn caller ->
      GenServer.reply(caller, result)
    end)

    survivors =
      settlement.pids
      |> List.wrap()
      |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))

    if survivors == [] do
      %{state | settlements: Map.delete(state.settlements, key)}
    else
      residual = %{
        settlement
        | pids: survivors,
          callers: [],
          worker_pid: nil,
          worker_ref: nil
      }

      %{state | settlements: Map.put(state.settlements, key, residual)}
    end
  end

  defp find_settlement_by_worker_ref(state, worker_ref) do
    Enum.find_value(state.settlements, :not_found, fn {key, %Settlement{} = settlement} ->
      if is_reference(worker_ref) and settlement.worker_ref == worker_ref do
        {:ok, key, settlement}
      end
    end)
  end

  # Worker vanished without a normal finish report: force-confirm survivors.
  # complete_settlement keeps any remaining live pids tracked.
  defp finalize_orphaned_settlement(%Settlement{} = settlement, reason) do
    case force_terminate_and_confirm(List.wrap(settlement.pids), 1_000) do
      :ok ->
        {:ok,
         settlement_receipt(settlement.task_id, settlement.agent_id, settlement.detached_count)}

      {:error, failures} ->
        {:error,
         {:settlement_close_failed,
          sanitize_close_failures([
            {:worker_crashed, Arbor.LLM.sanitize_external_reason(reason)} | failures
          ])}}
    end
  end

  # Runs outside the pool GenServer. Shared wall-clock deadline across every
  # detached pid (parallel graceful attempts), then force-confirm survivors.
  # Graceful attempts reserve a small tail of the deadline for force-confirm so
  # one slow close cannot consume the entire budget alone.
  defp settle_detached_sessions(pids, opts) when is_list(pids) do
    close_opts = close_opts(opts)
    parent = self()
    now = System.monotonic_time(:millisecond)

    {graceful_deadline, confirm_ms} =
      case Arbor.AI.Timeout.remaining(opts) do
        {:ok, _opts, remaining} when is_integer(remaining) and remaining > 500 ->
          confirm_ms = min(1_000, div(remaining, 4))
          {now + (remaining - confirm_ms), confirm_ms}

        {:ok, _opts, remaining} when is_integer(remaining) and remaining >= 0 ->
          {now, max(remaining, 250)}

        {:ok, _opts, :infinity} ->
          {:infinity, 1_000}

        {:error, _} ->
          {now, 250}
      end

    Enum.each(pids, fn pid ->
      spawn(fn ->
        _ = attempt_session_close(pid, close_opts)
        send(parent, {:settlement_close_attempted, pid})
      end)
    end)

    _ = await_close_attempts(MapSet.new(pids), graceful_deadline)

    case force_terminate_and_confirm(pids, confirm_ms) do
      :ok ->
        :ok

      {:error, failures} ->
        {:error, {:settlement_close_failed, sanitize_close_failures(failures)}}
    end
  end

  defp await_close_attempts(%MapSet{} = pending, deadline) do
    if MapSet.size(pending) == 0 do
      :ok
    else
      do_await_close_attempts(pending, deadline)
    end
  end

  defp do_await_close_attempts(pending, :infinity) do
    receive do
      {:settlement_close_attempted, pid} ->
        await_close_attempts(MapSet.delete(pending, pid), :infinity)
    end
  end

  defp do_await_close_attempts(pending, deadline) when is_integer(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:settlement_close_attempted, pid} ->
        await_close_attempts(MapSet.delete(pending, pid), deadline)
    after
      remaining ->
        :timeout
    end
  end

  defp attempt_session_close(pid, opts) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        case session_close(pid, opts) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, {:unexpected_close_result, other}}
        end
      rescue
        exception ->
          {:error, Exception.message(exception)}
      catch
        :exit, {:noproc, _} -> :ok
        :exit, {:normal, _} -> :ok
        :exit, reason -> {:error, Arbor.LLM.sanitize_external_reason(reason)}
      end
    else
      :ok
    end
  end

  defp attempt_session_close(_pid, _opts), do: :ok

  # Same-library test seam: production always uses AcpSession.close/2. Tests
  # may install an MFA via Application env; never accepted through public API.
  defp session_close(pid, opts) do
    case Application.get_env(:arbor_ai, :acp_pool_session_close_mfa) do
      {mod, fun, extra} when is_atom(mod) and is_atom(fun) and is_list(extra) ->
        apply(mod, fun, [pid, opts | extra])

      _ ->
        AcpSession.close(pid, opts)
    end
  end

  defp force_terminate_pids(pids) when is_list(pids) do
    Enum.each(pids, fn pid ->
      if is_pid(pid) and Process.alive?(pid) do
        try do
          Process.unlink(pid)
        catch
          :error, _ -> :ok
        end

        Process.exit(pid, :kill)
      end
    end)
  end

  # Monitor first, then kill, so we never race past an already-dead process
  # without a positive confirmation signal.
  defp force_terminate_and_confirm(pids, timeout_ms)
       when is_list(pids) and is_integer(timeout_ms) do
    monitors =
      pids
      |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))
      |> Enum.map(fn pid ->
        ref = Process.monitor(pid)

        try do
          Process.unlink(pid)
        catch
          :error, _ -> :ok
        end

        Process.exit(pid, :kill)
        {pid, ref}
      end)

    deadline = System.monotonic_time(:millisecond) + max(timeout_ms, 0)
    await_monitors_down(monitors, deadline)
  end

  defp await_monitors_down([], _deadline), do: :ok

  defp await_monitors_down(monitors, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, pid, _reason} ->
        monitors =
          Enum.reject(monitors, fn {m_pid, m_ref} -> m_ref == ref or m_pid == pid end)

        await_monitors_down(monitors, deadline)
    after
      remaining ->
        survivors =
          Enum.filter(monitors, fn {pid, ref} ->
            Process.demonitor(ref, [:flush])
            Process.alive?(pid)
          end)

        if survivors == [] do
          :ok
        else
          failures =
            Enum.map(survivors, fn _ ->
              {:process_still_alive, :close_timeout}
            end)

          {:error, failures}
        end
    end
  end

  defp close_opts(opts) when is_list(opts) do
    timeout_keys = Arbor.LLM.timeout_option_keys()

    Enum.filter(opts, fn
      {key, _value} when is_atom(key) -> key == :deadline_ms or key in timeout_keys
      _ -> false
    end)
  end

  # Receipts / errors must stay JSON-clean — never echo PIDs.
  defp sanitize_close_failures(failures) when is_list(failures) do
    Enum.map(failures, fn
      {marker, reason} ->
        {marker, Arbor.LLM.sanitize_external_reason(reason)}

      other ->
        Arbor.LLM.sanitize_external_reason(other)
    end)
  end

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

  # -- Private: Distributed Discovery --

  defp pg_join do
    try do
      # Start the :pg scope if not already running
      case :pg.start_link(@pg_scope) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end

      :pg.join(@pg_scope, @pg_group, self())
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end

  defp remote_nodes do
    try do
      :pg.get_members(@pg_scope, @pg_group)
      |> Enum.map(&node/1)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == Node.self()))
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp safe_call(msg) do
    try do
      GenServer.call(__MODULE__, msg, 5_000)
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end

  defp find_remote_session(provider, opts, timeout, started_at) do
    nodes = remote_nodes()

    Enum.find_value(nodes, {:error, :pool_exhausted}, fn node ->
      case remote_checkout_before_deadline(node, provider, opts, timeout, started_at) do
        {:ok, pid, ^node} -> {:ok, pid, node}
        {:error, :timeout} = error -> error
        _ -> nil
      end
    end)
  end

  defp checkout_before_deadline(provider, opts, timeout, started_at) do
    with {:ok, opts} <- remaining_timeout_options(opts, timeout, started_at) do
      checkout(provider, opts)
    end
  end

  defp remote_checkout_before_deadline(target_node, provider, opts, timeout, started_at) do
    with {:ok, opts} <- remaining_timeout_options(opts, timeout, started_at) do
      remote_checkout(target_node, provider, opts)
    end
  end

  defp remaining_timeout_options(opts, :infinity, _started_at),
    do: remaining_deadline_options(opts)

  defp remaining_timeout_options(opts, _timeout, _started_at),
    do: remaining_deadline_options(opts)

  defp remaining_deadline_options(opts) do
    case Arbor.AI.Timeout.remaining(opts) do
      {:ok, remaining_opts, _remaining} -> {:ok, remaining_opts}
      {:error, _reason} = error -> error
    end
  end

  defp remote_checkout(target_node, provider, opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    rpc_timeout = if timeout == :infinity, do: 10_000, else: min(timeout, 10_000)
    remote_opts = remote_deadline_opts(opts)

    case :rpc.call(target_node, __MODULE__, :checkout, [provider, remote_opts], rpc_timeout) do
      {:ok, pid} ->
        case Arbor.AI.Timeout.ensure_active(opts) do
          :ok ->
            {:ok, pid, target_node}

          {:error, reason} ->
            :rpc.cast(target_node, __MODULE__, :checkin, [pid])
            {:error, reason}
        end

      {:badrpc, reason} ->
        {:error, {:remote_call_failed, target_node, Arbor.LLM.sanitize_external_reason(reason)}}

      error ->
        error
    end
  end

  # Monotonic timestamps are VM-local. Preserve the remaining duration across
  # an RPC boundary and let the destination VM mint its own absolute deadline.
  defp remote_deadline_opts(opts), do: Keyword.delete(opts, :deadline_ms)

  defp safe_pool_call(message, timeout) do
    GenServer.call(__MODULE__, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, {:noproc, _call} -> {:error, :pool_unavailable}
    :exit, reason -> {:error, {:pool_call_failed, Arbor.LLM.sanitize_external_reason(reason)}}
  end
end
