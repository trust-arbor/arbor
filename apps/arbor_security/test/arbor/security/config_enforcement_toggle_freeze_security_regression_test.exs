defmodule Arbor.Security.ConfigEnforcementToggleFreezeSecurityRegressionTest do
  @moduledoc """
  Security regression: closed fail-open-when-false Security.Config enforcement
  toggles cannot be weakened by Application.put_env/3 after freeze.
  """

  use ExUnit.Case, async: false

  alias Arbor.Security.Config

  @moduletag :fast
  @moduletag security: :regression

  @fail_open_when_false [
    {:identity_verification, &Config.identity_verification_enabled?/0},
    {:capability_signing_required, &Config.capability_signing_required?/0},
    {:constraint_enforcement_enabled, &Config.constraint_enforcement_enabled?/0},
    {:reflex_checking_enabled, &Config.reflex_checking_enabled?/0},
    {:consensus_escalation_enabled, &Config.consensus_escalation_enabled?/0},
    {:quota_enforcement_enabled, &Config.quota_enforcement_enabled?/0},
    {:policy_enforcer_enabled, &Config.policy_enforcer_enabled?/0},
    {:delegation_chain_verification_enabled, &Config.delegation_chain_verification_enabled?/0},
    {:strict_identity_mode, &Config.strict_identity_mode?/0},
    {:distributed_signals, &Config.distributed_signals_enabled?/0}
  ]

  setup do
    originals = env_snapshot()

    on_exit(fn ->
      Config.restore_enforcement_toggles()
      restore_env(originals)
    end)

    :ok
  end

  test "security regression: put_env false after freeze does not weaken public Config readers" do
    set_enforcement_toggles(true)
    assert :ok = Config.freeze_enforcement_toggles()

    set_enforcement_toggles(false)

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} weakened after freeze"
    end
  end

  test "security regression: test env Application.start does not auto-freeze put_env Config reads" do
    assert List.keymember?(Application.started_applications(), :arbor_security, 0)
    refute_frozen_readers()

    assert :ok = Config.maybe_freeze_enforcement_toggles(:test)
    refute_frozen_readers()
  end

  test "security regression: production start path freezes enforcement toggles" do
    set_enforcement_toggles(true)
    assert :ok = Config.maybe_freeze_enforcement_toggles(:prod)

    set_enforcement_toggles(false)

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} weakened after production start freeze"
    end
  end

  test "security regression: restore seam unfreezes so put_env can weaken again" do
    set_enforcement_toggles(true)
    assert :ok = Config.freeze_enforcement_toggles()
    set_enforcement_toggles(false)
    assert Config.identity_verification_enabled?() == true

    assert :ok = Config.restore_enforcement_toggles()
    refute_frozen_readers()
  end

  test "security regression: a second freeze does not adopt a later weakened put_env" do
    set_enforcement_toggles(true)
    assert :ok = Config.freeze_enforcement_toggles()
    set_enforcement_toggles(false)
    assert :ok = Config.freeze_enforcement_toggles()

    assert Config.identity_verification_enabled?() == true
    assert Config.capability_signing_required?() == true
    assert Config.strict_identity_mode?() == true
    assert Config.distributed_signals_enabled?() == true
  end

  test "security regression: freeze snapshots the false default for strict identity" do
    Application.delete_env(:arbor_security, :strict_identity_mode)
    Application.put_env(:arbor_security, :distributed_signals, false)

    assert Config.strict_identity_mode?() == false
    assert Config.distributed_signals_enabled?() == false
    assert :ok = Config.freeze_enforcement_toggles()

    Application.put_env(:arbor_security, :strict_identity_mode, true)
    Application.put_env(:arbor_security, :distributed_signals, true)

    assert Config.strict_identity_mode?() == false
    assert Config.distributed_signals_enabled?() == false
  end

  test "security regression: Application start owns the claim table and freeze does not create it" do
    table = claim_table()
    assert :ets.whereis(table) != :undefined
    owner = :ets.info(table, :owner)
    assert owner == application_start_pid(:arbor_security)
    assert Process.alive?(owner)

    set_enforcement_toggles(true)
    assert :ok = Config.freeze_enforcement_toggles()
    assert :ets.info(table, :owner) == owner
  end

  test "security regression: first freezer process exit does not reopen the claim for a later freeze" do
    set_enforcement_toggles(true)

    freezer =
      Task.async(fn ->
        assert :ok = Config.freeze_enforcement_toggles()
        self()
      end)

    freezer_pid = Task.await(freezer, 5_000)
    refute Process.alive?(freezer_pid)

    table = claim_table()
    assert :ets.whereis(table) != :undefined
    owner = :ets.info(table, :owner)
    assert owner == application_start_pid(:arbor_security)
    assert owner != freezer_pid

    set_enforcement_toggles(false)
    assert :ok = Config.freeze_enforcement_toggles()

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} replaced after first freezer exited"
    end
  end

  test "security regression: winner death after ETS snapshot insert cannot unfreeze readers" do
    set_enforcement_toggles(true)

    previous_seam =
      Application.get_env(:arbor_security, :enforcement_toggle_freeze_after_ets_insert_test_seam)

    Application.put_env(:arbor_security, :enforcement_toggle_freeze_after_ets_insert_test_seam, %{
      delay_ms: 500,
      notify_pid: self()
    })

    winner =
      spawn(fn ->
        Config.freeze_enforcement_toggles()
      end)

    on_exit(fn ->
      if Process.alive?(winner), do: Process.exit(winner, :kill)

      case previous_seam do
        nil ->
          Application.delete_env(
            :arbor_security,
            :enforcement_toggle_freeze_after_ets_insert_test_seam
          )

        value ->
          Application.put_env(
            :arbor_security,
            :enforcement_toggle_freeze_after_ets_insert_test_seam,
            value
          )
      end
    end)

    assert_receive :enforcement_toggle_ets_snapshot_inserted, 1_000
    monitor = Process.monitor(winner)
    Process.exit(winner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^winner, :killed}, 1_000

    assert :persistent_term.get({Config, :enforcement_toggles}, :not_frozen) == :not_frozen

    table = claim_table()
    assert [{:claimed, snapshot}] = :ets.lookup(table, :claimed)
    assert %{identity_verification: true} = snapshot

    set_enforcement_toggles(false)

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} followed mutable env after winner death"
    end

    assert :ok = Config.freeze_enforcement_toggles()

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} replaced by later freeze after winner death"
    end

    assert %{identity_verification: true} =
             :persistent_term.get({Config, :enforcement_toggles}, :not_frozen)
  end

  test "security regression: concurrent freezes cannot replace the winning snapshot after env is weakened" do
    set_enforcement_toggles(true)

    tasks =
      for _ <- 1..2 do
        Task.async(fn -> Config.freeze_enforcement_toggles() end)
      end

    Enum.each(tasks, fn task ->
      assert Task.await(task, 5_000) == :ok
    end)

    set_enforcement_toggles(false)

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} overwritten by concurrent second freeze"
    end
  end

  test "security regression: recreating the claim table does not overwrite an existing freeze snapshot" do
    set_enforcement_toggles(true)
    assert :ok = Config.freeze_enforcement_toggles()
    set_enforcement_toggles(false)

    table = claim_table()
    assert :ok = Application.stop(:arbor_security)
    assert :ets.whereis(table) == :undefined

    assert {:ok, _} = Application.ensure_all_started(:arbor_security)
    assert :ets.whereis(table) != :undefined
    assert :ets.info(table, :owner) == application_start_pid(:arbor_security)
    assert :ets.member(table, :claimed)

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} lost after claim table recreate"
    end

    assert :ok = Config.freeze_enforcement_toggles()

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} replaced after claim table recreate"
    end
  after
    restore_security_app()
  end

  test "security regression: foreign named claim table fails Application start closed" do
    table = claim_table()
    set_enforcement_toggles(false)

    assert :ok = Application.stop(:arbor_security)
    assert :ets.whereis(table) == :undefined

    ^table = :ets.new(table, [:named_table, :set, :public])
    foreign_owner = self()
    assert :ets.info(table, :owner) == foreign_owner

    assert {:error, {reason, {Arbor.Security.Application, :start, _args}}} =
             Application.start(:arbor_security)

    assert reason == {:enforcement_toggle_claim_table_foreign_owner, foreign_owner}

    refute List.keymember?(Application.started_applications(), :arbor_security, 0)

    set_enforcement_toggles(true)

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} frozen during failed foreign-table start"
    end
  after
    restore_security_app()
  end

  defp refute_frozen_readers do
    set_enforcement_toggles(true)

    for {_key, reader} <- @fail_open_when_false do
      assert reader.() == true
    end

    set_enforcement_toggles(false)

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == false, "#{key} did not follow put_env while unfrozen"
    end
  end

  defp ensure_signals_children do
    {:ok, _started} = Application.ensure_all_started(:arbor_kernel_runtime)

    for child <- [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ] do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          {module, _opts} = child
          :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)
      end
    end
  end

  defp claim_table, do: Module.concat(Config, EnforcementToggleClaim)

  # The claim table is created inside `Arbor.Security.Application.start/2`, so
  # its owner is the process OTP uses to run `Mod.start/2` — which sits between
  # the application master and the root supervisor and has no public accessor.
  # (`Application.app_pid/1` does not exist; this test shipped calling it.)
  # The root supervisor is started from that process, so it is the head of the
  # supervisor's `$ancestors`.
  #
  # Asserting the exact pid is the point: it proves the table belongs to the
  # application itself and not to whichever process happened to call
  # `freeze_enforcement_toggles/0` first — a freezer-owned table would die with
  # that process and reopen the claim.
  defp application_start_pid(app) do
    master = :application_controller.get_master(app)
    {root_sup, _module} = :application_master.get_child(master)

    root_sup
    |> Process.info(:dictionary)
    |> elem(1)
    |> Keyword.fetch!(:"$ancestors")
    |> hd()
  end

  defp set_enforcement_toggles(value) do
    for {key, _reader} <- @fail_open_when_false do
      Application.put_env(:arbor_security, key, value)
    end
  end

  defp env_snapshot do
    keys = Enum.map(@fail_open_when_false, fn {key, _reader} -> key end)

    Map.new(keys, fn key ->
      {key, Application.get_env(:arbor_security, key)}
    end)
  end

  defp restore_env(originals) do
    Enum.each(originals, fn
      {key, nil} -> Application.delete_env(:arbor_security, key)
      {key, value} -> Application.put_env(:arbor_security, key, value)
    end)
  end

  defp restore_security_app do
    table = claim_table()

    if :ets.whereis(table) != :undefined and :ets.info(table, :owner) == self() do
      :ets.delete(table)
    end

    _ = Application.stop(:arbor_security)

    if :ets.whereis(table) != :undefined and :ets.info(table, :owner) == self() do
      :ets.delete(table)
    end

    {:ok, _} = Application.ensure_all_started(:arbor_security)

    # Restarting :arbor_security brings Identity.Registry back, and with
    # distributed signals enabled it subscribes to Arbor.Signals.Bus during
    # init. The two tests that fully stop the app leave the Bus down, so
    # without this the restore crashes with :noproc and the test reports a
    # teardown failure rather than its actual result.
    ensure_signals_children()

    _ = Arbor.Security.TestBootstrap.start!()
    restore_extra_security_test_children()
    :ok
  end

  defp restore_extra_security_test_children do
    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    issuer =
      Supervisor.child_spec(
        {Arbor.Persistence.BufferedStore,
         name: :arbor_security_issuers, backend: backend, write_mode: :sync, collection: "issuers"},
        id: :arbor_security_issuers
      )

    start_security_test_child(issuer)

    signing_authority_owner_token = make_ref()

    for child <- [
          {Arbor.Security.IssuerRegistry, []},
          {Arbor.Security.SigningAuthorityStateOwner,
           broker_token: signing_authority_owner_token},
          {Arbor.Security.SigningAuthorityBroker,
           state_owner_token: signing_authority_owner_token},
          {Arbor.Security.DeliveryReceiptBroker, []}
        ] do
      start_security_test_child(child)
    end
  end

  defp start_security_test_child(spec) do
    child_spec = Supervisor.child_spec(spec, [])

    case Supervisor.start_child(Arbor.Security.Supervisor, child_spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, :already_present} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
