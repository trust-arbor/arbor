defmodule Arbor.SecurityTest do
  use ExUnit.Case, async: true

  alias Arbor.Security

  setup do
    # Create a unique agent ID for each test
    agent_id = "agent_#{:erlang.unique_integer([:positive])}"
    {:ok, agent_id: agent_id}
  end

  describe "authorize/4" do
    test "returns unauthorized without capability", %{agent_id: agent_id} do
      assert {:error, :unauthorized} =
               Security.authorize(agent_id, "arbor://fs/read/docs")
    end

    test "returns authorized with valid capability", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/docs"
        )

      assert {:ok, :authorized} =
               Security.authorize(agent_id, "arbor://fs/read/docs")
    end

    test "returns trust_frozen when agent is frozen", %{agent_id: agent_id} do
      {:ok, _} = Security.create_trust_profile(agent_id)

      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/docs"
        )

      :ok = Security.freeze_trust(agent_id, :anomaly_detected)

      assert {:error, :trust_frozen} =
               Security.authorize(agent_id, "arbor://fs/read/docs")
    end
  end

  describe "can?/2" do
    test "returns false without capability", %{agent_id: agent_id} do
      refute Security.can?(agent_id, "arbor://fs/read/docs")
    end

    test "returns true with valid capability", %{agent_id: agent_id} do
      {:ok, _cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/docs"
        )

      assert Security.can?(agent_id, "arbor://fs/read/docs")
    end
  end

  describe "grant/1 and revoke/2" do
    test "grants capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/read/project"
        )

      assert cap.principal_id == agent_id
      assert cap.resource_uri == "arbor://fs/read/project"
    end

    test "revokes capability", %{agent_id: agent_id} do
      {:ok, cap} =
        Security.grant(
          principal: agent_id,
          resource: "arbor://fs/write/temp"
        )

      assert Security.can?(agent_id, "arbor://fs/write/temp")

      :ok = Security.revoke(cap.id)

      refute Security.can?(agent_id, "arbor://fs/write/temp")
    end
  end

  describe "list_capabilities/2" do
    test "lists capabilities for agent", %{agent_id: agent_id} do
      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/a")

      {:ok, _} =
        Security.grant(principal: agent_id, resource: "arbor://fs/read/b")

      {:ok, caps} = Security.list_capabilities(agent_id)

      assert length(caps) == 2
    end
  end

  describe "trust management" do
    test "creates trust profile", %{agent_id: agent_id} do
      {:ok, profile} = Security.create_trust_profile(agent_id)

      assert profile.agent_id == agent_id
      assert profile.tier == :untrusted
      assert profile.trust_score == 0
    end

    test "returns error for duplicate profile", %{agent_id: agent_id} do
      {:ok, _} = Security.create_trust_profile(agent_id)
      assert {:error, :already_exists} = Security.create_trust_profile(agent_id)
    end

    test "gets trust profile", %{agent_id: agent_id} do
      {:ok, _} = Security.create_trust_profile(agent_id)
      {:ok, profile} = Security.get_trust_profile(agent_id)

      assert profile.agent_id == agent_id
    end

    test "gets trust tier", %{agent_id: agent_id} do
      {:ok, _} = Security.create_trust_profile(agent_id)
      {:ok, tier} = Security.get_trust_tier(agent_id)

      assert tier == :untrusted
    end

    test "returns not_found for unknown agent" do
      assert {:error, :not_found} = Security.get_trust_profile("unknown_agent")
      assert {:error, :not_found} = Security.get_trust_tier("unknown_agent")
    end
  end

  describe "record_trust_event/3" do
    test "records action success", %{agent_id: agent_id} do
      {:ok, _} = Security.create_trust_profile(agent_id)

      :ok = Security.record_trust_event(agent_id, :action_success, %{})

      {:ok, profile} = Security.get_trust_profile(agent_id)
      assert profile.total_actions == 1
      assert profile.successful_actions == 1
    end

    test "records security violation", %{agent_id: agent_id} do
      {:ok, _} = Security.create_trust_profile(agent_id)

      :ok = Security.record_trust_event(agent_id, :security_violation, %{})

      {:ok, profile} = Security.get_trust_profile(agent_id)
      assert profile.security_violations == 1
    end
  end

  describe "freeze_trust/2 and unfreeze_trust/1" do
    test "freezes and unfreezes trust", %{agent_id: agent_id} do
      {:ok, _} = Security.create_trust_profile(agent_id)

      :ok = Security.freeze_trust(agent_id, :anomaly_detected)

      {:ok, frozen_profile} = Security.get_trust_profile(agent_id)
      assert frozen_profile.frozen == true
      assert frozen_profile.frozen_reason == :anomaly_detected

      :ok = Security.unfreeze_trust(agent_id)

      {:ok, unfrozen_profile} = Security.get_trust_profile(agent_id)
      assert unfrozen_profile.frozen == false
    end
  end

  describe "healthy?/0" do
    test "returns true when system is running" do
      assert Security.healthy?() == true
    end
  end

  describe "stats/0" do
    test "returns combined statistics" do
      stats = Security.stats()

      assert Map.has_key?(stats, :capabilities)
      assert Map.has_key?(stats, :trust)
      assert Map.has_key?(stats, :healthy)
    end
  end
end
