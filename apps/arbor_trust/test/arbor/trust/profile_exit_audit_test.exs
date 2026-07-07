defmodule Arbor.Trust.ProfileExitAuditTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Capability
  alias Arbor.Contracts.Trust.Profile
  alias Arbor.Trust.Store
  alias Arbor.Trust.ProfileExitAudit

  setup do
    previous = Application.get_env(:arbor_security, :capability_signing_required)
    Application.put_env(:arbor_security, :capability_signing_required, false)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_security, :capability_signing_required)
      else
        Application.put_env(:arbor_security, :capability_signing_required, previous)
      end
    end)
  end

  test "security regression: reports legacy baseline and auto rule without explicit cap" do
    profile =
      "agent_exit_audit_1"
      |> profile()
      |> Map.merge(%{
        baseline: :auto,
        rules: %{
          "arbor://action/git" => :auto,
          "arbor://shell" => :block
        }
      })

    audit = ProfileExitAudit.audit_profiles([profile], fn _agent_id -> {:ok, []} end)

    refute audit.clean
    assert audit.counts.legacy_baselines == 1
    assert audit.counts.mint_reliant_rules == 1

    [finding] = audit.findings
    assert finding.agent_id == profile.agent_id
    assert finding.baseline == :auto
    assert finding.legacy_baseline

    assert [
             %{
               uri: "arbor://action/git",
               mode: :auto,
               suggested_capability: "arbor://action/git/**"
             }
           ] = finding.mint_reliant_rules
  end

  test "does not report auto rule when an equivalent explicit wildcard cap is held" do
    agent_id = "agent_exit_audit_2"

    profile =
      agent_id
      |> profile()
      |> Map.merge(%{
        baseline: :ask,
        rules: %{"arbor://action/git" => :allow}
      })

    held_cap = capability(agent_id, "arbor://action/git/**")

    audit = ProfileExitAudit.audit_profiles([profile], fn ^agent_id -> {:ok, [held_cap]} end)

    assert audit.clean
    assert audit.findings == []
    assert audit.counts.mint_reliant_rules == 0
  end

  test "canonicalizes legacy glob trust rules before suggesting capability bundles" do
    assert ProfileExitAudit.suggested_capability_uri("arbor://fs/read/**") ==
             "arbor://fs/read/**"

    assert ProfileExitAudit.suggested_capability_uri("arbor://action/github/*") ==
             "arbor://action/github/**"
  end

  test "security regression: migration demotes ungrantable invalid-principal auto rules" do
    start_store()
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)

    profile =
      "audit_fresh_invalid"
      |> profile()
      |> Map.merge(%{
        baseline: :ask,
        rules: %{"arbor://fs/read" => :auto}
      })

    :ok = Store.store_profile(profile)

    assert {:ok, result} = ProfileExitAudit.migrate(grant_missing: true)
    assert result.after.clean

    assert [
             %{
               agent_id: "audit_fresh_invalid",
               status: :demoted,
               rule_uri: "arbor://fs/read",
               demoted_to: :ask
             }
           ] = result.grants

    assert {:ok, updated} = Store.get_profile("audit_fresh_invalid")
    assert updated.rules["arbor://fs/read"] == :ask
  end

  defp profile(agent_id) do
    {:ok, profile} = Profile.new(agent_id)
    profile
  end

  defp capability(agent_id, resource_uri) do
    {:ok, cap} =
      Capability.new(
        principal_id: agent_id,
        resource_uri: resource_uri
      )

    cap
  end

  defp start_store do
    case GenServer.whereis(Store) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end

    if :ets.info(:trust_profile_cache) != :undefined do
      :ets.delete(:trust_profile_cache)
    end

    {:ok, pid} = Store.start_link([])

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end)
  end

  defp ensure_started(module) do
    if Process.whereis(module), do: :ok, else: start_supervised!({module, []})
  end
end
