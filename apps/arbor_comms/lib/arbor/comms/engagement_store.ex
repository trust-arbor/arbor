defmodule Arbor.Comms.EngagementStore do
  @moduledoc """
  In-memory store + resolver for `Arbor.Contracts.Comms.Engagement` records.

  An Engagement is a device-independent conversation that channels attach to and
  Sessions key their per-conversation transcript on (see
  `.arbor/roadmap/2-planned/channels-as-engagements.md`). This store holds the
  records and resolves an inbound channel/context to its Engagement, creating one
  on first contact.

  ## Resolution

  `resolve_or_create/3` looks up by an opaque **resolution key** scoped to an
  agent. The key is whatever the caller's scope policy computes — `channel_id`
  for `:channel` scope (1:1), a user/tenant id for `:user` scope, etc. Keeping the
  key opaque lets the scope-policy decision live at the call site for now (it's
  one of the open design questions in the plan doc). Resolution is race-safe via
  `:ets.insert_new` on the index.

  ## Durability caveat (v1 — flagged follow-up)

  This is an in-memory ETS store. One limit remains before it's load-bearing,
  already in the plan ("ETS first, Postgres later"):

    * **Persistence** — engagements are not yet persisted. `Arbor.Persistence`
      gets an `EngagementStore` (mirroring `ChannelStore`) so engagements survive
      a full restart and support "show me all my conversations" cross-device
      queries. (Until then, an app restart loses in-memory engagements.)

  Table ownership is handled: a supervised GenServer (this module, started in
  `Arbor.Comms.Application`) owns the tables, so they persist for the app's
  lifetime rather than dying with a transient caller.
  """

  use GenServer

  alias Arbor.Contracts.Comms.Engagement

  @table :arbor_engagements
  @index :arbor_engagement_index

  # ── Table owner ──
  #
  # A lazily-created ETS table is owned by whatever process first touches it; if
  # that's a transient caller, the table dies with it (and under concurrency the
  # table churns, breaking resolution). So a long-lived supervised GenServer owns
  # the tables — its only job. The public API below still does direct, concurrent
  # ETS reads/writes (the GenServer is not on the hot path). `ensure_tables/0`
  # remains a defensive fallback for contexts where the owner isn't started.

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    ensure_tables()
    {:ok, %{}}
  end

  @doc "Store (insert or replace) an engagement by id."
  @spec put(Engagement.t()) :: :ok
  def put(%Engagement{id: id} = engagement) when is_binary(id) do
    ensure_tables()
    :ets.insert(@table, {id, engagement})
    :ok
  end

  @doc "Fetch an engagement by id."
  @spec get(String.t()) :: {:ok, Engagement.t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    ensure_tables()

    case :ets.lookup(@table, id) do
      [{_, engagement}] -> {:ok, engagement}
      [] -> {:error, :not_found}
    end
  end

  @doc "Delete an engagement (and any index entries pointing at it)."
  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    ensure_tables()
    :ets.delete(@table, id)
    :ets.match_delete(@index, {:_, id})
    :ok
  end

  @doc "All engagements for an agent (v1: full scan — fine at low volume)."
  @spec list_for_agent(String.t()) :: [Engagement.t()]
  def list_for_agent(agent_id) when is_binary(agent_id) do
    ensure_tables()

    :ets.tab2list(@table)
    |> Enum.flat_map(fn
      {_id, %Engagement{agent_id: ^agent_id} = e} -> [e]
      _ -> []
    end)
  end

  @doc """
  Resolve the engagement for `(agent_id, resolution_key)`, creating one if absent.

  `opts` are passed to `Engagement.new/1` only when creating (e.g. `scope:`,
  `visibility:`, `owner_tenant:`, `primary_channel:`). Race-safe: concurrent
  callers for the same key converge on a single engagement.
  """
  @spec resolve_or_create(String.t(), term(), keyword()) :: {:ok, Engagement.t()}
  def resolve_or_create(agent_id, resolution_key, opts \\ []) when is_binary(agent_id) do
    ensure_tables()

    case :ets.lookup(@index, {agent_id, resolution_key}) do
      [{_, id}] -> resolve_existing(id, agent_id, resolution_key, opts)
      [] -> create_and_claim(agent_id, resolution_key, opts)
    end
  end

  # The index points at an id; return it, or recreate if the record is gone
  # (stale index — e.g. the engagement was deleted out from under it).
  defp resolve_existing(id, agent_id, resolution_key, opts) do
    case get(id) do
      {:ok, _} = ok ->
        ok

      {:error, :not_found} ->
        :ets.delete(@index, {agent_id, resolution_key})
        create_and_claim(agent_id, resolution_key, opts)
    end
  end

  defp create_and_claim(agent_id, resolution_key, opts) do
    opts =
      opts
      |> Keyword.put(:agent_id, agent_id)
      |> maybe_stable_id(agent_id, resolution_key)

    engagement = Engagement.new(opts)

    # Atomic test-and-set: only the first caller to claim the index slot wins.
    if :ets.insert_new(@index, {{agent_id, resolution_key}, engagement.id}) do
      :ets.insert(@table, {engagement.id, engagement})
      {:ok, engagement}
    else
      # Lost the race — use whoever claimed it.
      [{_, winner_id}] = :ets.lookup(@index, {agent_id, resolution_key})
      get(winner_id)
    end
  end

  @doc "Attach a channel to an engagement (idempotent)."
  @spec attach_channel(String.t(), String.t()) ::
          {:ok, Engagement.t()} | {:error, :not_found}
  def attach_channel(id, channel_id) when is_binary(id) and is_binary(channel_id) do
    update(id, &Engagement.attach_channel(&1, channel_id))
  end

  @doc "Detach a channel from an engagement (the engagement persists)."
  @spec detach_channel(String.t(), String.t()) ::
          {:ok, Engagement.t()} | {:error, :not_found}
  def detach_channel(id, channel_id) when is_binary(id) and is_binary(channel_id) do
    update(id, &Engagement.detach_channel(&1, channel_id))
  end

  defp update(id, fun) do
    case get(id) do
      {:ok, engagement} ->
        updated = fun.(engagement)
        :ets.insert(@table, {id, updated})
        {:ok, updated}

      {:error, :not_found} = err ->
        err
    end
  end

  # :user / :role engagements are durable, addressable conversations — the same
  # (agent, resolution_key) MUST resolve to the same engagement_id across restarts
  # so engagement-stamped history stays consistent. The ETS index is cleared on
  # restart, but a deterministic id regenerates identically, giving stable ids
  # without requiring the store to be persisted yet (the Postgres follow-up).
  # :channel scope stays random (ephemeral, 1:1).
  defp maybe_stable_id(opts, agent_id, resolution_key) do
    if Keyword.get(opts, :scope) in [:user, :role] and is_nil(Keyword.get(opts, :id)) do
      Keyword.put(opts, :id, deterministic_id(agent_id, resolution_key))
    else
      opts
    end
  end

  defp deterministic_id(agent_id, resolution_key) do
    digest = :crypto.hash(:sha256, "#{agent_id}|#{inspect(resolution_key)}")
    "eng_" <> (digest |> Base.encode16(case: :lower) |> binary_part(0, 32))
  end

  defp ensure_tables do
    create_table(@table)
    create_table(@index)
    :ok
  end

  defp create_table(name) do
    if :ets.whereis(name) == :undefined do
      :ets.new(name, [:set, :public, :named_table])
    end

    :ok
  rescue
    # Lost the create race with a concurrent caller — the table now exists.
    ArgumentError -> :ok
  end
end
