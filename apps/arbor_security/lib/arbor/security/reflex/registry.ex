defmodule Arbor.Security.Reflex.Registry do
  @moduledoc """
  ETS-based storage for reflex definitions.

  Reflexes are stored in an ETS table for fast lookup during authorization.
  Built-in reflexes are loaded on startup, and custom reflexes can be
  registered dynamically.

  ## Storage Structure

  The registry uses a named ETS table with `:set` semantics:

      {reflex_id :: atom(), %Arbor.Contracts.Security.Reflex{}}

  Reflexes are indexed by their ID for O(1) lookup, but the check operation
  iterates all enabled reflexes sorted by priority.
  """

  use GenServer

  alias Arbor.Contracts.Security.Reflex
  alias Arbor.Security.Reflex.Builtin

  @table_name :arbor_reflex_registry

  # ── Client API ──

  @doc """
  Start the reflex registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a reflex.

  Returns `:ok` if the reflex was registered, or `{:error, :already_exists}`
  if a reflex with the same ID already exists (unless `:force` is true).

  ## Options

  - `:force` - If true, overwrite existing reflex with same ID
  """
  @spec register(atom(), Reflex.t(), keyword()) :: :ok | {:error, :already_exists}
  def register(id, %Reflex{} = reflex, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if force do
      :ets.insert(@table_name, {id, reflex})
      :ok
    else
      case :ets.insert_new(@table_name, {id, reflex}) do
        true -> :ok
        false -> {:error, :already_exists}
      end
    end
  end

  @doc """
  Unregister a reflex by ID.
  """
  @spec unregister(atom()) :: :ok | {:error, :not_found}
  def unregister(id) do
    case :ets.member(@table_name, id) do
      true ->
        :ets.delete(@table_name, id)
        :ok

      false ->
        {:error, :not_found}
    end
  end

  @doc """
  Get a reflex by ID.
  """
  @spec get(atom()) :: {:ok, Reflex.t()} | {:error, :not_found}
  def get(id) do
    case :ets.lookup(@table_name, id) do
      [{^id, reflex}] -> {:ok, reflex}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  List all registered reflexes.

  ## Options

  - `:enabled_only` - Only return enabled reflexes (default: false)
  - `:sorted` - Sort by priority, highest first (default: true)
  """
  @spec list(keyword()) :: [Reflex.t()]
  def list(opts \\ []) do
    enabled_only = Keyword.get(opts, :enabled_only, false)
    sorted = Keyword.get(opts, :sorted, true)

    reflexes =
      @table_name
      |> :ets.tab2list()
      |> Enum.map(fn {_id, reflex} -> reflex end)

    reflexes =
      if enabled_only do
        Enum.filter(reflexes, & &1.enabled)
      else
        reflexes
      end

    if sorted do
      Enum.sort_by(reflexes, & &1.priority, :desc)
    else
      reflexes
    end
  end

  @doc """
  Get registry statistics.
  """
  @spec stats() :: map()
  def stats do
    all = list(sorted: false)

    %{
      total: length(all),
      enabled: Enum.count(all, & &1.enabled),
      disabled: Enum.count(all, &(not &1.enabled)),
      by_type: Enum.frequencies_by(all, & &1.type),
      by_response: Enum.frequencies_by(all, & &1.response)
    }
  end

  @doc """
  Clear all reflexes (for testing).
  """
  @spec clear() :: :ok
  def clear do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  # ── GenServer Callbacks ──

  @impl GenServer
  def init(opts) do
    # Create the ETS table
    table_opts = [:set, :named_table, :public, read_concurrency: true]
    :ets.new(@table_name, table_opts)

    # Load built-in reflexes unless disabled
    unless Keyword.get(opts, :skip_builtin, false) do
      load_builtin_reflexes()
    end

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, stats(), state}
  end

  # ── Private Functions ──

  defp load_builtin_reflexes do
    for reflex <- Builtin.all() do
      # IDs come from trusted built-in definitions in Builtin module, not user input.
      # The set of built-in IDs is fixed at compile time, so no atom exhaustion risk.
      # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
      id = String.to_atom(reflex.id)
      :ets.insert(@table_name, {id, reflex})
    end
  end
end
