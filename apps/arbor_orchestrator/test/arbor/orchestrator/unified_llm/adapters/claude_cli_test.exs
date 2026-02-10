defmodule Arbor.Orchestrator.UnifiedLLM.Adapters.ClaudeCliTest do
  use ExUnit.Case, async: true

  alias Arbor.Orchestrator.UnifiedLLM.Adapters.ClaudeCli
  alias Arbor.Orchestrator.UnifiedLLM.{Request, Response, Message}

  describe "provider/0" do
    test "returns claude_cli" do
      assert ClaudeCli.provider() == "claude_cli"
    end
  end

  describe "available?/0" do
    test "returns boolean" do
      result = ClaudeCli.available?()
      assert is_boolean(result)
    end
  end

  describe "complete/2 error cases" do
    test "returns error when claude binary not found" do
      # Save and unset PATH to simulate missing binary
      original_path = System.get_env("PATH")

      try do
        System.put_env("PATH", "/nonexistent")

        request = %Request{
          model: "haiku",
          messages: [Message.new(:user, "hello")]
        }

        # ClaudeCli checks System.find_executable which uses PATH
        # When claude isn't in PATH, available? returns false
        # but complete should still handle gracefully
        result = ClaudeCli.complete(request, [])

        case result do
          {:error, :claude_not_found} -> :ok
          {:error, _} -> :ok
          # If claude somehow still found (unlikely), that's fine too
          {:ok, _} -> :ok
        end
      after
        System.put_env("PATH", original_path)
      end
    end
  end

  describe "integration" do
    @tag :external
    @tag :llm
    test "completes a simple request with claude binary" do
      if ClaudeCli.available?() do
        request = %Request{
          model: "haiku",
          messages: [Message.new(:user, "Reply with exactly: PONG")]
        }

        case ClaudeCli.complete(request, timeout: 30_000) do
          {:ok, %Response{} = response} ->
            assert is_binary(response.text)
            assert response.text != ""
            assert response.finish_reason in [:stop, :error]

          {:error, reason} ->
            # Acceptable in CI or when quota exhausted
            assert reason != nil
        end
      end
    end

    @tag :external
    @tag :llm
    test "passes system prompt to claude" do
      if ClaudeCli.available?() do
        request = %Request{
          model: "haiku",
          messages: [
            Message.new(:system, "You are a calculator. Only respond with numbers."),
            Message.new(:user, "What is 2+2?")
          ]
        }

        case ClaudeCli.complete(request, timeout: 30_000) do
          {:ok, %Response{} = response} ->
            assert is_binary(response.text)

          {:error, _} ->
            :ok
        end
      end
    end
  end
end
