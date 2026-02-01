defmodule Arbor.Actions.ProposalTest do
  use Arbor.Actions.ActionCase, async: true

  alias Arbor.Actions.Proposal

  @moduletag :fast

  describe "Submit" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Proposal.Submit.validate_params(%{})
      assert {:error, _} = Proposal.Submit.validate_params(%{title: "Test"})

      assert {:error, _} =
               Proposal.Submit.validate_params(%{
                 title: "Test",
                 description: "A test"
               })

      # Test that schema accepts valid params
      assert {:ok, _} =
               Proposal.Submit.validate_params(%{
                 title: "Add caching",
                 description: "Implements Redis caching",
                 branch: "hand/agent_001/caching"
               })

      # Test with optional params
      assert {:ok, _} =
               Proposal.Submit.validate_params(%{
                 title: "Add caching",
                 description: "Implements Redis caching",
                 branch: "hand/agent_001/caching",
                 evidence: ["evt_123", "evt_124"],
                 urgency: "high",
                 change_type: "code_modification"
               })
    end

    test "schema rejects invalid urgency" do
      assert {:error, _} =
               Proposal.Submit.validate_params(%{
                 title: "Test",
                 description: "Test",
                 branch: "test",
                 urgency: "super_urgent"
               })
    end

    test "validates action metadata" do
      assert Proposal.Submit.name() == "proposal_submit"
      assert Proposal.Submit.category() == "proposal"
      assert "proposal" in Proposal.Submit.tags()
      assert "submit" in Proposal.Submit.tags()
    end

    test "generates tool schema" do
      tool = Proposal.Submit.to_tool()
      assert is_map(tool)
      assert tool[:name] == "proposal_submit"
      assert tool[:description] =~ "Submit"
    end
  end

  describe "Revise" do
    test "schema validates correctly" do
      # Test that schema rejects missing required fields
      assert {:error, _} = Proposal.Revise.validate_params(%{})

      assert {:error, _} =
               Proposal.Revise.validate_params(%{
                 proposal_id: "prop_123"
               })

      assert {:error, _} =
               Proposal.Revise.validate_params(%{
                 proposal_id: "prop_123",
                 notes: "Fixed issues"
               })

      # Test that schema accepts valid params
      assert {:ok, _} =
               Proposal.Revise.validate_params(%{
                 proposal_id: "prop_123",
                 notes: "Added tests and fixed edge cases",
                 branch: "hand/agent_001/caching"
               })
    end

    test "validates action metadata" do
      assert Proposal.Revise.name() == "proposal_revise"
      assert Proposal.Revise.category() == "proposal"
      assert "proposal" in Proposal.Revise.tags()
      assert "revise" in Proposal.Revise.tags()
    end

    test "generates tool schema" do
      tool = Proposal.Revise.to_tool()
      assert is_map(tool)
      assert tool[:name] == "proposal_revise"
      assert tool[:description] =~ "Resubmit"
    end
  end

  describe "module structure" do
    test "modules compile and are usable" do
      assert Code.ensure_loaded?(Proposal.Submit)
      assert Code.ensure_loaded?(Proposal.Revise)

      assert function_exported?(Proposal.Submit, :run, 2)
      assert function_exported?(Proposal.Revise, :run, 2)
    end
  end
end
