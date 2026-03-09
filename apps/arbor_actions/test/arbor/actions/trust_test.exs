defmodule Arbor.Actions.TrustTest do
  @moduledoc """
  Tests for Trust profile actions used by the InterviewAgent.
  """
  use ExUnit.Case, async: false

  alias Arbor.Actions.Trust.{
    ReadProfile,
    ProposeProfile,
    ApplyProfile,
    ExplainMode,
    ListPresets,
    ListAgents
  }

  @moduletag :fast

  setup do
    # Ensure trust infrastructure is running — restart if crashed
    restart_if_dead(Arbor.Trust.Store, fn -> Arbor.Trust.Store.start_link([]) end)

    restart_if_dead(Arbor.Trust.Manager, fn ->
      Arbor.Trust.Manager.start_link(event_store: false)
    end)

    agent_id = "interview_test_#{:rand.uniform(100_000)}"
    {:ok, _profile} = Arbor.Trust.Manager.create_trust_profile(agent_id)

    on_exit(fn ->
      try do
        Arbor.Trust.Manager.delete_trust_profile(agent_id)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end)

    %{agent_id: agent_id}
  end

  describe "ReadProfile" do
    test "reads an existing agent's trust profile", %{agent_id: agent_id} do
      assert {:ok, result} = ReadProfile.run(%{agent_id: agent_id}, %{})

      assert result.agent_id == agent_id
      assert result.tier == :untrusted
      assert is_atom(result.baseline)
      assert is_map(result.rules)
      assert result.frozen == false
    end

    test "returns error for non-existent agent" do
      assert {:error, msg} = ReadProfile.run(%{agent_id: "nonexistent_agent"}, %{})
      assert msg =~ "No trust profile found"
    end
  end

  describe "ProposeProfile" do
    test "proposes preset change", %{agent_id: agent_id} do
      assert {:ok, result} =
               ProposeProfile.run(
                 %{agent_id: agent_id, preset: "balanced", rule_changes: %{}},
                 %{}
               )

      assert result.status == :proposed
      assert result.proposed.baseline == :ask
      assert is_map(result.proposed.rules)
      assert is_map(result.diff)
      assert result.instructions =~ "Review"
    end

    test "proposes baseline change", %{agent_id: agent_id} do
      assert {:ok, result} =
               ProposeProfile.run(
                 %{agent_id: agent_id, baseline: "allow", rule_changes: %{}},
                 %{}
               )

      assert result.proposed.baseline == :allow
    end

    test "proposes rule additions", %{agent_id: agent_id} do
      rule_changes = %{
        "arbor://shell/exec/git" => "ask",
        "arbor://code/read" => "auto"
      }

      assert {:ok, result} =
               ProposeProfile.run(
                 %{agent_id: agent_id, rule_changes: rule_changes},
                 %{}
               )

      assert result.proposed.rules["arbor://shell/exec/git"] == :ask
      assert result.proposed.rules["arbor://code/read"] == :auto
    end

    test "proposes rule removal", %{agent_id: agent_id} do
      # First set a rule
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | rules: Map.put(profile.rules, "arbor://test/uri", :block)}
      end)

      assert {:ok, result} =
               ProposeProfile.run(
                 %{agent_id: agent_id, rule_changes: %{"arbor://test/uri" => "remove"}},
                 %{}
               )

      refute Map.has_key?(result.proposed.rules, "arbor://test/uri")
    end

    test "shows diff between current and proposed", %{agent_id: agent_id} do
      assert {:ok, result} =
               ProposeProfile.run(
                 %{
                   agent_id: agent_id,
                   baseline: "allow",
                   rule_changes: %{"arbor://shell/exec/git" => "ask"}
                 },
                 %{}
               )

      assert result.diff.baseline_changed == true
      assert result.diff.baseline_to == :allow
      assert Map.has_key?(result.diff.rules_added_or_changed, "arbor://shell/exec/git")
    end
  end

  describe "ApplyProfile" do
    test "applies confirmed profile changes", %{agent_id: agent_id} do
      rules = %{"arbor://code/read" => "auto", "arbor://shell" => "block"}

      assert {:ok, result} =
               ApplyProfile.run(
                 %{agent_id: agent_id, baseline: "ask", rules: rules},
                 %{}
               )

      assert result.status == :applied
      assert result.baseline == :ask
      assert result.rules["arbor://code/read"] == :auto
      assert result.rules["arbor://shell"] == :block

      # Verify it was actually persisted
      {:ok, profile} = Arbor.Trust.get_trust_profile(agent_id)
      assert profile.baseline == :ask
      assert profile.rules["arbor://code/read"] == :auto
    end
  end

  describe "ExplainMode" do
    test "explains trust resolution for a URI", %{agent_id: agent_id} do
      assert {:ok, result} =
               ExplainMode.run(
                 %{agent_id: agent_id, resource_uri: "arbor://shell/exec/git"},
                 %{}
               )

      assert is_map(result)
      assert Map.has_key?(result, :resource_uri) or Map.has_key?(result, :effective_mode)
    end
  end

  describe "ListPresets" do
    test "lists all available presets" do
      assert {:ok, result} = ListPresets.run(%{}, %{})

      assert length(result.presets) == 4

      preset_names = Enum.map(result.presets, & &1.name)
      assert :cautious in preset_names
      assert :balanced in preset_names
      assert :hands_off in preset_names
      assert :full_trust in preset_names

      # Each preset has baseline, rules, and description
      Enum.each(result.presets, fn preset ->
        assert is_atom(preset.baseline)
        assert is_map(preset.rules)
        assert is_binary(preset.description)
      end)
    end
  end

  describe "ListAgents" do
    test "lists agents with trust summaries", %{agent_id: agent_id} do
      assert {:ok, result} = ListAgents.run(%{}, %{})

      assert result.count >= 1

      agent = Enum.find(result.agents, &(&1.agent_id == agent_id))
      assert agent != nil
      assert agent.tier == :untrusted
      assert is_atom(agent.baseline)
      assert is_integer(agent.rule_count)
      assert agent.frozen == false
    end
  end

  describe "propose-then-apply workflow" do
    test "full workflow: propose preset, review, apply", %{agent_id: agent_id} do
      # Step 1: Propose balanced preset
      assert {:ok, proposal} =
               ProposeProfile.run(
                 %{agent_id: agent_id, preset: "balanced", rule_changes: %{}},
                 %{}
               )

      assert proposal.status == :proposed

      # Step 2: Apply the proposed changes
      rules_as_strings =
        proposal.proposed.rules
        |> Enum.map(fn {uri, mode} -> {uri, to_string(mode)} end)
        |> Enum.into(%{})

      assert {:ok, applied} =
               ApplyProfile.run(
                 %{
                   agent_id: agent_id,
                   baseline: to_string(proposal.proposed.baseline),
                   rules: rules_as_strings
                 },
                 %{}
               )

      assert applied.status == :applied

      # Step 3: Verify the profile matches what was proposed
      assert {:ok, final} = ReadProfile.run(%{agent_id: agent_id}, %{})
      assert final.baseline == proposal.proposed.baseline
      assert final.rules == proposal.proposed.rules
    end
  end

  # Helpers

  defp restart_if_dead(module, start_fn) do
    case Process.whereis(module) do
      nil ->
        start_fn.()

      pid ->
        if Process.alive?(pid) do
          :ok
        else
          start_fn.()
        end
    end
    |> case do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      :ok -> :ok
    end
  end
end
