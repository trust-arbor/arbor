defmodule Arbor.AI.LLMUsageOutbox do
  @moduledoc """
  Process-lifetime ETS outbox for `[:arbor, :llm, :usage]` handoff.

  The telemetry callback enqueues the validated event, then casts only the
  outbox id to `Arbor.AI.LLMUsageConsumer`. Entries survive a consumer crash
  and are redelivered until the consumer acks after ledger admission.

  The table is `:public` so enqueue/ack do not serialize through this
  GenServer mailbox. This process exists to own the table.
  """

  use GenServer

  @type id :: pos_integer()

  @doc """
  Start the outbox owner.

  Options:
  - `:name` — registered name (default `__MODULE__`). The ETS table name is
    derived from this name so named test instances stay isolated.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start(__MODULE__, opts, name: name)
  end

  @doc """
  Return a running outbox, starting an unlinked owner when absent.

  Unlinked start lets a named consumer crash without dropping pending rows.
  The production singleton is started by `Arbor.AI.Application` and is reused.
  """
  @spec ensure_started(atom()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case start(name: name) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @doc "Persist a validated usage event and return its outbox id."
  @spec enqueue(atom(), map()) :: {:ok, id()} | {:error, :outbox_unavailable}
  def enqueue(name, event_map) when is_atom(name) and is_map(event_map) do
    id = System.unique_integer([:monotonic, :positive])
    true = :ets.insert(table_name(name), {id, event_map})
    {:ok, id}
  rescue
    ArgumentError -> {:error, :outbox_unavailable}
  end

  @doc "Return one pending event or `:error` when the id is unknown."
  @spec lookup(atom(), id()) :: {:ok, map()} | :error | {:error, :outbox_unavailable}
  def lookup(name, id) when is_atom(name) and is_integer(id) and id > 0 do
    case :ets.lookup(table_name(name), id) do
      [{^id, event_map}] -> {:ok, event_map}
      [] -> :error
    end
  rescue
    ArgumentError -> {:error, :outbox_unavailable}
  end

  @doc "Remove an admitted (or abandoned) outbox row."
  @spec ack(atom(), id()) :: :ok | {:error, :outbox_unavailable}
  def ack(name, id) when is_atom(name) and is_integer(id) and id > 0 do
    true = :ets.delete(table_name(name), id)
    :ok
  rescue
    ArgumentError -> {:error, :outbox_unavailable}
  end

  @doc "Return pending `{id, event}` rows in enqueue order."
  @spec pending(atom()) :: [{id(), map()}]
  def pending(name) when is_atom(name) do
    name
    |> table_name()
    |> :ets.tab2list()
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  @doc false
  @spec stop(atom()) :: :ok
  def stop(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end

      nil ->
        :ok
    end
  end

  @impl true
  def init(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    table = table_name(name)

    tid =
      case :ets.whereis(table) do
        :undefined ->
          :ets.new(table, [:named_table, :ordered_set, :public, read_concurrency: true])

        existing ->
          existing
      end

    {:ok, %{name: name, table: tid}}
  end

  defp table_name(__MODULE__), do: :arbor_llm_usage_outbox
  defp table_name(name) when is_atom(name), do: Module.concat(name, Table)
end
