defmodule Arbor.Actions.CliAgentTest do
  use ExUnit.Case, async: true

  alias Arbor.Actions.CliAgent.Execute
  alias Arbor.Actions.CliAgent.Adapters
  alias Arbor.Actions.CliAgent.Adapters.Claude

  @moduletag :fast

  describe "Execute metadata" do
    test "action has correct name" do
      assert Execute.name() == "cli_agent_execute"
    end

    test "action has correct category" do
      assert Execute.category() == "cli_agent"
    end

    test "action has expected tags" do
      tags = Execute.tags()
      assert "cli" in tags
      assert "agent" in tags
      assert "llm" in tags
    end

    test "schema requires agent" do
      schema = Execute.schema()
      agent_schema = Keyword.get(schema, :agent)
      assert agent_schema[:required] == true
      assert agent_schema[:type] == :string
    end

    test "schema requires prompt" do
      schema = Execute.schema()
      prompt_schema = Keyword.get(schema, :prompt)
      assert prompt_schema[:required] == true
      assert prompt_schema[:type] == :string
    end

    test "timeout defaults to 300_000" do
      schema = Execute.schema()
      timeout_schema = Keyword.get(schema, :timeout)
      assert timeout_schema[:default] == 300_000
    end

    test "max_thinking_tokens defaults to 10_000" do
      schema = Execute.schema()
      mtt_schema = Keyword.get(schema, :max_thinking_tokens)
      assert mtt_schema[:default] == 10_000
    end
  end

  describe "Execute taint_roles/0" do
    test "agent is control" do
      roles = Execute.taint_roles()
      assert roles.agent == :control
    end

    test "prompt is control" do
      roles = Execute.taint_roles()
      assert roles.prompt == :control
    end

    test "model is control" do
      roles = Execute.taint_roles()
      assert roles.model == :control
    end

    test "system_prompt is control" do
      roles = Execute.taint_roles()
      assert roles.system_prompt == :control
    end

    test "working_dir is control" do
      roles = Execute.taint_roles()
      assert roles.working_dir == :control
    end

    test "timeout is data" do
      roles = Execute.taint_roles()
      assert roles.timeout == :data
    end

    test "allowed_tools is control" do
      roles = Execute.taint_roles()
      assert roles.allowed_tools == :control
    end

    test "session_id is control" do
      roles = Execute.taint_roles()
      assert roles.session_id == :control
    end
  end

  describe "Execute to_tool/0" do
    test "generates LLM tool schema" do
      tool = Execute.to_tool()
      assert is_map(tool)
      assert tool[:name] == "cli_agent_execute"
      assert is_binary(tool[:description])
    end
  end

  describe "Adapters.resolve/1" do
    test "resolves claude adapter" do
      assert {:ok, Claude} = Adapters.resolve("claude")
    end

    test "returns error for unsupported agent" do
      assert {:error, {:unsupported_agent, "unknown"}} = Adapters.resolve("unknown")
    end

    test "list_agents includes claude" do
      assert "claude" in Adapters.list_agents()
    end
  end

  describe "Execute.run/2 with unsupported agent" do
    test "returns error for unsupported agent" do
      result = Execute.run(%{agent: "nonexistent", prompt: "hello"}, %{})
      assert {:error, {:unsupported_agent, "nonexistent"}} = result
    end
  end

  describe "Claude.build_args/2" do
    test "minimal args include prompt, output format, and thinking tokens" do
      args = Claude.build_args(%{prompt: "hello"}, [])
      assert "-p" in args
      assert "hello" in args
      assert "--output-format" in args
      assert "json" in args
      assert "--max-thinking-tokens" in args
      assert "10000" in args
    end

    test "includes model flag when specified" do
      args = Claude.build_args(%{prompt: "hello", model: "opus"}, [])
      assert "--model" in args
      assert "opus" in args
    end

    test "omits model flag when nil" do
      args = Claude.build_args(%{prompt: "hello"}, [])
      refute "--model" in args
    end

    test "includes system prompt when specified" do
      args = Claude.build_args(%{prompt: "hello", system_prompt: "be concise"}, [])
      assert "--system-prompt" in args
      assert "be concise" in args
    end

    test "omits system prompt when empty string" do
      args = Claude.build_args(%{prompt: "hello", system_prompt: ""}, [])
      refute "--system-prompt" in args
    end

    test "includes resume flag for session_id" do
      args = Claude.build_args(%{prompt: "hello", session_id: "abc123"}, [])
      assert "--resume" in args
      assert "abc123" in args
    end

    test "omits resume flag when session_id is nil" do
      args = Claude.build_args(%{prompt: "hello"}, [])
      refute "--resume" in args
    end

    test "appends tool flags" do
      args = Claude.build_args(%{prompt: "hello"}, ["--allowedTools", "Read,Glob"])
      assert "--allowedTools" in args
      assert "Read,Glob" in args
    end

    test "custom thinking tokens" do
      args = Claude.build_args(%{prompt: "hello", max_thinking_tokens: 5000}, [])
      assert "5000" in args
    end

    test "never includes --dangerously-skip-permissions" do
      args = Claude.build_args(%{prompt: "hello"}, [])
      refute "--dangerously-skip-permissions" in args
    end
  end

  describe "Claude.parse_result/2" do
    test "parses standard JSON result" do
      json =
        Jason.encode!(%{
          "type" => "result",
          "result" => "Hello world",
          "session_id" => "sess_123",
          "is_error" => false,
          "duration_ms" => 1500,
          "total_cost_usd" => 0.003,
          "usage" => %{"input_tokens" => 100, "output_tokens" => 50}
        })

      result = Claude.parse_result(json, %{})
      assert result.text == "Hello world"
      assert result.session_id == "sess_123"
      assert result.input_tokens == 100
      assert result.output_tokens == 50
      assert result.cost_usd == 0.003
      assert result.is_error == false
      assert result.duration_ms == 1500
    end

    test "parses result with modelUsage" do
      json =
        Jason.encode!(%{
          "type" => "result",
          "result" => "Done",
          "session_id" => "sess_456",
          "modelUsage" => %{
            "claude-sonnet-4-5-20250929" => %{
              "inputTokens" => 200,
              "outputTokens" => 80
            }
          }
        })

      result = Claude.parse_result(json, %{})
      assert result.text == "Done"
      assert result.model == "claude-sonnet-4-5-20250929"
      assert result.input_tokens == 200
      assert result.output_tokens == 80
    end

    test "handles error result" do
      json =
        Jason.encode!(%{
          "type" => "result",
          "result" => "Something went wrong",
          "is_error" => true,
          "session_id" => "sess_err"
        })

      result = Claude.parse_result(json, %{})
      assert result.is_error == true
      assert result.text == "Something went wrong"
    end

    test "handles non-standard JSON" do
      json = Jason.encode!(%{"text" => "Fallback response"})
      result = Claude.parse_result(json, %{})
      assert result.text == "Fallback response"
    end

    test "handles plain text (non-JSON)" do
      result = Claude.parse_result("Just plain text\nwith newlines", %{})
      assert result.text == "Just plain text\nwith newlines"
      assert result.session_id == nil
    end

    test "handles JSON with extra output before it" do
      output =
        "Some debug output\nAnother line\n" <>
          Jason.encode!(%{
            "type" => "result",
            "result" => "The actual response",
            "session_id" => "sess_mixed"
          })

      result = Claude.parse_result(output, %{})
      assert result.text == "The actual response"
      assert result.session_id == "sess_mixed"
    end

    test "empty result field defaults to empty string" do
      json = Jason.encode!(%{"type" => "result"})
      result = Claude.parse_result(json, %{})
      assert result.text == ""
    end
  end

  describe "Execute.run/2 without claude binary" do
    test "returns error when claude is not found" do
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")
        result = Execute.run(%{agent: "claude", prompt: "test"}, %{})
        assert {:error, _} = result
      after
        if original_path, do: System.put_env("PATH", original_path)
      end
    end
  end

  # Integration tests requiring the actual claude binary
  describe "Execute.run/2 integration" do
    @describetag :external

    test "executes a simple prompt" do
      result =
        Execute.run(
          %{agent: "claude", prompt: "What is 2+2? Reply with ONLY the number."},
          %{}
        )

      case result do
        {:ok, %{text: text}} ->
          assert String.contains?(text, "4")

        {:error, :agent_not_found} ->
          :ok
      end
    end

    test "respects working_dir" do
      result =
        Execute.run(
          %{
            agent: "claude",
            prompt: "Run `pwd` and reply with ONLY the path.",
            working_dir: System.tmp_dir!()
          },
          %{}
        )

      case result do
        {:ok, %{text: text}} ->
          assert String.contains?(text, "tmp") or String.contains?(text, "temp")

        {:error, :agent_not_found} ->
          :ok
      end
    end

    test "passes allowed_tools as explicit override" do
      result =
        Execute.run(
          %{
            agent: "claude",
            prompt: "Say hello",
            allowed_tools: ["Read", "Glob"]
          },
          %{}
        )

      case result do
        {:ok, %{text: _text, session_id: session_id}} ->
          assert is_binary(session_id)

        {:error, :agent_not_found} ->
          :ok
      end
    end

    test "result includes agent field" do
      result =
        Execute.run(
          %{agent: "claude", prompt: "Say hi"},
          %{}
        )

      case result do
        {:ok, %{agent: agent}} ->
          assert agent == "claude"

        {:error, :agent_not_found} ->
          :ok
      end
    end
  end
end
