defmodule Arbor.Memory.Provenance do
  @moduledoc """
  Memory-owned live provenance for domain values.

  The sidecar binds each label to the exact JSON-shaped value held by a memory
  domain. Domain stores remain responsible for durable rehydration; when this
  process restarts, an absent live label resolves conservatively until that
  rehydration occurs.
  """

  use GenServer

  alias Arbor.Contracts.Security.{Taint, TaintEnvelope}

  @table :arbor_memory_provenance
  @max_identifier_bytes 256
  @max_domain_agent_entries 512

  @allowed_domains [
    :goal,
    :intent,
    :percept,
    :working_memory_base,
    :working_memory_aggregate,
    :working_memory_thought,
    :working_memory_goal,
    :working_memory_skill,
    :working_memory_concern,
    :working_memory_curiosity,
    :knowledge_node,
    :knowledge_pending_fact,
    :knowledge_pending_learning,
    :index_entry,
    :embedding,
    :proposal,
    :thinking_entry,
    :code_item,
    :self_knowledge,
    :preference,
    :relationship,
    :context_window
  ]

  @type domain ::
          :goal
          | :intent
          | :percept
          | :working_memory_base
          | :working_memory_aggregate
          | :working_memory_thought
          | :working_memory_goal
          | :working_memory_skill
          | :working_memory_concern
          | :working_memory_curiosity
          | :knowledge_node
          | :knowledge_pending_fact
          | :knowledge_pending_learning
          | :index_entry
          | :embedding
          | :proposal
          | :thinking_entry
          | :code_item
          | :self_knowledge
          | :preference
          | :relationship
          | :context_window

  @type provenance_status :: :verified | :legacy_unlabeled | :invalid_durable_provenance

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc "Returns the closed set of memory domains that can own provenance."
  @spec allowed_domains() :: [domain()]
  def allowed_domains, do: @allowed_domains

  @doc "Binds a taint label to an exact live domain payload."
  @spec put(domain(), String.t(), String.t(), term(), Taint.t()) ::
          :ok | {:error, atom()}
  def put(domain, agent_id, item_id, payload, taint) do
    with :ok <- validate_key(domain, agent_id, item_id),
         {:ok, envelope} <- TaintEnvelope.new(payload, taint),
         {:ok, persisted} <- TaintEnvelope.to_map(envelope) do
      call_owner({:put, {domain, agent_id, item_id}, persisted})
    end
  rescue
    _ -> {:error, :invalid_provenance}
  catch
    _, _ -> {:error, :invalid_provenance}
  end

  @doc "Resolves live provenance against the exact current domain payload."
  @spec resolve(domain(), String.t(), String.t(), term()) ::
          {:ok, Taint.t(), provenance_status()}
  def resolve(domain, agent_id, item_id, payload) do
    case validate_key(domain, agent_id, item_id) do
      :ok ->
        {domain, agent_id, item_id}
        |> lookup_envelope()
        |> resolve_lookup(payload)

      {:error, _reason} ->
        invalid_resolution()
    end
  rescue
    _ -> invalid_resolution()
  catch
    _, _ -> invalid_resolution()
  end

  @doc "Deletes one live provenance entry."
  @spec delete(domain(), String.t(), String.t()) :: :ok | {:error, atom()}
  def delete(domain, agent_id, item_id) do
    with :ok <- validate_key(domain, agent_id, item_id) do
      delete_through_owner({:delete, {domain, agent_id, item_id}})
    end
  end

  @doc "Return a bounded owner-mediated inventory for one domain and agent."
  @spec list_item_ids(domain(), String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def list_item_ids(domain, agent_id) do
    with :ok <- validate_domain(domain),
         :ok <- validate_identifier(agent_id, :invalid_agent_id) do
      call_owner({:list_item_ids, domain, agent_id})
    end
  end

  @doc "Delete every live entry for exactly one domain and agent."
  @spec delete_domain_agent(domain(), String.t()) :: :ok | {:error, atom()}
  def delete_domain_agent(domain, agent_id) do
    with :ok <- validate_domain(domain),
         :ok <- validate_identifier(agent_id, :invalid_agent_id) do
      delete_through_owner({:delete_domain_agent, domain, agent_id})
    end
  end

  @doc "Deletes every live provenance entry owned by an agent."
  @spec delete_agent(String.t()) :: :ok | {:error, atom()}
  def delete_agent(agent_id) do
    with :ok <- validate_identifier(agent_id, :invalid_agent_id) do
      delete_through_owner({:delete_agent, agent_id})
    end
  end

  @impl true
  def init(:ok) do
    table =
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table, owners: %{}, agents: %{}}}
  end

  @impl true
  def handle_call(
        {:put, {domain, agent_id, _item_id} = key, persisted},
        _from,
        %{table: table, owners: owners, agents: agents} = state
      ) do
    owner = {domain, agent_id}
    item_id = elem(key, 2)
    owner_ids = Map.get(owners, owner, MapSet.new())

    cond do
      MapSet.member?(owner_ids, item_id) ->
        true = :ets.insert(table, {key, persisted})
        {:reply, :ok, state}

      MapSet.size(owner_ids) >= @max_domain_agent_entries ->
        {:reply, {:error, :domain_inventory_limit_exceeded}, state}

      true ->
        true = :ets.insert(table, {key, persisted})

        owners = Map.put(owners, owner, MapSet.put(owner_ids, item_id))
        agents = Map.update(agents, agent_id, MapSet.new([domain]), &MapSet.put(&1, domain))

        {:reply, :ok, %{state | owners: owners, agents: agents}}
    end
  end

  def handle_call(
        {:delete, {domain, agent_id, _item_id} = key},
        _from,
        %{table: table} = state
      ) do
    true = :ets.delete(table, key)
    {:reply, :ok, remove_owner_item(state, domain, agent_id, elem(key, 2))}
  end

  def handle_call({:list_item_ids, domain, agent_id}, _from, %{owners: owners} = state) do
    ids = owners |> Map.get({domain, agent_id}, MapSet.new()) |> MapSet.to_list() |> Enum.sort()
    {:reply, {:ok, ids}, state}
  end

  def handle_call(
        {:delete_domain_agent, domain, agent_id},
        _from,
        %{table: table, owners: owners} = state
      ) do
    owners
    |> Map.get({domain, agent_id}, MapSet.new())
    |> Enum.each(&:ets.delete(table, {domain, agent_id, &1}))

    {:reply, :ok, remove_owner(state, domain, agent_id)}
  end

  def handle_call(
        {:delete_agent, agent_id},
        _from,
        %{table: table, owners: owners, agents: agents} = state
      ) do
    domains = Map.get(agents, agent_id, MapSet.new())

    Enum.each(domains, fn domain ->
      owners
      |> Map.get({domain, agent_id}, MapSet.new())
      |> Enum.each(&:ets.delete(table, {domain, agent_id, &1}))
    end)

    owners = Enum.reduce(domains, owners, &Map.delete(&2, {&1, agent_id}))
    {:reply, :ok, %{state | owners: owners, agents: Map.delete(agents, agent_id)}}
  end

  defp remove_owner_item(%{owners: owners} = state, domain, agent_id, item_id) do
    owner = {domain, agent_id}
    owner_ids = Map.get(owners, owner, MapSet.new())

    if MapSet.member?(owner_ids, item_id) do
      remaining = MapSet.delete(owner_ids, item_id)

      if MapSet.size(remaining) == 0 do
        remove_owner(state, domain, agent_id)
      else
        %{state | owners: Map.put(owners, owner, remaining)}
      end
    else
      state
    end
  end

  defp remove_owner(%{owners: owners, agents: agents} = state, domain, agent_id) do
    domains = agents |> Map.get(agent_id, MapSet.new()) |> MapSet.delete(domain)

    agents =
      if MapSet.size(domains) == 0,
        do: Map.delete(agents, agent_id),
        else: Map.put(agents, agent_id, domains)

    %{state | owners: Map.delete(owners, {domain, agent_id}), agents: agents}
  end

  defp validate_key(domain, agent_id, item_id) do
    with :ok <- validate_domain(domain),
         :ok <- validate_identifier(agent_id, :invalid_agent_id) do
      validate_identifier(item_id, :invalid_item_id)
    end
  end

  defp validate_domain(domain) when domain in @allowed_domains, do: :ok
  defp validate_domain(_domain), do: {:error, :invalid_domain}

  defp validate_identifier(value, error) when is_binary(value) do
    if byte_size(value) <= @max_identifier_bytes and String.valid?(value) and
         String.trim(value) != "" do
      :ok
    else
      {:error, error}
    end
  end

  defp validate_identifier(_value, error), do: {:error, error}

  defp call_owner(message) do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        try do
          GenServer.call(pid, message, :infinity)
        catch
          :exit, _reason ->
            if Process.whereis(__MODULE__) == pid,
              do: {:error, :provenance_unavailable},
              else: {:error, :provenance_absent}
        end

      nil ->
        {:error, :provenance_absent}
    end
  end

  defp delete_through_owner(message) do
    case call_owner(message) do
      {:error, :provenance_absent} -> :ok
      result -> result
    end
  end

  defp lookup_envelope(key) do
    with pid when is_pid(pid) <- Process.whereis(__MODULE__),
         table when table != :undefined <- :ets.whereis(@table),
         ^pid <- :ets.info(table, :owner) do
      case :ets.lookup(table, key) do
        [{^key, persisted}] -> {:found, persisted}
        [] -> :missing
        _unexpected -> :invalid_live_provenance
      end
    else
      nil -> :missing
      :undefined -> :missing
      _owner_mismatch -> :invalid_live_provenance
    end
  rescue
    ArgumentError -> :missing
  catch
    :error, :badarg -> :missing
    _, _ -> :invalid_live_provenance
  end

  defp resolve_lookup(:missing, payload), do: TaintEnvelope.resolve(:missing, payload)

  defp resolve_lookup({:found, persisted}, payload) do
    case persisted do
      :missing -> invalid_resolution()
      _other -> TaintEnvelope.resolve(persisted, payload)
    end
  end

  defp resolve_lookup(_invalid, _payload), do: invalid_resolution()

  defp invalid_resolution do
    {:ok, TaintEnvelope.invalid_fallback(), :invalid_durable_provenance}
  end
end
