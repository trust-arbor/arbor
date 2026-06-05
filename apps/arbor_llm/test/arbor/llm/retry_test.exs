defmodule Arbor.LLM.RetryTest do
  @moduledoc """
  Unit tests for `Arbor.LLM.Retry.fallback_eligible?/1` — the public
  classifier shared by `Retry.execute/2`'s default :should_retry callback
  AND `Arbor.AI.Runtime.Dispatch.fallback_eligible?/1` AND the LlmHandler
  tool-loop fallback wrapper. All three must classify errors identically
  so behavior is consistent across the system.
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.LLM.Retry

  describe "fallback_eligible?/1" do
    test "transient atoms are eligible" do
      assert Retry.fallback_eligible?(:timeout)
      assert Retry.fallback_eligible?(:rate_limited)
      assert Retry.fallback_eligible?(:network_error)
      assert Retry.fallback_eligible?(:transient_error)
    end

    test "unrelated atoms are NOT eligible (fail closed)" do
      refute Retry.fallback_eligible?(:something_else)
      refute Retry.fallback_eligible?(:bad_auth)
      refute Retry.fallback_eligible?(:invalid_prompt)
    end

    test "HTTP 429 + 5xx are eligible" do
      assert Retry.fallback_eligible?({:http_status, 429})
      assert Retry.fallback_eligible?({:http_status, 500})
      assert Retry.fallback_eligible?({:http_status, 503})
      assert Retry.fallback_eligible?({:http_status, 599})
    end

    test "HTTP 4xx other than 429 NOT eligible" do
      refute Retry.fallback_eligible?({:http_status, 400})
      refute Retry.fallback_eligible?({:http_status, 401})
      refute Retry.fallback_eligible?({:http_status, 403})
      refute Retry.fallback_eligible?({:http_status, 404})
    end

    test "ProviderError respects :retryable flag" do
      assert Retry.fallback_eligible?(%Arbor.LLM.ProviderError{
               message: "rate",
               provider: :anthropic,
               retryable: true
             })

      refute Retry.fallback_eligible?(%Arbor.LLM.ProviderError{
               message: "bad",
               provider: :anthropic,
               retryable: false
             })
    end

    test "RequestTimeoutError is always eligible" do
      assert Retry.fallback_eligible?(%Arbor.LLM.RequestTimeoutError{
               message: "took too long",
               timeout_ms: 30_000
             })
    end

    test "tuples and other shapes default to NOT eligible" do
      refute Retry.fallback_eligible?({:bad_prompt, "..."})
      refute Retry.fallback_eligible?({:something, "else"})
      refute Retry.fallback_eligible?("string error")
      refute Retry.fallback_eligible?(nil)
    end
  end
end
