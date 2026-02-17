defmodule Arbor.Contracts.Consensus.ProposalTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Consensus.Proposal

  @valid_attrs %{
    proposer: "agent_1",
    topic: :code_modification,
    description: "Add caching layer",
    target_layer: 4
  }

  describe "new/1" do
    test "creates proposal with valid attributes" do
      assert {:ok, %Proposal{} = p} = Proposal.new(@valid_attrs)
      assert p.proposer == "agent_1"
      assert p.topic == :code_modification
      assert p.description == "Add caching layer"
      assert p.status == :pending
      assert p.mode == :decision
      assert String.starts_with?(p.id, "prop_")
    end

    test "auto-generates timestamps" do
      {:ok, p} = Proposal.new(@valid_attrs)
      assert %DateTime{} = p.created_at
      assert %DateTime{} = p.updated_at
      assert p.decided_at == nil
    end

    test "accepts custom id" do
      {:ok, p} = Proposal.new(Map.put(@valid_attrs, :id, "custom_id"))
      assert p.id == "custom_id"
    end

    test "accepts advisory mode" do
      {:ok, p} = Proposal.new(Map.put(@valid_attrs, :mode, :advisory))
      assert p.mode == :advisory
    end

    test "accepts context map" do
      ctx = %{code_diff: "- old\n+ new"}
      {:ok, p} = Proposal.new(Map.put(@valid_attrs, :context, ctx))
      assert p.context == ctx
    end

    test "backward compat: change_type maps to topic" do
      attrs = %{
        proposer: "agent_1",
        change_type: :capability_change,
        description: "Grant cap",
        target_layer: 3
      }

      {:ok, p} = Proposal.new(attrs)
      assert p.topic == :capability_change
    end

    test "backward compat: legacy fields migrate to context" do
      attrs =
        Map.merge(@valid_attrs, %{
          target_module: MyModule,
          code_diff: "diff here",
          new_code: "code here",
          configuration: %{key: :val}
        })

      {:ok, p} = Proposal.new(attrs)
      assert p.context[:target_module] == MyModule
      assert p.context[:code_diff] == "diff here"
      assert p.context[:new_code] == "code here"
      assert p.context[:configuration] == %{key: :val}
    end

    test "errors on missing proposer" do
      attrs = Map.delete(@valid_attrs, :proposer)
      assert {:error, {:missing_required_field, :proposer}} = Proposal.new(attrs)
    end

    test "errors on missing description" do
      attrs = Map.delete(@valid_attrs, :description)
      assert {:error, {:missing_required_field, :description}} = Proposal.new(attrs)
    end

    test "errors on missing topic and change_type" do
      attrs = Map.delete(@valid_attrs, :topic)
      assert {:error, {:missing_required_field, :change_type}} = Proposal.new(attrs)
    end

    test "infers layer from target_module in context" do
      attrs = %{
        proposer: "a",
        topic: :code_modification,
        description: "d",
        context: %{target_module: Arbor.Security.Kernel}
      }

      {:ok, p} = Proposal.new(attrs)
      # Security.Kernel matches layer 1
      assert p.target_layer == 1
    end

    test "defaults to layer 4 when no module" do
      attrs = %{proposer: "a", topic: :code_modification, description: "d"}
      {:ok, p} = Proposal.new(attrs)
      assert p.target_layer == 4
    end
  end

  describe "change_type/1" do
    test "returns the topic" do
      {:ok, p} = Proposal.new(@valid_attrs)
      assert Proposal.change_type(p) == :code_modification
    end
  end

  describe "update_status/2" do
    test "updates status and updated_at" do
      {:ok, p} = Proposal.new(@valid_attrs)
      updated = Proposal.update_status(p, :evaluating)
      assert updated.status == :evaluating
      assert DateTime.compare(updated.updated_at, p.updated_at) in [:gt, :eq]
    end

    test "sets decided_at for terminal statuses" do
      {:ok, p} = Proposal.new(@valid_attrs)

      for status <- [:approved, :rejected, :deadlock, :vetoed] do
        updated = Proposal.update_status(p, status)
        assert updated.decided_at != nil, "decided_at should be set for #{status}"
      end
    end

    test "does not set decided_at for non-terminal statuses" do
      {:ok, p} = Proposal.new(@valid_attrs)
      updated = Proposal.update_status(p, :evaluating)
      assert updated.decided_at == nil
    end
  end

  describe "meta_change?/1" do
    test "true for governance_change" do
      {:ok, p} = Proposal.new(%{@valid_attrs | topic: :governance_change})
      assert Proposal.meta_change?(p) == true
    end

    test "true for topic_governance" do
      {:ok, p} = Proposal.new(%{@valid_attrs | topic: :topic_governance})
      assert Proposal.meta_change?(p) == true
    end

    test "true for layer <= 1" do
      {:ok, p} = Proposal.new(%{@valid_attrs | target_layer: 1})
      assert Proposal.meta_change?(p) == true
    end

    test "false for standard changes" do
      {:ok, p} = Proposal.new(@valid_attrs)
      assert Proposal.meta_change?(p) == false
    end
  end

  describe "required_quorum/1" do
    test "returns 0 for advisory mode" do
      {:ok, p} = Proposal.new(Map.put(@valid_attrs, :mode, :advisory))
      assert Proposal.required_quorum(p) == 0
    end

    test "returns meta quorum for governance changes" do
      {:ok, p} = Proposal.new(%{@valid_attrs | topic: :governance_change})
      assert Proposal.required_quorum(p) == 6
    end

    test "returns standard quorum for normal changes" do
      {:ok, p} = Proposal.new(@valid_attrs)
      assert Proposal.required_quorum(p) == 5
    end
  end

  describe "violates_invariants?/1" do
    test "no violations for clean proposal" do
      {:ok, p} = Proposal.new(@valid_attrs)
      assert {false, []} = Proposal.violates_invariants?(p)
    end

    test "detects quorum violation in new_code" do
      {:ok, p} =
        Proposal.new(
          Map.put(@valid_attrs, :context, %{new_code: "quorum = 0"})
        )

      {violated, invariants} = Proposal.violates_invariants?(p)
      assert violated == true
      assert :consensus_requires_quorum in invariants
    end

    test "detects audit log violation" do
      {:ok, p} =
        Proposal.new(
          Map.put(@valid_attrs, :context, %{new_code: "delete_audit()"})
        )

      {violated, invariants} = Proposal.violates_invariants?(p)
      assert violated == true
      assert :audit_log_append_only in invariants
    end

    test "detects containment violation" do
      {:ok, p} =
        Proposal.new(
          Map.put(@valid_attrs, :context, %{new_code: "bypass_boundary()"})
        )

      {violated, invariants} = Proposal.violates_invariants?(p)
      assert violated == true
      assert :containment_boundary_exists in invariants
    end
  end
end
