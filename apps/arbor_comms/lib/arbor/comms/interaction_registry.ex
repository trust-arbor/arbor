defmodule Arbor.Comms.InteractionRegistry do
  @moduledoc """
  Cluster-aware storage for outstanding `Interaction` requests.

  The registry serves three purposes:

    1. Channel adapters that receive a response on Node B can look up
       the originating interaction record without holding any agent
       state — `respond/3` finds the record by `request_id` and
       publishes back via PubSub on the right per-agent topic.
    2. Node restarts shouldn't lose pending interactions. The ETS
       backing is per-node; future Phases can swap in a BufferedStore
       backend with the same API.
    3. Audit — the registry's history is the source of truth for
       "what did we ask the human, and what did they answer."

  ## Phase 1 implementation

  Local ETS table owned by a GenServer for serialization of writes.
  Reads bypass the GenServer for low latency. Cluster correctness
  comes from PubSub on response routing — the registry just needs to
  be reachable on whichever node the responding adapter runs on.

  For full cluster-wide pending state, a future Phase swaps the ETS
  backend for a distributed store (BufferedStore + replication, or a
  CRDT). The public API stays the same.
  """

  use GenServer
  require Logger

  alias Arbor.Contracts.Comms.Interaction

  @table :arbor_interaction_registry

  ## Public API

  @doc "Start the registry (named, single per node)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Record a new outstanding interaction. Stored under its `request_id`.
  Returns the same interaction back for chaining.
  """
  @spec put(Interaction.t(), keyword()) :: {:ok, Interaction.t()} | {:error, term()}
  def put(%Interaction{} = interaction, opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:put, interaction})
  end

  @doc """
  Look up a pending interaction by request_id. Returns the interaction
  if found, `:not_found` otherwise. ETS read — no GenServer hop.
  """
  @spec get(String.t()) :: {:ok, Interaction.t()} | :not_found
  def get(request_id) when is_binary(request_id) do
    case :ets.lookup(@table, request_id) do
      [{^request_id, %Interaction{} = interaction}] -> {:ok, interaction}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :not_found
  end

  @doc """
  Mark an interaction resolved and remove it from the pending set.
  Returns the original interaction (so adapters can use its
  `response_topic` for the broadcast that follows).
  """
  @spec resolve(String.t(), keyword()) :: {:ok, Interaction.t()} | :not_found
  def resolve(request_id, opts \\ []) when is_binary(request_id) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, {:resolve, request_id})
  end

  @doc """
  List all currently-pending interactions. Used by the dashboard to
  show "you have N pending approvals" and by audit queries.
  """
  @spec list_pending() :: [Interaction.t()]
  def list_pending do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_id, interaction} -> interaction end)
  rescue
    ArgumentError -> []
  end

  @doc "Reset all registry state (test-only)."
  @spec reset(keyword()) :: :ok
  def reset(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.call(name, :reset)
  end

  ## GenServer

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, %Interaction{request_id: id} = interaction}, _from, state) do
    :ets.insert(@table, {id, interaction})
    {:reply, {:ok, interaction}, state}
  end

  def handle_call({:resolve, id}, _from, state) do
    case :ets.lookup(@table, id) do
      [{^id, %Interaction{} = interaction}] ->
        :ets.delete(@table, id)
        {:reply, {:ok, interaction}, state}

      [] ->
        {:reply, :not_found, state}
    end
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
