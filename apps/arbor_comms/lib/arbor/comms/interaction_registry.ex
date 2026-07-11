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

  ## Resolved answers (cluster-coherent, bounded)

  Resolved responses are Tracker-backed (`@resolved_topic`) so a waiter
  on another node can observe an already-published answer without
  sleeping or depending on local-only `:public` ETS. Entries carry a
  `resolved_at` timestamp; reads expire them after a short TTL and
  hard-cap the resolved topic size to avoid unbounded tombstone leaks.
  Notes are bounded before storage.
  """

  use Phoenix.Tracker

  require Logger

  alias Arbor.Contracts.Comms.ApprovalAnswer
  alias Arbor.Contracts.Comms.Interaction

  # All interactions land on this single topic. Tracker filters keys
  # within the topic, so per-user partitioning would buy little for a
  # registry this small (dozens of pending entries at most).
  @topic "interactions"
  @resolved_topic "interactions:resolved"
  # Keep resolved answers long enough for a waiter that subscribed after the
  # response was published (visible-request-before-subscribe race).
  @resolved_ttl_ms 120_000
  # Hard bound on resolved Tracker entries (cluster-wide approx per node view).
  @resolved_max_entries 512

  ## Public API

  @doc "Start the Tracker."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
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
    case lookup_meta(@topic, request_id) do
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
  answer is stored in the cluster-aware resolved topic (plus a bounded local
  protected cache) so waiters that subscribe after the response is published
  can still observe it without sleeping.
  """
  @spec resolve(String.t(), keyword()) :: {:ok, Interaction.t()} | :not_found
  def resolve(request_id, opts \\ []) when is_binary(request_id) do
    name = Keyword.get(opts, :name, __MODULE__)

    case lookup_meta(@topic, request_id) do
      %{interaction: data} ->
        # Untrack from THIS node's Tracker entry. CRDT merge will
        # propagate the removal to peers within the merge interval.
        owner = ensure_owner!()
        Phoenix.Tracker.untrack(name, owner, @topic, request_id)

        if Keyword.has_key?(opts, :response) do
          put_resolved(
            request_id,
            Keyword.get(opts, :response),
            Keyword.get(opts, :metadata, %{}) || %{},
            name: name
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

  Cluster-coherent via the Tracker-replicated resolved topic so a waiter on
  another node does not lose an already-resolved answer. Entries expire
  after a short TTL.
  """
  @spec get_resolved(String.t()) ::
          {:ok, %{response: term(), metadata: map(), resolved_at: integer()}} | :not_found
  def get_resolved(request_id) when is_binary(request_id) do
    now = System.system_time(:millisecond)
    tracker_get_resolved(request_id, now)
  rescue
    _ -> :not_found
  end

  @doc false
  @spec put_resolved(String.t(), term(), map(), keyword()) :: :ok
  def put_resolved(request_id, response, metadata, opts \\ [])
      when is_binary(request_id) and is_map(metadata) do
    name = Keyword.get(opts, :name, __MODULE__)
    now = System.system_time(:millisecond)
    bounded_meta = bound_resolved_metadata(metadata)

    payload = %{
      response: response,
      metadata: bounded_meta,
      resolved_at: now
    }

    # Tracker: cluster-visible durable answer with protected ownership
    # (Tracker GenServer is the owning pid — not a world-writable ETS table).
    owner = ensure_owner!()

    case Phoenix.Tracker.track(name, owner, @resolved_topic, request_id, payload) do
      {:ok, _ref} ->
        :ok

      {:error, {:already_tracked, _, _, _}} ->
        _ = Phoenix.Tracker.update(name, owner, @resolved_topic, request_id, fn _ -> payload end)
        :ok

      {:error, reason} ->
        Logger.warning("[InteractionRegistry] track resolved failed: #{inspect(reason)}")
        :ok
    end

    maybe_prune_resolved(name, owner, now)
    :ok
  rescue
    e ->
      Logger.warning("[InteractionRegistry] put_resolved failed: #{Exception.message(e)}")
      :ok
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

    for topic <- [@topic, @resolved_topic] do
      name
      |> Phoenix.Tracker.list(topic)
      |> Enum.each(fn {key, _meta} ->
        Phoenix.Tracker.untrack(name, owner, topic, key)
      end)
    end

    # Give the merge a tick to settle for synchronous test code.
    Process.sleep(20)
    :ok
  rescue
    _ -> :ok
  end

  ## Phoenix.Tracker callbacks

  @impl true
  def init(opts) do
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

  defp lookup_meta(topic, request_id) do
    __MODULE__
    |> Phoenix.Tracker.list(topic)
    |> Enum.find_value(fn
      {^request_id, meta} -> meta
      _ -> nil
    end)
  end

  defp tracker_get_resolved(request_id, now) do
    case lookup_meta(@resolved_topic, request_id) do
      %{response: response, metadata: metadata, resolved_at: at}
      when is_integer(at) ->
        if now - at <= @resolved_ttl_ms do
          {:ok,
           %{
             response: response,
             metadata: if(is_map(metadata), do: metadata, else: %{}),
             resolved_at: at
           }}
        else
          # Expired: untrack to avoid unbounded tombstone growth.
          drop_resolved(request_id)
          :not_found
        end

      %{response: response} = payload ->
        # Tolerate partial meta shapes from older peers.
        at = Map.get(payload, :resolved_at) || Map.get(payload, "resolved_at") || now
        metadata = Map.get(payload, :metadata) || Map.get(payload, "metadata") || %{}

        if is_integer(at) and now - at <= @resolved_ttl_ms do
          {:ok, %{response: response, metadata: metadata, resolved_at: at}}
        else
          drop_resolved(request_id)
          :not_found
        end

      _ ->
        :not_found
    end
  end

  defp drop_resolved(request_id) do
    owner = ensure_owner!()
    Phoenix.Tracker.untrack(__MODULE__, owner, @resolved_topic, request_id)
  rescue
    _ -> :ok
  end

  defp maybe_prune_resolved(name, owner, now) do
    entries =
      name
      |> Phoenix.Tracker.list(@resolved_topic)
      |> Enum.flat_map(fn
        {key, meta} when is_map(meta) ->
          at = Map.get(meta, :resolved_at) || Map.get(meta, "resolved_at")
          if is_integer(at), do: [{key, at}], else: []

        _ ->
          []
      end)

    # Drop expired.
    Enum.each(entries, fn {key, at} ->
      if now - at > @resolved_ttl_ms do
        Phoenix.Tracker.untrack(name, owner, @resolved_topic, key)
      end
    end)

    # Hard entry bound: drop oldest when over cap.
    live =
      entries
      |> Enum.reject(fn {_k, at} -> now - at > @resolved_ttl_ms end)
      |> Enum.sort_by(fn {_k, at} -> at end)

    excess = length(live) - @resolved_max_entries

    if excess > 0 do
      live
      |> Enum.take(excess)
      |> Enum.each(fn {key, _} ->
        Phoenix.Tracker.untrack(name, owner, @resolved_topic, key)
      end)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp bound_resolved_metadata(metadata) when is_map(metadata) do
    note = Map.get(metadata, :note) || Map.get(metadata, "note")

    case note do
      n when is_binary(n) ->
        bounded =
          case ApprovalAnswer.validate_note(n, truncate: true, drop_invalid: true) do
            {:ok, b} -> b
            _ -> ""
          end

        metadata
        |> Map.put(:note, bounded)
        |> Map.delete("note")

      _ ->
        metadata
    end
  end

  defp bound_resolved_metadata(_), do: %{}

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
