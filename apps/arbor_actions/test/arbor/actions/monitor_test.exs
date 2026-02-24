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

  describe "Monitor.Read returns data or unavailable" do
    # Monitor may or may not be running depending on test context.
    # Both {:ok, _} and {:error, :monitor_unavailable} are valid.

    test "status query returns ok or unavailable" do
      result = Monitor.Read.run(%{query: "status"}, %{})
      assert match?({:ok, %{query: "status"}}, result) or result == {:error, :monitor_unavailable}
    end

    test "all query types return ok or unavailable" do
      queries = ["status", "anomalies", "metrics", "skills", "healing_status", "collect"]

      for query <- queries do
        result = Monitor.Read.run(%{query: query}, %{})

        assert match?({:ok, %{query: ^query}}, result) or
                 result == {:error, :monitor_unavailable},
               "Expected {:ok, _} or :monitor_unavailable for query #{query}, got: #{inspect(result)}"
      end
    end

    test "skill-specific metrics returns ok or unavailable" do
      result = Monitor.Read.run(%{query: "metrics", skill: "beam"}, %{})

      assert match?({:ok, %{query: "metrics", skill: "beam"}}, result) or
               result == {:error, :monitor_unavailable}
    end

    test "skill-specific collect returns ok or unavailable" do
      result = Monitor.Read.run(%{query: "collect", skill: "processes"}, %{})

      assert match?({:ok, %{query: "collect", skill: "processes"}}, result) or
               result == {:error, :monitor_unavailable}
    end
  end

  describe "Monitor.Read skill validation" do
    test "known skills are accepted atoms" do
      known = [:beam, :memory, :ets, :processes, :supervisor, :system]

      for skill <- known do
        skill_str = Atom.to_string(skill)
        result = Monitor.Read.run(%{query: "metrics", skill: skill_str}, %{})

        # Should succeed or be unavailable, but never :unknown_skill for known skills
        refute match?({:error, {:unknown_skill, _}}, result),
               "Known skill #{skill_str} was rejected as unknown"
      end
    end
  end
end
