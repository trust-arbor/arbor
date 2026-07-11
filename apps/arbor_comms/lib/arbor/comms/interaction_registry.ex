defmodule Arbor.Comms.InteractionRegistry do
  @moduledoc """
  Cluster-aware storage for outstanding `Interaction` requests.

  The registry serves three purposes:

    1. Channel adapters that receive a response on Node B can look up
       the originating interaction record without holding any agent
       state — `respond/3` finds the record by `request_id` and
       publishes back via PubSub on the right per-agent topic.
    2. Cluster-coherent: a `put` on Node A is visible from Node B's
       `get`/`list_pending_for_user` within the Phoenix.Tracker
       merge interval (~10ms). This matters because the Signal
       poller and the agent that submitted the interaction can run
       on different nodes.
    3. Audit — the registry's pending+resolved state is the source of
       truth for "what did we ask the human, and what did they
       answer."

  ## Implementation (2026-06-06 cluster refactor)

  Phoenix.Tracker on top of `Arbor.Comms.PubSub` — the same bus
  `PresenceTracker` uses, so cluster-coherency is symmetric across
  the two registries. Eventually consistent: `track` returns
  immediately, the entry propagates to other nodes within the
  Tracker's merge interval. For interaction-request lookup latency
  this is well below the human-response latency the registry is
  serving, so the consistency model is fine.

  A dedicated `Owner` process holds every tracked entry's owning
  pid. That process lives for the lifetime of the supervisor;
  entries don't die with the calling agent. If the Owner crashes,
  its local entries vanish — but other nodes' replicas remain
  visible via Tracker's CRDT merge, so cluster-wide state survives
  any single-node restart.

  Pre-2026-06-06: this was an ETS-only single-node store. A
  `put` on Node A was invisible to Node B's `get`, so the Signal
  poller's `Router.maybe_route_as_interaction` returned `:not_found`
  for any interaction created on a peer — silently passing the
  operator's approval reply to the chat handler instead of routing
  it. The refactor fixes that.

  ## Future work

  - **Persistence across cluster-wide restart.** Tracker is
    in-memory; if every node restarts simultaneously, pending
    interactions vanish. Postgres-backed store (BufferedStore +
    read-fallthrough, matching the EventLog refactor that landed
    earlier today) is the right answer when this becomes a real
    issue. Documented in `5-completed/human-in-the-loop-router.md`
    under "What's not done."
  """

  use Phoenix.Tracker

  require Logger

  alias Arbor.Contracts.Comms.Interaction

  # All interactions land on this single topic. Tracker filters keys
  # within the topic, so per-user partitioning would buy little for a
  # registry this small (dozens of pending entries at most).
  @topic "interactions"
  @resolved_table :arbor_interaction_resolved
  # Keep resolved answers long enough for a waiter that subscribed after the
  # response was published (visible-request-before-subscribe race).
  @resolved_ttl_ms 120_000

  ## Public API

  @doc "Start the Tracker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    ensure_resolved_table!()
    pubsub = Keyword.get(opts, :pubsub_server, Arbor.Comms.PubSub)
    opts = Keyword.merge([name: __MODULE__, pubsub_server: pubsub], opts)
    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @doc """
  Record a new outstanding interaction. Returns the interaction back
  for chaining. Eventually-consistent across the cluster — visible
  from peer nodes within the Tracker merge interval (~10ms).
  """
  @spec put(Interaction.t(), keyword()) :: {:ok, Interaction.t()} | {:error, term()}
  def put(%Interaction{request_id: id} = interaction, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    owner = ensure_owner!()

    case Phoenix.Tracker.track(name, owner, @topic, id, %{interaction: interaction}) do
      {:ok, _ref} -> {:ok, interaction}
      {:error, {:already_tracked, _, _, _}} -> {:ok, interaction}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[InteractionRegistry] put failed: #{Exception.message(e)}")
      {:error, :tracker_unavailable}
  end

  @doc """
  Look up a pending interaction by request_id. Cluster-wide search.

  Note on cross-node struct shape: Phoenix.Tracker meta is replicated
  via the PubSub bus, which goes through Erlang distribution. In some
  paths the `%Interaction{}` struct arrives on peer nodes as a plain
  map (no `__struct__` key). `materialize_interaction/1` reconstructs
  the struct from either shape so callers always get the canonical
  type.
  """
  @spec get(String.t()) :: {:ok, Interaction.t()} | :not_found
  def get(request_id) when is_binary(request_id) do
    case lookup_meta(request_id) do
      %{interaction: data} -> {:ok, materialize_interaction(data)}
      _ -> :not_found
    end
  rescue
    _ -> :not_found
  end

  @doc """
  Mark an interaction resolved and remove it from the pending set.
  Returns the original interaction (so adapters can use its
  `response_topic` for the broadcast that follows).

  When `response` is supplied (keyword opts `:response` / `:metadata`), the
  answer is stored in a durable local lookup so waiters that subscribe after
  the response is published can still observe it without sleeping.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, Interaction.t()} | :not_found
  def resolve(request_id, opts \\ []) when is_binary(request_id) do
    name = Keyword.get(opts, :name, __MODULE__)

    case lookup_meta(request_id) do
      %{interaction: data} ->
        # Untrack from THIS node's Tracker entry. CRDT merge will
        # propagate the removal to peers within the merge interval.
        # If the entry was created on another node, untrack here is a
        # no-op locally but emits a cluster signal anyway — the
        # owning node observes the diff and clears its entry. For the
        # common path (same node owns the entry) this is correct
        # immediately.
        owner = ensure_owner!()
        Phoenix.Tracker.untrack(name, owner, @topic, request_id)

        if Keyword.has_key?(opts, :response) do
          put_resolved(
            request_id,
            Keyword.get(opts, :response),
            Keyword.get(opts, :metadata, %{}) || %{}
          )
        end

        {:ok, materialize_interaction(data)}

      _ ->
        :not_found
    end
  rescue
    e ->
      Logger.warning("[InteractionRegistry] resolve failed: #{Exception.message(e)}")
      :not_found
  end

  @doc """
  Look up a durable resolved answer for `request_id`.

  Used by waiters that may have subscribed after the response was published.
  Entries expire after a short TTL.
  """
  @spec get_resolved(String.t()) ::
          {:ok, %{response: term(), metadata: map(), resolved_at: integer()}} | :not_found
  def get_resolved(request_id) when is_binary(request_id) do
    ensure_resolved_table!()
    now = System.system_time(:millisecond)

    case :ets.lookup(@resolved_table, request_id) do
      [{^request_id, %{resolved_at: at} = payload}] when is_integer(at) ->
        if now - at <= @resolved_ttl_ms do
          {:ok, payload}
        else
          :ets.delete(@resolved_table, request_id)
          :not_found
        end

      _ ->
        :not_found
    end
  rescue
    _ -> :not_found
  end

  @doc false
  @spec put_resolved(String.t(), term(), map()) :: :ok
  def put_resolved(request_id, response, metadata)
      when is_binary(request_id) and is_map(metadata) do
    ensure_resolved_table!()

    :ets.insert(
      @resolved_table,
      {request_id,
       %{
         response: response,
         metadata: metadata,
         resolved_at: System.system_time(:millisecond)
       }}
    )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  List all currently-pending interactions across the cluster.
  Newest entries are not specially ordered here — callers that need
  ordering should sort by `submitted_at`.
  """
  @spec list_pending() :: [Interaction.t()]
  def list_pending do
    __MODULE__
    |> Phoenix.Tracker.list(@topic)
    |> Enum.flat_map(fn
      {_key, %{interaction: data}} -> [materialize_interaction(data)]
      _ -> []
    end)
  rescue
    _ -> []
  end

  @doc """
  Pending interactions for a specific user, newest first.

  Used by `Arbor.Comms.Router` to resolve adapter `:partial`
  responses ("APPROVE" without an `irq_<hex>` id) to the operator's
  most-recent pending request. Cluster-wide — entries created on
  any node are included.
  """
  @spec list_pending_for_user(String.t()) :: [Interaction.t()]
  def list_pending_for_user(user_id) when is_binary(user_id) do
    list_pending()
    |> Enum.filter(fn %Interaction{user_id: uid} -> uid == user_id end)
    |> Enum.sort_by(& &1.submitted_at, {:desc, DateTime})
  end

  @doc """
  Reset all registry state (test-only). Untracks everything this
  node currently owns. Peer-node entries are NOT cleared — for
  cluster-wide test reset, every node must call this.
  """
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    owner = ensure_owner!()

    name
    |> Phoenix.Tracker.list(@topic)
    |> Enum.each(fn {key, _meta} ->
      Phoenix.Tracker.untrack(name, owner, @topic, key)
    end)

    ensure_resolved_table!()
    :ets.delete_all_objects(@resolved_table)

    # Give the merge a tick to settle for synchronous test code.
    Process.sleep(20)
    :ok
  rescue
    _ -> :ok
  end

  ## Phoenix.Tracker callbacks

  @impl true
  def init(opts) do
    ensure_resolved_table!()
    server = Keyword.fetch!(opts, :pubsub_server)
    {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
  end

  @impl true
  def handle_diff(_diff, state) do
    # Phase 1: no subscribers care about diff events (the Router
    # learns about responses via the normal Signal poller path, not
    # via Tracker diffs). Add diff subscribers later if dashboards
    # want to react to peer-node interaction events in real time.
    {:ok, state}
  end

  ## Private

  # Look up a tracked entry's meta by request_id across cluster state.
  defp lookup_meta(request_id) do
    __MODULE__
    |> Phoenix.Tracker.list(@topic)
    |> Enum.find_value(fn
      {^request_id, meta} -> meta
      _ -> nil
    end)
  end

  defp ensure_resolved_table! do
    case :ets.info(@resolved_table) do
      :undefined ->
        :ets.new(@resolved_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _info ->
        @resolved_table
    end
  rescue
    ArgumentError ->
      # Concurrent create race: another process won.
      @resolved_table
  end

  # Owning pid for all tracked entries on this node. We use the
  # Tracker's own GenServer pid — it lives for the supervisor's
  # lifetime, and tracking against it means entries vanish if the
  # Tracker process itself dies (which is the right semantics —
  # other nodes' replicas survive).
  defp ensure_owner! do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> pid
      nil -> raise "InteractionRegistry not running"
    end
  end

  # Reconstruct an `%Interaction{}` struct from either a struct (local
  # node, same-process put/get) or a plain map (cross-node replicated
  # meta — Phoenix.Tracker's CRDT distribution serializes struct
  # values through Erlang term encoding and the receiving node ends up
  # with a regular map). Confirmed empirically 2026-06-06 on the
  # homelab cluster: a `put` on node A produced a struct in node A's
  # local tracker state but a map (no `__struct__` key) on node B's
  # tracker state. Both shapes need to be acceptable.
  defp materialize_interaction(%Interaction{} = i), do: i

  defp materialize_interaction(%{} = m) do
    struct(Interaction, atomize_known_keys(m))
  end

  @interaction_keys ~w(
    request_id kind agent_id user_id description metadata resource_uri
    urgency expires_at response_topic submitted_at
  )a

  defp atomize_known_keys(map) do
    Enum.reduce(@interaction_keys, %{}, fn key, acc ->
      cond do
        Map.has_key?(map, key) ->
          Map.put(acc, key, Map.get(map, key))

        Map.has_key?(map, Atom.to_string(key)) ->
          Map.put(acc, key, Map.get(map, Atom.to_string(key)))

        true ->
          acc
      end
    end)
  end
end
