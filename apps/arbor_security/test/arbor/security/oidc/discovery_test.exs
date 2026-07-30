defmodule Arbor.Security.OIDC.DiscoveryTest do
  @moduledoc """
  Security-owned endpoint trust: issuer shape validation (pre-IO) and the
  issuer-same-origin closed policy over a discovered document.

  Deterministic throughout — ephemeral loopback servers, no DNS, no egress.
  """

  use ExUnit.Case, async: true

  alias Arbor.Security.LoopbackHTTPServer, as: Server
  alias Arbor.Security.OIDC.Discovery

  @moduletag :fast

  describe "validate_issuer/2 rejects unsafe shapes without IO" do
    test "rejects non-binary, empty, oversize, and control-character issuers" do
      assert {:error, {:invalid_issuer, :binary_required}} = Discovery.validate_issuer(nil)
      assert {:error, {:invalid_issuer, :binary_required}} = Discovery.validate_issuer(:atom)
      assert {:error, {:invalid_issuer, :binary_required}} = Discovery.validate_issuer(123)
      assert {:error, {:invalid_issuer, :empty}} = Discovery.validate_issuer("")

      assert {:error, {:invalid_discovery_operation, :unsupported}} =
               Discovery.discover("https://idp.example", for: :unsupported)

      assert {:error, {:invalid_issuer, :too_long}} =
               Discovery.validate_issuer("https://a.example/" <> String.duplicate("p", 2_048))

      assert {:error, {:invalid_issuer, :unsafe_characters}} =
               Discovery.validate_issuer("https://a.example/\r\nHost: evil")

      assert {:error, {:invalid_issuer, :unsafe_characters}} =
               Discovery.validate_issuer("https://a.example/ path")
    end

    test "rejects a missing or disallowed scheme and honours allow_http" do
      assert {:error, {:invalid_issuer, :scheme_required}} =
               Discovery.validate_issuer("accounts.google.com")

      assert {:error, {:invalid_issuer, :scheme_not_allowed}} =
               Discovery.validate_issuer("ftp://idp.example")

      assert {:error, {:invalid_issuer, :scheme_not_allowed}} =
               Discovery.validate_issuer("http://idp.example")

      assert {:ok, "http://idp.example"} = Discovery.validate_issuer("http://idp.example", true)
    end

    test "rejects userinfo, a query, a fragment, dot segments, and empty path segments" do
      assert {:error, {:invalid_issuer, :userinfo_not_allowed}} =
               Discovery.validate_issuer("https://user:pw@idp.example")

      assert {:error, {:invalid_issuer, :query_not_allowed}} =
               Discovery.validate_issuer("https://idp.example?a=b")

      assert {:error, {:invalid_issuer, :fragment_not_allowed}} =
               Discovery.validate_issuer("https://idp.example#f")

      assert {:error, {:invalid_issuer, :dot_segment}} =
               Discovery.validate_issuer("https://idp.example/a/../b")

      assert {:error, {:invalid_issuer, :empty_path_segment}} =
               Discovery.validate_issuer("https://idp.example/a//b")
    end

    test "accepts ordinary issuers: root, trailing slash, path-bearing, port, IPv6" do
      assert {:ok, "https://accounts.google.com"} =
               Discovery.validate_issuer("https://accounts.google.com")

      # A trailing slash is normalized away, matching the historical join.
      assert {:ok, "https://idp.example"} = Discovery.validate_issuer("https://idp.example/")

      assert {:ok, "https://idp.example/tenant/1"} =
               Discovery.validate_issuer("https://idp.example/tenant/1")

      assert {:ok, "https://idp.example:8443/oidc"} =
               Discovery.validate_issuer("https://idp.example:8443/oidc")

      assert {:ok, "https://[::1]:9000"} = Discovery.validate_issuer("https://[::1]:9000", false)

      assert {:error, {:invalid_issuer, :invalid_port}} =
               Discovery.validate_issuer("https://idp.example:0")

      assert {:error, {:invalid_issuer, :invalid_port}} =
               Discovery.validate_issuer("https://idp.example:65536")
    end

    test "an invalid issuer never opens a socket" do
      # Points at a port with no listener: a transport error here would mean
      # validation leaked into IO.
      url = Server.closed_port_url()

      assert {:error, {:invalid_issuer, :scheme_not_allowed}} =
               Discovery.discover(url, allow_http: false)
    end
  end

  describe "option boundaries fail closed before any network I/O" do
    test "rejects malformed trusted_origins and endpoints inputs" do
      assert {:error, {:invalid_discovery_options, :duplicate_key}} =
               Discovery.discover("https://idp.example", %{
                 "allow_http" => false,
                 allow_http: true
               })

      assert {:error, {:invalid_discovery_options, :unknown_key}} =
               Discovery.discover("https://idp.example", %{unexpected: true})

      assert {:error, {:invalid_discovery_options, :invalid_opts}} =
               Discovery.discover("https://idp.example", [:allow_http, :bad])

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover("https://idp.example", trusted_origins: "https://evil.example")

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: ["bad\x00host", :atom, %{a: 1}]
               )

      assert {:error, {:invalid_discovery_options, :pinned_endpoint}} =
               Discovery.discover("https://idp.example",
                 endpoints: %{authorization_endpoint: "javascript:alert(1)"}
               )

      assert {:error, {:invalid_discovery_options, :pinned_endpoints}} =
               Discovery.discover("https://idp.example", endpoints: %{"not" => "allowed"})
    end

    test "normalizes proper keyword-style lists with atom or string keys" do
      assert {:ok, endpoints} =
               Discovery.discover(
                 "https://idp.example",
                 [
                   {"allow_http", false},
                   {"endpoints",
                    %{
                      "authorization_endpoint" => "https://idp.example/authorize",
                      "token_endpoint" => "https://idp.example/token"
                    }}
                 ]
               )

      assert endpoints.authorization_endpoint == "https://idp.example/authorize"
      assert endpoints.token_endpoint == "https://idp.example/token"
    end

    test "strictly validates trusted origin syntax and bounds" do
      max_origins = Enum.map(1..32, &"https://trusted#{&1}.example")

      assert {:ok, %{authorization_endpoint: nil, token_endpoint: nil}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: max_origins,
                 endpoints: %{}
               )

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: max_origins ++ ["https://trusted33.example"],
                 endpoints: %{}
               )

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: ["https://idp.example/path"],
                 endpoints: %{}
               )

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: ["https://user:pw@idp.example"],
                 endpoints: %{}
               )

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: ["https://idp.example?x=1"],
                 endpoints: %{}
               )

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: ["https://idp.example#fragment"],
                 endpoints: %{}
               )

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: ["https://idp.example:65536"],
                 endpoints: %{}
               )

      assert {:error, {:invalid_discovery_options, :trusted_origins}} =
               Discovery.discover(
                 "https://idp.example",
                 trusted_origins: ["https://idp.example path"],
                 endpoints: %{}
               )
    end
  end

  describe "discover/2 closed origin policy" do
    test "accepts same-origin endpoints" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "#{base}/authorize",
                 "token_endpoint" => "#{base}/token"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:ok, endpoints} = Discovery.discover(issuer, allow_http: true)
      assert endpoints.authorization_endpoint == "#{issuer}/authorize"
      assert endpoints.token_endpoint == "#{issuer}/token"
    end

    test "rejects a cross-origin authorization_endpoint" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "https://evil.example/authorize"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer, allow_http: true)
    end

    test "rejects a relative endpoint and a non-binary endpoint" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{"issuer" => base, "authorization_endpoint" => "/authorize"})}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer, allow_http: true)

      {issuer2, server2} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{"issuer" => base, "authorization_endpoint" => 42})}
          }
        end)

      on_exit(fn -> Server.stop(server2) end)

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer2, allow_http: true)
    end

    test "an untrusted-endpoint error never echoes the rejected URL" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "https://exfiltration-host.example/authorize"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      result = Discovery.discover(issuer, allow_http: true)
      refute inspect(result) =~ "exfiltration-host"
    end

    test "rejects a document whose issuer field disagrees, ignoring a trailing slash" do
      {issuer, server} =
        Server.start(%{
          "/.well-known/openid-configuration" =>
            {:respond, 200, [{"content-type", "application/json"}],
             Jason.encode!(%{"issuer" => "https://other.example"})}
        })

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:untrusted_endpoint, :issuer_mismatch}} =
               Discovery.discover(issuer, allow_http: true)

      {issuer2, server2} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base <> "/",
                 "token_endpoint" => "#{base}/token"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server2) end)

      assert {:ok, %{token_endpoint: _}} = Discovery.discover(issuer2, allow_http: true)
    end

    test "requires a string issuer in remotely fetched metadata" do
      for document <- [%{}, %{"issuer" => nil}] do
        {issuer, server} =
          Server.start(%{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}], Jason.encode!(document)}
          })

        on_exit(fn -> Server.stop(server) end)

        assert {:error, {:untrusted_endpoint, :issuer_mismatch}} =
                 Discovery.discover(issuer, allow_http: true)
      end
    end

    test "an omitted endpoint yields nil so the caller requires only what it needs" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "#{base}/authorize"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:ok, %{token_endpoint: nil, authorization_endpoint: authorize}} =
               Discovery.discover(issuer, allow_http: true)

      assert is_binary(authorize)
    end

    test "operation-scoped discovery ignores unrelated malformed sibling endpoints" do
      {issuer, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "authorization_endpoint" => "#{base}/authorize",
                   "token_endpoint" => "/not-origin"
                 })}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      assert {:ok, %{authorization_endpoint: authorize, token_endpoint: nil}} =
               Discovery.discover(issuer, allow_http: true, for: :authorize)

      assert authorize == "#{issuer}/authorize"

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer, allow_http: true, for: :token)
    end

    test "operation-scoped discovery rejects only the relevant malformed endpoint" do
      {issuer, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{
                   "issuer" => base,
                   "authorization_endpoint" => "#{base}/authorize",
                   "token_endpoint" => "/cross-origin-token"
                 })}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      expected_authorize = "#{issuer}/authorize"

      assert {:ok, %{authorization_endpoint: ^expected_authorize, token_endpoint: nil}} =
               Discovery.discover(issuer, allow_http: true, for: :authorize)

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer, allow_http: true, for: :token)
    end

    test "rejects discovered endpoints with invalid ports at the untrusted boundary" do
      {issuer, server} =
        Server.start(fn base ->
          %{
            "/.well-known/openid-configuration" =>
              {:respond, 200, [{"content-type", "application/json"}],
               Jason.encode!(%{
                 "issuer" => base,
                 "authorization_endpoint" => "#{base}:99999/authorize"
               })}
          }
        end)

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer, allow_http: true)
    end

    test "rejects pinned endpoints with invalid ports before network I/O" do
      assert {:error, {:invalid_discovery_options, :pinned_endpoint}} =
               Discovery.discover(
                 "https://idp.example",
                 endpoints: %{authorization_endpoint: "https://idp.example:99999/authorize"}
               )
    end

    test "an explicitly trusted origin widens the policy" do
      {foreign, foreign_server} = Server.start(%{})
      on_exit(fn -> Server.stop(foreign_server) end)

      # Two connections: the issuer is discovered once per assertion below.
      {issuer, server} =
        Server.start(
          fn base ->
            %{
              "/.well-known/openid-configuration" =>
                {:respond, 200, [{"content-type", "application/json"}],
                 Jason.encode!(%{"issuer" => base, "token_endpoint" => "#{foreign}/token"})}
            }
          end,
          connections: 2
        )

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer, allow_http: true)

      assert {:ok, %{token_endpoint: _}} =
               Discovery.discover(issuer, allow_http: true, trusted_origins: [foreign])
    end

    test "pinned endpoints skip discovery entirely but still face the origin gate" do
      # No server is started: a network fetch would fail with a transport error.
      issuer = "https://idp.example"

      assert {:ok, endpoints} =
               Discovery.discover(issuer,
                 endpoints: %{
                   authorization_endpoint: "https://idp.example/authorize",
                   token_endpoint: "https://idp.example/token"
                 }
               )

      assert endpoints.token_endpoint == "https://idp.example/token"

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Discovery.discover(issuer,
                 endpoints: %{token_endpoint: "https://evil.example/token"}
               )
    end

    test "rejects pinned endpoint key aliases and malformed endpoint urls" do
      assert {:error, {:invalid_discovery_options, :pinned_endpoints}} =
               Discovery.discover(
                 "https://idp.example",
                 endpoints: %{
                   "authorization_endpoint" => "https://idp.example/authorize",
                   authorization_endpoint: "https://idp.example/authorize-dup"
                 }
               )

      assert {:error, {:invalid_discovery_options, :pinned_endpoint}} =
               Discovery.discover(
                 "https://idp.example",
                 endpoints: %{authorization_endpoint: "ftp://idp.example/authorize"}
               )

      assert {:error, {:invalid_discovery_options, :pinned_endpoint}} =
               Discovery.discover(
                 "https://idp.example",
                 endpoints: %{authorization_endpoint: "https://user:pw@idp.example/authorize"}
               )

      assert {:error, {:invalid_discovery_options, :pinned_endpoint}} =
               Discovery.discover(
                 "https://idp.example",
                 endpoints: %{authorization_endpoint: "https://idp.example/authorize#frag"}
               )

      assert {:error, {:invalid_discovery_options, :pinned_endpoint}} =
               Discovery.discover(
                 "https://idp.example",
                 endpoints: %{authorization_endpoint: "https://idp.example/authorize path"}
               )
    end

    test "a malformed or non-object document is rejected" do
      {issuer, server} =
        Server.start(%{
          "/.well-known/openid-configuration" =>
            {:respond, 200, [{"content-type", "application/json"}], "{not json"}
        })

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:invalid_openid_config, :malformed_json}} =
               Discovery.discover(issuer, allow_http: true)

      {issuer2, server2} =
        Server.start(%{
          "/.well-known/openid-configuration" =>
            {:respond, 200, [{"content-type", "application/json"}], "[1,2,3]"}
        })

      on_exit(fn -> Server.stop(server2) end)

      assert {:error, {:invalid_openid_config, :object_required}} =
               Discovery.discover(issuer2, allow_http: true)
    end

    test "a non-200 discovery response surfaces the status" do
      {issuer, server} =
        Server.start(%{
          "/.well-known/openid-configuration" => {:respond, 500, [], "boom"}
        })

      on_exit(fn -> Server.stop(server) end)

      assert {:error, {:openid_config_fetch_failed, 500}} =
               Discovery.discover(issuer, allow_http: true)
    end
  end

  describe "discovery_url/1" do
    test "joins the well-known path without doubling a slash" do
      assert Discovery.discovery_url("https://idp.example") ==
               "https://idp.example/.well-known/openid-configuration"

      assert Discovery.discovery_url("https://idp.example/") ==
               "https://idp.example/.well-known/openid-configuration"
    end
  end
end
