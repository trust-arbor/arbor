defmodule Arbor.Common.SafeRegexTest do
  use ExUnit.Case, async: true

  alias Arbor.Common.SafeRegex

  describe "run/3" do
    test "returns match result for simple patterns" do
      assert {:ok, ["foo"]} = SafeRegex.run(~r/foo/, "foobar")
      assert {:ok, ["bar"]} = SafeRegex.run(~r/bar/, "foobar")
    end

    test "returns nil for no match" do
      assert {:ok, nil} = SafeRegex.run(~r/baz/, "foobar")
    end

    test "returns capture groups" do
      assert {:ok, ["foo123", "123"]} = SafeRegex.run(~r/foo(\d+)/, "foo123bar")
    end

    test "respects custom timeout" do
      # Simple pattern should complete well under 50ms
      assert {:ok, ["test"]} = SafeRegex.run(~r/test/, "test", timeout: 50)
    end
  end

  describe "scan/3" do
    test "returns all matches" do
      assert {:ok, [["a"], ["a"], ["a"]]} = SafeRegex.scan(~r/a/, "banana")
    end

    test "returns empty list for no matches" do
      assert {:ok, []} = SafeRegex.scan(~r/z/, "banana")
    end

    test "returns capture groups for each match" do
      result = SafeRegex.scan(~r/(\d+)/, "a1b2c3")
      assert {:ok, [["1", "1"], ["2", "2"], ["3", "3"]]} = result
    end
  end

  describe "match?/3" do
    test "returns true for matching patterns" do
      assert {:ok, true} = SafeRegex.match?(~r/foo/, "foobar")
    end

    test "returns false for non-matching patterns" do
      assert {:ok, false} = SafeRegex.match?(~r/baz/, "foobar")
    end
  end

  describe "timeout protection" do
    @tag :slow
    test "handles pathological input gracefully" do
      # This pattern with nested quantifiers is vulnerable to ReDoS
      # On adversarial input, it could take exponential time
      evil_pattern = ~r/(a+)+$/

      # Input designed to cause backtracking: many 'a's followed by 'b'
      evil_input = String.duplicate("a", 30) <> "b"

      # With a short timeout, this should return timeout error
      # rather than hanging the process
      result = SafeRegex.run(evil_pattern, evil_input, timeout: 100)

      # Either it times out or completes quickly with no match
      # The important thing is it doesn't hang
      assert result in [{:error, :timeout}, {:ok, nil}]
    end

    test "normal patterns complete within timeout" do
      # A normal pattern should complete quickly even on larger input
      normal_pattern = ~r/api_key:\s*"[^"]+"/
      normal_input = "config: api_key: \"abc123\" more text"

      assert {:ok, ["api_key: \"abc123\""]} =
               SafeRegex.run(normal_pattern, normal_input, timeout: 100)
    end
  end
end
