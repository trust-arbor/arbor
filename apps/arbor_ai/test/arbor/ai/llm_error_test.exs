defmodule Arbor.AI.LLMErrorTest do
  use ExUnit.Case, async: true

  alias Arbor.AI.LLMError
  alias Arbor.LLM.OAuth.ResponsesFailure

  @moduletag :fast

  describe "classify/1 ResponsesFailure" do
    test "maps closed class/code table and preserves exact route" do
      failure =
        ResponsesFailure.exception(
          route: :openai_oauth,
          backend: :openai,
          code: :rate_limited,
          status: 429,
          retry_after_ms: 1_500
        )

      info = LLMError.classify(failure)
      assert info.type == :rate_limited
      assert info.code == "rate_limited"
      assert info.status == 429
      assert info.retryable == true
      assert info.retry_after_ms == 1_500
      assert info.provider == :openai_oauth
      assert is_binary(info.message)
      assert String.length(info.message) <= 220
      refute info.message =~ "sk-"
    end

    test "maps each class distinctly without using backend as provider" do
      cases = [
        {:auth, :unauthorized, 401, :auth_failure, "unauthorized", false},
        {:forbidden, :forbidden, 403, :auth_failure, "forbidden", false},
        {:tier_denied, :xai_oauth_tier_denied, 403, :auth_failure, "xai_oauth_tier_denied",
         false},
        {:quota, :rate_limited, 429, :rate_limited, "rate_limited", true},
        {:provider_outage, :server_error, 503, :provider_error, "server_error", true},
        {:transport, :request_timeout, nil, :timeout, "request_timeout", true},
        {:transport, :connection_failed, nil, :network, "connection_failed", true},
        {:protocol, :invalid_stream, nil, :provider_error, "invalid_stream", false}
      ]

      for {class, code, status, type, code_str, retryable} <- cases do
        route = if class == :tier_denied, do: :xai_oauth, else: :openai_oauth
        backend = if route == :xai_oauth, do: :xai, else: :openai

        failure =
          ResponsesFailure.exception(
            route: route,
            backend: backend,
            code: code,
            status: status
          )

        info = LLMError.classify(failure)
        assert info.type == type, "class=#{class}"
        assert info.code == code_str
        assert info.retryable == retryable
        assert info.provider == route
        assert LLMError.control_plane_effect(info) != :none
      end
    end

    test "nil route yields nil provider and does not invent identity" do
      failure = ResponsesFailure.transport(nil, :openai, :connection_failed)
      info = LLMError.classify(failure)
      assert info.provider == nil
      assert info.type == :network
      assert info.code == "connection_failed"
    end

    test "control_plane_effect separates quota from non-quota via exact type/code table" do
      assert {:quota, :rate_limited} =
               LLMError.control_plane_effect(%{
                 type: :rate_limited,
                 code: "rate_limited",
                 provider: :openai_oauth
               })

      assert {:route_failure, :tier_denied} =
               LLMError.control_plane_effect(%{
                 type: :auth_failure,
                 code: "xai_oauth_tier_denied",
                 provider: :xai_oauth
               })

      assert {:route_failure, :outage} =
               LLMError.control_plane_effect(%{
                 type: :provider_error,
                 code: "server_error",
                 provider: :openai_oauth
               })

      assert {:route_failure, :auth} =
               LLMError.control_plane_effect(%{
                 type: :auth_failure,
                 code: "unauthorized",
                 provider: :openai_oauth
               })

      assert {:route_failure, :transport} =
               LLMError.control_plane_effect(%{
                 type: :network,
                 code: "connection_failed",
                 provider: :openai_oauth
               })

      assert :none = LLMError.control_plane_effect(%{type: :unknown, code: nil})
    end

    test "security regression: type-only control_plane_effect maps are no-ops" do
      assert :none = LLMError.control_plane_effect(%{type: :rate_limited})
      assert :none = LLMError.control_plane_effect(%{type: :auth_failure})
      assert :none = LLMError.control_plane_effect(%{type: :rate_limited, code: nil})
      assert :none = LLMError.control_plane_effect(%{type: :provider_error})
      assert :none = LLMError.control_plane_effect(%{code: "rate_limited"})
    end
  end
end
