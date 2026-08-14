defmodule Arbor.Persistence.AgentTelemetryTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Persistence
  alias Arbor.Persistence.AgentTelemetry

  describe "facade delegates" do
    test "public facade matches the implementation when the repo is down" do
      assert Persistence.persist_event("agent_x", :turn_completed, %{input_tokens: 1}) ==
               AgentTelemetry.persist_event("agent_x", :turn_completed, %{input_tokens: 1})

      assert Persistence.load_lifetime("agent_x") == AgentTelemetry.load_lifetime("agent_x")

      assert Persistence.query_events("agent_x", []) ==
               AgentTelemetry.query_events("agent_x", [])
    end
  end

  describe "unavailable repository" do
    test "persist, load, and query stay non-fatal when Repo is not running" do
      if Process.whereis(Arbor.Persistence.Repo) do
        # A sibling :database module may have started Repo in this VM.
        assert AgentTelemetry.load_lifetime("agent_x") == nil or
                 is_map(AgentTelemetry.load_lifetime("agent_x"))
      else
        assert {:error, :repo_unavailable} =
                 AgentTelemetry.persist_event("agent_x", :tool_call, %{tool_name: "file.read"})

        assert AgentTelemetry.load_lifetime("agent_x") == nil
        assert {:error, :repo_unavailable} = AgentTelemetry.query_events("agent_x")
      end
    end
  end

  describe "query_events/2 adapter portability (regression)" do
    test "SQLite gets anonymous placeholders, not Postgres positional ones" do
      {clauses, params, _idx} =
        AgentTelemetry.build_query_conditions(:sqlite, "agent_x", event_type: :tool_call)

      sql = Enum.join(clauses, " AND ")

      refute sql =~ "$1", "SQLite cannot bind Postgres positional placeholders"
      refute sql =~ ~r/\$\d/
      assert sql == "agent_id = ? AND event_type = ?"
      assert params == ["agent_x", "tool_call"]
    end

    test "Postgres keeps positional placeholders, numbered in order" do
      {clauses, params, _idx} =
        AgentTelemetry.build_query_conditions(
          :postgres,
          "agent_x",
          event_type: :tool_call,
          since: ~U[2026-01-01 00:00:00Z]
        )

      assert Enum.join(clauses, " AND ") ==
               "agent_id = $1 AND event_type = $2 AND timestamp >= $3"

      assert length(params) == 3
    end

    test "an unknown adapter falls back to anonymous placeholders" do
      {clauses, _params, _idx} =
        AgentTelemetry.build_query_conditions(:unknown, "agent_x", [])

      assert clauses == ["agent_id = ?"]
    end
  end

  describe "lifetime_sql/1 adapter dialects (regression)" do
    test "Postgres keeps FILTER and JSON arrow operators" do
      {sql, params} = AgentTelemetry.lifetime_sql(:postgres)
      assert sql =~ "FILTER"
      assert sql =~ "->>"
      assert sql =~ "$1"
      refute sql =~ "json_extract"
      assert params == ["$1"]
    end

    test "SQLite uses json_extract and CASE, not Postgres JSON operators" do
      {sql, params} = AgentTelemetry.lifetime_sql(:sqlite)
      assert sql =~ "json_extract"
      assert sql =~ "CASE WHEN"
      assert sql =~ "?"
      refute sql =~ "->>"
      refute sql =~ "FILTER"
      assert params == ["?"]
    end
  end
end
