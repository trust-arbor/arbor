Code.require_file(
  Path.expand("../../../arbor_security/test/support/approval_answer_fixture.ex", __DIR__)
)

defmodule Arbor.Agent.Test.ManagementSessionFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  alias Arbor.Agent, as: Agents
  alias Arbor.Agent.{Character, Lifecycle, Profile}
  alias Arbor.Security
  alias Arbor.Security.TestSupport.ApprovalAnswerFixture, as: Humans

  defmodule Repo do
    use Ecto.Repo, otp_app: :arbor_agent, adapter: Ecto.Adapters.SQLite3
  end

  defmodule Host do
    use Agent
    def start_link(_opts), do: Agent.start_link(fn -> :private_management_fixture end)
  end

  defmodule ApprovalProbe do
    def healthy?, do: true
    def submit(%{topic: :authorization_request}, _opts), do: {:ok, "management-pending-fixture"}
  end

  def initialize! do
    assert :ok = Security.TestBootstrap.start!()
    assert :ok = Arbor.Memory.TestBootstrap.start!()

    for {name, child} <- [
          {Arbor.Agent.ExecutorRegistry,
           {Registry, keys: :unique, name: Arbor.Agent.ExecutorRegistry}},
          {Arbor.Agent.Registry, Arbor.Agent.Registry},
          {Arbor.Agent.Supervisor, Arbor.Agent.Supervisor},
          {Arbor.Security.UriRegistry, Arbor.Security.UriRegistry}
        ] do
      if Process.whereis(name) == nil, do: start_supervised!(child)
    end

    root =
      Path.join(
        System.tmp_dir!(),
        "management-session-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(root)

    start_supervised!(
      {Repo,
       database: Path.join(root, "management.sqlite3"),
       pool: DBConnection.ConnectionPool,
       pool_size: 1,
       busy_timeout: 5_000,
       journal_mode: :wal}
    )

    migrations = Path.expand("../../../arbor_persistence/priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    assert Process.whereis(:arbor_agent_profiles) == nil,
           "Run management session qualification separately; fixture owns the real SQL profile store."

    start_supervised!(
      Supervisor.child_spec(
        {Arbor.Persistence.BufferedStore,
         name: :arbor_agent_profiles,
         backend: Arbor.Persistence.QueryableStore.Postgres,
         backend_opts: [repo: Repo],
         write_mode: :sync,
         ack_mode: :backend},
        id: :arbor_agent_profiles
      )
    )

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  def setup!(root) do
    ctx = Humans.setup!()

    for {app, key, value} <- [
          {:arbor_security, :uri_registry_enforcement, true},
          {:arbor_security, :policy_enforcer_enabled, false},
          {:arbor_security, :reflex_checking_enabled, false},
          {:arbor_security, :approval_guard_enabled, false},
          {:arbor_security, :egress_gate_enforcing, false},
          {:arbor_security, :consensus_escalation_enabled, true},
          {:arbor_security, :use_interaction_router_for_approval, false},
          {:arbor_security, :consensus_module, ApprovalProbe},
          {:arbor_agent, :legacy_agents_dir, root},
          {:arbor_historian, :durable_event_log_target,
           %{
             name: :management_session_audit,
             backend: Arbor.Persistence.EventLog.Ecto,
             opts: [repo: Repo]
           }}
        ],
        do: set_env(app, key, value)

    ctx
  end

  def target! do
    {:ok, identity} = Security.generate_identity()
    assert :ok = Security.register_identity_fixture(identity)
    target = identity.agent_id

    profile = %Profile{
      agent_id: target,
      display_name: "Private management fixture",
      character: Character.new(name: target),
      created_at: DateTime.utc_now()
    }

    assert :ok = Agents.store_profile(profile)

    {:ok, stored} =
      Arbor.Persistence.get(
        :arbor_agent_profiles,
        Arbor.Persistence.QueryableStore.Postgres,
        target,
        repo: Repo
      )

    assert stored.key == target

    {:ok, pid} =
      Supervisor.start_link([{Host, []}],
        strategy: :rest_for_one,
        name: {:via, Registry, {Arbor.Agent.ExecutorRegistry, {:branch, target}}}
      )

    Process.unlink(pid)
    assert :ok = Arbor.Agent.Registry.register(target, pid, %{supervisor_pid: pid})

    on_exit(fn ->
      if Process.alive?(pid), do: Supervisor.stop(pid)
      Arbor.Agent.Registry.unregister(target)
      # Cleanup only this private fixture identity/profile after trace closure.
      Agents.destroy_agent(target)
    end)

    %{target: target, pid: pid, identity: identity}
  end

  def grant!(human, action, target, opts \\ []),
    do: Humans.grant!(human, resource(action, target), opts)

  def resource(:stop, target), do: "arbor://agent/stop/" <> target
  def resource(:destroy, target), do: "arbor://agent/lifecycle/destroy/" <> target
  def proof(ctx), do: [session_token: ctx.token]

  def preserved!(target) do
    assert Process.alive?(target.pid)
    assert {:ok, profile} = Agents.load_profile(target.target)
    assert profile.agent_id == target.target

    assert {:ok, record} =
             Arbor.Persistence.get(
               :arbor_agent_profiles,
               Arbor.Persistence.QueryableStore.Postgres,
               target.target,
               repo: Repo
             )

    assert record.key == target.target
    assert {:ok, :active} = Security.identity_status(target.target)
  end

  def audit_count!(principal) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT COUNT(*) FROM events WHERE type = ? AND json_extract(data, '$.principal_id') = ?",
        ["security.invocation.authorization", principal]
      )

    count
  end

  def deleted_if_destroy!(:stop, _target), do: :ok

  def deleted_if_destroy!(:destroy, target),
    do: assert({:error, :not_found} == Agents.load_profile(target))

  def observe!(pid, fun) when pid == self() do
    owner = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run ->
            send(owner, {:management_result, self(), fun.()})

            receive do
              :release -> :ok
            end
        end
      end)

    try do
      observe!(worker, fn ->
        send(worker, :run)

        receive do
          {:management_result, ^worker, result} -> result
        after
          15_000 -> flunk("management operation did not return")
        end
      end)
    after
      send(worker, :release)

      receive do
        {:DOWN, ^monitor, :process, ^worker, _} -> :ok
      after
        5_000 -> Process.exit(worker, :kill)
      end
    end
  end

  def observe!(pid, fun) do
    assert Code.ensure_loaded?(Lifecycle)
    session = :trace.session_create(:management_session_effects, self(), [])

    try do
      for operation <- [:stop, :destroy],
          do: assert(:trace.function(session, {Lifecycle, operation, 1}, true, [:local]) > 0)

      assert :trace.process(session, pid, true, [:call]) == 1
      result = fun.()
      barrier = :trace.delivered(session, pid)
      {result, drain(pid, barrier, [])}
    after
      :trace.session_destroy(session)
    end
  end

  defp drain(pid, barrier, effects) do
    receive do
      {:trace, ^pid, :call, {Lifecycle, op, [target]}} ->
        drain(pid, barrier, [{op, target} | effects])

      {:trace_delivered, ^pid, ^barrier} ->
        Enum.reverse(effects)

      _ ->
        drain(pid, barrier, effects)
    after
      10_000 -> flunk("management effect trace did not drain")
    end
  end

  def set_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(app, key, old)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
