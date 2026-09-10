defmodule Arbor.Scheduler.Test.OwnedRoutineFixture do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Arbor.Common.SafePath
  alias Arbor.Contracts.Security.{Capability, SignedRequest}
  alias Arbor.Persistence.Repo
  alias Arbor.Scheduler
  alias Arbor.Scheduler.{CapsFile, RoutineCatalog}
  alias Arbor.Security
  alias Arbor.Security.{Crypto, IssuerRegistry}
  alias Arbor.Trust
  alias Arbor.Trust.PolicyHost
  alias Ecto.Adapters.Postgres

  # This compiled fixture also accompanies the test-only parent revision,
  # where the new routine APIs are intentionally absent. Runtime apply keeps
  # compilation strict while exercising the same actual APIs on the candidate.
  @oban Arbor.Scheduler.Test.OwnedRoutineOban
  @dot Path.expand("../../priv/pipelines/morning_digest.dot", __DIR__)
  @migrations Path.expand("../../../arbor_persistence/priv/repo/migrations", __DIR__)

  # Observation-only test boundary. Every invocation still reaches the actual
  # public Scheduler gate after the pause. It cannot authorize an effect itself.
  defmodule ObservedScheduler do
    def routine_effect_requirement(principal),
      do: apply(Arbor.Scheduler, :routine_effect_requirement, [principal])

    def authorize_routine_effect(token, effect) do
      observer = Application.fetch_env!(:arbor_scheduler, :_owned_routine_observer)
      send(observer, {:routine_effect, self(), token, effect})
      pause = Application.get_env(:arbor_scheduler, :_owned_routine_pause)
      count = Process.get({__MODULE__, effect.operation, Map.get(effect, :path)}, 0) + 1
      Process.put({__MODULE__, effect.operation, Map.get(effect, :path)}, count)

      if pause?(pause, effect, count) do
        marker = make_ref()
        send(observer, {:routine_paused, self(), marker, token, effect})

        receive do
          {:continue_routine, ^marker} -> :ok
        after
          30_000 -> raise "test did not release owned routine pause"
        end
      end

      apply(Arbor.Scheduler, :authorize_routine_effect, [token, effect])
    end

    defp pause?(:first_read, %{operation: :read}, 1), do: true

    defp pause?(:publication, %{operation: :write, path: path}, 2),
      do: String.ends_with?(path, ".md")

    defp pause?(_, _, _), do: false
  end

  # Existing Oban engine injection seam: reproduce pinned Basic.insert_unique
  # advisory-lock/DO NOTHING results without claiming a live Postgres test.
  defmodule InsertResultEngine do
    @behaviour Oban.Engine
    for {name, arity} <- Oban.Engines.Lite.__info__(:functions),
        {name, arity} != {:insert_job, 3} do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl Oban.Engine
      def unquote(name)(unquote_splicing(args)) do
        apply(Oban.Engines.Lite, unquote(name), [unquote_splicing(args)])
      end
    end

    @impl true
    def insert_job(conf, changeset, opts) do
      case Application.fetch_env!(:arbor_scheduler, :_owned_oban_result) do
        :lock_loser ->
          {:ok, job} = Ecto.Changeset.apply_action(changeset, :insert)
          {:ok, %{job | conflict?: true}}

        :positive_ghost ->
          {:ok, job} = Ecto.Changeset.apply_action(changeset, :insert)
          {:ok, %{job | id: 9_000_000, conflict?: true}}

        :persisted_without_result_id ->
          with {:ok, job} <- Oban.Engines.Lite.insert_job(conf, changeset, opts),
               do: {:ok, %{job | id: nil, conflict?: true}}
      end
    end
  end

  def start_sql! do
    assert Process.whereis(Repo) == nil,
           "Run the owned Scheduler SQLite journey standalone; it may not reuse another Repo"

    assert {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)

    root =
      Path.join(System.tmp_dir!(), "arbor_owned_scheduler_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    {:ok, root} = SafePath.resolve_real(root)

    repo_opts = [
      database: Path.join(root, "jobs.sqlite3"),
      pool: DBConnection.ConnectionPool,
      pool_size: 4,
      busy_timeout: 5_000,
      journal_mode: :wal
    ]

    # Oban checks Repo.config/0 when verifying migrations; the reported pool
    # must agree with the actual private owner, including during cold restart.
    # Initialize the new SQLite file/WAL with one connection, then retain four
    # real connections for the concurrent insertion/admission regressions.
    bootstrap_opts = Keyword.put(repo_opts, :pool_size, 1)
    env(:arbor_persistence, Repo, bootstrap_opts)
    start_supervised!({Repo, bootstrap_opts})
    assert Repo.config()[:pool] == DBConnection.ConnectionPool
    assert [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false)
    assert :ok = stop_supervised(Repo)
    Application.put_env(:arbor_persistence, Repo, repo_opts)

    supervisor =
      start_supervised!(%{
        id: :owned_routine_repo,
        start: {Supervisor, :start_link, [[{Repo, repo_opts}], [strategy: :one_for_one]]}
      })

    assert Repo.config()[:pool] == DBConnection.ConnectionPool
    assert Repo.config()[:pool_size] == 4

    if Process.whereis(Arbor.Orchestrator.EventRegistry) == nil,
      do: start_supervised!({Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry})

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      assert String.starts_with?(Path.basename(root), "arbor_owned_scheduler_")
      File.rm_rf!(root)
    end)

    %{sql_root: root, repo_supervisor: supervisor}
  end

  # This opt-in lane owns a newly created database on a disposable test server.
  # It never opens or clears the configured development/test database.
  def start_postgres_sql! do
    assert System.get_env("ARBOR_OWNED_SCHEDULER_POSTGRES_TEST") == "1"
    assert apply(Repo, :__adapter__, []) == Postgres
    assert Process.whereis(Repo) == nil
    assert {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)

    name = "arbor_owned_scheduler_#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), name)
    File.mkdir_p!(root)
    {:ok, root} = SafePath.resolve_real(root)

    opts =
      Application.fetch_env!(:arbor_persistence, Repo)
      |> Keyword.put(:database, name)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    assert :ok = Postgres.storage_up(opts)
    env(:arbor_persistence, Repo, opts)

    supervisor =
      start_supervised!(%{
        id: :owned_routine_repo,
        start: {Supervisor, :start_link, [[{Repo, opts}], [strategy: :one_for_one]]}
      })

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
      assert :ok = Postgres.storage_down(opts)
      File.rm_rf!(root)
    end)

    for {version, file, module} <- [
          {20_260_602_000_001, "20260602000001_add_oban_jobs.exs",
           Arbor.Persistence.Repo.Migrations.AddObanJobs},
          {20_260_909_000_001, "20260909000001_unique_owned_routine_requests.exs",
           Arbor.Persistence.Repo.Migrations.UniqueOwnedRoutineRequests}
        ] do
      Code.require_file(Path.join(@migrations, file))
      assert :ok = Ecto.Migrator.up(Repo, version, module, log: false)
    end

    if Process.whereis(Arbor.Orchestrator.EventRegistry) == nil,
      do: start_supervised!({Registry, keys: :duplicate, name: Arbor.Orchestrator.EventRegistry})

    %{
      sql_root: root,
      repo_supervisor: supervisor,
      oban_engine: Oban.Engines.Basic,
      oban_prefix: "public",
      oban_testing: :disabled
    }
  end

  def start!(ctx) do
    Repo.delete_all(Oban.Job)
    workdir = Path.join(ctx.sql_root, "case_#{System.unique_integer([:positive])}")

    for topic <- ["upstream-deps", "upstream-deps-summary", "morning-digest"],
        do: File.mkdir_p!(Path.join([workdir, "reports", topic]))

    pipelines = Path.join(workdir, "pipelines")
    File.mkdir!(pipelines)
    dot = Path.join(pipelines, "morning_digest.dot")
    File.cp!(@dot, dot)

    for {app, key, value} <- [
          {:arbor_scheduler, :oban_name, @oban},
          {:arbor_scheduler, :orchestrator_module, Arbor.Orchestrator},
          {:arbor_scheduler, :pipeline_roots, %{"owned_test" => pipelines}},
          {:arbor_scheduler, :morning_digest_pipeline, dot},
          {:arbor_scheduler, :routine_logs_root, Path.join(workdir, "logs")},
          {:arbor_scheduler, :_owned_routine_observer, self()},
          {:arbor_scheduler, :_owned_routine_pause, nil},
          {:arbor_scheduler, :_owned_oban_result, Map.get(ctx, :oban_insert_variant)},
          {:arbor_actions, :scheduler_module, ObservedScheduler},
          {:arbor_security, :identity_verification, true},
          {:arbor_security, :capability_signing_required, true},
          {:arbor_security, :policy_enforcer_enabled, false},
          {:arbor_security, :approval_guard_enabled, false},
          {:arbor_security, :reflex_checking_enabled, false},
          {:arbor_trust, :policy_enforcer_enabled, false},
          {:arbor_trust, :approval_guard_enabled, false}
        ],
        do: env(app, key, value)

    engine =
      if Map.has_key?(ctx, :oban_insert_variant),
        do: InsertResultEngine,
        else: Map.get(ctx, :oban_engine, Oban.Engines.Lite)

    oban =
      start_supervised!(
        {Oban,
         name: @oban,
         repo: Repo,
         engine: engine,
         prefix: Map.get(ctx, :oban_prefix, false),
         notifier: Oban.Notifiers.PG,
         queues: false,
         plugins: false,
         testing: Map.get(ctx, :oban_testing, :manual)}
      )

    install_policy!(workdir)

    issuer = identity!()
    resources = apply(RoutineCatalog, :resources, [workdir])

    envelopes =
      for resource <- resources do
        {:ok, cap} = Capability.new(resource_uri: resource, principal_id: issuer.agent_id)
        cap
      end

    :ok =
      IssuerRegistry.register(issuer.agent_id, envelopes, reason: "test-owned routine manifest")

    descriptors = Enum.map(resources, &%{resource_uri: &1, constraints: %{}})

    {:ok, payload} =
      CapsFile.build(issuer.agent_id, descriptors,
        pipeline_root: "owned_test",
        pipeline_path: "morning_digest.dot",
        graph_hash: digest(File.read!(dot)),
        workdir: workdir,
        initial_args: %{
          "reports_directory" => "reports",
          "topics" => ["upstream-deps", "upstream-deps-summary"]
        }
      )

    signature = Crypto.sign(CapsFile.signing_payload(payload), issuer.private_key)
    caps_path = Path.rootname(dot) <> ".caps.json"
    File.write!(caps_path, Jason.encode!(CapsFile.manifest_map(payload, signature)))
    assert {:ok, _} = apply(RoutineCatalog, :load, ["morning_digest"])

    owner = owner!(workdir)
    other = owner!(workdir)
    date = Date.to_iso8601(Date.utc_today())

    fixture =
      Map.merge(ctx, %{
        workdir: workdir,
        dot: dot,
        caps_path: caps_path,
        issuer: issuer,
        owner: owner,
        other: other,
        date: date,
        oban: oban
      })

    File.write!(report(fixture, "upstream-deps"), "first bounded source")
    File.write!(report(fixture, "upstream-deps-summary"), "second bounded source")
    File.write!(report(fixture, "morning-digest"), "previous digest")

    on_exit(fn ->
      IssuerRegistry.revoke(issuer.agent_id, "test cleanup")
      if Process.alive?(oban), do: Supervisor.stop(oban)
    end)

    fixture
  end

  def owner!(workdir) do
    identity = identity!()

    caps =
      for resource <- apply(RoutineCatalog, :resources, [workdir]) do
        {:ok, cap} = Security.grant(principal: identity.agent_id, resource: resource)
        cap
      end

    rules =
      Map.new(
        apply(RoutineCatalog, :resources, [workdir]),
        &{String.trim_trailing(&1, "/**"), :allow}
      )

    assert {:ok, _} =
             Trust.ensure_trust_profile(identity.agent_id, baseline: :block, rules: rules)

    on_exit(fn ->
      for cap <- caps, do: Security.revoke(cap.id)
      Trust.delete_trust_profile(identity.agent_id)
    end)

    %{identity: identity, caps: caps}
  end

  def identity! do
    {:ok, identity} = Security.generate_identity()
    :ok = Security.register_identity(identity)
    on_exit(fn -> Security.deregister_identity(identity.agent_id) end)
    identity
  end

  def intent!(fixture, owner \\ nil, opts \\ []) do
    owner = owner || fixture.owner

    at =
      Keyword.get(
        opts,
        :at,
        DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      )

    id = Keyword.get(opts, :request_id, "routine_#{System.unique_integer([:positive])}_request")

    assert {:ok, intent} =
             apply(Scheduler, :prepare_routine_intent, [
               owner.identity.agent_id,
               "morning_digest",
               at,
               id
             ])

    intent
  end

  def proof!(owner, operation, value, opts \\ []) do
    {:ok, payload} = apply(Scheduler, :routine_request_payload, [operation, value])

    {:ok, proof} =
      SignedRequest.sign(payload, owner.identity.agent_id, owner.identity.private_key)

    case Keyword.fetch(opts, :timestamp) do
      {:ok, timestamp} ->
        proof = %{proof | timestamp: timestamp}

        %{
          proof
          | signature:
              Crypto.sign(SignedRequest.signing_payload(proof), owner.identity.private_key)
        }

      :error ->
        proof
    end
  end

  def enqueue!(fixture, opts \\ []) do
    intent = intent!(fixture, fixture.owner, opts)

    assert {:ok, job} =
             apply(Scheduler, :enqueue_routine, [intent, proof!(fixture.owner, :enqueue, intent)])

    job
  end

  def drain do
    Oban.drain_queue(@oban,
      queue: :pipelines,
      with_limit: 1,
      with_safety: false,
      with_scheduled: DateTime.utc_now()
    )
  end

  def drain_async do
    observer = self()
    spawn_monitor(fn -> send(observer, {:routine_drain_result, self(), drain()}) end)
  end

  def pause_next_job_query!(targets) do
    id = {__MODULE__, make_ref()}
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]

    :ok =
      :telemetry.attach(id, event, &__MODULE__.pause_job_query/4, %{
        id: id,
        observer: self(),
        targets: MapSet.new(targets)
      })

    on_exit(fn -> :telemetry.detach(id) end)
    id
  end

  def pause_job_query(_event, _measurements, metadata, config) do
    query = Map.get(metadata, :query, "")
    key = {__MODULE__, config.id}

    if MapSet.member?(config.targets, self()) and not Process.get(key, false) and
         is_binary(query) and String.starts_with?(query, "SELECT") and
         String.contains?(query, "FROM \"oban_jobs\"") do
      Process.put(key, true)
      marker = make_ref()
      send(config.observer, {:routine_sql_paused, self(), marker})

      receive do
        {:continue_routine_sql, ^marker} -> :ok
      after
        25_000 -> raise "test did not release actual SQL query callback"
      end
    end
  end

  def report(fixture, topic),
    do: Path.join([fixture.workdir, "reports", topic, fixture.date <> ".md"])

  def digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

  def env(app, key, value) do
    old = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case old do
        {:ok, previous} -> Application.put_env(app, key, previous)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp install_policy!(workdir) do
    assert {:ok, original} = PolicyHost.snapshot()
    :ok = Supervisor.terminate_child(Arbor.Trust.ApplicationSupervisor, PolicyHost)
    :ok = PolicyHost.release_claim()

    exact_output =
      apply(RoutineCatalog, :file_uri, [:write, Path.join(workdir, "reports/morning-digest")])

    snapshot = %{
      original
      | security_ceilings: Map.put(original.security_ceilings, exact_output, :allow)
    }

    assert {:ok, host} = PolicyHost.start_link_with_snapshot(snapshot)
    Process.unlink(host)

    on_exit(fn ->
      if Process.alive?(host), do: GenServer.stop(host)
      :ok = PolicyHost.release_claim()
      assert {:ok, _} = Supervisor.restart_child(Arbor.Trust.ApplicationSupervisor, PolicyHost)
    end)
  end
end
