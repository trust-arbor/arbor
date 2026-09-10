defmodule Arbor.Orchestrator.EngineDiskNodeRecoverySupport do
  @moduledoc false

  alias Arbor.Contracts.Security.Identity
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.{Config, PipelineStatus}
  alias Arbor.Orchestrator.Engine.Checkpoint
  alias Arbor.Persistence
  alias Arbor.Persistence.Repo
  alias Arbor.Security

  @run_id "private_disk_node_loss"
  @marker "ARBOR_DISK_PROBE "

  # This decorator owns no data. Every Store operation and durability report
  # delegates to the actual Repo-backed Store. Only the acknowledged progress
  # return is held, creating a deterministic whole-workload-VM crash window.
  defmodule CrashWindowStore do
    @moduledoc false
    alias Arbor.Persistence.QueryableStore.Postgres, as: SQL
    alias Arbor.Contracts.Persistence.Record

    def put(key, value, opts) do
      result = SQL.put(key, value, opts)
      if result == :ok, do: hold_completed_progress(value)
      result
    end

    def compare_and_swap(key, expected, replacement, opts) do
      result = SQL.compare_and_swap(key, expected, replacement, opts)
      if match?({:ok, _}, result), do: hold_completed_progress(replacement)
      result
    end

    defdelegate get(key, opts), to: SQL
    defdelegate list(opts), to: SQL
    defdelegate query(filter, opts), to: SQL
    defdelegate delete(key, opts), to: SQL
    defdelegate compare_and_delete(key, expected, opts), to: SQL
    defdelegate durability_class(opts), to: SQL

    defp hold_completed_progress(%Record{data: data}) do
      effect = data["current_effect"]

      if is_map(effect) and effect["status"] == "completed" and
           effect["node_id"] == "effect" and "effect" in (data["completed_nodes"] || []) do
        sync_effect_witness!()
        Arbor.Orchestrator.EngineDiskNodeRecoverySupport.emit("crash_window")

        receive do
          :release_disk_probe -> raise "crash window must end through workload VM loss"
        after
          60_000 -> raise "controller did not terminate the held workload VM"
        end
      end
    end

    defp hold_completed_progress(_), do: :ok

    # The bound production FileWriteHandler produced this witness. Sync only
    # its existing exact contents after the SQL completion acknowledgement;
    # this decorator must never manufacture or repeat the graph's effect.
    defp sync_effect_witness! do
      path = Application.fetch_env!(:arbor_orchestrator, :disk_probe_effect_path)
      {:ok, file} = :file.open(String.to_charlist(path), [:read, :write, :raw, :binary])

      try do
        {:ok, "invoked\n"} = :file.read(file, 16)
        :eof = :file.read(file, 1)
        :ok = :file.sync(file)
      after
        :ok = :file.close(file)
      end
    end
  end

  # Each call is a new OS BEAM. No parent-process data store, RPC, distribution,
  # ETS table, Repo connection, or signing authority is reused across phases.
  def main([phase, source_root, disk_root]) do
    # The test controller owns stdin. If its Port closes, no workload VM may
    # continue an orphaned proof after the test has stopped observing it.
    spawn_link(fn ->
      IO.read(:stdio, :line)
      System.halt(2)
    end)

    try do
      fixture_paths!(source_root, disk_root)
      configure!(source_root, disk_root, phase)
      boot!(source_root)
      check_owners!()
      run_phase(phase, disk_root)
      emit("done", %{phase: phase})
      System.halt(0)
    rescue
      exception ->
        emit("failed", %{phase: phase, error: Exception.message(exception)})
        System.halt(1)
    catch
      kind, reason ->
        emit("failed", %{phase: phase, error: inspect({kind, reason}, limit: 10)})
        System.halt(1)
    end
  end

  def emit(stage, fields \\ %{}) do
    IO.puts(@marker <> Jason.encode!(Map.merge(fields, %{stage: stage, os_pid: System.pid()})))
  end

  defp fixture_paths!(source_root, disk_root) do
    check!(
      Path.type(source_root) == :absolute and Path.type(disk_root) == :absolute,
      :absolute_paths
    )

    check!(Path.dirname(disk_root) == Path.expand(System.tmp_dir!()), :private_fixture_parent)

    check!(
      String.starts_with?(Path.basename(disk_root), "arbor_engine_disk_"),
      :private_fixture_name
    )

    check!(not File.exists?(Path.join(source_root, ".env")), :isolated_checkout_without_dotenv)
    check!(not Node.alive?(), :no_distribution)
  end

  defp configure!(source_root, disk_root, phase) do
    System.put_env("ARBOR_DB", "sqlite")

    source_root
    |> Path.join("config/config.exs")
    |> Elixir.Config.Reader.read!(env: :test)
    |> Application.put_all_env()

    prod = Elixir.Config.Reader.read!(Path.join(source_root, "config/prod.exs"), env: :prod)

    for key <- [:run_journal, :engine_checkpoints] do
      Application.put_env(
        :arbor_orchestrator,
        key,
        get_in(prod, [:arbor_orchestrator, key]) || []
      )
    end

    Application.put_env(
      :arbor_memory,
      :persistence_backend,
      get_in(prod, [:arbor_memory, :persistence_backend])
    )

    Application.put_env(:arbor_persistence, Repo,
      database: Path.join(disk_root, "authority.sqlite3"),
      pool: DBConnection.ConnectionPool,
      pool_size: 2,
      busy_timeout: 2_000,
      journal_mode: :wal,
      log: false
    )

    # Boot the Repo explicitly before Orchestrator; never open the test-config
    # default database. All other optional service owners remain disabled.
    Application.put_env(:arbor_persistence, :start_children, false)
    Application.put_env(:arbor_orchestrator, :recovery_enabled, false)
    Application.put_env(:arbor_orchestrator, :discover_local_providers, false)
    Application.put_env(:arbor_orchestrator, :preflight_models_on_start, false)
    Application.put_env(:arbor_security, :master_key_path, Path.join(disk_root, "master.key"))
    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :capability_signing_required, true)

    Application.put_env(
      :arbor_orchestrator,
      :disk_probe_effect_path,
      Path.join(disk_root, "effects.log")
    )

    if phase == "crash" do
      journal = Application.fetch_env!(:arbor_orchestrator, :run_journal)
      # Preserve an unset backend for the parent regression: an instrumentation
      # decorator must never repair missing production configuration itself.
      if journal[:backend] == Arbor.Persistence.QueryableStore.Postgres do
        Application.put_env(
          :arbor_orchestrator,
          :run_journal,
          Keyword.put(journal, :backend, CrashWindowStore)
        )
      end
    end
  end

  defp boot!(source_root) do
    check!(apply(Repo, :__adapter__, []) == Ecto.Adapters.SQLite3, :compiled_sqlite_adapter)
    {:ok, _} = Application.ensure_all_started(:arbor_persistence)
    {:ok, _} = Supervisor.start_child(Arbor.Persistence.Supervisor, Repo)
    migrations = Path.join(source_root, "apps/arbor_persistence/priv/repo/migrations")
    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
    :ok = Security.TestBootstrap.start!()
    {:ok, _} = Application.ensure_all_started(:arbor_orchestrator)

    # Match Memory.Application's existing ordinary async owner policy. The
    # observation below concerns the separate acknowledged authority APIs.
    {:ok, _} =
      Supervisor.start_child(
        Arbor.Memory.Supervisor,
        {Arbor.Persistence.BufferedStore,
         name: :arbor_memory_durable,
         backend: Application.get_env(:arbor_memory, :persistence_backend),
         write_mode: :async}
      )
  end

  defp check_owners! do
    memory = Persistence.buffered_store_authority_mode(:arbor_memory_durable)
    status = PipelineStatus.durability_status()
    checkpoint = Checkpoint.durability_status(Config.engine_checkpoint_store_opts())

    emit("owners", %{
      memory: inspect(memory),
      journal: %{durable: status.durable, durability_class: status.durability_class},
      checkpoint: %{durable: checkpoint.durable, durability_class: checkpoint.durability_class}
    })

    check!(memory == {:ok, {:backend, :node_restart}}, :memory_authority_must_be_node_restart)
    check!(status.durable and status.durability_class == :node_restart, :journal_must_be_durable)

    check!(
      checkpoint.durable and checkpoint.durability_class == :node_restart,
      :checkpoint_must_be_durable
    )

    check!(
      Arbor.Orchestrator.RecoveryCoordinator.automatic_recovery_eligibility(status) == :ok,
      :automatic_recovery_storage_eligibility
    )
  end

  defp run_phase("config", _disk_root), do: :ok

  defp run_phase("crash", disk_root) do
    identity = identity!(disk_root, :create)
    authority = authority!(identity, disk_root)
    dot_path = Path.join(disk_root, "pipeline.dot")

    File.write!(dot_path, """
    digraph DiskLoss {
      start [shape=Mdiamond]
      effect [type="write", target="file", content_key="witness", output="effects.log", append="true"]
      exit [shape=Msquare]
      start -> effect -> exit
    }
    """)

    result =
      Orchestrator.run_file_as(dot_path, identity.agent_id, authority,
        run_id: @run_id,
        workdir: disk_root,
        initial_values: %{"witness" => "invoked\n"},
        logs_root: Path.join(disk_root, "logs"),
        resumable: true
      )

    detail =
      case result do
        {:ok, %{final_outcome: outcome}} ->
          {outcome.status, outcome.failure_reason}

        {:error, reason} ->
          {:error, reason}

        _ ->
          :invalid_envelope
      end

    raise "run escaped the acknowledged crash window: #{inspect(detail, limit: 10)}"
  end

  defp run_phase("outage", disk_root) do
    identity = identity!(disk_root, :read)
    authority = authority!(identity, disk_root)
    check_interrupted!()
    :ok = Supervisor.terminate_child(Arbor.Persistence.Supervisor, Repo)
    status = Checkpoint.durability_status(Config.engine_checkpoint_store_opts())
    check!(status.durable == false, :outage_is_not_durable)

    result =
      Orchestrator.resume(@run_id,
        authorization: true,
        workdir: disk_root,
        signing_authority: authority,
        agent_id: identity.agent_id
      )

    check!(match?({:error, _}, result), :sql_outage_must_refuse_resume)
    check!(effects(disk_root) == ["invoked"], :outage_must_not_replay_effect)
    check!(not File.exists?(Path.join(disk_root, "logs/checkpoint.json")), :no_file_fallback)
  end

  defp run_phase("resume", disk_root) do
    identity = identity!(disk_root, :read)
    authority = authority!(identity, disk_root)
    check_interrupted!()

    # run_file_as enabled authorization on the original run. Resume accepts
    # trusted Engine opts, so reconstruct the same binding explicitly; a fresh
    # signing handle alone does not opt into RunAuthorization reconstruction.
    {:ok, result} =
      Orchestrator.resume(@run_id,
        authorization: true,
        workdir: disk_root,
        signing_authority: authority,
        agent_id: identity.agent_id
      )

    check!(result.final_outcome.status == :success, :resumed_graph_success)

    check!(
      Enum.all?(["start", "effect", "exit"], &(&1 in result.completed_nodes)),
      :completed_nodes
    )

    check!(effects(disk_root) == ["invoked"], :completed_effect_must_not_replay)
    check!(PipelineStatus.get_record(@run_id).status == :completed, :completed_journal)

    check!(
      File.exists?(Path.join(disk_root, "logs/checkpoint.json")),
      :sql_checkpoint_materialized
    )
  end

  defp run_phase("completed", disk_root) do
    check!(
      PipelineStatus.get_record(@run_id).status == :completed,
      :completed_survives_cold_restart
    )

    {:ok, resumable} = Orchestrator.list_resumable()
    check!(Enum.all?(resumable, &(&1.run_id != @run_id)), :completed_not_resumable)

    check!(
      match?({:error, {:invalid_status, :completed}}, Orchestrator.resume(@run_id)),
      :completed_resume_refused
    )

    check!(effects(disk_root) == ["invoked"], :second_cold_restart_does_not_replay)
  end

  defp check_interrupted! do
    record = PipelineStatus.get_record(@run_id)
    check!(record.status == :interrupted, :cold_journal_interrupted)
    check!(record.current_effect["status"] == "completed", :completed_effect_reconstructed)
    {:ok, resumable} = Orchestrator.list_resumable()
    check!(Enum.any?(resumable, &(&1.run_id == @run_id)), :public_resumable_discovery)
  end

  defp identity!(disk_root, :create) do
    {:ok, identity} = Identity.generate(name: "private-disk-recovery-fixture")
    path = Path.join(disk_root, "fixture-identity.term")
    :ok = File.write(path, :erlang.term_to_binary(identity), [:exclusive])
    :ok = File.chmod(path, 0o600)
    identity
  end

  defp identity!(disk_root, :read) do
    %Identity{} =
      identity =
      disk_root
      |> Path.join("fixture-identity.term")
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    identity
  end

  defp authority!(identity, disk_root) do
    :ok = Security.register_identity(Identity.public_only(identity))
    :ok = Security.store_signing_key(identity.agent_id, identity.private_key)

    file_resource =
      Security.authorization_resource_uri("arbor://fs/write",
        file_path: Path.join(disk_root, "effects.log")
      )

    for resource <- [
          "arbor://orchestrator/execute",
          "arbor://orchestrator/execute/**",
          file_resource
        ] do
      {:ok, _} = Security.grant(principal: identity.agent_id, resource: resource)
    end

    {:ok, proof} =
      Security.build_signing_authority_acquisition_proof(identity.agent_id, identity.private_key,
        purpose: :coding_task_recovery,
        owner: self()
      )

    {:ok, authority} = Security.open_signing_authority(proof)
    authority
  end

  defp effects(disk_root),
    do: disk_root |> Path.join("effects.log") |> File.read!() |> String.split("\n", trim: true)

  defp check!(true, _label), do: :ok
  defp check!(_, label), do: raise("disk recovery assertion failed: #{label}")
end
