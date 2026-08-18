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

  test "security regression: concurrent second freeze cannot replace the winning snapshot after env is weakened" do
    set_enforcement_toggles(true)

    Application.put_env(:arbor_security, :enforcement_toggle_freeze_test_seam, %{
      delay_ms: 100,
      notify_pid: self()
    })

    first = Task.async(fn -> Config.freeze_enforcement_toggles() end)

    assert_receive {:enforcement_toggle_freeze_claimed, _winner_pid}, 1_000

    set_enforcement_toggles(false)

    second = Task.async(fn -> Config.freeze_enforcement_toggles() end)

    assert Task.await(second, 5_000) == :ok
    assert Task.await(first, 5_000) == :ok

    for {key, reader} <- @fail_open_when_false do
      assert reader.() == true, "#{key} overwritten by concurrent second freeze"
    end
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

  defp set_enforcement_toggles(value) do
    for {key, _reader} <- @fail_open_when_false do
      Application.put_env(:arbor_security, key, value)
    end
  end

  defp env_snapshot do
    keys =
      Enum.map(@fail_open_when_false, fn {key, _reader} -> key end) ++
        [:enforcement_toggle_freeze_test_seam]

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
end
