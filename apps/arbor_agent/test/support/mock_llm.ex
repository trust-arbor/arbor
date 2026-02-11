defmodule Arbor.Test.MockLLM do
  @moduledoc """
  Deterministic mock LLM provider for behavioral tests.

  Configurable per-test responses based on prompt patterns.
  Tracks call history for verification. Process-dict based
  for test isolation (each test process has its own mock state).

  ## Usage

      # In test setup
      MockLLM.configure(%{
        default: ~s({"thoughts": "test thinking", "observations": []}),
        patterns: [
          {~r/heartbeat/i, heartbeat_json()},
          {~r/evaluate/i, evaluation_json()}
        ]
      })

      # The mock is injected via application config
      # Arbor.AI.generate_text/2 routes to MockLLM when configured

      # After test, verify calls
      assert MockLLM.call_count() == 2
      assert MockLLM.last_prompt() =~ "heartbeat"
  """

  @doc """
  Configure the mock for the current test process.
  """
  def configure(config \\ %{}) do
    Process.put(:mock_llm_config, config)
    Process.put(:mock_llm_calls, [])
    :ok
  end

  @doc """
  Generate a mock response based on configured patterns.
  Called by test infrastructure in place of real LLM calls.
  """
  def generate(prompt, opts \\ []) do
    config = Process.get(:mock_llm_config, %{})
    calls = Process.get(:mock_llm_calls, [])
    Process.put(:mock_llm_calls, [{prompt, opts} | calls])

    # Check if a specific error is configured
    case Map.get(config, :error) do
      nil -> find_response(prompt, config)
      error -> {:error, error}
    end
  end

  @doc """
  Generate a mock response for tool-use conversations.
  Returns a response that may include tool_use blocks.
  """
  def generate_with_tools(prompt, tools, opts \\ []) do
    config = Process.get(:mock_llm_config, %{})
    calls = Process.get(:mock_llm_calls, [])
    Process.put(:mock_llm_calls, [{prompt, Keyword.put(opts, :tools, tools)} | calls])

    case Map.get(config, :tool_response) do
      nil -> find_response(prompt, config)
      response -> {:ok, response}
    end
  end

  @doc "Get the number of calls made to the mock."
  def call_count do
    Process.get(:mock_llm_calls, []) |> length()
  end

  @doc "Get the most recent prompt sent to the mock."
  def last_prompt do
    case Process.get(:mock_llm_calls, []) do
      [{prompt, _opts} | _] -> prompt
      [] -> nil
    end
  end

  @doc "Get the full call history (most recent first)."
  def calls do
    Process.get(:mock_llm_calls, [])
  end

  @doc "Reset the mock state for the current test process."
  def reset do
    Process.put(:mock_llm_calls, [])
    Process.put(:mock_llm_config, %{})
    :ok
  end

  # -- Preset Responses --

  @doc "Standard heartbeat response with basic observations."
  def heartbeat_response(opts \\ []) do
    mode = Keyword.get(opts, :cognitive_mode, "reflection")
    goals = Keyword.get(opts, :new_goals, [])
    thoughts = Keyword.get(opts, :thoughts, "Mock heartbeat thinking")

    Jason.encode!(%{
      "thoughts" => thoughts,
      "cognitive_mode" => mode,
      "observations" => ["Test observation from mock"],
      "new_goals" => goals,
      "goal_updates" => [],
      "decompositions" => [],
      "memory_notes" => [],
      "proposals" => [],
      "actions" => []
    })
  end

  @doc "Standard advisory evaluation response."
  def evaluation_response(opts \\ []) do
    vote = Keyword.get(opts, :vote, "approve")
    confidence = Keyword.get(opts, :confidence, 0.8)

    Jason.encode!(%{
      "analysis" => "Mock evaluation analysis",
      "considerations" => ["Test consideration"],
      "alternatives" => [],
      "recommendation" => "Mock recommendation",
      "vote" => vote,
      "confidence" => confidence
    })
  end

  # -- Internal --

  defp find_response(prompt, config) do
    patterns = Map.get(config, :patterns, [])

    case Enum.find(patterns, fn {regex, _response} -> Regex.match?(regex, prompt) end) do
      {_regex, response} -> {:ok, response}
      nil -> {:ok, Map.get(config, :default, "Mock LLM response")}
    end
  end
end
