defmodule Arbor.Consensus.TopicRegistryTest do
  use ExUnit.Case, async: true

  alias Arbor.Consensus.{TopicRegistry, TopicRule}

  setup do
    # Use unique table and registry names for test isolation
    suffix = System.unique_integer([:positive])
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    table_name = :"test_topic_registry_#{suffix}"
    # credo:disable-for-next-line Credo.Check.Security.UnsafeAtomConversion
    registry_name = :"test_registry_#{suffix}"

    {:ok, pid} =
      TopicRegistry.start_link(
        name: registry_name,
        table_name: table_name,
        # Skip checkpointing in tests
        checkpoint_id: nil,
        checkpoint_store: nil
      )

    %{registry: registry_name, table: table_name, pid: pid}
  end

  describe "bootstrap topics" do
    test "topic_governance is present on start", %{table: table} do
      assert [{:topic_governance, rule}] = :ets.lookup(table, :topic_governance)
      assert rule.topic == :topic_governance
      assert rule.is_bootstrap == true
      assert rule.min_quorum == :supermajority
      assert rule.allowed_modes == [:decision]
    end

    test "general is present on start", %{table: table} do
      assert [{:general, rule}] = :ets.lookup(table, :general)
      assert rule.topic == :general
      assert rule.is_bootstrap == true
      assert rule.min_quorum == :majority
      assert rule.allowed_modes == [:decision, :advisory]
    end

    test "bootstrap_topics/0 returns the bootstrap topic map" do
      topics = TopicRegistry.bootstrap_topics()
      assert Map.has_key?(topics, :topic_governance)
      assert Map.has_key?(topics, :general)
    end
  end

  describe "get/2" do
    test "returns {:ok, rule} for existing topic", %{table: table} do
      assert {:ok, rule} = TopicRegistry.get(:general, table)
      assert rule.topic == :general
    end

    test "returns {:error, :not_found} for non-existent topic", %{table: table} do
      assert {:error, :not_found} = TopicRegistry.get(:non_existent_topic, table)
    end
  end

  describe "list/1" do
    test "returns all registered topics", %{table: table} do
      rules = TopicRegistry.list(table)
      topics = Enum.map(rules, & &1.topic)
      assert :topic_governance in topics
      assert :general in topics
      assert length(rules) >= 2
    end
  end

  describe "exists?/2" do
    test "returns true for existing topic", %{table: table} do
      assert TopicRegistry.exists?(:general, table) == true
      assert TopicRegistry.exists?(:topic_governance, table) == true
    end

    test "returns false for non-existent topic", %{table: table} do
      assert TopicRegistry.exists?(:non_existent, table) == false
    end
  end

  describe "register_topic/2" do
    test "registers a new topic", %{registry: registry, table: table} do
      rule =
        TopicRule.new(
          topic: :security_audit,
          min_quorum: :supermajority,
          match_patterns: ["security", "audit"],
          registered_by: "admin_agent"
        )

      assert {:ok, registered} = TopicRegistry.register_topic(rule, registry)
      assert registered.topic == :security_audit
      assert registered.min_quorum == :supermajority
      assert TopicRegistry.exists?(:security_audit, table)
    end

    test "accepts keyword list", %{registry: registry} do
      attrs = [
        topic: :code_review,
        min_quorum: :majority,
        match_patterns: ["review", "code"]
      ]

      assert {:ok, registered} = TopicRegistry.register_topic(attrs, registry)
      assert registered.topic == :code_review
    end

    test "accepts map", %{registry: registry} do
      attrs = %{
        topic: :deployment,
        min_quorum: :unanimous,
        allowed_modes: [:decision]
      }

      assert {:ok, registered} = TopicRegistry.register_topic(attrs, registry)
      assert registered.topic == :deployment
    end

    test "rejects duplicate topic", %{registry: registry} do
      rule = TopicRule.new(topic: :test_topic)
      {:ok, _} = TopicRegistry.register_topic(rule, registry)

      assert {:error, :already_exists} = TopicRegistry.register_topic(rule, registry)
    end

    test "rejects registering bootstrap topic", %{registry: registry} do
      rule = %TopicRule{topic: :custom_bootstrap, is_bootstrap: true}
      assert {:error, :cannot_register_bootstrap} = TopicRegistry.register_topic(rule, registry)
    end
  end

  describe "update_topic/3" do
    test "updates an existing topic", %{registry: registry} do
      rule = TopicRule.new(topic: :updatable_topic, min_quorum: :majority)
      {:ok, _} = TopicRegistry.register_topic(rule, registry)

      assert {:ok, updated} =
               TopicRegistry.update_topic(
                 :updatable_topic,
                 %{min_quorum: :supermajority},
                 registry
               )

      assert updated.min_quorum == :supermajority
    end

    test "returns error for non-existent topic", %{registry: registry} do
      assert {:error, :not_found} =
               TopicRegistry.update_topic(:non_existent, %{min_quorum: :majority}, registry)
    end

    test "allows updating bootstrap topic fields except is_bootstrap", %{registry: registry} do
      # Can update match_patterns
      assert {:ok, updated} =
               TopicRegistry.update_topic(:general, %{match_patterns: ["fallback"]}, registry)

      assert updated.match_patterns == ["fallback"]
      assert updated.is_bootstrap == true
    end

    test "rejects modifying is_bootstrap flag", %{registry: registry} do
      assert {:error, :cannot_modify_bootstrap_status} =
               TopicRegistry.update_topic(:general, %{is_bootstrap: false}, registry)
    end
  end

  describe "retire_topic/2" do
    test "retires a non-bootstrap topic", %{registry: registry, table: table} do
      rule = TopicRule.new(topic: :retirable_topic)
      {:ok, _} = TopicRegistry.register_topic(rule, registry)

      assert :ok = TopicRegistry.retire_topic(:retirable_topic, registry)

      # Topic still exists but has empty allowed_modes
      {:ok, retired} = TopicRegistry.get(:retirable_topic, table)
      assert retired.allowed_modes == []
    end

    test "returns error for non-existent topic", %{registry: registry} do
      assert {:error, :not_found} = TopicRegistry.retire_topic(:non_existent, registry)
    end

    test "cannot retire bootstrap topics", %{registry: registry} do
      assert {:error, :cannot_retire_bootstrap} = TopicRegistry.retire_topic(:general, registry)

      assert {:error, :cannot_retire_bootstrap} =
               TopicRegistry.retire_topic(:topic_governance, registry)
    end
  end

  describe "concurrent reads" do
    test "multiple processes can read simultaneously", %{table: table} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Process.sleep(:rand.uniform(10))
            {:ok, rule} = TopicRegistry.get(:general, table)
            assert rule.topic == :general
            i
          end)
        end

      results = Task.await_many(tasks, 5_000)
      assert length(results) == 10
    end
  end

  describe "TopicRule helpers" do
    test "proposer_allowed?/2 with :any" do
      rule = TopicRule.new(topic: :test, allowed_proposers: :any)
      assert TopicRule.proposer_allowed?(rule, :any_agent)
      assert TopicRule.proposer_allowed?(rule, "any_agent_string")
    end

    test "proposer_allowed?/2 with specific list" do
      rule = TopicRule.new(topic: :test, allowed_proposers: [:admin, :security_team])
      assert TopicRule.proposer_allowed?(rule, :admin)
      assert TopicRule.proposer_allowed?(rule, :security_team)
      refute TopicRule.proposer_allowed?(rule, :random_agent)
    end

    test "mode_allowed?/2" do
      decision_only = TopicRule.new(topic: :test, allowed_modes: [:decision])
      advisory_only = TopicRule.new(topic: :test, allowed_modes: [:advisory])
      both = TopicRule.new(topic: :test, allowed_modes: [:decision, :advisory])

      assert TopicRule.mode_allowed?(decision_only, :decision)
      refute TopicRule.mode_allowed?(decision_only, :advisory)

      refute TopicRule.mode_allowed?(advisory_only, :decision)
      assert TopicRule.mode_allowed?(advisory_only, :advisory)

      assert TopicRule.mode_allowed?(both, :decision)
      assert TopicRule.mode_allowed?(both, :advisory)
    end

    test "quorum_to_number/2" do
      assert TopicRule.quorum_to_number(5, 7) == 5
      assert TopicRule.quorum_to_number(:majority, 7) == 4
      assert TopicRule.quorum_to_number(:supermajority, 7) == 5
      assert TopicRule.quorum_to_number(:unanimous, 7) == 7
    end
  end
end
