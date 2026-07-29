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
  alias Arbor.LLM.OAuth.ResponsesFailure

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

    test "ResponsesFailure eligibility is table authoritative" do
      assert Retry.fallback_eligible?(
               ResponsesFailure.transport(:openai_oauth, :openai, :deadline_exceeded)
             )

      assert Retry.fallback_eligible?(
               ResponsesFailure.transport(:xai_oauth, :xai, :connection_failed)
             )

      assert Retry.fallback_eligible?(ResponsesFailure.from_status(:openai_oauth, :openai, 408))

      refute Retry.fallback_eligible?(
               ResponsesFailure.protocol(:openai_oauth, :openai, :invalid_stream)
             )

      refute Retry.fallback_eligible?(ResponsesFailure.from_status(:openai_oauth, :openai, 401))
    end

    test "ResponsesFailure ignores direct struct and override forgery attempts" do
      assert Retry.fallback_eligible?(
               ResponsesFailure.exception(
                 route: :openai_oauth,
                 backend: :openai,
                 code: :rate_limited,
                 retryable: false
               )
             )

      refute Retry.fallback_eligible?(
               struct(ResponsesFailure,
                 route: :openai_oauth,
                 backend: :openai,
                 class: :auth,
                 code: :connection_failed,
                 status: 500,
                 retryable: true
               )
             )

      refute Retry.fallback_eligible?(
               struct(
                 ResponsesFailure,
                 route: :openai_oauth,
                 backend: :openai,
                 class: :quota,
                 code: :unexpected_status,
                 status: 500,
                 retryable: true
               )
             )
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
