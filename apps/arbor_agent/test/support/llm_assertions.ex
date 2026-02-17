defmodule Arbor.Test.LLMAssertions do
  @moduledoc """
  Shared assertion helpers for behavioral tests involving LLM interactions.

  Provides assertions that verify the LLM response contract — the shape
  and content of responses that callers depend on. These assertions
  implicitly document what the response contract IS, which is exactly
  what the unified LLM migration is standardizing.

  ## Usage

      import Arbor.Test.LLMAssertions

      assert_valid_llm_response(result)
      assert_response_has_content(result)
      assert_response_has_usage(result)
  """

  import ExUnit.Assertions

  alias Arbor.Signals.Store, as: SignalsStore

  @doc """
  Asserts that a result is a successful LLM response with non-empty content.

  Accepts:
  - `{:ok, %Arbor.AI.Response{}}` — the standard return type
  - `{:ok, text}` — simplified text tuple
  - raw text string
  """
  def assert_valid_llm_response({:ok, %{text: text} = response}) when is_binary(text) do
    assert String.trim(text) != "",
           "LLM response was empty (blank string)"

    response
  end

  def assert_valid_llm_response({:ok, text}) when is_binary(text) do
    assert String.trim(text) != "",
           "LLM response was empty (blank string)"

    text
  end

  def assert_valid_llm_response(text) when is_binary(text) do
    assert String.trim(text) != "",
           "LLM response was empty (blank string)"

    text
  end

  def assert_valid_llm_response({:error, reason}) do
    flunk("Expected successful LLM response, got error: #{inspect(reason)}")
  end

  def assert_valid_llm_response(other) do
    flunk("Expected {:ok, response} or text binary, got: #{inspect(other)}")
  end

  @doc """
  Asserts the response is an %Arbor.AI.Response{} struct with expected fields.
  Returns the response for chaining.
  """
  def assert_response_struct({:ok, %{text: _, provider: _} = response}) do
    assert is_binary(response.text), "Response.text should be a string"
    response
  end

  def assert_response_struct({:ok, other}) do
    flunk("Expected %Arbor.AI.Response{} struct, got: #{inspect(other)}")
  end

  def assert_response_struct({:error, reason}) do
    flunk("Expected successful response struct, got error: #{inspect(reason)}")
  end

  @doc """
  Asserts the response has non-nil usage information with token counts.
  """
  def assert_response_has_usage(%{usage: usage} = response) do
    assert usage != nil, "Response missing usage information"
    assert is_map(usage), "Usage should be a map, got: #{inspect(usage)}"
    response
  end

  def assert_response_has_usage({:ok, response}), do: assert_response_has_usage(response)

  @doc """
  Asserts that a result is a successful LLM response containing specific text.
  Case-insensitive matching.
  """
  def assert_response_contains({:ok, %{text: text}}, expected) when is_binary(text) do
    assert String.contains?(String.downcase(text), String.downcase(expected)),
           "Expected LLM response to contain #{inspect(expected)}, got: #{String.slice(text, 0, 200)}"

    text
  end

  def assert_response_contains({:ok, text}, expected) when is_binary(text) do
    assert String.contains?(String.downcase(text), String.downcase(expected)),
           "Expected LLM response to contain #{inspect(expected)}, got: #{String.slice(text, 0, 200)}"

    text
  end

  def assert_response_contains(text, expected) when is_binary(text) do
    assert String.contains?(String.downcase(text), String.downcase(expected)),
           "Expected LLM response to contain #{inspect(expected)}, got: #{String.slice(text, 0, 200)}"

    text
  end

  @doc """
  Asserts that a result is a valid JSON-parseable LLM response.
  Returns the parsed map.
  """
  def assert_valid_json_response({:ok, text}) when is_binary(text) do
    assert_valid_json_response(text)
  end

  def assert_valid_json_response(text) when is_binary(text) do
    # Strip markdown code fences if present
    cleaned =
      text
      |> String.trim()
      |> String.replace(~r/^```json\s*\n?/, "")
      |> String.replace(~r/\n?```\s*$/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        flunk(
          "Expected valid JSON in LLM response, got parse error: #{inspect(reason)}\nResponse: #{String.slice(text, 0, 500)}"
        )
    end
  end

  @doc """
  Asserts that an LLM response is an error with specific reason.
  """
  def assert_llm_error({:error, reason}, expected_reason) do
    assert reason == expected_reason,
           "Expected LLM error #{inspect(expected_reason)}, got: #{inspect(reason)}"

    reason
  end

  def assert_llm_error({:ok, text}, _expected_reason) do
    flunk("Expected LLM error, got successful response: #{String.slice(text, 0, 200)}")
  end

  @doc """
  Asserts that a heartbeat response has the expected structure.
  The heartbeat LLM returns JSON with specific fields.
  """
  def assert_valid_heartbeat_response(response) when is_map(response) do
    assert Map.has_key?(response, "thoughts") or Map.has_key?(response, :thoughts),
           "Heartbeat response missing 'thoughts' field: #{inspect(Map.keys(response))}"

    response
  end

  def assert_valid_heartbeat_response(text) when is_binary(text) do
    parsed = assert_valid_json_response(text)
    assert_valid_heartbeat_response(parsed)
  end

  @doc """
  Asserts that signals were emitted with the given prefix during a block.
  Uses the signal store to check.
  """
  defmacro assert_signals_emitted(prefix, do: block) do
    quote do
      # Get signal count before
      before_count = signal_count(unquote(prefix))

      # Execute the block
      result = unquote(block)

      # Allow async signals to propagate
      Process.sleep(100)

      # Check signals were emitted
      after_count = signal_count(unquote(prefix))

      assert after_count > before_count,
             "Expected signals with prefix #{inspect(unquote(prefix))} to be emitted, " <>
               "but count didn't change (before: #{before_count}, after: #{after_count})"

      result
    end
  end

  @doc false
  def signal_count(prefix) do
    case SignalsStore.recent(100) do
      {:ok, signals} ->
        Enum.count(signals, fn s ->
          type = Map.get(s, :type, "") |> to_string()
          String.starts_with?(type, to_string(prefix))
        end)

      _ ->
        0
    end
  end
end
