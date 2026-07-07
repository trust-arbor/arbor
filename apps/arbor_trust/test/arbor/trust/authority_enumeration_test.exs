defmodule Arbor.Trust.AuthorityEnumerationTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  setup :start_infrastructure

  describe "enumerate_authority/3" do
    test "returns held caps plus profile-mintable candidate URIs without minting", %{
      agent_id: agent_id
    } do
      set_policy_enforcer_enabled(true)

      create_profile_with_rules(agent_id, :ask, %{
        "arbor://memory" => :auto,
        "arbor://code/write" => :block
      })

      {:ok, held_cap} = Arbor.Security.grant(principal: agent_id, resource: "arbor://fs/read")
      {:ok, caps_before} = Arbor.Security.list_capabilities(agent_id)

      {:ok, snapshot} =
        Arbor.Trust.enumerate_authority(agent_id, [
          "arbor://fs/read",
          "arbor://memory/recall",
          "arbor://code/write"
        ])

      {:ok, caps_after} = Arbor.Security.list_capabilities(agent_id)

      assert Enum.map(caps_after, & &1.id) == Enum.map(caps_before, & &1.id)
      assert "arbor://fs/read" in snapshot.held_uris
      assert snapshot.policy_mintable_uris == ["arbor://memory/recall"]
      assert snapshot.effective_uris == ["arbor://fs/read", "arbor://memory/recall"]

      fs_read = entry(snapshot, "arbor://fs/read")
      assert fs_read.held
      refute fs_read.policy_mintable
      assert fs_read.held_capability_ids == [held_cap.id]
      assert fs_read.sources == [:held_capability]

      memory = entry(snapshot, "arbor://memory/recall")
      refute memory.held
      assert memory.policy_mintable
      assert memory.mode == :auto
      assert memory.sources == [:policy_mintable]

      code_write = entry(snapshot, "arbor://code/write")
      refute code_write.held
      refute code_write.policy_mintable
      assert code_write.mode == :block
      assert code_write.sources == []
    end

    test "does not treat a missing trust profile as policy-mintable", %{agent_id: agent_id} do
      {:ok, snapshot} = Arbor.Trust.enumerate_authority(agent_id, ["arbor://memory/recall"])

      memory = entry(snapshot, "arbor://memory/recall")
      refute memory.held
      refute memory.policy_mintable
      assert memory.sources == []
      assert memory.policy_error == :not_found
    end

    test "does not report policy-mintable URIs when policy enforcer is disabled", %{
      agent_id: agent_id
    } do
      previous = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
      Application.put_env(:arbor_trust, :policy_enforcer_enabled, false)

      on_exit(fn ->
        if is_nil(previous) do
          Application.delete_env(:arbor_trust, :policy_enforcer_enabled)
        else
          Application.put_env(:arbor_trust, :policy_enforcer_enabled, previous)
        end
      end)

      create_profile_with_rules(agent_id, :ask, %{"arbor://memory" => :auto})

      {:ok, snapshot} = Arbor.Trust.enumerate_authority(agent_id, ["arbor://memory/recall"])

      memory = entry(snapshot, "arbor://memory/recall")
      assert memory.mode == :auto
      refute memory.policy_mintable
      assert memory.sources == []
    end

    test "B6 security regression: unprofiled auto rules are not policy-mintable", %{
      agent_id: agent_id
    } do
      set_policy_enforcer_enabled(true)
      create_profile_with_rules(agent_id, :ask, %{"arbor://unprofiled" => :auto})

      {:ok, snapshot} = Arbor.Trust.enumerate_authority(agent_id, ["arbor://unprofiled/op"])

      entry = entry(snapshot, "arbor://unprofiled/op")
      assert entry.mode == :auto
      refute entry.held
      refute entry.policy_mintable
      assert entry.sources == []
      assert snapshot.policy_mintable_uris == []
    end
  end

  defp entry(snapshot, uri) do
    Enum.find(snapshot.candidate_entries, &(&1.uri == uri)) ||
      flunk("missing authority entry for #{uri}")
  end

  defp start_infrastructure(_context) do
    ensure_started(Arbor.Security.Identity.Registry)
    ensure_started(Arbor.Security.SystemAuthority)
    ensure_started(Arbor.Security.CapabilityStore)
    ensure_started(Arbor.Security.Reflex.Registry)
    ensure_started(Arbor.Security.Constraint.RateLimiter)

    ensure_started(Arbor.Trust.EventStore)
    ensure_started(Arbor.Trust.Store)

    ensure_started(Arbor.Trust.Manager,
      circuit_breaker: false,
      decay: false,
      event_store: true
    )

    agent_id = "agent_authority_enum_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        case Arbor.Security.list_capabilities(agent_id) do
          {:ok, caps} -> Enum.each(caps, &Arbor.Security.revoke(&1.id))
          _ -> :ok
        end
      end
    end)

    {:ok, agent_id: agent_id}
  end

  defp ensure_started(module, opts \\ []) do
    if Process.whereis(module) do
      :already_running
    else
      start_supervised!({module, opts})
    end
  end

  defp create_profile_with_rules(agent_id, baseline, rules) do
    case Arbor.Trust.create_trust_profile(agent_id) do
      {:ok, _} -> :ok
      {:error, :already_exists} -> :ok
    end

    Arbor.Trust.Store.update_profile(agent_id, fn profile ->
      %{profile | baseline: baseline, rules: rules}
    end)
  end

  defp set_policy_enforcer_enabled(value) do
    previous = Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, value)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_trust, :policy_enforcer_enabled)
      else
        Application.put_env(:arbor_trust, :policy_enforcer_enabled, previous)
      end
    end)
  end
end
