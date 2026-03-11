defmodule Arbor.Signals.ClusterTestHelpers do
  @moduledoc """
  Helper functions that run on remote nodes during cluster integration tests.

  These are compiled on the remote node via LocalCluster's `files:` option,
  making them available for :erpc.call.

  Important: All start_* functions use Process.unlink/1 after start_link
  so the GenServer survives the :erpc caller process exiting.
  """

  # ── Signal Infrastructure ─────────────────────────────────────────────

  @doc "Start signal infrastructure children on the current node."
  def start_signal_children do
    children = [
      {Arbor.Signals.Store, []},
      {Arbor.Signals.TopicKeys, []},
      {Arbor.Signals.Channels, []},
      {Arbor.Signals.Bus, []},
      {Arbor.Signals.Relay, []}
    ]

    Application.put_env(:arbor_signals, :relay_enabled, true)
    Application.put_env(:arbor_signals, :relay_batch_interval_ms, 10)

    start_children(Arbor.Signals.Supervisor, children)
  end

  @doc "Subscribe to a pattern and forward matching signals to the given pid."
  def subscribe_and_forward(pattern, target_pid, label) do
    Arbor.Signals.Bus.subscribe(pattern, fn signal ->
      send(target_pid, {label, signal})
      :ok
    end)
  end

  @doc "Emit a cluster-scoped signal."
  def emit_cluster_signal(category, type, data) do
    Arbor.Signals.emit(category, type, data, scope: :cluster)
  end

  @doc "Emit a local-scoped signal (default)."
  def emit_local_signal(category, type, data) do
    Arbor.Signals.emit(category, type, data)
  end

  @doc "Get relay stats."
  def relay_stats do
    Arbor.Signals.Relay.stats()
  end

  # ── BufferedStore ──────────────────────────────────────────────────────

  @doc "Start a distributed BufferedStore instance."
  def start_buffered_store(name, collection) do
    mod = Arbor.Persistence.BufferedStore
    backend = Arbor.Persistence.Store.ETS

    opts = [
      name: name,
      backend: backend,
      backend_opts: [name: :"#{name}_backend"],
      collection: collection,
      distributed: true,
      write_mode: :sync
    ]

    start_and_unlink(mod, opts, name)
  end

  @doc "Put a value in a BufferedStore."
  def buffered_store_put(name, key, value) do
    apply(Arbor.Persistence.BufferedStore, :put, [key, value, [name: name]])
  end

  @doc "Get a value from a BufferedStore."
  def buffered_store_get(name, key) do
    apply(Arbor.Persistence.BufferedStore, :get, [key, [name: name]])
  end

  @doc "Delete a value from a BufferedStore."
  def buffered_store_delete(name, key) do
    apply(Arbor.Persistence.BufferedStore, :delete, [key, [name: name]])
  end

  @doc "Read directly from the ETS table (bypasses GenServer)."
  def ets_lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :table_not_found
  end

  # ── Memory DistributedSync ────────────────────────────────────────────

  @doc "Start Memory DistributedSync and create required ETS tables."
  def start_memory_distributed_sync do
    # Create ETS tables owned by a long-lived process (not the erpc caller).
    # Tables must be :public so DistributedSync and test helpers can access them.
    for table <- [:arbor_working_memory, :arbor_memory_graphs] do
      case :ets.info(table) do
        :undefined ->
          ensure_persistent_ets(table, [:named_table, :public, :set, {:read_concurrency, true}])
        _ ->
          :ok
      end
    end

    mod = Arbor.Memory.DistributedSync
    start_and_unlink(mod, [], mod)
  end

  @doc "Insert a value directly into an ETS table."
  def ets_insert(table, key, value) do
    :ets.insert(table, {key, value})
    :ok
  end

  @doc "Check if a key exists in an ETS table."
  def ets_exists?(table, key) do
    case :ets.lookup(table, key) do
      [{^key, _}] -> true
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  # ── Trust Store ───────────────────────────────────────────────────────

  @doc "Start Trust Store GenServer."
  def start_trust_store do
    mod = Arbor.Trust.Store
    start_and_unlink(mod, [], mod)
  end

  @doc "Create and store a trust profile, returns :ok."
  def create_and_store_profile(agent_id) do
    {:ok, profile} = apply(Arbor.Contracts.Trust.Profile, :new, [agent_id])
    apply(Arbor.Trust.Store, :store_profile, [profile])
    :ok
  end

  @doc "Get a trust profile."
  def get_trust_profile(agent_id) do
    apply(Arbor.Trust.Store, :get_profile, [agent_id])
  end

  # ── Gateway EndpointRegistry ──────────────────────────────────────────

  @doc "Start Gateway EndpointRegistry."
  def start_endpoint_registry do
    mod = Arbor.Gateway.MCP.EndpointRegistry

    case apply(mod, :start_link, []) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        {:ok, pid}
    end
  end

  @doc "Register an MCP endpoint."
  def register_endpoint(agent_id, tools) do
    apply(Arbor.Gateway.MCP.EndpointRegistry, :register, [agent_id, self(), tools])
  end

  @doc "Look up an MCP endpoint."
  def lookup_endpoint(agent_id) do
    apply(Arbor.Gateway.MCP.EndpointRegistry, :lookup, [agent_id])
  end

  @doc "List all MCP endpoints."
  def list_endpoints do
    apply(Arbor.Gateway.MCP.EndpointRegistry, :list, [])
  end

  @doc "Unregister an MCP endpoint."
  def unregister_endpoint(agent_id) do
    apply(Arbor.Gateway.MCP.EndpointRegistry, :unregister, [agent_id])
  end

  @doc "Read endpoint ETS table directly."
  def endpoint_ets_lookup(agent_id) do
    case :ets.lookup(:arbor_mcp_endpoints, agent_id) do
      [{^agent_id, location, tools, _ts}] -> {:ok, location, tools}
      [] -> :not_found
    end
  rescue
    ArgumentError -> :table_not_found
  end

  # ── Generic Helpers ───────────────────────────────────────────────────

  # Start a GenServer via start_link, then unlink so it survives
  # the :erpc caller process exiting.
  defp start_and_unlink(mod, opts, name) do
    case GenServer.start_link(mod, opts, name: name) do
      {:ok, pid} ->
        Process.unlink(pid)
        {:ok, pid}
      {:error, {:already_started, pid}} ->
        {:ok, pid}
    end
  end

  # Spawn a long-lived process to own an ETS table.
  # Without this, ETS tables created during :erpc.call are destroyed
  # when the caller process exits.
  defp ensure_persistent_ets(name, opts) do
    spawn(fn ->
      :ets.new(name, opts)
      # Block forever to keep the table alive
      ref = make_ref()
      receive do: (^ref -> :ok)
    end)

    # Wait for the table to be created
    wait_for_ets(name, 50)
  end

  defp wait_for_ets(_name, 0), do: :error
  defp wait_for_ets(name, retries) do
    case :ets.info(name) do
      :undefined ->
        Process.sleep(10)
        wait_for_ets(name, retries - 1)
      _ ->
        :ok
    end
  end

  defp start_children(supervisor, children) do
    for child <- children do
      case Supervisor.start_child(supervisor, child) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        {:error, :already_present} ->
          {mod, _} = child
          Supervisor.delete_child(supervisor, mod)
          Supervisor.start_child(supervisor, child)
        _ -> :ok
      end
    end

    :ok
  end
end
