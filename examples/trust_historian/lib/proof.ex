defmodule PairedStandaloneConsumer.Proof do
  @moduledoc "Actual canonical authority + Trust + SQL Historian proof in a caller-owned single-node host."
  alias PairedStandaloneConsumer.{CoreProof, Provisioner}

  def run!(phase, opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:paired_standalone_consumer)

    if Keyword.get(opts, :require_no_mix, false) do
      false = Code.ensure_loaded?(Mix)
      {:error, :bad_name} = :code.lib_dir(:mix)
    end

    GenServer.call(Provisioner, {:phase, phase}, 3_600_000)
  end

  def start_canonical! do
    for app <- [:arbor_capabilities, :arbor_trust, :arbor_historian] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    for {name, app} <- [
          {Arbor.Security.Supervisor, :arbor_capabilities},
          {Arbor.Trust.PolicyHost, :arbor_trust},
          {Arbor.Trust.Supervisor, :arbor_trust},
          {Arbor.Historian.Supervisor, :arbor_historian},
          {Arbor.Historian.AuthorityAuditPuller, :arbor_historian}
        ] do
      pid = Process.whereis(name)
      true = is_pid(pid) and Process.alive?(pid)
      {:ok, ^app} = :application.get_application(pid)
    end

    {Arbor.Historian.AuthorityAuditPuller, puller, :worker, _} =
      Enum.find(
        Supervisor.which_children(Arbor.Historian.Supervisor),
        &(elem(&1, 0) == Arbor.Historian.AuthorityAuditPuller)
      )

    ^puller = Process.whereis(Arbor.Historian.AuthorityAuditPuller)
    :ok
  end

  def run_owned!(:install) do
    versions = Ecto.Migrator.run(Arbor.Persistence.SQL.Repo, :up, all: true, log: false)
    true = length(versions) == 11
    :ok = start_canonical!()

    %{
      "phase" => "install",
      "checks" => [
        "explicit public SQL migration installation",
        "canonical active roots/PID provenance"
      ]
    }
  end

  def run_owned!(phase) when phase in [:write, :recover, :refused] do
    :ok = start_canonical!()
    :ok = PairedStandaloneConsumer.HistorianProof.pause!()
    core = CoreProof.run_owned!(phase)
    context = CoreProof.context!(phase)

    if phase == :recover do
      :ok = PairedStandaloneConsumer.HistorianProof.refused!()
      :ok = PairedStandaloneConsumer.HistorianProof.outage!()
      :ok = PairedStandaloneConsumer.HistorianProof.lost_ack!()
    end

    trust = ComposedTrustProof.verify!(context)

    historian =
      case phase do
        :refused -> PairedStandaloneConsumer.HistorianProof.recover!()
        _ -> PairedStandaloneConsumer.HistorianProof.write!()
      end

    :ok = quiescent!()

    %{
      "phase" => Atom.to_string(phase),
      "checks" => core["checks"] ++ trust["checks"] ++ historian["checks"],
      "core" => Map.drop(core, ["code_paths"]),
      "trust" => trust,
      "historian" => historian,
      "quiescent" => true,
      "single_node" => true,
      "production_m2_credit" => false
    }
  end

  def run_owned!(:namespace_seed) do
    :ok = start_canonical!()
    :ok = PairedStandaloneConsumer.HistorianProof.pause!()
    context = CoreProof.context!(:namespace_seed)

    result =
      PairedStandaloneConsumer.HistorianProof.namespace_attack_seed!(fn ->
        exact_grant(context)
      end)

    :ok = quiescent!()
    Map.merge(result, %{"phase" => "namespace_seed", "quiescent" => true})
  end

  def run_owned!(:namespace_rollback_attack) do
    :ok = start_canonical!()
    :ok = PairedStandaloneConsumer.HistorianProof.pause!()
    context = CoreProof.context!(:namespace_rollback_attack)

    PairedStandaloneConsumer.HistorianProof.namespace_rollback_attack!(fn ->
      exact_grant(context)
    end)
  end

  def run_owned!(:conflict) do
    :ok = start_canonical!()
    :ok = PairedStandaloneConsumer.HistorianProof.pause!()
    context = CoreProof.context!(:conflict)

    {:ok, _capability} =
      Arbor.Security.grant(
        principal: context.agent_id,
        resource: "arbor://standalone/read/conflict-proof",
        actor_authority: context.operator_authority
      )

    PairedStandaloneConsumer.HistorianProof.conflict!()
  end

  def run_owned!(:retirement) do
    :ok = start_canonical!()
    :ok = PairedStandaloneConsumer.HistorianProof.pause!()
    context = CoreProof.context!(:retirement)

    result =
      PairedStandaloneConsumer.HistorianProof.retirement!(fn index ->
        {:ok, capability} =
          Arbor.Security.grant(
            principal: context.agent_id,
            resource: "arbor://standalone/read/retirement/#{index}",
            actor_authority: context.operator_authority
          )

        :ok = Arbor.Security.revoke(capability.id, actor_authority: context.operator_authority)
        :ok
      end)

    :ok = quiescent!()

    Map.merge(result, %{
      "phase" => "retirement",
      "quiescent" => true,
      "single_node" => true,
      "production_m2_credit" => false
    })
  end

  defp exact_grant(context) do
    Arbor.Security.acknowledged_grant(
      capability_id:
        "cap_" <> Base.encode16(:erlang.md5(context.agent_id <> "-namespace-seed"), case: :lower),
      granted_at: ~U[2026-10-30 12:00:00Z],
      principal: context.agent_id,
      resource: "arbor://standalone/read/namespace-rollback-seed",
      actor_authority: context.operator_authority
    )
  end

  defp quiescent! do
    :ok = PairedStandaloneConsumer.HistorianProof.pause!()
    # Only a fully delivered journal can be copied for predecessor rollback.
    {:ok, status} = Arbor.Security.audit_journal_status()
    true = status["pending_count"] == 0

    %{rows: [[0, _log_frames, _checkpointed]]} =
      Ecto.Adapters.SQL.query!(Arbor.Persistence.SQL.Repo, "PRAGMA wal_checkpoint(TRUNCATE)", [])

    :ok
  end
end
