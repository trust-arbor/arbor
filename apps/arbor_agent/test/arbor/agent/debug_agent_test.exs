defmodule Arbor.Agent.DiagnosticianTemplateTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Templates.Diagnostician

  describe "template callbacks" do
    test "character returns valid Character struct" do
      char = Diagnostician.character()
      assert char.name == "Diagnostician"
      assert char.role == "BEAM SRE / Runtime Diagnostician"
      assert is_list(char.traits)
      assert is_list(char.values)
      assert is_list(char.instructions)
      assert length(char.instructions) >= 5
    end

    test "trust_tier is :established" do
      assert Diagnostician.trust_tier() == :established
    end

    test "initial_goals are well-defined" do
      goals = Diagnostician.initial_goals()
      assert length(goals) == 3
      assert Enum.all?(goals, &is_map/1)
      assert Enum.all?(goals, &Map.has_key?(&1, :type))
      assert Enum.all?(goals, &Map.has_key?(&1, :description))
    end

    test "required_capabilities include monitor facade URIs" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      # Monitor read and remediate (facade URIs)
      assert "arbor://monitor/read" in resources
      assert "arbor://monitor/remediate" in resources
    end

    test "required_capabilities include remediation via monitor facade" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      # Remediation actions are covered by the monitor/remediate facade URI
      assert "arbor://monitor/remediate" in resources
    end

    test "required_capabilities include fs facade URIs" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      assert "arbor://fs/read" in resources
      assert "arbor://fs/write" in resources
      assert "arbor://fs/list" in resources
    end

    test "required_capabilities include memory facade URIs" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      assert "arbor://memory/recall" in resources
      assert "arbor://memory/add_knowledge" in resources
      assert "arbor://memory/read" in resources
      assert "arbor://memory/write" in resources
    end

    test "required_capabilities include comms facade URIs" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      assert "arbor://comms/send" in resources
      assert "arbor://comms/poll" in resources
    end

    test "required_capabilities include governance and code facade URIs" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      assert "arbor://consensus/propose" in resources
      assert "arbor://code/hot_load" in resources
      assert "arbor://shell/exec" in resources
    end

    test "domain_context includes remediation playbook" do
      context = Diagnostician.domain_context()
      assert is_binary(context)
      assert context =~ "Remediation Playbook"
      assert context =~ "Message Queue Flood"
      assert context =~ "Memory Leak"
      assert context =~ "Supervisor Restart Storm"
      assert context =~ "EWMA Noise"
      assert context =~ "EWMA Drift"
      assert context =~ "Safety Rules"
    end

    test "metadata includes ops_room flag" do
      meta = Diagnostician.metadata()
      assert meta.ops_room == true
      assert meta.version == "2.0.0"
    end

    test "description mentions ops chat room" do
      desc = Diagnostician.description()
      assert desc =~ "ops chat room"
    end

    test "instructions mention ops room operation" do
      char = Diagnostician.character()
      instructions = Enum.join(char.instructions, " ")
      assert instructions =~ "ops chat room"
      assert instructions =~ "monitor_claim_anomaly"
      assert instructions =~ "monitor_complete_anomaly"
    end
  end
end
