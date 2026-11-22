defmodule Arbor.LLM.OAuth.ModelCatalogSecurityRegressionTest do
  @moduledoc """
  Public-boundary security regression for subscription model-catalog transport.

  Aliases, lookalikes, bare backends, and forbidden endpoint/client_version
  options must be rejected before credential or network functions are invoked.
  """

  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Contracts.LLM.ProviderModelCatalog
  alias Arbor.LLM
  alias Arbor.LLM.OAuth.{CredentialReceipt, ModelCatalogFailure}

  @now ~U[2026-07-29 12:00:00Z]

  test "security regression: aliases and lookalikes are rejected before credential or request I/O" do
    cred = :counters.new(1, [])
    req = :counters.new(1, [])

    injectors = [
      now_fn: fn -> @now end,
      credential_receipt_fun: fn _backend ->
        :counters.add(cred, 1, 1)
        flunk("credential_receipt_fun must not run for rejected routes")
      end,
      request_fun: fn _spec ->
        :counters.add(req, 1, 1)
        flunk("request_fun must not run for rejected routes")
      end
    ]

    for route <- [
          "chatgpt",
          "codex",
          "gpt",
          "openai",
          "xai",
          "grok",
          "x-ai",
          "openai-oauth",
          "claude",
          "anthropic",
          :openai,
          :xai,
          :grok
        ] do
      assert {:error, _reason} = LLM.oauth_model_catalog(route, injectors)
    end

    assert :counters.get(cred, 1) == 0
    assert :counters.get(req, 1) == 0
  end

  test "security regression: forbidden endpoint, client_version, and ttl options reject before I/O" do
    cred = :counters.new(1, [])
    req = :counters.new(1, [])

    base = [
      credential_receipt_fun: fn _ ->
        :counters.add(cred, 1, 1)
        flunk("credential must not run")
      end,
      request_fun: fn _ ->
        :counters.add(req, 1, 1)
        flunk("request must not run")
      end
    ]

    for forbidden <- [
          [url: "https://evil.example/v1/models"],
          [endpoint: "https://chatgpt.com/backend-api/codex/models"],
          [base_url: "https://cli-chat-proxy.grok.com/v1"],
          [client_version: "1.2.3"],
          [access_token: "tok"],
          [trusted_endpoints: ["https://evil.example"]],
          [ttl_ms: 60_000]
        ] do
      assert {:error, %ModelCatalogFailure{code: :forbidden_option}} =
               LLM.oauth_model_catalog(:openai_oauth, forbidden ++ base)
    end

    assert :counters.get(cred, 1) == 0
    assert :counters.get(req, 1) == 0
  end

  test "security regression: exact routes reach credential and request seams" do
    cred = :counters.new(1, [])
    req = :counters.new(1, [])

    assert {:ok, %ProviderModelCatalog{route: "openai_oauth", model_ids: ["m1"]}} =
             LLM.oauth_model_catalog(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn backend ->
                 :counters.add(cred, 1, 1)
                 assert backend == :openai

                 {:ok,
                  %CredentialReceipt{
                    provider: :openai,
                    owner: "arbor_owned",
                    access_token: "tok",
                    account_id: nil,
                    generation: 1
                  }}
               end,
               request_fun: fn spec ->
                 :counters.add(req, 1, 1)

                 assert spec.url ==
                          "https://chatgpt.com/backend-api/codex/models?client_version=0.0.0"

                 {:ok,
                  %{
                    status: 200,
                    body:
                      Jason.encode!(%{
                        "models" => [%{"slug" => "m1", "supported_in_api" => true}]
                      }),
                    headers: %{"content-type" => ["application/json"]}
                  }}
               end
             )

    assert :counters.get(cred, 1) == 1
    assert :counters.get(req, 1) == 1
  end

  test "security regression: mismatched receipts reject before request I/O" do
    req = :counters.new(1, [])

    assert {:error, %ModelCatalogFailure{code: :invalid_credential_receipt}} =
             LLM.oauth_model_catalog(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok,
                  %CredentialReceipt{
                    provider: :xai,
                    owner: "arbor_owned",
                    access_token: "tok",
                    account_id: nil,
                    generation: 1
                  }}
               end,
               request_fun: fn _ ->
                 :counters.add(req, 1, 1)
                 flunk("request must not run for mismatched receipt")
               end
             )

    assert :counters.get(req, 1) == 0
  end

  test "security regression: missing and conflicting content-type headers fail closed" do
    base_cred = fn ->
      {:ok,
       %CredentialReceipt{
         provider: :openai,
         owner: "arbor_owned",
         access_token: "tok",
         account_id: nil,
         generation: 1
       }}
    end

    body = Jason.encode!(%{"models" => [%{"slug" => "m", "supported_in_api" => true}]})

    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             LLM.oauth_model_catalog(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ -> base_cred.() end,
               request_fun: fn _ ->
                 {:ok, %{status: 200, body: body, headers: []}}
               end
             )

    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             LLM.oauth_model_catalog(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ -> base_cred.() end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: %{"content-type" => ["application/json", "text/plain"]}
                  }}
               end
             )
  end

  test "security regression: non-keyword options fail closed without I/O" do
    assert {:error, :keyword_options_required} = LLM.oauth_model_catalog(:openai_oauth, %{})
    assert {:error, :keyword_options_required} = LLM.oauth_model_catalog(:openai_oauth, "nope")
  end
end
