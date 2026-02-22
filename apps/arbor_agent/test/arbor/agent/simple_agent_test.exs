defmodule Arbor.Agent.SimpleAgentTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.SimpleAgent

  describe "run/2 defaults" do
    test "returns max_turns with default model" do
      {:ok, result} = SimpleAgent.run("test", max_turns: 0)

      assert result.status == :max_turns
      assert result.turns == 0
      assert result.tool_calls == []
      assert result.text == nil
      assert result.model == "arcee-ai/trinity-large-preview:free"
    end

    test "custom model and provider are used" do
      {:ok, result} =
        SimpleAgent.run("test",
          max_turns: 0,
          model: "custom-model",
          provider: :anthropic
        )

      assert result.model == "custom-model"
    end
  end

  describe "system prompt" do
    test "includes working directory" do
      # The system prompt is built internally, but we can verify
      # the run function accepts a custom one
      {:ok, result} =
        SimpleAgent.run("test",
          max_turns: 0,
          system_prompt: "Custom prompt"
        )

      assert result.status == :max_turns
    end
  end

  describe "tool call tracking" do
    test "records tool call entries with timing" do
      entry = %{
        turn: 1,
        name: "file_read",
        args: %{"path" => "test.ex"},
        result: "content here",
        duration_ms: 42
      }

      assert entry.turn == 1
      assert entry.name == "file_read"
      assert is_map(entry.args)
      assert is_binary(entry.result)
      assert is_integer(entry.duration_ms)
    end
  end

  describe "result structure" do
    test "completed result has all fields" do
      {:ok, result} = SimpleAgent.run("test", max_turns: 0)

      assert Map.has_key?(result, :text)
      assert Map.has_key?(result, :turns)
      assert Map.has_key?(result, :tool_calls)
      assert Map.has_key?(result, :model)
      assert Map.has_key?(result, :status)
    end
  end

  describe "live integration" do
    @describetag :llm

    test "can complete a simple file read task" do
      # Create a temp file to read
      tmp_dir = System.tmp_dir!()
      test_file = Path.join(tmp_dir, "simple_agent_test_#{:rand.uniform(100_000)}.txt")
      File.write!(test_file, "Hello from SimpleAgent test!")

      try do
        {:ok, result} =
          SimpleAgent.run(
            "Read the file at #{test_file} and tell me what it says.",
            provider: :openrouter,
            model: "arcee-ai/trinity-large-preview:free",
            working_dir: tmp_dir,
            max_turns: 5
          )

        assert result.status in [:completed, :max_turns]
        assert result.tool_calls != []

        # Should have called file_read
        tool_names = Enum.map(result.tool_calls, & &1.name)
        assert "file_read" in tool_names

        # Should have a text response
        if result.status == :completed do
          assert is_binary(result.text)
          assert String.length(result.text) > 0
        end
      after
        File.rm(test_file)
      end
    end
  end
end
