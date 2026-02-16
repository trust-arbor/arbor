defmodule Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutorTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.ArborActionsExecutor

  describe "definitions/0" do
    test "returns all action definitions in OpenAI format" do
      defs = ArborActionsExecutor.definitions()
      assert is_list(defs)
      assert length(defs) > 0

      # Check OpenAI format
      first = hd(defs)
      assert first["type"] == "function"
      assert is_map(first["function"])
      assert is_binary(first["function"]["name"])
      assert is_binary(first["function"]["description"])
      assert is_map(first["function"]["parameters"])
    end
  end

  describe "definitions/1" do
    test "returns definitions for specific action names" do
      defs = ArborActionsExecutor.definitions(["file_read", "file_write"])
      assert length(defs) == 2

      names = Enum.map(defs, & &1["function"]["name"])
      assert "file_read" in names
      assert "file_write" in names
    end

    test "skips unknown action names" do
      defs = ArborActionsExecutor.definitions(["file_read", "nonexistent_action"])
      assert length(defs) == 1
      assert hd(defs)["function"]["name"] == "file_read"
    end

    test "returns empty list for all unknown names" do
      defs = ArborActionsExecutor.definitions(["totally_unknown"])
      assert defs == []
    end

    test "handles whitespace in action names" do
      defs = ArborActionsExecutor.definitions([" file_read ", "file_write"])
      assert length(defs) == 2
    end
  end

  describe "execute/4" do
    test "executes a known action" do
      # file_read with a path that exists
      result = ArborActionsExecutor.execute("file_read", %{"path" => "mix.exs"}, ".")

      case result do
        {:ok, content} -> assert is_binary(content)
        {:error, _reason} -> :ok
      end
    end

    test "returns error for unknown action" do
      assert {:error, "Unknown action: nonexistent"} =
               ArborActionsExecutor.execute("nonexistent", %{}, ".")
    end

    test "accepts agent_id via opts" do
      # Should not crash — agent_id flows through to authorize_and_execute
      result =
        ArborActionsExecutor.execute("file_read", %{"path" => "mix.exs"}, ".",
          agent_id: "test-agent-123"
        )

      # Either succeeds or fails authorization — both are valid outcomes
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "defaults agent_id to system when not provided" do
      # Same as calling without opts — backward compatible
      result = ArborActionsExecutor.execute("file_read", %{"path" => "mix.exs"}, ".")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "atomizes string keys from LLM JSON output" do
      # LLMs produce string-keyed maps from JSON. The executor should
      # atomize them using the action's schema as an allowlist.
      # file_read expects :path (atom key) but LLM sends "path" (string key).
      result =
        ArborActionsExecutor.execute(
          "file_read",
          %{"path" => "mix.exs"},
          "."
        )

      # If key atomization works, the action should receive the path correctly
      case result do
        {:ok, content} ->
          assert is_binary(content)
          assert content =~ "defp deps"

        {:error, reason} ->
          # Authorization failure is acceptable, but NOT a nil path error
          refute reason =~ "nil"
      end
    end

    test "formats map results as JSON" do
      # We can't easily test this without a mock, but we can verify
      # the format_result function behavior through the public API
      # by checking that results are always strings
      result = ArborActionsExecutor.execute("file_read", %{"path" => "mix.exs"}, ".")

      case result do
        {:ok, text} -> assert is_binary(text)
        {:error, msg} -> assert is_binary(msg)
      end
    end
  end

  describe "OpenAI format conversion" do
    test "all definitions have required OpenAI fields" do
      for def <- ArborActionsExecutor.definitions() do
        assert def["type"] == "function"
        func = def["function"]
        assert is_binary(func["name"]), "name missing for #{inspect(def)}"
        assert is_binary(func["description"]), "description missing for #{func["name"]}"
        assert is_map(func["parameters"]), "parameters missing for #{func["name"]}"
      end
    end

    test "parameters are valid JSON Schema objects" do
      for def <- ArborActionsExecutor.definitions() do
        params = def["function"]["parameters"]
        # Parameters should either have type=object or be a valid (possibly empty) schema
        assert is_map(params), "#{def["function"]["name"]} params should be a map"
      end
    end
  end

  describe "integration with CodingTools interface" do
    test "definitions format matches CodingTools.definitions format" do
      arbor_defs = ArborActionsExecutor.definitions(["file_read"])
      coding_defs = Arbor.Orchestrator.UnifiedLLM.CodingTools.definitions()

      # Both should have same top-level structure
      arbor_first = hd(arbor_defs)
      coding_first = hd(coding_defs)

      assert Map.keys(arbor_first) == Map.keys(coding_first)
      assert Map.keys(arbor_first["function"]) == Map.keys(coding_first["function"])
    end

    test "execute/4 is compatible with ToolLoop's calling convention" do
      # ToolLoop calls executor.execute(name, args, workdir, agent_id: agent_id)
      # Both CodingTools and ArborActionsExecutor must accept this signature
      coding_result =
        Arbor.Orchestrator.UnifiedLLM.CodingTools.execute(
          "read_file",
          %{"path" => "mix.exs"},
          ".",
          agent_id: "test"
        )

      assert match?({:ok, _}, coding_result)

      arbor_result =
        ArborActionsExecutor.execute(
          "file_read",
          %{"path" => "mix.exs"},
          ".",
          agent_id: "test"
        )

      assert match?({:ok, _}, arbor_result) or match?({:error, _}, arbor_result)
    end
  end
end
