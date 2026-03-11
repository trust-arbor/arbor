defmodule Arbor.Memory.ReflectionProcessorRelationshipsTest do
  use ExUnit.Case, async: false

  alias Arbor.Memory.{ReflectionProcessor, Relationship}

  @moduletag :database

  setup do
    agent_id = "test_agent_#{:rand.uniform(100_000)}"
    {:ok, agent_id: agent_id}
  end

  describe "process_relationships/2" do
    test "creates new relationship", %{agent_id: agent_id} do
      ReflectionProcessor.process_relationships(agent_id, [
        %{
          "name" => "TestPerson",
          "dynamic" => "Collaborative partnership",
          "observation" => "Worked together on tests"
        }
      ])

      {:ok, rel} = Arbor.Memory.get_relationship_by_name(agent_id, "TestPerson")
      assert rel.name == "TestPerson"
    end

    test "updates existing relationship", %{agent_id: agent_id} do
      rel = Relationship.new("ExistingPerson")
      {:ok, _} = Arbor.Memory.save_relationship(agent_id, rel)

      ReflectionProcessor.process_relationships(agent_id, [
        %{
          "name" => "ExistingPerson",
          "dynamic" => "Updated dynamic",
          "observation" => "New observation"
        }
      ])

      {:ok, updated} = Arbor.Memory.get_relationship_by_name(agent_id, "ExistingPerson")
      assert updated.name == "ExistingPerson"
    end
  end
end
