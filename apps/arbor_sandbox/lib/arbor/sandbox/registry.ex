defmodule Arbor.Sandbox.Registry do
  @moduledoc """
  Registry for tracking active sandboxes.

  Maintains a mapping of sandbox IDs and agent IDs to sandbox state.
  """

  use GenServer

  # Client API

  @doc """
  Start the registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a new sandbox.
  """
  @spec register(map()) :: :ok
  def register(sandbox) do
    GenServer.call(__MODULE__, {:register, sandbox})
  end

  @doc """
  Get a sandbox by ID or agent ID.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(id_or_agent_id) do
    GenServer.call(__MODULE__, {:get, id_or_agent_id})
  end

  @doc """
  Unregister a sandbox.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(sandbox_id) do
    GenServer.call(__MODULE__, {:unregister, sandbox_id})
  end

  @doc """
  List all sandboxes.
  """
  @spec list(keyword()) :: {:ok, [map()]}
  def list(opts \\ []) do
    GenServer.call(__MODULE__, {:list, opts})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok,
     %{
       by_id: %{},
       by_agent: %{}
     }}
  end

  @impl true
  def handle_call({:register, sandbox}, _from, state) do
    state =
      state
      |> put_in([:by_id, sandbox.id], sandbox)
      |> put_in([:by_agent, sandbox.agent_id], sandbox.id)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get, id_or_agent_id}, _from, state) do
    result =
      case Map.get(state.by_id, id_or_agent_id) do
        nil ->
          # Try by agent ID
          case Map.get(state.by_agent, id_or_agent_id) do
            nil -> {:error, :not_found}
            sandbox_id -> {:ok, Map.fetch!(state.by_id, sandbox_id)}
          end

        sandbox ->
          {:ok, sandbox}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:unregister, sandbox_id}, _from, state) do
    case Map.get(state.by_id, sandbox_id) do
      nil ->
        {:reply, :ok, state}

      sandbox ->
        state =
          state
          |> update_in([:by_id], &Map.delete(&1, sandbox_id))
          |> update_in([:by_agent], &Map.delete(&1, sandbox.agent_id))

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    sandboxes = Map.values(state.by_id)

    sandboxes =
      case Keyword.get(opts, :level) do
        nil -> sandboxes
        level -> Enum.filter(sandboxes, &(&1.level == level))
      end

    sandboxes =
      case Keyword.get(opts, :limit) do
        nil -> sandboxes
        limit -> Enum.take(sandboxes, limit)
      end

    {:reply, {:ok, sandboxes}, state}
  end
end
