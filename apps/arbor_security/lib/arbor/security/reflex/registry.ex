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
  alias Arbor.Security.SupervisedOwner

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

  if Mix.env() == :test do
    @doc false
    @spec register_fixture(atom(), Reflex.t(), keyword()) :: :ok | {:error, :already_exists}
    def register_fixture(id, %Reflex{} = reflex, opts \\ []) do
      owner_call(
        {:register_fixture, id, reflex, opts},
        {:error, :reflex_registry_unavailable}
      )
    end

    @doc false
    @spec unregister_fixture(atom()) :: :ok | {:error, :not_found}
    def unregister_fixture(id) when is_atom(id) do
      owner_call({:unregister_fixture, id}, {:error, :reflex_registry_unavailable})
    end
  end

  @doc """
  Get a reflex by ID.
  """
  @spec get(atom()) :: {:ok, Reflex.t()} | {:error, :not_found}
  def get(id) do
    records =
      if owned_table?() do
        :ets.lookup(@table_name, id)
      else
        Builtin.all()
        |> Enum.filter(&(&1.id == Atom.to_string(id)))
        |> Enum.map(&{id, &1})
      end

    case records do
      [{^id, reflex}] -> {:ok, reflex}
      [] -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  catch
    :exit, _ -> {:error, :not_found}
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
      if owned_table?() do
        @table_name
        |> :ets.tab2list()
        |> Enum.map(fn {_id, reflex} -> reflex end)
      else
        # Runtime mutation is retired in production, so the immutable built-in
        # projection is the complete safe fallback. Never trust a replacement
        # named table whose owner is not the exact supervised Registry child.
        Builtin.all()
      end

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
  rescue
    _ -> fallback_list(opts)
  catch
    :exit, _ -> fallback_list(opts)
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

  # ── GenServer Callbacks ──

  @impl GenServer
  def init(opts) do
    # Create the ETS table
    table_opts = [:set, :named_table, :protected, read_concurrency: true]
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

  if Mix.env() == :test do
    def handle_call({:register_fixture, id, %Reflex{} = reflex, opts}, _from, state)
        when is_atom(id) and is_list(opts) do
      reply = owner_register(id, reflex, Keyword.get(opts, :force, false) == true)
      {:reply, reply, state}
    end

    def handle_call({:unregister_fixture, id}, _from, state) when is_atom(id) do
      reply =
        if :ets.member(@table_name, id) do
          :ets.delete(@table_name, id)
          :ok
        else
          {:error, :not_found}
        end

      {:reply, reply, state}
    end
  end

  def handle_call({operation, _id, _value, _opts}, _from, state)
      when operation in [:register, :register_fixture],
      do: {:reply, {:error, :reflex_mutation_unauthorized}, state}

  def handle_call({operation, _id}, _from, state)
      when operation in [:unregister, :unregister_fixture],
      do: {:reply, {:error, :reflex_mutation_unauthorized}, state}

  defp owned_table? do
    case SupervisedOwner.registered_child(__MODULE__, :arbor_security, [__MODULE__]) do
      pid when is_pid(pid) -> :ets.info(@table_name, :owner) == pid
      nil -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp fallback_list(opts) do
    reflexes =
      if Keyword.get(opts, :enabled_only, false),
        do: Enum.filter(Builtin.all(), & &1.enabled),
        else: Builtin.all()

    if Keyword.get(opts, :sorted, true),
      do: Enum.sort_by(reflexes, & &1.priority, :desc),
      else: reflexes
  end

  if Mix.env() == :test do
    defp owner_call(request, unavailable) do
      case SupervisedOwner.registered_child(__MODULE__, :arbor_security, [__MODULE__]) do
        pid when is_pid(pid) -> GenServer.call(pid, request)
        nil -> unavailable
      end
    rescue
      _ -> unavailable
    catch
      :exit, _ -> unavailable
    end
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

  if Mix.env() == :test do
    defp owner_register(id, reflex, true) do
      :ets.insert(@table_name, {id, reflex})
      :ok
    end

    defp owner_register(id, reflex, false) do
      if :ets.insert_new(@table_name, {id, reflex}),
        do: :ok,
        else: {:error, :already_exists}
    end
  end
end
