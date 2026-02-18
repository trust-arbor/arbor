defmodule Arbor.Actions.MonitorTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.Monitor

  @moduletag :fast

  describe "Monitor.Read metadata" do
    test "has correct action name" do
      assert Monitor.Read.name() == "monitor_read"
    end

    test "has required schema fields" do
      schema = Monitor.Read.schema()
      assert Keyword.has_key?(schema, :query)
    end
  end

  describe "Monitor.Read when monitor unavailable" do
    test "returns error when Monitor.Server is not running" do
      # Monitor.Server won't be running in test env
      assert {:error, :monitor_unavailable} = Monitor.Read.run(%{query: "status"}, %{})
    end

    test "returns error for all query types" do
      queries = ["status", "anomalies", "metrics", "skills", "healing_status", "collect"]

      for query <- queries do
        assert {:error, :monitor_unavailable} = Monitor.Read.run(%{query: query}, %{}),
               "Expected :monitor_unavailable for query #{query}"
      end
    end

    test "returns error for skill-specific metrics" do
      assert {:error, :monitor_unavailable} =
               Monitor.Read.run(%{query: "metrics", skill: "beam"}, %{})
    end

    test "returns error for skill-specific collect" do
      assert {:error, :monitor_unavailable} =
               Monitor.Read.run(%{query: "collect", skill: "processes"}, %{})
    end
  end

  describe "Monitor.Read skill validation" do
    # These would still fail with :monitor_unavailable, but test the skill name
    # validation by checking it doesn't crash on invalid skills
    test "known skills are accepted atoms" do
      known = [:beam, :memory, :ets, :processes, :supervisor, :system]

      for skill <- known do
        skill_str = Atom.to_string(skill)
        # Should fail with :monitor_unavailable, not :unknown_skill
        assert {:error, :monitor_unavailable} =
                 Monitor.Read.run(%{query: "metrics", skill: skill_str}, %{})
      end
    end
  end
end
