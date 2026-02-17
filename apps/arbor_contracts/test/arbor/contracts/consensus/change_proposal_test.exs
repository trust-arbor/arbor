defmodule Arbor.Contracts.Consensus.ChangeProposalTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.ChangeProposal

  @valid_hot_load %{
    module: MyApp.Worker,
    change_type: :hot_load,
    source_code: "defmodule MyApp.Worker do end",
    rationale: "Fix process leak",
    evidence: ["anomaly_123"],
    rollback_plan: "Reload previous version",
    estimated_impact: :medium
  }

  @valid_config_change %{
    module: MyApp.Config,
    change_type: :config_change,
    config_changes: %{pool_size: 20},
    rationale: "Scale up pool",
    rollback_plan: "Revert pool_size to 10",
    estimated_impact: :low
  }

  @valid_restart %{
    module: MyApp.Server,
    change_type: :restart,
    rationale: "Unresponsive process",
    rollback_plan: "Monitor after restart",
    estimated_impact: :high
  }

  describe "new/1" do
    test "creates hot_load change proposal" do
      assert {:ok, %ChangeProposal{} = cp} = ChangeProposal.new(@valid_hot_load)
      assert cp.module == MyApp.Worker
      assert cp.change_type == :hot_load
      assert cp.source_code == "defmodule MyApp.Worker do end"
      assert String.starts_with?(cp.id, "chg_")
    end

    test "creates config_change proposal" do
      assert {:ok, %ChangeProposal{} = cp} = ChangeProposal.new(@valid_config_change)
      assert cp.change_type == :config_change
      assert cp.config_changes == %{pool_size: 20}
    end

    test "creates restart proposal" do
      assert {:ok, %ChangeProposal{}} = ChangeProposal.new(@valid_restart)
    end

    test "errors on missing module" do
      attrs = Map.delete(@valid_hot_load, :module)
      assert {:error, {:missing_required_field, :module}} = ChangeProposal.new(attrs)
    end

    test "errors on missing change_type" do
      attrs = Map.delete(@valid_hot_load, :change_type)
      assert {:error, {:missing_required_field, :change_type}} = ChangeProposal.new(attrs)
    end

    test "errors on hot_load without source_code" do
      attrs = Map.delete(@valid_hot_load, :source_code)
      assert {:error, {:validation_error, _}} = ChangeProposal.new(attrs)
    end

    test "errors on config_change without config_changes" do
      attrs = Map.delete(@valid_config_change, :config_changes)
      assert {:error, {:validation_error, _}} = ChangeProposal.new(attrs)
    end

    test "errors on invalid change_type" do
      attrs = %{@valid_restart | change_type: :invalid}
      assert {:error, {:validation_error, _}} = ChangeProposal.new(attrs)
    end
  end

  describe "valid?/1" do
    test "hot_load with source_code is valid" do
      {:ok, cp} = ChangeProposal.new(@valid_hot_load)
      assert ChangeProposal.valid?(cp) == true
    end

    test "config_change with non-empty config is valid" do
      {:ok, cp} = ChangeProposal.new(@valid_config_change)
      assert ChangeProposal.valid?(cp) == true
    end

    test "restart is always valid" do
      {:ok, cp} = ChangeProposal.new(@valid_restart)
      assert ChangeProposal.valid?(cp) == true
    end

    test "hot_load with blank source_code is invalid" do
      {:ok, cp} = ChangeProposal.new(@valid_hot_load)
      cp = %{cp | source_code: "   "}
      assert ChangeProposal.valid?(cp) == false
    end

    test "blank rollback_plan is invalid" do
      {:ok, cp} = ChangeProposal.new(@valid_hot_load)
      cp = %{cp | rollback_plan: "   "}
      assert ChangeProposal.valid?(cp) == false
    end
  end

  describe "to_context/1" do
    test "produces context map for Proposal" do
      {:ok, cp} = ChangeProposal.new(@valid_hot_load)
      ctx = ChangeProposal.to_context(cp)

      assert ctx.change_proposal == cp
      assert ctx.target_module == MyApp.Worker
      assert ctx.new_code == "defmodule MyApp.Worker do end"
      assert ctx.change_type == :hot_load
      assert ctx.rationale == "Fix process leak"
      assert ctx.evidence == ["anomaly_123"]
      assert ctx.rollback_plan == "Reload previous version"
      assert ctx.estimated_impact == :medium
    end
  end
end
