defmodule Arbor.Agent.DiagnosticianTemplateTest do
  use ExUnit.Case, async: true

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

    test "required_capabilities include monitor actions" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      # Monitor actions
      assert "arbor://actions/execute/monitor.read" in resources
      assert "arbor://actions/execute/monitor.claim_anomaly" in resources
      assert "arbor://actions/execute/monitor.complete_anomaly" in resources
      assert "arbor://actions/execute/monitor.suppress_fingerprint" in resources
      assert "arbor://actions/execute/monitor.reset_baseline" in resources
      assert "arbor://actions/execute/monitor.read_diagnostics" in resources
    end

    test "required_capabilities include remediation actions" do
      caps = Diagnostician.required_capabilities()
      resources = Enum.map(caps, & &1.resource)

      assert "arbor://actions/execute/remediation.force_gc" in resources
      assert "arbor://actions/execute/remediation.kill_process" in resources
      assert "arbor://actions/execute/remediation.stop_supervisor" in resources
      assert "arbor://actions/execute/remediation.restart_child" in resources
    end

    test "dangerous actions require approval" do
      caps = Diagnostician.required_capabilities()

      kill_cap =
        Enum.find(caps, &(&1.resource == "arbor://actions/execute/remediation.kill_process"))

      stop_cap =
        Enum.find(caps, &(&1.resource == "arbor://actions/execute/remediation.stop_supervisor"))

      assert kill_cap[:requires_approval] == true
      assert stop_cap[:requires_approval] == true
    end

    test "safe actions do not require approval" do
      caps = Diagnostician.required_capabilities()

      gc_cap = Enum.find(caps, &(&1.resource == "arbor://actions/execute/remediation.force_gc"))

      suppress_cap =
        Enum.find(caps, &(&1.resource == "arbor://actions/execute/monitor.suppress_fingerprint"))

      assert gc_cap[:requires_approval] != true
      assert suppress_cap[:requires_approval] != true
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
