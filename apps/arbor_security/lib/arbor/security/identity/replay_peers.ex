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

  Each node is probed once, on `nodeup` (and once for each node already
  connected at boot), with a short timeout. The result is cached until the
  node goes down. Probing is asynchronous: a slow or wedged peer delays its
  own classification and never blocks the authentication path.

  Classification fails closed in every uncertain case. A node is treated as
  a replay peer unless it has been positively classified as foreign:

    * probe still outstanding → replay peer
    * probe timed out, or the node was unreachable → replay peer
    * probe raised, or returned something unexpected → replay peer
    * this process is not running → **every** connected node is a replay peer

  Only an affirmative "`:arbor_security` is not running there" downgrades a
  node to foreign. A peer that starts `:arbor_security` later is re-probed
  on its next `nodeup`; within a single connection the cached verdict
  stands, which is the same window the nonce cache already tolerates.
  """

  use GenServer

  require Logger

  @table :arbor_security_replay_peers

  # Deliberately short. A peer that cannot answer a `which_applications`
  # call within this window stays classified as a replay peer, which is the
  # safe direction — this bound exists to keep probes from piling up, not to
  # decide anything.
  @probe_timeout_ms 2_000

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
    case :ets.lookup(@table, node) do
      [{^node, classification}] -> classification
      [] -> await_classification(node)
    end
  rescue
    ArgumentError -> :replay_peer
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
    case :ets.lookup(@table, node) do
      [{^node, :foreign}] -> :foreign
      _ -> :replay_peer
    end
  rescue
    ArgumentError -> :replay_peer
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
  defp connected_nodes, do: Node.list(:connected)

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
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    # `node_type: :all` for the same reason `connected_nodes/0` uses
    # `:connected` — the default only reports visible nodes, so a hidden peer
    # would never be probed and would sit unclassified forever.
    :ok = :net_kernel.monitor_nodes(true, node_type: :all)

    # Nodes connected before this process started are unclassified, and so
    # already count as replay peers. Probing them only ever relaxes the gate.
    state =
      Enum.reduce(connected_nodes(), %{waiters: %{}, inflight: MapSet.new()}, fn node, acc ->
        start_probe(node, acc)
      end)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:await_classification, node}, from, state) do
    case :ets.lookup(@table, node) do
      [{^node, classification}] ->
        {:reply, classification, state}

      [] ->
        if node in connected_nodes() do
          state = start_probe(node, state)
          {:noreply, %{state | waiters: Map.update(state.waiters, node, [from], &[from | &1])}}
        else
          # Disconnected between the caller's check and this call. A node that
          # is not connected cannot accept a replayed request.
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

  # `monitor_nodes/2` with a non-empty option list delivers three-element
  # messages (`{:nodeup, node, info}`), not the two-element form `monitor_nodes/1`
  # sends. Match both so this keeps working if the options are ever dropped —
  # a silently unmatched nodeup would leave every peer unclassified forever.
  @impl GenServer
  def handle_info({:nodeup, node, _info}, state), do: handle_nodeup(node, state)
  def handle_info({:nodeup, node}, state), do: handle_nodeup(node, state)
  def handle_info({:nodedown, node, _info}, state), do: handle_nodedown(node, state)
  def handle_info({:nodedown, node}, state), do: handle_nodedown(node, state)

  def handle_info({:probe_result, node, classification}, state) do
    # A node that went down while its probe was in flight must not be
    # resurrected in the table as foreign.
    if node in connected_nodes() do
      :ets.insert(@table, {node, classification})
    end

    {:noreply, release_waiters(node, classification, state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_nodeup(node, state) do
    # Drop any verdict from a previous connection: the peer may have started
    # or stopped :arbor_security while it was away.
    :ets.delete(@table, node)
    {:noreply, start_probe(node, state)}
  end

  defp handle_nodedown(node, state) do
    :ets.delete(@table, node)
    # Anyone waiting on this node is released as :foreign — a disconnected
    # node cannot accept a replayed request. Leaving them to time out would
    # stall the auth path for no reason.
    {:noreply, release_waiters(node, :foreign, state)}
  end

  defp release_waiters(node, classification, state) do
    {waiting, remaining} = Map.pop(state.waiters, node, [])
    Enum.each(waiting, &GenServer.reply(&1, classification))

    %{state | waiters: remaining, inflight: MapSet.delete(state.inflight, node)}
  end

  # =========================================================================
  # Probing
  # =========================================================================

  # Idempotent per node: a waiter arriving while the nodeup probe is still
  # running must not spawn a second `:erpc` against the same peer.
  defp start_probe(node, state) do
    if MapSet.member?(state.inflight, node) do
      state
    else
      owner = self()
      spawn(fn -> send(owner, {:probe_result, node, classify(node)}) end)
      %{state | inflight: MapSet.put(state.inflight, node)}
    end
  end

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
