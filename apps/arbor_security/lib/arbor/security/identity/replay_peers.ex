defmodule Arbor.Security.Identity.ReplayPeers do
  @moduledoc """
  Tracks which connected BEAM nodes are *replay-relevant* for signed requests.

  ## Why this exists

  `Arbor.Security.Identity.Verifier` fails closed when a captured
  `SignedRequest` could be replayed against a node that has not seen its
  nonce. Nonces are node-local (`NonceCache`), so two *honest* nodes both
  accept the same captured request — neither knows the other burned it.

  Note what the missing piece is: **consistency, not authentication**. Signal
  propagation of `nonce_seen` is fire-and-forget, so a replay can beat the
  signal; the connection is already authenticated by the cookie (later
  TLS-dist). The successor design is therefore a synchronous claim against a
  single owner node per nonce, not a security-sync transport — see the
  2026-08-19 section of `.arbor/roadmap/1-brainstorming/`
  `trust-zone-segmentation-architecture.md`.

  ## This is not a trust boundary

  `classification/1` answers exactly one question: *could this node accept a
  replayed signed request?* It contains nothing. Erlang distribution has no
  intra-cluster authorization — a `:foreign` node can still `:erpc` arbitrary
  code onto this one. Mesh membership is the trust boundary, and it is
  all-or-nothing; separating trust levels requires separate clusters bridged
  by the Gateway. Never read `:foreign` as "sandboxed" or "untrusted but
  contained."

  The threat requires a peer that can *actually accept* the replayed
  request. Verifying a `SignedRequest` needs this node's identity registry
  (to resolve the agent's public key) and the security stack that consumes
  it — i.e. the peer must be running `:arbor_security`. A connected node
  that does not run `:arbor_security` — an SDR recorder, a build box, an
  ops shell, an `iex` attached for diagnostics — cannot resolve the agent
  id, cannot verify the signature, and has no signed-request entry point.
  It is a distribution peer, not a replay target.

  Treating bare `Node.list() != []` as the danger condition therefore
  refuses valid single-node traffic whenever *any* unrelated node is in the
  mesh, which is the normal state of a development machine. This module
  narrows the condition to peers that could serve the same request.

  ## Classification

  Each node is probed on `nodeup` (and once for each node already connected at
  boot), with a short timeout. Replay-peer verdicts remain conservative.
  Foreign verdicts expire and are revalidated so a peer cannot start
  `:arbor_security` on an existing connection and retain an old permissive
  classification indefinitely. Probing is asynchronous: a slow or wedged peer
  delays its own classification and never blocks the GenServer.

  Classification fails closed in every uncertain case. A node is treated as
  a replay peer unless it has been positively classified as foreign:

    * probe still outstanding → replay peer
    * probe timed out, or the node was unreachable → replay peer
    * probe raised, or returned something unexpected → replay peer
    * this process is not running → **every** connected node is a replay peer

  Only an affirmative "`:arbor_security` is not running there" downgrades a
  node to foreign. Once that verdict expires, callers see the fail-closed
  `:replay_peer` classification until a generation-tagged asynchronous probe
  produces a fresh verdict.
  """

  use GenServer

  require Logger

  @table :arbor_security_replay_peers

  # Deliberately short. A peer that cannot answer a `which_applications`
  # call within this window stays classified as a replay peer, which is the
  # safe direction — this bound exists to keep probes from piling up, not to
  # decide anything.
  @probe_timeout_ms 2_000

  # A foreign verdict is permissive, so it must not survive indefinitely.
  # Revalidation is lazy: the first gate read after expiry starts a probe and
  # awaits it, while non-blocking reads report :replay_peer until it completes.
  @default_foreign_ttl_ms 30_000

  # Slightly above @probe_timeout_ms so a probe that is going to time out gets
  # to report its own verdict rather than having the waiter give up first.
  # Both directions land on :replay_peer, so this only decides who says so.
  @await_timeout_ms 2_500

  @typedoc """
  A node's replay classification.

  `:replay_peer` — runs `:arbor_security`, or is not yet known not to.
  `:foreign` — positively observed not running `:arbor_security`.
  """
  @type classification :: :replay_peer | :foreign

  # =========================================================================
  # Public API
  # =========================================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Whether any connected node could accept a replayed signed request.

  Returns `false` only when every connected node has been positively
  classified as foreign (including the trivial case of no connected nodes).
  """
  @spec peers_present?() :: boolean()
  def peers_present? do
    case connected_nodes() do
      [] -> false
      nodes -> Enum.any?(nodes, &(resolved_classification(&1) == :replay_peer))
    end
  end

  # A cached verdict answers straight from ETS (lock-free). A MISS means the
  # probe for this node is still in flight, and treating that as "replay peer"
  # is not merely conservative — it is a guaranteed failure:
  #
  #   `mix arbor.agent chat` connects an ephemeral node to the server and
  #   issues its RPC immediately. `nodeup` drops the old verdict and probes
  #   asynchronously, so the gate is consulted before any probe can finish.
  #   Every local CLI call lost that race and returned
  #   `:cluster_replay_protection_unavailable` (found 2026-08-19 walking the
  #   quickstart on a clean box).
  #
  # So wait for the verdict instead. Still fails closed — a probe that times
  # out or a tracker that is not running yields `:replay_peer` — but a node
  # that is merely *new* costs latency rather than a refusal.
  defp resolved_classification(node) do
    case cached_classification(node) do
      {:ok, classification} -> classification
      :unknown -> await_classification(node)
    end
  end

  defp await_classification(node) do
    GenServer.call(__MODULE__, {:await_classification, node}, @await_timeout_ms)
  catch
    # Tracker down, or the probe outran the await budget. Fail closed.
    :exit, _ -> :replay_peer
  end

  @doc """
  The cached classification for one node.

  Anything not positively known to be foreign reads as `:replay_peer`,
  including nodes this process has never seen and the case where the table
  does not exist because the process is not running.
  """
  @spec classification(node()) :: classification()
  def classification(node) when is_atom(node) do
    case cached_classification(node) do
      {:ok, classification} ->
        classification

      :unknown ->
        # This API remains non-blocking. Ask the tracker to refresh an expired
        # verdict, but expose the conservative answer while it is uncertain.
        GenServer.cast(__MODULE__, {:revalidate, node})
        :replay_peer
    end
  end

  @doc """
  The connected nodes that could accept a replayed signed request.

  Diagnostic helper — `peers_present?/0` is the gate. Useful when a signed
  request is being refused and you need to see *which* peer is responsible.
  """
  @spec list() :: [node()]
  def list, do: Enum.filter(connected_nodes(), &(resolved_classification(&1) == :replay_peer))

  # `:connected`, never the `Node.list/0` default of `:visible`. A hidden node
  # (`-hidden`, or `-connect_all false`) is a perfectly good replay target: it
  # can run :arbor_security and accept a captured request. It just does not
  # join the global mesh. Counting only visible nodes would let anyone silence
  # this gate by starting the peer hidden.
  defp connected_nodes, do: Map.keys(connected_connections())

  defp connected_connections do
    :connected
    |> :erlang.nodes(%{connection_id: true})
    |> Map.new(fn {node, %{connection_id: connection_id}} -> {node, connection_id} end)
  end

  defp current_connection_id(node), do: Map.fetch(connected_connections(), node)

  if Mix.env() == :test do
    @doc """
    Drop a node's cached classification without disconnecting it.

    Reproduces the state the gate sees while a probe is outstanding or after
    a probe timed out against a wedged peer. This seam can only *remove* a
    verdict, never insert one, so it can only make the gate stricter — there
    is no way to use it to mark a node foreign and admit a request.
    """
    @spec forget(node()) :: :ok
    def forget(node) when is_atom(node) do
      GenServer.call(__MODULE__, {:forget, node})
    end
  end

  # =========================================================================
  # GenServer callbacks
  # =========================================================================

  @impl GenServer
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    # `node_type: :all` for the same reason `connected_nodes/0` uses
    # `:connected` — the default only reports visible nodes, so a hidden peer
    # would never be probed and would sit unclassified forever.
    :ok = :net_kernel.monitor_nodes(true, %{node_type: :all, connection_id: true})

    # Nodes connected before this process started are unclassified, and so
    # already count as replay peers. Probing them only ever relaxes the gate.
    connections = connected_connections()

    state = %{
      waiters: %{},
      inflight: %{},
      connections: connections,
      foreign_ttl_ms: foreign_ttl_ms(opts),
      probe_fun: probe_fun(opts)
    }

    state = Enum.reduce(Map.keys(connections), state, &start_probe/2)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:await_classification, node}, from, state) do
    case cached_classification(node) do
      {:ok, classification} ->
        {:reply, classification, state}

      :unknown ->
        # An expired foreign row must not remain readable while its refresh is
        # in flight. Deleting it also keeps raw ETS diagnostics conservative.
        :ets.delete(@table, node)

        case ensure_probe(node, state) do
          {:ok, generation, state} ->
            key = {node, generation}

            {:noreply, %{state | waiters: Map.update(state.waiters, key, [from], &[from | &1])}}

          {:error, state} ->
            # Disconnected between the caller's check and this call. A node
            # that is not connected cannot accept a replayed request.
            {:reply, :foreign, state}
        end
    end
  end

  if Mix.env() == :test do
    @impl GenServer
    def handle_call({:forget, node}, _from, state) do
      :ets.delete(@table, node)
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_cast({:revalidate, node}, state) do
    case cached_classification(node) do
      {:ok, _classification} ->
        {:noreply, state}

      :unknown ->
        :ets.delete(@table, node)

        {:noreply, start_probe(node, state)}
    end
  end

  # `monitor_nodes/2` with a non-empty option list delivers three-element
  # messages (`{:nodeup, node, info}`), not the two-element form `monitor_nodes/1`
  # sends. Match both so this keeps working if the options are ever dropped —
  # a silently unmatched nodeup would leave every peer unclassified forever.
  #
  # OTP 23+ also guarantees that the old connection's nodedown is delivered
  # before the replacement connection's nodeup for the same node name. Since a
  # GenServer consumes these status messages in mailbox order, a genuine stale
  # nodeup cannot overwrite a newer connection id. This ordering is why OTP's
  # own `:global` server also records the reported nodeup id unconditionally.
  @impl GenServer
  def handle_info({:nodeup, node, info}, state),
    do: handle_nodeup(node, connection_id_from_info(info), state)

  def handle_info({:nodeup, node}, state), do: handle_nodeup(node, nil, state)

  def handle_info({:nodedown, node, info}, state),
    do: handle_nodedown(node, connection_id_from_info(info), state)

  def handle_info({:nodedown, node}, state), do: handle_nodedown(node, nil, state)

  def handle_info({:probe_result, node, generation, classification}, state) do
    # Results are valid only for the exact probe generation still registered
    # for this connection. A result from before nodedown/nodeup must neither
    # cache a permissive verdict nor release/delete the new generation's work.
    if Map.get(state.inflight, node) == generation do
      {connection_id, _probe_ref} = generation

      case current_connection_id(node) do
        {:ok, ^connection_id} ->
          cache_classification(node, connection_id, classification, state)
          {:noreply, release_waiters(node, generation, classification, state)}

        {:ok, _new_connection_id} ->
          # Reconnected before its nodeup message reached us. The old result is
          # not valid for the live connection, so release conservatively.
          {:noreply, release_waiters(node, generation, :replay_peer, state)}

        :error ->
          {:noreply, release_waiters(node, generation, :foreign, state)}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_nodeup(node, reported_connection_id, state) do
    # Drop any verdict from a previous connection: the peer may have started
    # or stopped :arbor_security while it was away.
    :ets.delete(@table, node)
    state = invalidate_node_generation(node, :replay_peer, state)
    connection_id = reported_connection_id || live_connection_id(node)
    state = put_connection(state, node, connection_id)
    {:noreply, start_probe(node, state)}
  end

  defp handle_nodedown(node, reported_connection_id, state) do
    if is_nil(reported_connection_id) or
         Map.get(state.connections, node) == reported_connection_id do
      :ets.delete(@table, node)

      # Anyone waiting on this node is released as :foreign — a disconnected
      # node cannot accept a replayed request. Leaving them to time out would
      # stall the auth path for no reason.
      state = invalidate_node_generation(node, :foreign, state)
      {:noreply, %{state | connections: Map.delete(state.connections, node)}}
    else
      # A delayed nodedown for an older connection must not invalidate state
      # established by a newer nodeup for the same node name.
      {:noreply, state}
    end
  end

  defp release_waiters(node, generation, classification, state) do
    {waiting, remaining} = Map.pop(state.waiters, {node, generation}, [])
    Enum.each(waiting, &GenServer.reply(&1, classification))

    inflight =
      if Map.get(state.inflight, node) == generation do
        Map.delete(state.inflight, node)
      else
        state.inflight
      end

    %{state | waiters: remaining, inflight: inflight}
  end

  defp invalidate_node_generation(node, classification, state) do
    {waiting, remaining} =
      Enum.split_with(state.waiters, fn {{waiting_node, _generation}, _callers} ->
        waiting_node == node
      end)

    Enum.each(waiting, fn {_key, callers} ->
      Enum.each(callers, &GenServer.reply(&1, classification))
    end)

    %{state | waiters: Map.new(remaining), inflight: Map.delete(state.inflight, node)}
  end

  # =========================================================================
  # Probing
  # =========================================================================

  # Idempotent per node: a waiter arriving while the nodeup probe is still
  # running must not spawn a second `:erpc` against the same peer.
  defp start_probe(node, state) do
    case ensure_probe(node, state) do
      {:ok, _generation, state} -> state
      {:error, state} -> state
    end
  end

  defp ensure_probe(node, state) do
    case Map.fetch(state.inflight, node) do
      {:ok, generation} ->
        {:ok, generation, state}

      :error ->
        case current_connection_id(node) do
          {:ok, connection_id} ->
            generation = {connection_id, make_ref()}
            owner = self()
            probe_fun = state.probe_fun

            spawn(fn ->
              classification = run_probe(probe_fun, node, generation)
              send(owner, {:probe_result, node, generation, classification})
            end)

            state = %{state | inflight: Map.put(state.inflight, node, generation)}
            {:ok, generation, state}

          :error ->
            {:error, state}
        end
    end
  end

  defp run_probe(probe_fun, node, generation) do
    case probe_fun.(node, generation) do
      classification when classification in [:replay_peer, :foreign] -> classification
      _unexpected -> :replay_peer
    end
  catch
    kind, reason ->
      Logger.debug(
        "[ReplayPeers] probe worker failed (#{inspect(kind)}: #{inspect(reason)}) — " <>
          "treating #{inspect(node)} as a replay peer"
      )

      :replay_peer
  end

  defp cached_classification(node) do
    case :ets.lookup(@table, node) do
      [{^node, :foreign, connection_id, expires_at}] when is_integer(expires_at) ->
        with true <- monotonic_ms() < expires_at,
             {:ok, ^connection_id} <- current_connection_id(node) do
          {:ok, :foreign}
        else
          _not_current_or_fresh -> :unknown
        end

      [{^node, :replay_peer}] ->
        {:ok, :replay_peer}

      _other ->
        :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  defp cache_classification(node, connection_id, :foreign, state) do
    expires_at = monotonic_ms() + state.foreign_ttl_ms
    :ets.insert(@table, {node, :foreign, connection_id, expires_at})
  end

  defp cache_classification(node, _connection_id, :replay_peer, _state) do
    :ets.insert(@table, {node, :replay_peer})
  end

  defp connection_id_from_info(%{connection_id: connection_id}), do: connection_id
  defp connection_id_from_info(info) when is_list(info), do: Keyword.get(info, :connection_id)
  defp connection_id_from_info(_info), do: nil

  defp live_connection_id(node) do
    case current_connection_id(node) do
      {:ok, connection_id} -> connection_id
      :error -> nil
    end
  end

  defp put_connection(state, _node, nil), do: state

  defp put_connection(state, node, connection_id) do
    %{state | connections: Map.put(state.connections, node, connection_id)}
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp foreign_ttl_ms(opts) do
    case Keyword.get(opts, :foreign_ttl_ms, @default_foreign_ttl_ms) do
      ttl when is_integer(ttl) and ttl > 0 -> ttl
      invalid -> raise ArgumentError, ":foreign_ttl_ms must be positive, got: #{inspect(invalid)}"
    end
  end

  defp probe_fun(opts) do
    case Keyword.get(opts, :probe_fun) do
      nil -> &default_probe/2
      fun when is_function(fun, 2) -> fun
      invalid -> raise ArgumentError, ":probe_fun must have arity 2, got: #{inspect(invalid)}"
    end
  end

  defp default_probe(node, _generation), do: classify(node)

  defp classify(node) do
    case :erpc.call(node, :application, :which_applications, [], @probe_timeout_ms) do
      apps when is_list(apps) ->
        if List.keymember?(apps, :arbor_security, 0) do
          :replay_peer
        else
          Logger.debug(
            "[ReplayPeers] #{inspect(node)} does not run :arbor_security — " <>
              "not a signed-request replay target"
          )

          :foreign
        end

      _other ->
        :replay_peer
    end
  catch
    kind, reason ->
      Logger.debug(
        "[ReplayPeers] probe of #{inspect(node)} failed (#{inspect(kind)}: " <>
          "#{inspect(reason)}) — treating as a replay peer"
      )

      :replay_peer
  end
end
