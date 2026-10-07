defmodule Arbor.Signals.Relay do
  @moduledoc """
  Cross-node signal relay using `:pg` process groups.

  Each node runs one Relay process that:
  1. Receives cluster-scoped signals from the local Bus
  2. Batches them into windows (default 50ms)
  3. Forwards batched signals to peer Relay processes via `:erpc`
  4. Receives batched signals from peers and injects them into the local Bus

  ## Architecture

  Hub-and-spoke model — one Relay per node, all in a shared `:pg` group.
  The Relay is the normal egress/ingress point for cross-node signals,
  which makes it the natural place for rate limiting and load shedding.

  ## Cluster Trust Boundary

  Every holder of the Erlang distribution cookie is a cluster root. A peer can
  execute arbitrary RPC on connected nodes. Within the application boundary,
  the supervised Bus and Relay share an opaque custody reference, and peer
  Relays establish a credential for the exact peer process before exchanging batches.
  Origin attribution is derived from the credential-bound peer pid rather than
  a caller-supplied node atom. These checks prevent an ordinary local process
  from laundering a forged signal through the trusted services; they do not
  reduce the Erlang cookie's cluster-root authority.

  ## Load Shedding (Phase 5)

  When the outbound queue exceeds `max_batch_size`, low-priority signals
  are dropped. Priority order (highest to lowest):
  1. `:security` — never dropped
  2. `:trust`, `:consensus` — dropped only under extreme pressure
  3. `:agent`, `:orchestrator` — dropped when queue is full

  Per-category token bucket rate limiting prevents any single category
  from flooding the relay. Dropped signals are logged as telemetry.

  ## Ingress Hardening (Phase 6)

  - Credential-bound peer validation: received batches must possess a token
    issued to an exact `:pg` Relay pid
  - Per-node ingress rate limiting: prevents flood from a single peer
  - SafeAtom validation on incoming signal metadata keys

  ## Configuration

      config :arbor_kernel,
        signals: [
          relay_batch_interval_ms: 50,
          relay_max_batch_size: 500,
          relay_enabled: true,
          # Per-category tokens per second (default 100/s per category)
          relay_category_rate_limit: 100,
          # Per-node ingress rate limit (signals per second, default 1000/s)
          relay_node_rate_limit: 1000
        ]
  """

  use GenServer

  require Logger

  alias Arbor.Signals.Bus
  alias Arbor.Signals.Config
  alias Arbor.Signals.Signal

  @pg_group {:arbor, :signal_relays}
  @bus_reregister_delay_ms 25
  @peer_verify_timeout_ms 250
  @peer_handshake_retry_ms 50
  @peer_handshake_max_attempts 40
  @max_pending_batches_per_peer 16
  @max_pending_peer_verifications 64
  @custody_directory :arbor_signals_relay_custody_directory
  @proof_bytes 32
  @test_env Application.compile_env(:arbor_kernel_runtime, :expose_test_fixtures, false)

  # Priority levels for load shedding (lower = higher priority = shed last)
  @category_priority %{
    security: 0,
    trust: 1,
    consensus: 1,
    agent: 2,
    orchestrator: 2
  }

  # Metadata keys that are safe to atomize from remote signals
  @safe_metadata_keys ~w(agent_id node pipeline_id run_id channel_id source)

  # Closed security-sync mutation types. Without authenticated transport,
  # only these remote types are dropped. Observability events and
  # nonce_seen stay injectable; CapabilityStore / Identity.Registry remain
  # fail-closed for remote mutations on apply.
  @restricted_security_sync_mutations [
    :capability_granted,
    :capability_revoked,
    :capabilities_revoked_all,
    :capabilities_cascade_revoked,
    :capabilities_scope_revoked,
    :identity_registered,
    :identity_deregistered,
    :identity_suspended,
    :identity_resumed,
    :identity_revoked
  ]

  # ── Client API ──────────────────────────────────────────────────────

  @doc "Start the relay process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Forward a cluster-scoped signal to peer nodes.

  Called by the Bus after local delivery. The signal is queued and
  sent in the next batch window.
  """
  @spec relay(Signal.t()) :: :ok | {:error, :unauthorized}
  def relay(%Signal{}), do: {:error, :unauthorized}

  @doc false
  @spec relay(Signal.t(), binary() | nil) :: :ok | {:error, :unauthorized}
  def relay(%Signal{} = signal, proof)
      when is_binary(proof) and byte_size(proof) == @proof_bytes do
    if enabled?() and Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:relay, signal, proof})
      :ok
    else
      :ok
    end
  end

  def relay(%Signal{}, _invalid_proof), do: {:error, :unauthorized}

  @doc false
  @spec custody_directory() :: atom()
  def custody_directory, do: @custody_directory

  if @test_env do
    @doc false
    def relay_fixture(%Signal{} = signal) do
      GenServer.call(__MODULE__, {:relay_fixture, signal})
    end

    @doc false
    def receive_batch_fixture(signals, from_node) when is_list(signals) and is_atom(from_node) do
      GenServer.call(__MODULE__, {:receive_batch_fixture, signals, from_node})
    end

    @doc false
    def reset_fixture do
      GenServer.call(__MODULE__, :reset_fixture)
    end
  end

  @doc "Get relay statistics."
  @spec stats() :: map()
  def stats do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :stats)
    else
      %{status: :not_running}
    end
  end

  @doc "Check if the relay is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Config.relay_enabled?()
  end

  # ── Server Callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    Process.flag(:sensitive, true)
    custody = new_custody!()

    state =
      if enabled?() do
        # Join the :pg group for relay discovery.
        join_pg_group()

        # Schedule first batch flush.
        Process.send_after(self(), :flush_batch, batch_interval_ms())

        %{
          batch: [],
          batch_size: 0,
          bus_pid: nil,
          bus_monitor_ref: nil,
          custody: custody,
          # Peer ingress uses possession-based credentials. The sender pid in
          # an ordinary BEAM message is caller-controlled data; the opaque
          # token proves that the batch followed the Relay-to-Relay handshake.
          pending_ingress: %{},
          verified_peers: MapSet.new(),
          pending_peer_verification_count: 0,
          # Phase 5: per-category token buckets {category => {tokens, last_refill_time}}
          rate_buckets: %{},
          # Phase 6: per-node ingress counters {node => {count, window_start}}
          node_counters: %{},
          stats: %{
            relayed_out: 0,
            relayed_in: 0,
            batches_sent: 0,
            signals_dropped: 0,
            signals_rate_limited: 0,
            signals_rejected: 0,
            peers_seen: 0
          }
        }
      else
        %{
          batch: [],
          batch_size: 0,
          bus_pid: nil,
          bus_monitor_ref: nil,
          custody: custody,
          pending_ingress: %{},
          verified_peers: MapSet.new(),
          pending_peer_verification_count: 0,
          rate_buckets: %{},
          node_counters: %{},
          stats: %{status: :disabled}
        }
      end

    # Registration is deferred until after init acknowledges the child start.
    # The parent supervisor can then answer the Bus's provenance query without
    # deadlocking on this child's in-progress start.
    {:ok, state, {:continue, :register_with_bus}}
  end

  @impl true
  def handle_continue(:register_with_bus, state) do
    {:noreply, register_with_bus(state)}
  end

  @impl true
  if @test_env do
    def handle_call({:relay_fixture, %Signal{} = signal}, _from, state) do
      {:reply, :ok, enqueue_signal(signal, state)}
    end

    def handle_call({:receive_batch_fixture, signals, from_node}, _from, state)
        when is_list(signals) and is_atom(from_node) do
      {:reply, :ok, admit_batch(signals, from_node, state)}
    end

    def handle_call(:reset_fixture, _from, state) do
      clear_peer_custody(state)
      {:reply, :ok, reset_runtime_state(state)}
    end
  end

  def handle_call(:stats, _from, state) do
    stats =
      Map.merge(state.stats, %{
        batch_pending: state.batch_size,
        peers_connected: count_peers(),
        enabled: enabled?()
      })

    {:reply, stats, state}
  end

  def handle_call(_unknown, _from, state),
    do: {:reply, {:error, :unsupported_request}, state}

  @impl true
  def handle_cast({:relay, %Signal{} = signal, proof}, state) do
    if custody_matches?(state, :bus_proof, proof) do
      {:noreply, enqueue_signal(signal, state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast(_unknown, state), do: {:noreply, state}

  defp enqueue_signal(%Signal{} = signal, state) do
    # Phase 5: Check per-category rate limit before queuing
    {allowed, state} = check_category_rate(signal.category, state)

    if allowed do
      max_batch = max_batch_size()

      if state.batch_size >= max_batch do
        # Load shedding — try to drop lowest priority signal
        shed_or_drop(signal, state)
      else
        %{state | batch: [signal | state.batch], batch_size: state.batch_size + 1}
      end
    else
      # Rate limited — drop and count
      stats = Map.update!(state.stats, :signals_rate_limited, &(&1 + 1))
      %{state | stats: stats}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, bus_pid, _reason},
        %{bus_monitor_ref: ref, bus_pid: bus_pid} = state
      ) do
    Process.send_after(self(), :register_with_bus, @bus_reregister_delay_ms)
    {:noreply, %{state | bus_pid: nil, bus_monitor_ref: nil}}
  end

  def handle_info(:register_with_bus, state) do
    {:noreply, register_with_bus(state)}
  end

  # A peer asks for a credential it can use to submit batches to this Relay.
  # The credential is returned to the claimed pid, so forging `peer_pid` only
  # discloses it to the legitimate peer. Subsequent batches must possess it.
  def handle_info({:open_ingress, peer_pid, challenge}, state)
      when is_pid(peer_pid) and is_reference(challenge) do
    {:noreply, request_peer_verification(peer_pid, {:grant_ingress, challenge}, state)}
  end

  def handle_info({:ingress_opened, peer_pid, challenge, token}, state)
      when is_pid(peer_pid) and is_reference(challenge) and is_binary(token) and
             byte_size(token) == @proof_bytes do
    case {Map.get(state.pending_ingress, peer_pid),
          custody_fetch(state, {:peer_challenge, peer_pid})} do
      {%{}, {:ok, ^challenge}} ->
        {:noreply,
         request_peer_verification(peer_pid, {:accept_ingress, challenge, token}, state)}

      _unknown_or_stale_challenge ->
        {:noreply, state}
    end
  end

  def handle_info({:peer_verification_result, verification_ref, peer_pid, registered_pid}, state)
      when is_reference(verification_ref) and is_pid(peer_pid) do
    case take_pending_verification(state, verification_ref) do
      {:ok, ^peer_pid, action, state} ->
        if registered_pid == peer_pid and listed_peer_relay?(peer_pid) do
          state = update_in(state, [:verified_peers], &MapSet.put(&1, peer_pid))
          {:noreply, complete_peer_action(peer_pid, action, state)}
        else
          {:noreply, state}
        end

      {:ok, _different_peer, _action, state} ->
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:receive_batch, peer_pid, token, signals}, state)
      when is_pid(peer_pid) and is_binary(token) and byte_size(token) == @proof_bytes and
             is_list(signals) do
    if listed_peer_relay?(peer_pid) and
         custody_matches?(state, {:peer_ingress, peer_pid}, token) do
      {:noreply, admit_batch(signals, node(peer_pid), state)}
    else
      stats = Map.update!(state.stats, :signals_rejected, &(&1 + length(signals)))
      {:noreply, %{state | stats: stats}}
    end
  end

  def handle_info({:retry_ingress, peer_pid, challenge}, state)
      when is_pid(peer_pid) and is_reference(challenge) do
    case {Map.get(state.pending_ingress, peer_pid),
          custody_fetch(state, {:peer_challenge, peer_pid})} do
      {%{attempts: attempts} = pending, {:ok, ^challenge}}
      when attempts < @peer_handshake_max_attempts ->
        send(peer_pid, {:open_ingress, self(), challenge})

        Process.send_after(
          self(),
          {:retry_ingress, peer_pid, challenge},
          @peer_handshake_retry_ms
        )

        {:noreply,
         put_in(state, [:pending_ingress, peer_pid], %{pending | attempts: attempts + 1})}

      {%{}, {:ok, ^challenge}} ->
        custody_delete(state, {:peer_challenge, peer_pid})
        {:noreply, update_in(state, [:pending_ingress], &Map.delete(&1, peer_pid))}

      _stale_retry ->
        {:noreply, state}
    end
  end

  def handle_info(:flush_batch, %{batch: []} = state) do
    # Nothing to flush
    state = prune_peer_state(state, peer_relays())
    Process.send_after(self(), :flush_batch, batch_interval_ms())
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_batch, state) do
    peers = peer_relays()
    state = prune_peer_state(state, peers)
    batch = Enum.reverse(state.batch)
    batch_count = state.batch_size

    state = Enum.reduce(peers, state, &deliver_or_open_ingress(&1, batch, &2))

    stats =
      state.stats
      |> Map.update!(:relayed_out, &(&1 + batch_count))
      |> Map.update!(:batches_sent, &(&1 + 1))
      |> Map.put(:peers_seen, count_peers())

    Process.send_after(self(), :flush_batch, batch_interval_ms())

    {:noreply, %{state | batch: [], batch_size: 0, stats: stats}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def format_status(status) when is_map(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, :redacted)
  end

  defp register_with_bus(state) do
    with {:ok, proof} <- custody_fetch(state, :bus_proof),
         {:ok, bus_pid} when is_pid(bus_pid) <- Bus.register_relay(proof) do
      if is_reference(state.bus_monitor_ref) do
        Process.demonitor(state.bus_monitor_ref, [:flush])
      end

      %{state | bus_pid: bus_pid, bus_monitor_ref: Process.monitor(bus_pid)}
    else
      _error ->
        Process.send_after(self(), :register_with_bus, @bus_reregister_delay_ms)
        state
    end
  end

  if @test_env do
    defp reset_runtime_state(state) do
      base = %{
        state
        | batch: [],
          batch_size: 0,
          pending_ingress: %{},
          verified_peers: MapSet.new(),
          pending_peer_verification_count: 0,
          rate_buckets: %{},
          node_counters: %{}
      }

      if enabled?() do
        %{
          base
          | stats: %{
              relayed_out: 0,
              relayed_in: 0,
              batches_sent: 0,
              signals_dropped: 0,
              signals_rate_limited: 0,
              signals_rejected: 0,
              peers_seen: 0
            }
        }
      else
        %{base | stats: %{status: :disabled}}
      end
    end
  end

  defp new_custody! do
    proof = :crypto.strong_rand_bytes(@proof_bytes)
    private = :ets.new(__MODULE__, [:set, :private])
    directory = :ets.new(@custody_directory, [:named_table, :set, :protected])
    true = :ets.insert(private, {:bus_proof, proof})
    true = :ets.insert(directory, {:relay, self(), :crypto.hash(:sha256, proof)})
    private
  end

  defp custody_owned?(%{custody: table}), do: :ets.info(table, :owner) == self()

  defp custody_fetch(state, key) do
    if custody_owned?(state) do
      case :ets.lookup(state.custody, key) do
        [{^key, value}] -> {:ok, value}
        _other -> :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp custody_put(state, key, value) do
    if custody_owned?(state) do
      true = :ets.insert(state.custody, {key, value})
      :ok
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp custody_matches?(state, key, candidate)
       when is_binary(candidate) and byte_size(candidate) == @proof_bytes do
    case custody_fetch(state, key) do
      {:ok, expected}
      when is_binary(expected) and byte_size(expected) == @proof_bytes ->
        :crypto.hash_equals(expected, candidate)

      _other ->
        false
    end
  end

  defp custody_matches?(_state, _key, _candidate), do: false

  defp custody_delete(state, key) do
    if custody_owned?(state), do: :ets.delete(state.custody, key)
    :ok
  rescue
    _error -> :ok
  end

  if @test_env do
    defp clear_peer_custody(state) do
      if custody_owned?(state) do
        :ets.select_delete(state.custody, [
          {{{:peer_ingress, :_}, :_}, [], [true]},
          {{{:peer_egress, :_}, :_}, [], [true]},
          {{{:peer_challenge, :_}, :_}, [], [true]},
          {{{:peer_verification, :_}, :_}, [], [true]}
        ])
      end

      :ok
    rescue
      _error -> :ok
    end
  end

  defp take_pending_verification(state, verification_ref) do
    key = {:peer_verification, verification_ref}

    if custody_owned?(state) do
      case :ets.take(state.custody, key) do
        [{^key, {peer_pid, action}}] ->
          next =
            update_in(state, [:pending_peer_verification_count], &max(&1 - 1, 0))

          {:ok, peer_pid, action, next}

        _other ->
          :error
      end
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp prune_peer_state(state, peers) do
    allowed = MapSet.new(peers)

    stale =
      if custody_owned?(state) do
        Enum.flat_map(:ets.tab2list(state.custody), fn
          {{kind, peer_pid} = key, _token}
          when kind in [:peer_ingress, :peer_egress, :peer_challenge] and is_pid(peer_pid) ->
            if MapSet.member?(allowed, peer_pid), do: [], else: [{key, false}]

          {{:peer_verification, _ref} = key, {peer_pid, _action}} when is_pid(peer_pid) ->
            if MapSet.member?(allowed, peer_pid), do: [], else: [{key, true}]

          _other ->
            []
        end)
      else
        []
      end

    Enum.each(stale, fn {key, _verification?} -> custody_delete(state, key) end)
    removed_verifications = Enum.count(stale, &elem(&1, 1))

    %{
      state
      | pending_ingress: Map.take(state.pending_ingress, peers),
        verified_peers: MapSet.intersection(state.verified_peers, allowed),
        pending_peer_verification_count:
          max(state.pending_peer_verification_count - removed_verifications, 0)
    }
  rescue
    _error -> state
  end

  # ── Phase 5: Rate Limiting ──────────────────────────────────────────

  defp check_category_rate(category, state) do
    limit = category_rate_limit()
    now = System.monotonic_time(:millisecond)
    bucket = Map.get(state.rate_buckets, category, {limit, now})

    {tokens, last_refill} = bucket

    # Refill tokens based on elapsed time (token bucket algorithm)
    elapsed_ms = now - last_refill
    refilled = tokens + div(elapsed_ms * limit, 1000)
    tokens = min(refilled, limit)
    last_refill = if elapsed_ms > 0, do: now, else: last_refill

    if tokens > 0 do
      buckets = Map.put(state.rate_buckets, category, {tokens - 1, last_refill})
      {true, %{state | rate_buckets: buckets}}
    else
      buckets = Map.put(state.rate_buckets, category, {0, last_refill})

      Logger.debug("[SignalRelay] Rate limited category #{category} (#{limit}/s)")

      {false, %{state | rate_buckets: buckets}}
    end
  end

  defp category_rate_limit do
    Config.relay_category_rate_limit()
  end

  # ── Phase 6: Security Hardening ─────────────────────────────────────

  defp admit_remote_security_sync_signals(signals) do
    if Config.authenticated_security_sync_transport?() do
      {signals, 0}
    else
      {admitted, blocked} =
        Enum.split_with(signals, &admitted_unauthenticated_remote_signal?/1)

      {admitted, length(blocked)}
    end
  end

  # Authority-REDUCING mutations must reach their consumers even without an
  # authenticated transport. Dropping them here is what silently kept revoked
  # capabilities live on peer nodes — the relay never delivered the eviction.
  defp admitted_unauthenticated_remote_signal?(%Signal{type: type})
       when type in @restricted_security_sync_mutations,
       do: Config.admit_remote_security_mutation?(type)

  defp admitted_unauthenticated_remote_signal?(%Signal{}), do: true

  defp admit_batch(signals, from_node, state) do
    {allowed_count, state} = check_node_rate(from_node, length(signals), state)

    {accepted, rejected_count} =
      if allowed_count >= length(signals) do
        {signals, 0}
      else
        {Enum.take(signals, allowed_count), length(signals) - allowed_count}
      end

    {accepted, restricted_rejected} = admit_remote_security_sync_signals(accepted)
    rejected_count = rejected_count + restricted_rejected

    case custody_fetch(state, :bus_proof) do
      {:ok, proof} ->
        Enum.each(accepted, fn signal ->
          signal
          |> sanitize_remote_signal(from_node)
          |> inject_to_local_bus(proof)
        end)

      :error ->
        :ok
    end

    count = length(accepted)

    stats =
      state.stats
      |> Map.update!(:relayed_in, &(&1 + count))
      |> Map.update!(:signals_rejected, &(&1 + rejected_count))
      |> Map.put(:peers_seen, count_peers())

    if restricted_rejected > 0 do
      Logger.warning(
        "[SignalRelay] Rejected #{restricted_rejected} unauthenticated " <>
          "security-sync signals from #{from_node}"
      )
    end

    if rejected_count > restricted_rejected do
      Logger.warning(
        "[SignalRelay] Rate limited #{rejected_count - restricted_rejected} " <>
          "signals from #{from_node}"
      )
    end

    Logger.debug("[SignalRelay] Received #{count} signals from #{from_node}")
    %{state | stats: stats}
  end

  defp check_node_rate(from_node, incoming_count, state) do
    limit = node_rate_limit()
    now = System.monotonic_time(:second)
    {count, window_start} = Map.get(state.node_counters, from_node, {0, now})

    # Reset counter if we're in a new 1-second window
    {count, window_start} =
      if now > window_start do
        {0, now}
      else
        {count, window_start}
      end

    available = max(limit - count, 0)
    allowed = min(incoming_count, available)
    new_count = count + allowed

    counters = Map.put(state.node_counters, from_node, {new_count, window_start})
    {allowed, %{state | node_counters: counters}}
  end

  defp node_rate_limit do
    Config.relay_node_rate_limit()
  end

  defp sanitize_remote_signal(%Signal{} = signal, from_node) do
    # Sanitize metadata keys — only allow known safe atoms
    sanitized_metadata =
      signal.metadata
      |> Enum.flat_map(fn
        {key, value} when is_atom(key) ->
          [{key, value}]

        {key, value} when is_binary(key) ->
          if key in @safe_metadata_keys do
            [{String.to_existing_atom(key), value}]
          else
            # Keep as string key — don't atomize unknown keys
            [{key, value}]
          end

        {key, value} ->
          [{key, value}]
      end)
      |> Map.new()

    remote_attribution = %{
      "id" => inspect(signal.id, limit: 20, printable_limit: 200),
      "timestamp" => inspect(signal.timestamp, limit: 20, printable_limit: 200),
      "emitter_pid" => inspect(signal.emitter_pid, limit: 20, printable_limit: 200),
      "origin_node" => inspect(signal.origin_node, limit: 20, printable_limit: 200)
    }

    metadata = Map.put(sanitized_metadata, "remote", remote_attribution)

    data =
      signal.data
      |> Map.delete("origin_node")
      |> Map.put(:origin_node, from_node)

    Signal.new(signal.category, signal.type, data,
      source: signal.source,
      cause_id: signal.cause_id,
      correlation_id: signal.correlation_id,
      metadata: metadata,
      scope: :local
    )
    |> Map.put(:emitter_pid, self())
    |> Map.put(:origin_node, from_node)
  rescue
    # Malformed remote metadata must not preserve attacker-controlled event
    # identity or attribution. Rebuild with empty metadata instead.
    _error ->
      data =
        if is_map(signal.data) do
          signal.data
          |> Map.delete("origin_node")
          |> Map.put(:origin_node, from_node)
        else
          %{origin_node: from_node}
        end

      Signal.new(signal.category, signal.type, data, scope: :local)
      |> Map.put(:emitter_pid, self())
      |> Map.put(:origin_node, from_node)
  end

  # ── Load Shedding ──────────────────────────────────────────────────

  defp shed_or_drop(new_signal, state) do
    new_priority = Map.get(@category_priority, new_signal.category, 3)

    # Find the lowest priority signal in the batch
    {worst_idx, worst_priority} =
      state.batch
      |> Enum.with_index()
      |> Enum.max_by(fn {sig, _idx} ->
        Map.get(@category_priority, sig.category, 3)
      end)
      |> then(fn {sig, idx} ->
        {idx, Map.get(@category_priority, sig.category, 3)}
      end)

    if new_priority < worst_priority do
      # New signal is higher priority — replace the worst one
      batch = List.delete_at(state.batch, worst_idx)
      stats = Map.update!(state.stats, :signals_dropped, &(&1 + 1))

      Logger.debug(
        "[SignalRelay] Shed signal (priority #{worst_priority} replaced by #{new_priority})"
      )

      %{state | batch: [new_signal | batch], stats: stats}
    else
      # New signal is lower or equal priority — drop it
      stats = Map.update!(state.stats, :signals_dropped, &(&1 + 1))

      Logger.debug("[SignalRelay] Dropped signal category=#{new_signal.category} (batch full)")

      %{state | stats: stats}
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp join_pg_group do
    # Ensure :pg is started (it may not be in test)
    case :pg.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> :ok
    end

    :pg.join(@pg_group, self())
  rescue
    _ -> :ok
  end

  defp peer_relays do
    case :pg.get_members(@pg_group) do
      members when is_list(members) ->
        Enum.reject(members, fn pid -> pid == self() end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp listed_peer_relay?(peer_pid) when is_pid(peer_pid) do
    peer_pid != self() and Enum.member?(peer_relays(), peer_pid)
  end

  defp remote_registered_relay_pid(peer_node) do
    try do
      :erpc.call(peer_node, Bus, :registered_relay_pid, [], @peer_verify_timeout_ms)
    rescue
      _error -> nil
    catch
      _kind, _reason -> nil
    end
  end

  defp request_peer_verification(peer_pid, action, state) do
    cond do
      not listed_peer_relay?(peer_pid) or node(peer_pid) == node() ->
        state

      MapSet.member?(state.verified_peers, peer_pid) ->
        complete_peer_action(peer_pid, action, state)

      verification_pending?(state, peer_pid, action) ->
        state

      state.pending_peer_verification_count >= @max_pending_peer_verifications ->
        state

      true ->
        verification_ref = make_ref()
        relay_pid = self()
        peer_node = node(peer_pid)

        {:ok, _task_pid} =
          Task.start(fn ->
            registered_pid = remote_registered_relay_pid(peer_node)

            send(
              relay_pid,
              {:peer_verification_result, verification_ref, peer_pid, registered_pid}
            )
          end)

        case custody_put(
               state,
               {:peer_verification, verification_ref},
               {peer_pid, action}
             ) do
          :ok ->
            %{state | pending_peer_verification_count: state.pending_peer_verification_count + 1}

          :error ->
            state
        end
    end
  end

  defp verification_pending?(state, peer_pid, action) do
    custody_owned?(state) and
      Enum.any?(:ets.tab2list(state.custody), fn
        {{:peer_verification, _ref}, {^peer_pid, ^action}} -> true
        _other -> false
      end)
  rescue
    _error -> false
  end

  defp complete_peer_action(peer_pid, {:grant_ingress, challenge}, state) do
    token =
      case custody_fetch(state, {:peer_ingress, peer_pid}) do
        {:ok, existing} -> existing
        :error -> :crypto.strong_rand_bytes(@proof_bytes)
      end

    if custody_put(state, {:peer_ingress, peer_pid}, token) == :ok do
      send(peer_pid, {:ingress_opened, self(), challenge, token})
    end

    state
  end

  defp complete_peer_action(peer_pid, {:accept_ingress, challenge, token}, state) do
    case {Map.get(state.pending_ingress, peer_pid),
          custody_fetch(state, {:peer_challenge, peer_pid})} do
      {%{batches: batches}, {:ok, ^challenge}} ->
        if custody_put(state, {:peer_egress, peer_pid}, token) == :ok do
          Enum.each(Enum.reverse(batches), &send_authenticated_batch(peer_pid, token, &1))
          custody_delete(state, {:peer_challenge, peer_pid})
          update_in(state, [:pending_ingress], &Map.delete(&1, peer_pid))
        else
          state
        end

      _stale_challenge ->
        state
    end
  catch
    _kind, _reason -> state
  end

  defp deliver_or_open_ingress(peer_pid, batch, state) do
    case custody_fetch(state, {:peer_egress, peer_pid}) do
      {:ok, token} when is_binary(token) and byte_size(token) == @proof_bytes ->
        send_authenticated_batch(peer_pid, token, batch)
        state

      _missing_or_invalid ->
        case Map.get(state.pending_ingress, peer_pid) do
          %{batches: batches} = pending ->
            batches = [batch | batches] |> Enum.take(@max_pending_batches_per_peer)
            put_in(state, [:pending_ingress, peer_pid], %{pending | batches: batches})

          nil ->
            challenge = make_ref()

            if custody_put(state, {:peer_challenge, peer_pid}, challenge) == :ok do
              send(peer_pid, {:open_ingress, self(), challenge})

              Process.send_after(
                self(),
                {:retry_ingress, peer_pid, challenge},
                @peer_handshake_retry_ms
              )

              put_in(state, [:pending_ingress, peer_pid], %{
                batches: [batch],
                attempts: 1
              })
            else
              state
            end
        end
    end
  end

  defp send_authenticated_batch(peer_pid, token, batch) do
    send(peer_pid, {:receive_batch, self(), token, batch})
    :ok
  end

  defp count_peers do
    length(peer_relays())
  end

  defp inject_to_local_bus(signal, proof) do
    # Publish directly to Bus — signal already has origin_node set,
    # and scope is set to :local to prevent re-relay
    if Process.whereis(Arbor.Signals.Bus) do
      Arbor.Signals.Bus.publish_remote(signal, proof)

      # Also store in local Store for query visibility
      if Process.whereis(Arbor.Signals.Store) do
        Arbor.Signals.Store.put(signal)
      end
    end
  end

  defp batch_interval_ms do
    Config.relay_batch_interval_ms()
  end

  defp max_batch_size do
    Config.relay_max_batch_size()
  end
end
