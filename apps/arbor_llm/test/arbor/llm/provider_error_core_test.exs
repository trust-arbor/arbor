defmodule Arbor.LLM.ProviderErrorCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.LLM.{Boundary, ProviderError, ProviderErrorCore}

  describe "retryable_status?/1" do
    test "transient statuses, including Anthropic 529 and Cloudflare 52x, are retryable" do
      for status <- [408, 429, 500, 502, 503, 504, 520, 521, 522, 523, 524, 529] do
        assert ProviderErrorCore.retryable_status?(status), "expected #{status} retryable"
      end
    end

    test "client errors and permanent server errors are not" do
      for status <- [400, 401, 403, 404, 413, 422, 501, 505, nil] do
        refute ProviderErrorCore.retryable_status?(status), "expected #{status} not retryable"
      end
    end
  end

  describe "retry_after_ms/1" do
    test "reads delta-seconds from retry-after (integer and decimal)" do
      assert ProviderErrorCore.retry_after_ms(%{"retry-after" => ["2"]}) == 2_000
      assert ProviderErrorCore.retry_after_ms(%{"retry-after" => [" 1.5 "]}) == 1_500
    end

    test "prefers OpenAI's retry-after-ms" do
      headers = %{"retry-after-ms" => ["250"], "retry-after" => ["9"]}
      assert ProviderErrorCore.retry_after_ms(headers) == 250
    end

    test "accepts header tuple lists case-insensitively" do
      assert ProviderErrorCore.retry_after_ms([{"Retry-After", "3"}]) == 3_000
    end

    test "ignores HTTP-dates, negatives, junk, and absent headers; caps at one day" do
      assert ProviderErrorCore.retry_after_ms(%{
               "retry-after" => ["Wed, 21 Oct 2026 07:28:00 GMT"]
             }) == nil

      assert ProviderErrorCore.retry_after_ms(%{"retry-after" => ["-1"]}) == nil
      assert ProviderErrorCore.retry_after_ms(%{"retry-after" => ["soon"]}) == nil
      assert ProviderErrorCore.retry_after_ms(%{}) == nil
      assert ProviderErrorCore.retry_after_ms(nil) == nil
      assert ProviderErrorCore.retry_after_ms(%{"retry-after" => ["999999999"]}) == 86_400_000
    end
  end

  describe "context_window_exceeded?/1" do
    @overflow_bodies [
      openai_code: %{
        "error" => %{
          "message" => "Your messages resulted in 9000 tokens. Please reduce them.",
          "type" => "invalid_request_error",
          "code" => "context_length_exceeded"
        }
      },
      openai_message: %{
        "error" => %{
          "message" =>
            "This model's maximum context length is 8192 tokens. However, your messages resulted in 9000 tokens.",
          "type" => "invalid_request_error"
        }
      },
      anthropic: %{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "message" => "prompt is too long: 208310 tokens > 200000 maximum"
        }
      },
      anthropic_with_max_tokens: %{
        "type" => "error",
        "error" => %{
          "type" => "invalid_request_error",
          "message" =>
            "input length and `max_tokens` exceed context limit: 180000 + 32000 > 200000, decrease input length or `max_tokens` and try again"
        }
      },
      vllm: %{
        "object" => "error",
        "message" =>
          "This model's maximum context length is 4096 tokens. However, you requested 5000 tokens.",
        "type" => "BadRequestError",
        "code" => 400
      },
      lm_studio: %{
        "error" =>
          "Trying to keep the first 5000 tokens when context the overflows. However, the model is loaded with context length of only 4096 tokens, which is not enough."
      },
      llama_cpp: %{
        "error" => %{
          "code" => 400,
          "message" => "the request exceeds the available context size, try increasing it",
          "type" => "exceed_context_size_error"
        }
      },
      xai: %{
        "code" => "Client specified an invalid argument",
        "error" =>
          "This model's maximum prompt length is 131072 but the request contains 150000 tokens."
      },
      gemini_list: [
        %{
          "error" => %{
            "code" => 400,
            "message" =>
              "The input token count (1200000) exceeds the maximum number of tokens allowed (1048576).",
            "status" => "INVALID_ARGUMENT"
          }
        }
      ],
      bedrock: %{"message" => "Input is too long for requested model."},
      mistral: %{
        "object" => "error",
        "message" =>
          "Prompt contains 40000 tokens and 0 draft tokens, too large for model with 32768 maximum context length",
        "type" => "invalid_request_error"
      },
      fastapi_detail: %{"detail" => "Request exceeds the model context window."},
      raw_text: "error: context size has been exceeded"
    ]

    for {name, body} <- @overflow_bodies do
      @body body
      test "detects #{name}" do
        assert ProviderErrorCore.context_window_exceeded?(@body)
      end
    end

    test "ordinary failures are not context overflows" do
      for body <- [
            %{
              "error" => %{
                "message" =>
                  "Request too large for gpt-4 on tokens per min (TPM): Limit 10000, Requested 12000.",
                "type" => "tokens",
                "code" => "rate_limit_exceeded"
              }
            },
            %{
              "type" => "error",
              "error" => %{
                "type" => "invalid_request_error",
                "message" => "messages: roles must alternate between user and assistant"
              }
            },
            %{
              "error" => %{"message" => "Incorrect API key provided", "code" => "invalid_api_key"}
            },
            "<html><body>502 Bad Gateway</body></html>",
            nil,
            %{},
            [],
            42
          ] do
        refute ProviderErrorCore.context_window_exceeded?(body), inspect(body)
      end
    end

    test "only the bounded prefix of a long text is scanned" do
      body = String.duplicate("x", 10_000) <> " prompt is too long"
      refute ProviderErrorCore.context_window_exceeded?(body)
    end
  end

  describe "from_http/4" do
    test "a 429 is retryable, carries Retry-After, and is never a context overflow" do
      error =
        ProviderErrorCore.from_http(
          429,
          %{"retry-after" => ["1"]},
          %{"error" => %{"message" => "context length budget per minute exhausted"}},
          original: :the_response,
          source: :req_llm
        )

      assert %ProviderError{
               status: 429,
               retryable: true,
               retry_after_ms: 1_000,
               context_window_exceeded: false,
               original: :the_response,
               details: %{source: :req_llm}
             } = error

      assert error.message == "HTTP 429: context length budget per minute exhausted"
    end

    test "a context overflow is never retryable, whatever its status" do
      body = %{"error" => %{"message" => "prompt is too long: 208310 tokens > 200000 maximum"}}

      for status <- [400, 413, 500, 503] do
        error = ProviderErrorCore.from_http(status, %{}, body)
        assert error.context_window_exceeded
        refute error.retryable
      end
    end

    test "Anthropic 529 overloaded is retryable" do
      body = %{
        "type" => "error",
        "error" => %{"type" => "overloaded_error", "message" => "Overloaded"}
      }

      assert %ProviderError{status: 529, retryable: true, context_window_exceeded: false} =
               ProviderErrorCore.from_http(529, %{}, body)
    end

    test "the provider message is bounded" do
      error = ProviderErrorCore.from_http(500, %{}, %{"error" => String.duplicate("é", 1_000)})
      assert byte_size(error.message) <= byte_size("HTTP 500: ") + 256
      assert String.valid?(error.message)
    end
  end

  describe "from_failure/2" do
    test "a transport exception is retryable and kept as the original term" do
      exception = %Req.TransportError{reason: :econnrefused}

      assert %ProviderError{status: nil, retryable: true, original: ^exception} =
               ProviderErrorCore.from_failure(exception, source: :req_llm)
    end

    test "ReqLLM's wrapper around a transport failure keeps the transport exception" do
      cause = %Req.TransportError{reason: :econnrefused}

      wrapped =
        ReqLLM.Error.API.Request.exception(
          reason: "connection refused",
          request_body: ~s({"messages":[{"role":"user","content":"secret prompt"}]}),
          cause: cause
        )

      assert %ProviderError{status: nil, retryable: true, original: ^cause} =
               ProviderErrorCore.from_failure(wrapped)
    end

    test "a ReqLLM HTTP exception is classified from its status and body" do
      exception =
        ReqLLM.Error.API.Request.exception(
          reason: "Provider response error (400)",
          status: 400,
          response_body: %{"error" => %{"code" => "context_length_exceeded"}}
        )

      assert %ProviderError{
               status: 400,
               retryable: false,
               context_window_exceeded: true,
               original: ^exception
             } = ProviderErrorCore.from_failure(exception)

      rate_limited = ReqLLM.Error.API.Request.exception(reason: "rate", status: 429)

      assert %ProviderError{status: 429, retryable: true} =
               ProviderErrorCore.from_failure(rate_limited)
    end

    test "local refusals of a provider response are typed and non-retryable" do
      for reason <- [
            {:response_bytes_exceeded, 1_024},
            {:invalid_response_body, {:invalid_content_type, :application_json_required}},
            {:embedding_index_reordered, 0, 1},
            {:exit, :shutdown},
            {:throw, :oops},
            %RuntimeError{message: "boom"}
          ] do
        assert %ProviderError{retryable: false, status: nil, original: ^reason} =
                 ProviderErrorCore.from_failure(reason)
      end
    end

    test "an existing ProviderError passes through unchanged" do
      error = %ProviderError{message: "x", status: 503, retryable: true}
      assert ProviderErrorCore.from_failure(error) == error
    end
  end

  describe "Boundary.provider_error/1" do
    test "an oversized original is bounded while the classification survives" do
      body = %{
        "error" => %{"message" => "prompt is too long: 999999 tokens > 200000 maximum"},
        "echo" => String.duplicate("x", 200_000)
      }

      error = ProviderErrorCore.from_http(400, %{}, body, original: %{body: body})
      bounded = Boundary.provider_error(error)

      assert %ProviderError{status: 400, retryable: false, context_window_exceeded: true} =
               bounded

      assert is_map(bounded.original)
      refute bounded.original == error.original
      assert Boundary.completion({:error, error}) == {:error, bounded}
    end

    test "an original the budget cannot represent keeps its shape, not its text" do
      error = ProviderErrorCore.from_failure({:exit, %{{:tuple, :key} => self()}})
      bounded = Boundary.provider_error(error)

      assert %ProviderError{retryable: false, details: nil} = bounded
      assert is_atom(bounded.original) or is_map(bounded.original) or is_tuple(bounded.original)
      assert {:error, ^bounded} = Boundary.completion({:error, error})
    end

    test "a small error is returned untouched" do
      error = ProviderErrorCore.from_http(503, %{}, %{"error" => "busy"}, original: :small)
      assert Boundary.provider_error(error) == error
    end
  end
end
