defmodule Arbor.Orchestrator.L4ClusterRecoverySupport do
  @moduledoc """
  Test-only harness for Engine L4 application-restart and owner-node-loss proofs.

  Provides:

  - a controller-owned linearizable GenServer store (shared by remote peers)
  - a remote Proxy store module used only through `Arbor.Persistence`
  - a side-effecting handler that records invocations centrally
  - remote configure/start helpers for `:arbor_orchestrator`

  ## Assurance boundary (explicit non-claims)

  These helpers prove owner BEAM termination and application restart against a
  single controller GenServer store on one physical Mac. They do **not** prove
  network partitions, old-owner write fencing, storage failover,
  shared-filesystem loss, or physical-host durability. Postgres availability is
  intentionally not required — the controller GenServer is the test
  linearization point; production Postgres CAS has separate suites.
  """

  alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord
  alias Arbor.Contracts.Security.Capability
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Security.CapabilityStore

  @handler_type "l4_cluster_side"

  # ---------------------------------------------------------------------------
  # Controller-owned central store (survives remote app / node loss)
  # ---------------------------------------------------------------------------

  defmodule CentralStore do
    @moduledoc false
    use GenServer

    alias Arbor.Contracts.Persistence.Record, as: PersistenceRecord

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def put(server, logical, key, value),
      do: GenServer.call(server, {:put, logical, key, value}, 30_000)

    def get(server, logical, key),
      do: GenServer.call(server, {:get, logical, key}, 30_000)

    def list(server, logical),
      do: GenServer.call(server, {:list, logical}, 30_000)

    def delete(server, logical, key),
      do: GenServer.call(server, {:delete, logical, key}, 30_000)

    def compare_and_swap(server, logical, key, expected, replacement),
      do:
        GenServer.call(
          server,
          {:compare_and_swap, logical, key, expected, replacement},
          30_000
        )

    def record_invocation(server, event),
      do: GenServer.call(server, {:record_invocation, event}, 30_000)

    def invocation_count(server),
      do: GenServer.call(server, :invocation_count, 30_000)

    def invocations(server),
      do: GenServer.call(server, :invocations, 30_000)

    def set_resume_material(server, material),
      do: GenServer.call(server, {:set_resume_material, material}, 5_000)

    def get_resume_material(server),
      do: GenServer.call(server, :get_resume_material, 5_000)

    def release_hold(server),
      do: GenServer.call(server, :release_hold, 5_000)

    def held?(server),
      do: GenServer.call(server, :held?, 5_000)

    def has_key?(server, logical, key),
      do: GenServer.call(server, {:has_key?, logical, key}, 5_000)

    @impl true
    def init(opts) do
      {:ok,
       %{
         parent: Keyword.fetch!(opts, :parent),
         hold_store: Keyword.fetch!(opts, :hold_store),
         hold_on: Keyword.get(opts, :hold_on, :completed_progress),
         hold_node: Keyword.get(opts, :hold_node, "task"),
         hold_fired?: false,
         held_from: nil,
         held_key: nil,
         data: %{},
         invocations: [],
         resume_material: nil
       }}
    end

    @impl true
    def handle_call({:put, logical, key, value}, from, state) do
      case apply_put(Map.get(state.data, {logical, key}, :absent), key, value) do
        {:ok, stored} ->
          new_data = Map.put(state.data, {logical, key}, stored)

          if should_hold?(state, logical, stored) do
            send(
              state.parent,
              {:l4_store_held, state.hold_on,
               %{
                 logical: logical,
                 key: key,
                 effect: effect_from_value(stored),
                 completed_nodes: completed_nodes_from_value(stored)
               }}
            )

            {:noreply,
             %{
               state
               | data: new_data,
                 hold_fired?: true,
                 held_from: from,
                 held_key: {logical, key}
             }}
          else
            {:reply, :ok, %{state | data: new_data}}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end

    def handle_call({:get, logical, key}, _from, state) do
      case Map.fetch(state.data, {logical, key}) do
        {:ok, {:tombstone, _}} -> {:reply, {:error, :not_found}, state}
        {:ok, value} -> {:reply, {:ok, value}, state}
        :error -> {:reply, {:error, :not_found}, state}
      end
    end

    def handle_call({:list, logical}, _from, state) do
      keys =
        state.data
        |> Enum.filter(fn
          {{^logical, _key}, {:tombstone, _}} -> false
          {{^logical, _key}, _} -> true
          _ -> false
        end)
        |> Enum.map(fn {{_logical, key}, _} -> key end)

      {:reply, {:ok, keys}, state}
    end

    def handle_call({:delete, logical, key}, _from, state) do
      ns = {logical, key}

      case Map.fetch(state.data, ns) do
        {:ok, %PersistenceRecord{generation: gen}} ->
          {:reply, :ok, %{state | data: Map.put(state.data, ns, {:tombstone, gen})}}

        {:ok, {:tombstone, _} = t} ->
          {:reply, :ok, %{state | data: Map.put(state.data, ns, t)}}

        :error ->
          {:reply, :ok, state}

        {:ok, _plain} ->
          {:reply, :ok, %{state | data: Map.delete(state.data, ns)}}
      end
    end

    def handle_call({:compare_and_swap, logical, key, expected, replacement}, _from, state) do
      ns = {logical, key}

      case cas(Map.get(state.data, ns, :absent), key, expected, replacement) do
        {:ok, stored} ->
          {:reply, {:ok, stored}, %{state | data: Map.put(state.data, ns, stored)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end

    def handle_call({:record_invocation, event}, _from, state) when is_map(event) do
      send(state.parent, {:l4_invocation, event})
      {:reply, :ok, %{state | invocations: state.invocations ++ [event]}}
    end

    def handle_call(:invocation_count, _from, state),
      do: {:reply, length(state.invocations), state}

    def handle_call(:invocations, _from, state), do: {:reply, state.invocations, state}

    def handle_call({:set_resume_material, material}, _from, state) do
      {:reply, :ok, %{state | resume_material: material}}
    end

    def handle_call(:get_resume_material, _from, state) do
      case state.resume_material do
        nil -> {:reply, {:error, :resume_material_missing}, state}
        material -> {:reply, {:ok, material}, state}
      end
    end

    def handle_call(:held?, _from, state), do: {:reply, is_tuple(state.held_from), state}

    def handle_call(:release_hold, _from, %{held_from: nil} = state), do: {:reply, :ok, state}

    def handle_call(:release_hold, _from, %{held_from: from} = state) do
      GenServer.reply(from, :ok)
      {:reply, :ok, %{state | held_from: nil, held_key: nil}}
    end

    def handle_call({:has_key?, logical, key}, _from, state) do
      case Map.fetch(state.data, {logical, key}) do
        :error -> {:reply, false, state}
        {:ok, {:tombstone, _}} -> {:reply, false, state}
        {:ok, _} -> {:reply, true, state}
      end
    end

    defp should_hold?(state, logical, value) do
      state.hold_store == logical and not state.hold_fired? and
        matches_transition?(state.hold_on, state.hold_node, value)
    end

    defp matches_transition?(:completed_progress, hold_node, value) do
      data = lifecycle_data(value)
      effect = data["current_effect"]
      completed = List.wrap(data["completed_nodes"])

      is_map(effect) and effect["status"] == "completed" and effect["node_id"] == hold_node and
        hold_node in completed
    end

    defp matches_transition?(_, _, _), do: false

    defp lifecycle_data(%PersistenceRecord{data: data}) when is_map(data), do: data
    defp lifecycle_data(%{data: data}) when is_map(data), do: data
    defp lifecycle_data(data) when is_map(data), do: data
    defp lifecycle_data(_), do: %{}

    defp effect_from_value(value), do: lifecycle_data(value)["current_effect"]

    defp completed_nodes_from_value(value),
      do: List.wrap(lifecycle_data(value)["completed_nodes"])

    defp apply_put(:absent, key, %PersistenceRecord{} = record) do
      if record.key == key do
        now = DateTime.utc_now()
        {:ok, %{record | generation: 1, revision: 1, updated_at: now}}
      else
        {:error, :key_mismatch}
      end
    end

    defp apply_put({:tombstone, prev_gen}, key, %PersistenceRecord{} = record)
         when is_integer(prev_gen) and prev_gen >= 0 do
      if record.key == key do
        now = DateTime.utc_now()
        {:ok, %{record | generation: prev_gen + 1, revision: 1, updated_at: now}}
      else
        {:error, :key_mismatch}
      end
    end

    defp apply_put(%PersistenceRecord{} = current, key, %PersistenceRecord{} = record) do
      if current.key == key and record.key == key do
        now = DateTime.utc_now()

        {:ok,
         %{
           record
           | id: current.id,
             key: current.key,
             generation: current.generation,
             revision: current.revision + 1,
             inserted_at: current.inserted_at || record.inserted_at,
             updated_at: now
         }}
      else
        {:error, :key_mismatch}
      end
    end

    defp apply_put(_current, key, %PersistenceRecord{} = record) do
      if record.key == key do
        now = DateTime.utc_now()
        {:ok, %{record | generation: 1, revision: 1, updated_at: now}}
      else
        {:error, :key_mismatch}
      end
    end

    defp apply_put(_other, _key, value), do: {:ok, value}

    defp cas(:absent, key, :not_found, replacement),
      do: cas_insert(key, 0, replacement)

    defp cas({:tombstone, generation}, key, :not_found, replacement)
         when is_integer(generation) and generation >= 0,
         do: cas_insert(key, generation, replacement)

    defp cas(:absent, _key, {:value, _}, _replacement), do: {:error, :conflict}
    defp cas({:tombstone, _}, _key, {:value, _}, _replacement), do: {:error, :conflict}

    defp cas(
           %PersistenceRecord{} = current,
           key,
           {:value, %PersistenceRecord{} = expected},
           replacement
         ) do
      cond do
        current.key != key or expected.key != key ->
          {:error, :key_mismatch}

        current.generation != expected.generation or current.revision != expected.revision ->
          {:error, :conflict}

        is_struct(replacement, PersistenceRecord) and replacement.key != key ->
          {:error, :key_mismatch}

        is_struct(replacement, PersistenceRecord) ->
          now = DateTime.utc_now()

          {:ok,
           %{
             replacement
             | id: current.id,
               key: current.key,
               generation: current.generation,
               revision: current.revision + 1,
               inserted_at: current.inserted_at || replacement.inserted_at,
               updated_at: now
           }}

        true ->
          {:ok, replacement}
      end
    end

    defp cas(current, key, {:value, expected}, replacement) do
      cond do
        is_struct(expected, PersistenceRecord) and expected.key != key ->
          {:error, :key_mismatch}

        is_struct(replacement, PersistenceRecord) and replacement.key != key ->
          {:error, :key_mismatch}

        current != expected ->
          {:error, :conflict}

        is_struct(replacement, PersistenceRecord) ->
          {:error, :conflict}

        true ->
          {:ok, replacement}
      end
    end

    defp cas(_current, _key, _expected, _replacement), do: {:error, :conflict}

    defp cas_insert(key, previous_generation, %PersistenceRecord{} = replacement) do
      if replacement.key == key do
        now = DateTime.utc_now()

        {:ok,
         %{
           replacement
           | generation: previous_generation + 1,
             revision: 1,
             updated_at: now
         }}
      else
        {:error, :key_mismatch}
      end
    end

    defp cas_insert(_key, _previous_generation, replacement), do: {:ok, replacement}
  end

  # ---------------------------------------------------------------------------
  # Remote proxy store — used only through Arbor.Persistence
  # ---------------------------------------------------------------------------

  defmodule Proxy do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Orchestrator.L4ClusterRecoverySupport.CentralStore

    @impl true
    def durability_class(_opts), do: :process_lifetime

    @impl true
    def put(key, value, opts) do
      {server, logical} = target(opts)
      CentralStore.put(server, logical, key, value)
    end

    @impl true
    def get(key, opts) do
      {server, logical} = target(opts)
      CentralStore.get(server, logical, key)
    end

    @impl true
    def list(opts) do
      {server, logical} = target(opts)
      CentralStore.list(server, logical)
    end

    @impl true
    def delete(key, opts) do
      {server, logical} = target(opts)
      CentralStore.delete(server, logical, key)
    end

    @impl true
    def compare_and_swap(key, expected, replacement, opts) do
      {server, logical} = target(opts)
      CentralStore.compare_and_swap(server, logical, key, expected, replacement)
    end

    defp target(opts) do
      logical = Keyword.fetch!(opts, :name)
      controller_name = Keyword.fetch!(opts, :controller_name)
      controller_node = Keyword.fetch!(opts, :controller_node)
      {{controller_name, controller_node}, logical}
    end
  end

  defmodule ApplicationRestartProxy do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Orchestrator.L4ClusterRecoverySupport.Proxy

    @impl true
    defdelegate put(key, value, opts), to: Proxy

    @impl true
    defdelegate get(key, opts), to: Proxy

    @impl true
    defdelegate list(opts), to: Proxy

    @impl true
    defdelegate delete(key, opts), to: Proxy

    @impl true
    defdelegate compare_and_swap(key, expected, replacement, opts), to: Proxy

    @impl true
    def durability_class(_opts), do: :application_restart
  end

  defmodule NodeRestartProxy do
    @moduledoc false
    @behaviour Arbor.Contracts.Persistence.Store

    alias Arbor.Orchestrator.L4ClusterRecoverySupport.Proxy

    @impl true
    defdelegate put(key, value, opts), to: Proxy

    @impl true
    defdelegate get(key, opts), to: Proxy

    @impl true
    defdelegate list(opts), to: Proxy

    @impl true
    defdelegate delete(key, opts), to: Proxy

    @impl true
    defdelegate compare_and_swap(key, expected, replacement, opts), to: Proxy

    @impl true
    def durability_class(_opts), do: :node_restart
  end

  # ---------------------------------------------------------------------------
  # Side-effecting handler (test-only)
  # ---------------------------------------------------------------------------

  defmodule SideEffectHandler do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    alias Arbor.Orchestrator.Engine.Outcome
    alias Arbor.Orchestrator.L4ClusterRecoverySupport.CentralStore

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(node, _context, _graph, opts) do
      event = %{
        node_id: node.id,
        execution_id: opts[:execution_id],
        run_id: opts[:run_id],
        node: node()
      }

      case controller_ref(opts) do
        {:ok, server} ->
          _ = CentralStore.record_invocation(server, event)

        :error ->
          :ok
      end

      if parent = opts[:parent] do
        send(parent, {:l4_cluster_probe, event})
      end

      %Outcome{status: :success, context_updates: %{"l4_cluster_probe" => node.id}}
    end

    defp controller_ref(opts) do
      cond do
        is_tuple(opts[:l4_controller]) ->
          {:ok, opts[:l4_controller]}

        match?({_, _}, Application.get_env(:arbor_orchestrator, :l4_proof_controller)) ->
          {:ok, Application.get_env(:arbor_orchestrator, :l4_proof_controller)}

        true ->
          :error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Public support API (controller + remote)
  # ---------------------------------------------------------------------------

  def handler_type, do: @handler_type

  @doc """
  MFA target for RecoveryCoordinator resume_options_resolver.

  Credentials stay runtime-only in the controller store.
  """
  def resolve_resume_options(%Record{} = _record) do
    case Application.get_env(:arbor_orchestrator, :l4_proof_controller) do
      {name, node} = server when is_atom(name) and is_atom(node) ->
        case CentralStore.get_resume_material(server) do
          {:ok, material} ->
            {:ok,
             [
               identity_private_key: material.identity,
               execution_principal: material.execution_principal,
               agent_id: material.execution_principal,
               parent: material.parent,
               l4_controller: server
             ]}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :authentication_unavailable}
    end
  end

  def configure_orchestrator!(opts) when is_list(opts) do
    controller_name = Keyword.fetch!(opts, :controller_name)
    controller_node = Keyword.fetch!(opts, :controller_node)
    journal_store = Keyword.fetch!(opts, :journal_store)
    checkpoint_store = Keyword.fetch!(opts, :checkpoint_store)
    durability = Keyword.fetch!(opts, :durability_class)
    recovery_enabled? = Keyword.get(opts, :recovery_enabled, false)
    recovery_delay_ms = Keyword.get(opts, :recovery_delay_ms, 100)
    recovery_root = Keyword.get(opts, :recovery_root)
    backend = proxy_backend(durability)

    shared_store_opts = [
      controller_name: controller_name,
      controller_node: controller_node
    ]

    Application.put_env(
      :arbor_orchestrator,
      :l4_proof_controller,
      {controller_name, controller_node}
    )

    Application.put_env(:arbor_orchestrator, :preflight_models_on_start, false)
    Application.put_env(:arbor_orchestrator, :mandatory_middleware, true)
    Application.put_env(:arbor_orchestrator, :recovery_enabled, recovery_enabled?)
    Application.put_env(:arbor_orchestrator, :recovery_max_concurrent, 1)
    Application.put_env(:arbor_orchestrator, :recovery_delay_ms, recovery_delay_ms)

    if is_binary(recovery_root) do
      Application.put_env(:arbor_orchestrator, :recovery_materialization_root, recovery_root)
    end

    if recovery_enabled? do
      Application.put_env(
        :arbor_orchestrator,
        :recovery_resume_options_resolver,
        {__MODULE__, :resolve_resume_options}
      )
    else
      Application.delete_env(:arbor_orchestrator, :recovery_resume_options_resolver)
    end

    Application.put_env(:arbor_orchestrator, :run_journal,
      backend: backend,
      store_name: journal_store,
      start_store: false,
      durability_class: durability,
      backend_opts: shared_store_opts
    )

    Application.put_env(:arbor_orchestrator, :engine_checkpoints,
      store: backend,
      store_name: checkpoint_store,
      start_store: false,
      store_opts: shared_store_opts,
      durability_class: durability
    )

    :ok
  end

  defp proxy_backend(:application_restart), do: ApplicationRestartProxy
  defp proxy_backend(:node_restart), do: NodeRestartProxy

  def start_orchestrator_app! do
    case Application.ensure_all_started(:arbor_orchestrator) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:orchestrator_start_failed, reason}}
    end
  end

  def stop_orchestrator_app! do
    _ = Application.stop(:arbor_orchestrator)
    :ok
  end

  def register_side_handler! do
    :ok = Registry.register(@handler_type, SideEffectHandler)
  end

  def grant_agent_system! do
    case CapabilityStore.start_link([]) do
      {:ok, pid} ->
        # This setup runs inside a short-lived :erpc worker. Keep the test store
        # alive after that worker returns so authority survives app restart.
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _}} ->
        :ok

      other ->
        other
    end

    {:ok, cap} =
      Capability.new(
        resource_uri: "arbor://orchestrator/execute/**",
        principal_id: "agent_system",
        delegation_depth: 0,
        constraints: %{},
        metadata: %{test: true, l4_cluster: true}
      )

    case CapabilityStore.put(cap) do
      {:ok, _} -> :ok
      :ok -> :ok
      other -> other
    end
  end

  def prepare_peer!(opts) when is_list(opts) do
    with :ok <- configure_orchestrator!(opts),
         :ok <- start_orchestrator_app!(),
         :ok <- grant_agent_system!(),
         :ok <- register_side_handler!() do
      :ok
    end
  end

  def restart_orchestrator_only!(opts) when is_list(opts) do
    _ = stop_orchestrator_app!()

    with :ok <- configure_orchestrator!(opts),
         :ok <- start_orchestrator_app!(),
         :ok <- grant_agent_system!(),
         :ok <- register_side_handler!() do
      :ok
    end
  end

  @doc """
  Spawn `Orchestrator.run_file/2` on the current node and report the owner pid.
  """
  def start_run_file_async(dot_path, run_opts, report_to)
      when is_binary(dot_path) and is_list(run_opts) and is_pid(report_to) do
    pid =
      spawn(fn ->
        send(report_to, {:l4_engine_started, node(), self()})

        result =
          try do
            Arbor.Orchestrator.run_file(dot_path, run_opts)
          catch
            kind, reason ->
              {:error, {kind, reason}}
          end

        send(report_to, {:l4_engine_finished, node(), self(), result})
      end)

    {:ok, pid}
  end

  def write_dot_file!(dir, contents) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "pipeline.dot")
    File.write!(path, contents)
    path
  end

  def side_dot do
    """
    digraph Flow {
      start [shape=Mdiamond]
      task [type="#{@handler_type}"]
      exit [shape=Msquare]
      start -> task -> exit
    }
    """
  end

  def checkpoint_key(run_id), do: "checkpoint:#{run_id}"

  def await_until(timeout_ms, fun) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_until_loop(deadline, fun)
  end

  defp await_until_loop(deadline, fun) do
    case fun.() do
      {:ok, value} ->
        {:ok, value}

      :ok ->
        :ok

      {:error, _} = err ->
        if System.monotonic_time(:millisecond) >= deadline do
          err
        else
          receive do
          after
            20 -> await_until_loop(deadline, fun)
          end
        end

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:await_timeout, other}}
        else
          receive do
          after
            20 -> await_until_loop(deadline, fun)
          end
        end
    end
  end
end
