defmodule Arbor.LLM.OAuth.ModelCatalogTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.LLM.ProviderModelCatalog
  alias Arbor.LLM.OAuth.{CredentialReceipt, ModelCatalog, ModelCatalogFailure}

  @now ~U[2026-07-29 12:00:00Z]
  @openai_url "https://chatgpt.com/backend-api/codex/models?client_version=0.0.0"
  @xai_url "https://cli-chat-proxy.grok.com/v1/models"

  test "OpenAI exact request construction and mixed supported_in_api filtering" do
    requests = :counters.new(1, [])

    assert {:ok, %ProviderModelCatalog{} = catalog} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn backend ->
                 assert backend == :openai
                 {:ok, receipt(:openai, "source_owned", 3, "tok-openai", "acct-1")}
               end,
               request_fun: fn spec ->
                 :counters.add(requests, 1, 1)
                 assert spec.method == :get
                 assert spec.url == @openai_url
                 assert spec.redirect == false
                 assert spec.compressed == false
                 assert_header(spec.headers, "authorization", "Bearer tok-openai")
                 assert_header(spec.headers, "chatgpt-account-id", "acct-1")

                 json_ok(%{
                   "models" => [
                     %{"slug" => "gpt-selectable", "supported_in_api" => true},
                     %{"slug" => "gpt-hidden", "supported_in_api" => false},
                     %{"slug" => "gpt-also", "supported_in_api" => true}
                   ]
                 })
               end
             )

    assert catalog.route == "openai_oauth"
    assert catalog.backend == "openai"
    assert catalog.runtime == "arbor"
    assert catalog.model_ids == ["gpt-selectable", "gpt-also"]
    assert catalog.credential_generation == 3
    assert catalog.observed_at == "2026-07-29T12:00:00Z"
    assert catalog.expires_at == "2026-07-29T12:05:00Z"
    assert :counters.get(requests, 1) == 1
  end

  test "OpenAI non-empty all-false report yields zero selectable models" do
    assert {:ok, %ProviderModelCatalog{model_ids: []}} =
             ModelCatalog.fetch("openai_oauth",
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _spec ->
                 json_ok(%{
                   "models" => [
                     %{"slug" => "a", "supported_in_api" => false},
                     %{"slug" => "b", "supported_in_api" => false}
                   ]
                 })
               end
             )
  end

  test "OpenAI empty models list fails closed" do
    assert {:error, %ModelCatalogFailure{code: :empty_catalog}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ -> json_ok(%{"models" => []}) end
             )
  end

  test "xAI exact request construction and data/id parsing" do
    assert {:ok, %ProviderModelCatalog{} = catalog} =
             ModelCatalog.fetch(:xai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn backend ->
                 assert backend == :xai
                 {:ok, receipt(:xai, "arbor_owned", 9, "xai-tok", nil)}
               end,
               request_fun: fn spec ->
                 assert spec.url == @xai_url
                 assert_header(spec.headers, "authorization", "Bearer xai-tok")

                 refute Enum.any?(spec.headers, fn {k, _} ->
                          String.downcase(k) == "chatgpt-account-id"
                        end)

                 json_ok(%{
                   "data" => [
                     %{"id" => "grok-4.5", "object" => "model"},
                     %{"id" => "grok-3"}
                   ]
                 })
               end
             )

    assert catalog.route == "xai_oauth"
    assert catalog.backend == "xai"
    assert catalog.model_ids == ["grok-4.5", "grok-3"]
    assert catalog.credential_generation == 9
  end

  test "malformed, duplicate, wrong shape, and oversized catalogs fail closed" do
    base = [
      now_fn: fn -> @now end,
      credential_receipt_fun: fn _ ->
        {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
      end
    ]

    assert {:error, %ModelCatalogFailure{code: :malformed_catalog}} =
             ModelCatalog.fetch(
               :openai_oauth,
               base ++ [request_fun: fn _ -> json_ok(%{"data" => [%{"id" => "x"}]}) end]
             )

    assert {:error, %ModelCatalogFailure{code: :duplicate_model_id}} =
             ModelCatalog.fetch(
               :openai_oauth,
               base ++
                 [
                   request_fun: fn _ ->
                     json_ok(%{
                       "models" => [
                         %{"slug" => "dup", "supported_in_api" => true},
                         %{"slug" => "dup", "supported_in_api" => false}
                       ]
                     })
                   end
                 ]
             )

    assert {:error, %ModelCatalogFailure{code: :malformed_catalog}} =
             ModelCatalog.fetch(
               :openai_oauth,
               base ++
                 [
                   request_fun: fn _ ->
                     json_ok(%{
                       "models" => [%{"slug" => "x", "supported_in_api" => "yes"}]
                     })
                   end
                 ]
             )

    assert {:error, %ModelCatalogFailure{code: :catalog_too_large}} =
             ModelCatalog.fetch(
               :openai_oauth,
               base ++
                 [
                   request_fun: fn _ ->
                     models =
                       for i <- 1..513 do
                         %{"slug" => "m-#{i}", "supported_in_api" => true}
                       end

                     json_ok(%{"models" => models})
                   end
                 ]
             )
  end

  test "current-shaped JSON above 256 map keys is admitted under 2048 ceiling" do
    extra =
      for i <- 1..300, into: %{} do
        {"k#{i}", i}
      end

    body =
      Map.merge(extra, %{
        "models" => [%{"slug" => "ok", "supported_in_api" => true}]
      })

    assert {:ok, %ProviderModelCatalog{model_ids: ["ok"]}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ -> json_ok(body) end
             )
  end

  test "JSON above 2048 map keys fails closed" do
    extra =
      for i <- 1..2100, into: %{} do
        {"k#{i}", i}
      end

    body =
      Map.merge(extra, %{
        "models" => [%{"slug" => "ok", "supported_in_api" => true}]
      })

    assert {:error, %ModelCatalogFailure{code: :malformed_catalog}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ -> json_ok(body) end
             )
  end

  test "empty raw body on 200 fails closed" do
    assert {:error, %ModelCatalogFailure{code: :empty_raw_body}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: "",
                    headers: %{"content-type" => ["application/json"]}
                  }}
               end
             )
  end

  test "header failures and admits on 200 path" do
    body = Jason.encode!(%{"models" => [%{"slug" => "m", "supported_in_api" => true}]})
    cred = fn _ -> {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)} end

    # missing content-type
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ -> {:ok, %{status: 200, body: body, headers: []}} end
             )

    # conflicting multi content-type
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: %{"content-type" => ["application/json", "text/plain"]}
                  }}
               end
             )

    # lookalike application/jsonp
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: [{"content-type", "application/jsonp"}]
                  }}
               end
             )

    # gzip content-encoding
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: [
                      {"content-type", "application/json"},
                      {"content-encoding", "gzip"}
                    ]
                  }}
               end
             )

    # duplicate content-encoding even when identity
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: %{
                      "content-type" => ["application/json"],
                      "content-encoding" => ["identity", "identity"]
                    }
                  }}
               end
             )

    # admit application/json with charset
    assert {:ok, %ProviderModelCatalog{model_ids: ["m"]}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: [{"content-type", "application/json; charset=utf-8"}]
                  }}
               end
             )

    # admit well-formed +json
    assert {:ok, %ProviderModelCatalog{model_ids: ["m"]}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: %{"content-type" => ["application/ld+json"]}
                  }}
               end
             )
  end

  test "private-chunk body normalization is admitted" do
    body = Jason.encode!(%{"models" => [%{"slug" => "chunked", "supported_in_api" => true}]})
    {part1, part2} = String.split_at(body, div(byte_size(body), 2))

    assert {:ok, %ProviderModelCatalog{model_ids: ["chunked"]}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: "",
                    headers: %{"content-type" => ["application/json"]},
                    private: %{
                      arbor_response_chunks: [part2, part1],
                      arbor_response_bytes: byte_size(body)
                    }
                  }}
               end
             )
  end

  test "malformed private chunks return protocol failure without raising" do
    assert {:error, %ModelCatalogFailure{code: :malformed_catalog}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: "",
                    headers: %{"content-type" => ["application/json"]},
                    private: %{arbor_response_chunks: [:not_binary, "x"]}
                  }}
               end
             )

    assert {:error, %ModelCatalogFailure{code: :malformed_catalog}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: "ignored",
                    headers: %{"content-type" => ["application/json"]},
                    private: %{arbor_response_chunks: "not-a-list"}
                  }}
               end
             )
  end

  test "case-insensitive duplicate header keys and nonbinary values fail closed" do
    body = Jason.encode!(%{"models" => [%{"slug" => "m", "supported_in_api" => true}]})
    cred = fn _ -> {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)} end

    # Duplicate case-insensitive map keys
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: %{
                      "Content-Type" => "application/json",
                      "content-type" => "text/plain"
                    }
                  }}
               end
             )

    # List form duplicate pairs (case-insensitive)
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: [
                      {"Content-Type", "application/json"},
                      {"content-type", "application/json"}
                    ]
                  }}
               end
             )

    # Nonbinary header value
    assert {:error, %ModelCatalogFailure{code: :invalid_response_headers}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: cred,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 200,
                    body: body,
                    headers: %{"content-type" => [:not_a_binary]}
                  }}
               end
             )
  end

  test "malformed credential reread returns closed reauth with exactly one request" do
    requests = :counters.new(1, [])
    used = receipt(:openai, "source_owned", 1, "old-tok", "acct")

    assert {:error, :oauth_source_reauthentication_required} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ -> {:ok, used} end,
               reread_source_credential_fun: fn _ ->
                 raise "hostile reread"
               end,
               request_fun: fn _ ->
                 :counters.add(requests, 1, 1)
                 {:ok, %{status: 401, body: ~s({"token":"secret"}), headers: []}}
               end
             )

    assert :counters.get(requests, 1) == 1

    assert {:error, :oauth_source_reauthentication_required} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ -> {:ok, used} end,
               reread_source_credential_fun: fn _ -> :not_a_tuple end,
               request_fun: fn _ ->
                 :counters.add(requests, 1, 1)
                 {:ok, %{status: 401, body: "x", headers: []}}
               end
             )

    assert :counters.get(requests, 1) == 2
  end

  test "status outside 100..599 is protocol failure" do
    assert {:error, %ModelCatalogFailure{code: :malformed_catalog, status: nil}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 999,
                    body: ~s({"error":"nope"}),
                    headers: [{"content-type", "application/json"}]
                  }}
               end
             )
  end

  test "non-200 status is classified before body overflow markers" do
    assert {:error, %ModelCatalogFailure{code: :unauthorized, status: 401}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 {:ok,
                  %{
                    status: 401,
                    body: "bounded-secret-prefix",
                    headers: [],
                    private: %{arbor_response_overflow: 1_048_576}
                  }}
               end
             )
  end

  test "non-200 classifies by status without retaining secret bodies" do
    secret = "sk-live-super-secret-token-value"

    assert {:error, %ModelCatalogFailure{} = failure} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "arbor_owned", 1, secret, "acct-secret")}
               end,
               request_fun: fn _ ->
                 body =
                   ~s({"error":"#{secret}","account":"acct-secret","path":"/home/user/.codex"})

                 {:ok,
                  %{
                    status: 500,
                    body: body,
                    headers: [{"content-type", "application/json"}]
                  }}
               end
             )

    message = Exception.message(failure)
    inspect_text = inspect(failure)
    refute String.contains?(message, secret)
    refute String.contains?(inspect_text, secret)
    refute String.contains?(message, "acct-secret")
    refute String.contains?(message, "/home/user")
    assert failure.code == :server_error
  end

  test "mismatched receipts never reach request_fun" do
    req = :counters.new(1, [])

    assert {:error, %ModelCatalogFailure{code: :invalid_credential_receipt}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:xai, "arbor_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 :counters.add(req, 1, 1)
                 flunk("must not request")
               end
             )

    assert {:error, %ModelCatalogFailure{code: :invalid_credential_receipt}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "source_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 :counters.add(req, 1, 1)
                 flunk("must not request")
               end
             )

    assert {:error, :oauth_source_owned_unsupported} =
             ModelCatalog.fetch(:xai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:xai, "source_owned", 1, "tok", nil)}
               end,
               request_fun: fn _ ->
                 :counters.add(req, 1, 1)
                 flunk("must not request")
               end
             )

    assert :counters.get(req, 1) == 0
  end

  test "source-owned OpenAI retries once on 401 only with changed source credential" do
    requests = :counters.new(1, [])
    rereads = :counters.new(1, [])

    used = receipt(:openai, "source_owned", 1, "old-tok", "acct", source_generation: 10)
    latest = receipt(:openai, "source_owned", 1, "new-tok", "acct", source_generation: 11)

    assert {:ok, %ProviderModelCatalog{model_ids: ["ok"]}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ -> {:ok, used} end,
               reread_source_credential_fun: fn receipt ->
                 :counters.add(rereads, 1, 1)
                 assert receipt.access_token == "old-tok"
                 {:ok, latest}
               end,
               request_fun: fn spec ->
                 :counters.add(requests, 1, 1)

                 case :counters.get(requests, 1) do
                   1 ->
                     assert_header(spec.headers, "authorization", "Bearer old-tok")

                     {:ok,
                      %{
                        status: 401,
                        body: ~s({"token":"secret-refresh","detail":"nope"}),
                        headers: []
                      }}

                   2 ->
                     assert_header(spec.headers, "authorization", "Bearer new-tok")
                     json_ok(%{"models" => [%{"slug" => "ok", "supported_in_api" => true}]})
                 end
               end
             )

    assert :counters.get(requests, 1) == 2
    assert :counters.get(rereads, 1) == 1
  end

  test "unchanged source after 401 does not retry network and returns reauth required" do
    requests = :counters.new(1, [])

    used = receipt(:openai, "source_owned", 1, "same-tok", "acct", source_generation: 4)

    assert {:error, :oauth_source_reauthentication_required} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ -> {:ok, used} end,
               reread_source_credential_fun: fn _ -> {:error, :oauth_source_token_unchanged} end,
               request_fun: fn _ ->
                 :counters.add(requests, 1, 1)
                 {:ok, %{status: 401, body: ~s({"token":"secret"}), headers: []}}
               end
             )

    assert :counters.get(requests, 1) == 1
  end

  test "non-401 does not reread source credential" do
    rereads = :counters.new(1, [])

    assert {:error, %ModelCatalogFailure{code: :forbidden, status: 403}} =
             ModelCatalog.fetch(:openai_oauth,
               now_fn: fn -> @now end,
               credential_receipt_fun: fn _ ->
                 {:ok, receipt(:openai, "source_owned", 1, "tok", "acct")}
               end,
               reread_source_credential_fun: fn _ ->
                 :counters.add(rereads, 1, 1)
                 flunk("must not reread on non-401")
               end,
               request_fun: fn _ ->
                 {:ok, %{status: 403, body: ~s({"detail":"nope"}), headers: []}}
               end
             )

    assert :counters.get(rereads, 1) == 0
  end

  test "forbidden and unknown options are rejected before credential or network I/O" do
    cred = :counters.new(1, [])
    req = :counters.new(1, [])

    for opts <- [
          [url: "https://evil.example/models"],
          [client_version: "9.9.9"],
          [endpoint: "https://evil.example"],
          [access_token: "tok"],
          [ttl_ms: 1],
          [unknown_key: true]
        ] do
      assert {:error, %ModelCatalogFailure{code: :forbidden_option}} =
               ModelCatalog.fetch(
                 :openai_oauth,
                 opts ++
                   [
                     credential_receipt_fun: fn _ ->
                       :counters.add(cred, 1, 1)
                       flunk("credential must not run")
                     end,
                     request_fun: fn _ ->
                       :counters.add(req, 1, 1)
                       flunk("request must not run")
                     end
                   ]
               )
    end

    assert :counters.get(cred, 1) == 0
    assert :counters.get(req, 1) == 0
  end

  test "aliases and bare backends never invoke credential or request functions" do
    cred = :counters.new(1, [])
    req = :counters.new(1, [])

    funs = [
      credential_receipt_fun: fn _ ->
        :counters.add(cred, 1, 1)
        flunk("credential must not run")
      end,
      request_fun: fn _ ->
        :counters.add(req, 1, 1)
        flunk("request must not run")
      end
    ]

    for route <- ["chatgpt", "codex", "gpt", "openai", "xai", "grok", "x-ai", "openai-oauth"] do
      assert {:error, reason} = ModelCatalog.fetch(route, funs)
      assert reason != :ok
    end

    assert :counters.get(cred, 1) == 0
    assert :counters.get(req, 1) == 0
  end

  defp receipt(provider, owner, generation, token, account_id, opts \\ []) do
    %CredentialReceipt{
      provider: provider,
      owner: owner,
      access_token: token,
      account_id: account_id,
      generation: generation,
      source_generation: Keyword.get(opts, :source_generation),
      source_observed_at: Keyword.get(opts, :source_observed_at)
    }
  end

  defp json_ok(map) do
    {:ok,
     %{
       status: 200,
       body: Jason.encode!(map),
       headers: %{"content-type" => ["application/json"]}
     }}
  end

  defp assert_header(headers, name, value) do
    found =
      Enum.find_value(headers, fn {key, val} ->
        if String.downcase(key) == name, do: val
      end)

    assert found == value
  end
end
