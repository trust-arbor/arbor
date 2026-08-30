defmodule Arbor.Orchestrator.RecoveryCoordinatorAuthorityAccountingTest.AppRestartStore do
  @moduledoc false
  use GenServer

  def durability_class(_opts), do: :application_restart

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def put(key, value, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:put, key, value})
  def get(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:get, key})
  def list(opts), do: GenServer.call(Keyword.fetch!(opts, :name), :list)
  def delete(key, opts), do: GenServer.call(Keyword.fetch!(opts, :name), {:delete, key})

  @impl true
  def init(_opts), do: {:ok, %{data: %{}}}

  @impl true
  def handle_call({:put, key, value}, _from, state) do
    {:reply, :ok, %{state | data: Map.put(state.data, key, value)}}
  end

  def handle_call({:get, key}, _from, state) do
    case Map.fetch(state.data, key) do
      {:ok, value} -> {:reply, {:ok, value}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list, _from, state), do: {:reply, {:ok, Map.keys(state.data)}, state}

  def handle_call({:delete, key}, _from, state) do
    {:reply, :ok, %{state | data: Map.delete(state.data, key)}}
  end
end

defmodule Arbor.Orchestrator.RecoveryCoordinatorAuthorityAccountingTest.TrackingCloser do
  @moduledoc false
  @table :g3b_recovery_authority_accounting

  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> _ = :ets.new(@table, [:named_table, :public, :set])
      _ -> :ok
    end

    :ok
  end

  def reset! do
    ensure_table!()
    :ets.insert(@table, {:closes, []})
    :ets.insert(@table, {:mode, :open_ok})
    :ets.insert(@table, {:close_reply, :ok})
    :ets.delete(@table, :authority)
    :ok
  end

  def ensure!, do: reset!()

  def set_mode(mode), do: :ets.insert(@table, {:mode, mode})
  def set_close_reply(reply), do: :ets.insert(@table, {:close_reply, reply})
  def set_authority(authority), do: :ets.insert(@table, {:authority, authority})

  def closes do
    case :ets.lookup(@table, :closes) do
      [{:closes, list}] -> Enum.reverse(list)
      _ -> []
    end
  end

  def close_signing_authority(authority) do
    ensure_table!()

    list =
      case :ets.lookup(@table, :closes) do
        [{:closes, current}] -> current
        _ -> []
      end

    :ets.insert(@table, {:closes, [%{closer: __MODULE__} | list]})

    case {:ets.lookup(@table, :authority), :ets.lookup(@table, :close_reply)} do
      {[{:authority, ^authority}], [{:close_reply, :ok}]} ->
        Arbor.Security.close_signing_authority(authority)

      {_authority, [{:close_reply, reply}]} ->
        reply

      _ ->
        :ok
    end
  end

  def resolver(record) do
    ensure_table!()
    principal = record.execution_principal

    auth =
      case :ets.lookup(@table, :authority) do
        [{:authority, authority}] ->
          authority

        _ ->
          {:ok, authority} =
            Arbor.Contracts.Security.SigningAuthority.new(%{
              token: :crypto.strong_rand_bytes(32),
              principal_id: principal,
              purpose: :coding_task_recovery
            })

          authority
      end

    {:ok, other} =
      Arbor.Contracts.Security.SigningAuthority.new(%{
        token: :crypto.strong_rand_bytes(32),
        principal_id: "agent_other_principal",
        purpose: :coding_task_recovery
      })

    case :ets.lookup(@table, :mode) do
      [{:mode, :skip}] ->
        {:skip, :task_store_owned}

      [{:mode, :no_auth}] ->
        {:ok, []}

      [{:mode, :principal_mismatch}] ->
        {:ok, [signing_authority: other, security_module: __MODULE__]}

      [{:mode, :open_ok}] ->
        {:ok, [signing_authority: auth, security_module: __MODULE__, authorization: false]}

      [{:mode, :wrong_closer}] ->
        {:ok, [signing_authority: auth]}

      _ ->
        {:ok, [signing_authority: auth, security_module: __MODULE__, authorization: false]}
    end
  end
end

defmodule Arbor.Orchestrator.RecoveryCoordinatorAuthorityAccountingTest do
  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.Security.{Identity, SigningAuthority}
  alias Arbor.Orchestrator.Engine
  alias Arbor.Orchestrator.Engine.Checkpoint
  alias Arbor.Orchestrator.Engine.Context
  alias Arbor.Orchestrator.Engine.Outcome
  alias Arbor.Orchestrator.Handlers.Registry
  alias Arbor.Orchestrator.RecoveryCoordinator
  alias Arbor.Orchestrator.RecoveryCoordinatorAuthorityAccountingTest.AppRestartStore
  alias Arbor.Orchestrator.RecoveryCoordinatorAuthorityAccountingTest.TrackingCloser
  alias Arbor.Orchestrator.RunJournal
  alias Arbor.Orchestrator.RunLifecycle.Record
  alias Arbor.Security

  setup do
    TrackingCloser.ensure!()
    suffix = System.unique_integer([:positive, :monotonic])
    {:ok, suffix: suffix}
  end

  test "task-owned skip never opens or closes an authority", %{suffix: suffix} do
    TrackingCloser.set_mode(:skip)
    {coord, journal, local_node} = start_coord(suffix, "skip")
    put_interrupted(journal, local_node, "run_skip_#{suffix}", "agent_skip_#{suffix}")
    send(coord, :discover_interrupted)
    wait_until(fn -> RecoveryCoordinator.status(coord).pending == 0 end)
    assert TrackingCloser.closes() == []
    assert RecoveryCoordinator.status(coord).recovered == 0
  end

  test "resolver validation without authority does not open", %{suffix: suffix} do
    TrackingCloser.set_mode(:no_auth)
    {coord, journal, local_node} = start_coord(suffix, "noauth")
    put_interrupted(journal, local_node, "run_noauth_#{suffix}", "agent_noauth_#{suffix}")
    send(coord, :discover_interrupted)
    wait_until(fn -> RecoveryCoordinator.status(coord).failed >= 1 end)
    assert TrackingCloser.closes() == []
  end

  test "principal mismatch closes through the captured opener", %{suffix: suffix} do
    TrackingCloser.set_mode(:principal_mismatch)
    {coord, journal, local_node} = start_coord(suffix, "pmm")
    put_interrupted(journal, local_node, "run_pmm_#{suffix}", "agent_pmm_#{suffix}")
    send(coord, :discover_interrupted)
    wait_until(fn -> TrackingCloser.closes() != [] end)
    assert Enum.all?(TrackingCloser.closes(), &(&1[:closer] == TrackingCloser))
    refute_forbidden_settlement(coord)
  end

  test "preclaim trust-zone failure closes through the captured opener", %{suffix: suffix} do
    TrackingCloser.set_mode(:open_ok)
    {coord, journal, local_node} = start_coord(suffix, "preclaim")

    put_interrupted(journal, local_node, "run_preclaim_#{suffix}", "agent_preclaim_#{suffix}",
      origin_trust_zone: -1
    )

    send(coord, :discover_interrupted)
    wait_until(fn -> TrackingCloser.closes() != [] end)
    assert Enum.all?(TrackingCloser.closes(), &(&1[:closer] == TrackingCloser))
    refute_forbidden_settlement(coord)
  end

  test "postclaim locate failure closes through the captured opener", %{suffix: suffix} do
    TrackingCloser.set_mode(:open_ok)
    {coord, journal, local_node} = start_coord(suffix, "postclaim")
    put_interrupted(journal, local_node, "run_post_#{suffix}", "agent_post_#{suffix}")
    send(coord, :discover_interrupted)

    wait_until(fn ->
      TrackingCloser.closes() != [] or RecoveryCoordinator.status(coord).failed >= 1
    end)

    assert Enum.all?(TrackingCloser.closes(), &(&1[:closer] == TrackingCloser))
    refute_forbidden_settlement(coord)
  end

  test "task error and close-failure settlement stay bounded", %{suffix: suffix} do
    TrackingCloser.set_mode(:open_ok)
    TrackingCloser.set_close_reply({:error, :forced_close})
    {coord, journal, local_node} = start_coord(suffix, "closefail")
    put_interrupted(journal, local_node, "run_cf_#{suffix}", "agent_cf_#{suffix}")
    send(coord, :discover_interrupted)
    wait_until(fn -> RecoveryCoordinator.status(coord).failed >= 1 end)
    status = RecoveryCoordinator.status(coord)
    assert status.recovered == 0
    assert status.failed >= 1
    refute_forbidden_settlement(coord)
    inspected = inspect(:sys.get_state(coord), limit: :infinity, printable_limit: :infinity)
    refute inspected =~ "final_outcome"
    refute inspected =~ "verification_report"
    assert inspected =~ "forced_close"
  end

  test "missing captured closer is security_unavailable not Config fallback", %{suffix: suffix} do
    TrackingCloser.set_mode(:wrong_closer)
    {coord, journal, local_node} = start_coord(suffix, "noclose")
    put_interrupted(journal, local_node, "run_nc_#{suffix}", "agent_nc_#{suffix}")
    send(coord, :discover_interrupted)
    wait_until(fn -> RecoveryCoordinator.status(coord).failed >= 1 end)
    assert TrackingCloser.closes() == []
    refute_forbidden_settlement(coord)
  end

  test "spawned resume error closes through the captured opener", %{suffix: suffix} do
    TrackingCloser.set_mode(:open_ok)
    {coord, journal, local_node} = start_coord(suffix, "spawnerr")
    logs = Path.join(System.tmp_dir!(), "g3b_acct_spawnerr_#{suffix}_logs")
    File.mkdir_p!(logs)
    File.write!(Path.join(logs, "checkpoint.json"), "{}")
    on_exit(fn -> File.rm_rf(logs) end)

    put_interrupted(journal, local_node, "run_spawn_#{suffix}", "agent_spawn_#{suffix}",
      logs_root: logs
    )

    send(coord, :discover_interrupted)

    wait_until(fn ->
      TrackingCloser.closes() != [] or RecoveryCoordinator.status(coord).failed >= 1
    end)

    assert Enum.all?(TrackingCloser.closes(), &(&1[:closer] == TrackingCloser))
    refute_forbidden_settlement(coord)
    inspected = inspect(:sys.get_state(coord), limit: :infinity, printable_limit: :infinity)
    refute inspected =~ "final_outcome"
    refute inspected =~ "verification_report"
    refute inspected =~ "%Arbor.Contracts.Security.SigningAuthority"
  end

  test "authentic Engine resume success closes through the captured opener", %{suffix: suffix} do
    TrackingCloser.set_mode(:open_ok)
    {identity, authority} = real_recovery_authority("g3b-accounting-success-#{suffix}")
    TrackingCloser.set_authority(authority)
    {coord, journal, local_node} = start_coord(suffix, "engok")
    {logs, dot_path, graph_hash} = prepare_engine_graph(suffix, "engok", success_dot())
    seed_start_checkpoint!(logs, "run_engok_#{suffix}", authority, graph_hash)

    put_interrupted(journal, local_node, "run_engok_#{suffix}", identity.agent_id,
      logs_root: logs,
      graph_hash: graph_hash,
      dot_source_path: dot_path
    )

    send(coord, :discover_interrupted)
    wait_until(fn -> RecoveryCoordinator.status(coord).recovered >= 1 end, 150)
    assert Enum.all?(TrackingCloser.closes(), &(&1[:closer] == TrackingCloser))
    refute_forbidden_settlement(coord)
    inspected = inspect(:sys.get_state(coord), limit: :infinity, printable_limit: :infinity)
    refute inspected =~ "final_outcome"
    refute inspected =~ "model text"
    refute inspected =~ "%Arbor.Contracts.Security.SigningAuthority"
  end

  test "authentic Engine handler exception/DOWN closes through the captured opener", %{
    suffix: suffix
  } do
    type = "g3b_boom_#{suffix}"
    :ok = Registry.register(type, __MODULE__.BoomHandler)
    TrackingCloser.set_mode(:open_ok)
    {identity, authority} = real_recovery_authority("g3b-accounting-boom-#{suffix}")
    TrackingCloser.set_authority(authority)
    {coord, journal, local_node} = start_coord(suffix, "engboom")
    {logs, dot_path, graph_hash} = prepare_engine_graph(suffix, "engboom", boom_dot(type))
    seed_start_checkpoint!(logs, "run_engboom_#{suffix}", authority, graph_hash)

    put_interrupted(journal, local_node, "run_engboom_#{suffix}", identity.agent_id,
      logs_root: logs,
      graph_hash: graph_hash,
      dot_source_path: dot_path
    )

    send(coord, :discover_interrupted)

    wait_until(
      fn ->
        TrackingCloser.closes() != [] or RecoveryCoordinator.status(coord).failed >= 1
      end,
      150
    )

    assert Enum.all?(TrackingCloser.closes(), &(&1[:closer] == TrackingCloser))
    refute_forbidden_settlement(coord)
    inspected = inspect(:sys.get_state(coord), limit: :infinity, printable_limit: :infinity)
    refute inspected =~ "%Arbor.Contracts.Security.SigningAuthority"
    refute inspected =~ "final_outcome"
  end

  test "spawned resume close-failure settlement stays bounded and authority-free", %{
    suffix: suffix
  } do
    TrackingCloser.set_mode(:open_ok)
    TrackingCloser.set_close_reply({:error, :forced_close})
    {coord, journal, local_node} = start_coord(suffix, "downtask")
    logs = Path.join(System.tmp_dir!(), "g3b_acct_down_#{suffix}_logs")
    File.mkdir_p!(logs)
    File.write!(Path.join(logs, "checkpoint.json"), "{}")
    on_exit(fn -> File.rm_rf(logs) end)

    put_interrupted(journal, local_node, "run_down_#{suffix}", "agent_down_#{suffix}",
      logs_root: logs
    )

    send(coord, :discover_interrupted)

    wait_until(fn ->
      TrackingCloser.closes() != [] or RecoveryCoordinator.status(coord).failed >= 1
    end)

    assert Enum.all?(TrackingCloser.closes(), &(&1[:closer] == TrackingCloser))
    refute_forbidden_settlement(coord)
    inspected = inspect(:sys.get_state(coord), limit: :infinity, printable_limit: :infinity)
    refute inspected =~ "final_outcome"
    refute inspected =~ "model text"
    refute inspected =~ "%Arbor.Contracts.Security.SigningAuthority"
  end

  defp start_coord(suffix, label) do
    ensure_session_task_supervisor()
    store_name = :"g3b_acct_store_#{label}_#{suffix}"
    journal = :"g3b_acct_j_#{label}_#{suffix}"
    coord = :"g3b_acct_c_#{label}_#{suffix}"
    local_node = node()
    recovery_root = Path.join(System.tmp_dir!(), "g3b_acct_#{label}_#{suffix}")
    File.mkdir_p!(recovery_root)
    on_exit(fn -> File.rm_rf(recovery_root) end)

    {:ok, _} =
      start_supervised(%{
        id: store_name,
        start: {AppRestartStore, :start_link, [[name: store_name]]}
      })

    {:ok, _} =
      start_supervised(%{
        id: journal,
        start:
          {RunJournal, :start_link,
           [
             [
               name: journal,
               ets_table: :"g3b_acct_hot_#{label}_#{suffix}",
               backend: AppRestartStore,
               store_name: store_name,
               durability_class: :application_restart,
               start_store: false,
               local_node: local_node
             ]
           ]}
      })

    durability = RunJournal.durability_status(server: journal)
    assert durability.durable == true
    assert durability.durability_class == :application_restart

    {:ok, pid} =
      start_supervised(%{
        id: coord,
        start:
          {RecoveryCoordinator, :start_link,
           [
             [
               name: coord,
               enabled: true,
               journal_opts: [server: journal],
               recovery_root: recovery_root,
               resume_options_resolver: &TrackingCloser.resolver/1,
               delay_ms: 60_000
             ]
           ]}
      })

    {pid, journal, local_node}
  end

  defp put_interrupted(journal, local_node, run_id, principal, extra \\ []) do
    now = DateTime.utc_now()

    record = %Record{
      run_id: run_id,
      pipeline_id: run_id,
      status: :interrupted,
      started_at: now,
      last_heartbeat: now,
      owner_node: local_node,
      source_node: local_node,
      execution_principal: principal,
      origin_trust_zone: Keyword.get(extra, :origin_trust_zone),
      logs_root: Keyword.get(extra, :logs_root),
      graph_hash: Keyword.get(extra, :graph_hash),
      dot_source_path: Keyword.get(extra, :dot_source_path)
    }

    assert :ok = RunJournal.put(record, server: journal)
  end

  defp ensure_session_task_supervisor do
    case Process.whereis(Arbor.Orchestrator.Session.TaskSupervisor) do
      pid when is_pid(pid) ->
        :ok

      _ ->
        start_supervised!({Task.Supervisor, name: Arbor.Orchestrator.Session.TaskSupervisor})
        :ok
    end
  end

  defp refute_forbidden_settlement(coord) do
    state = :sys.get_state(coord)
    inspected = inspect(state.settlement_failures ++ state.failed, limit: :infinity)

    refute inspected =~ "SigningAuthority"
    refute inspected =~ ":context"
    refute inspected =~ "final_outcome"
    refute match?(%SigningAuthority{}, state)
  end

  defmodule BoomHandler do
    @moduledoc false
    @behaviour Arbor.Orchestrator.Handlers.Handler

    @impl true
    def idempotency, do: :side_effecting

    @impl true
    def execute(_node, _context, _graph, _opts), do: raise("g3b-recovery-boom")
  end

  defp prepare_engine_graph(suffix, label, source) do
    logs = Path.join(System.tmp_dir!(), "g3b_acct_#{label}_#{suffix}_engine")
    File.mkdir_p!(logs)
    on_exit(fn -> File.rm_rf(logs) end)
    dot_path = Path.join(logs, "graph.dot")
    File.write!(dot_path, source)
    graph_hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
    {logs, dot_path, graph_hash}
  end

  defp seed_start_checkpoint!(logs_root, run_id, authority, graph_hash) do
    hmac = Engine.derive_checkpoint_hmac_secret(signing_authority: authority)
    assert is_binary(hmac)

    checkpoint =
      Checkpoint.from_state(
        "start",
        ["start"],
        %{},
        Context.new(%{}),
        %{"start" => %Outcome{status: :success}},
        run_id: run_id,
        graph_hash: graph_hash,
        pipeline_started_at: DateTime.utc_now(),
        execution_digests: %{}
      )

    assert {:ok, _} =
             Checkpoint.persist(checkpoint, logs_root, hmac_secret: hmac, store: nil)
  end

  defp real_recovery_authority(name) do
    {:ok, identity} = Identity.generate(name: name)
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(
        identity.agent_id,
        identity.private_key,
        purpose: :coding_task_recovery,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)

    on_exit(fn ->
      _ = Security.close_signing_authority(authority)
      _ = Security.delete_signing_key(identity.agent_id)
      _ = Security.deregister_identity(identity.agent_id)
    end)

    {identity, authority}
  end

  defp success_dot do
    """
    digraph G3BSuccess {
      start [shape=Mdiamond]
      done [shape=Msquare]
      start -> done
    }
    """
  end

  defp boom_dot(type) do
    """
    digraph G3BBoom {
      start [shape=Mdiamond]
      boom [type="#{type}"]
      done [shape=Msquare]
      start -> boom -> done
    }
    """
  end

  defp wait_until(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        flunk("timeout waiting for coordinator accounting")

      true ->
        Process.sleep(40)
        wait_until(fun, attempts - 1)
    end
  end
end
