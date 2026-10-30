defmodule OIDCStandaloneConsumer do
  @moduledoc "Real OIDC protocols and signatures without an Arbor product runtime."

  alias Arbor.Capabilities.OIDC
  alias Arbor.Common.OAuth.HttpClient
  alias Arbor.Common.OAuth.HttpClient.Pool
  alias OIDCStandaloneConsumer.HTTPFixture

  @canary "standalone-oidc-sensitive-canary"
  @client "standalone-client"
  @first_party ["arbor_capabilities_oidc", "arbor_oauth"]
  @modules [
    {OIDC, :arbor_capabilities_oidc},
    {Arbor.Capabilities.OIDC.AuthCodeFlow, :arbor_capabilities_oidc},
    {Arbor.Capabilities.OIDC.DeviceFlow, :arbor_capabilities_oidc},
    {Arbor.Capabilities.OIDC.Discovery, :arbor_capabilities_oidc},
    {Arbor.Capabilities.OIDC.TokenVerifier, :arbor_capabilities_oidc},
    {Arbor.Capabilities.OIDC.Verification, :arbor_capabilities_oidc},
    {HttpClient, :arbor_oauth},
    {Pool, :arbor_oauth}
  ]
  @forbidden_modules [
    Arbor.Contracts,
    Arbor.KernelRuntime,
    Arbor.Security,
    Arbor.Common,
    Arbor.Common.Config,
    Arbor.Security.OIDC,
    Arbor.Security.OIDC.JwksCache
  ]
  @providers [:req, :finch, :mint, :joken]

  def verify!(opts \\ []) do
    if Keyword.get(opts, :require_no_mix, false) do
      ensure(not Code.ensure_loaded?(Mix), "Mix code was present in the release")
      ensure(:code.lib_dir(:mix) == {:error, :bad_name}, "Mix metadata was present")
    end

    {:ok, _started} = Application.ensure_all_started(:arbor_capabilities_oidc)
    assert_passive!()
    assert_no_product!()

    providers =
      Enum.flat_map(@providers, fn app ->
        {:ok, started} = Application.ensure_all_started(app)
        started
      end)

    try do
      supervisor = start_pool!()

      try do
        protocols!()
        signatures!()
        endpoint_policy!()
        malformed_inputs!()
        transport!()
        assert_no_product!()
        assert_no_cache!()

        ensure(
          not List.keymember?(Application.started_applications(), :plug_crypto, 0),
          "nonce comparison started an unrelated provider application"
        )
      after
        Supervisor.stop(supervisor)
      end

      ensure(Process.whereis(Pool.name()) == nil, "pool survived its supervisor")

      {_result, absent} =
        HTTPFixture.run(%{}, fn base ->
          ensure(
            match?({:error, _}, OIDC.discover(base, allow_http: true)),
            "missing host pool did not deny discovery"
          )
        end)

      ensure(absent.accepted == 0, "unavailable pool opened a socket")

      restarted = start_pool!()

      try do
        {_result, report} =
          HTTPFixture.run(&discovery_routes/1, fn base ->
            ensure(
              match?({:ok, _}, OIDC.discover(base, allow_http: true)),
              "restarted pool did not serve discovery"
            )
          end)

        ensure(report.accepted == 1, "restarted discovery did not execute HTTP")
      after
        Supervisor.stop(restarted)
      end
    after
      Enum.each(Enum.reverse(providers), &Application.stop/1)
    end

    :ok = Application.stop(:arbor_capabilities_oidc)
    :ok = Application.stop(:arbor_oauth)
    {:ok, _restarted} = Application.ensure_all_started(:arbor_capabilities_oidc)
    assert_passive!()
    assert_no_product!()

    paths =
      Map.new(@modules, fn {module, owner} ->
        ensure(:application.get_application(module) == {:ok, owner}, "wrong module owner")
        {Atom.to_string(module), List.to_string(:code.which(module))}
      end)

    %{
      package: "arbor_capabilities_oidc",
      version: Application.spec(:arbor_capabilities_oidc, :vsn) |> List.to_string(),
      checks: [
        "passive exact two-package closure without a JWKS cache singleton",
        "explicit provider and proven Finch subtree ownership; stop/restart",
        "discovery plus exact PKCE, nonce, code, device, poll and refresh wire fields",
        "real uncached ES256 and RS256 HTTP/JWKS signatures and key rotation",
        "opaque prepared verification and sensitive Inspect redaction",
        "signature, key-id, issuer, audience, expiration, azp and nonce denials",
        "closed endpoint origins before credential POST or JWKS fetch",
        "explicit trusted origins and pinned endpoints retain their policy",
        "invalid metadata and key material cannot yield verified claims",
        "OIDC response/header bounds, encoding refusal and whole-request deadline",
        "status-only errors with no redirect or retry"
      ],
      code_paths: paths,
      compiled_applications: compiled_applications(),
      loaded_applications: app_names(Application.loaded_applications()),
      started_applications: app_names(Application.started_applications()),
      mix_available: Code.ensure_loaded?(Mix)
    }
  end

  defp assert_passive! do
    Enum.each([:arbor_capabilities_oidc, :arbor_oauth], fn app ->
      ensure(Application.spec(app, :mod) in [nil, []], "leaf library has an application callback")
    end)

    started = app_names(Application.started_applications())

    ensure(
      Enum.all?(["req", "finch", "mint", "joken", "jose", "plug_crypto"], &(&1 not in started)),
      "leaf loading auto-started providers"
    )

    ensure(Process.whereis(Pool.name()) == nil, "passive leaf started an HTTP pool")
    assert_no_cache!()
  end

  defp assert_no_cache! do
    ensure(:ets.whereis(:arbor_oidc_jwks_cache) == :undefined, "a shared JWKS cache appeared")
    ensure(Process.whereis(Arbor.Security.OIDC.JwksCache) == nil, "a host JWKS cache appeared")
    ensure(not Code.ensure_loaded?(Arbor.Capabilities.OIDC.JwksCache), "leaf cache code appeared")
  end

  defp assert_no_product! do
    for apps <- [Application.loaded_applications(), Application.started_applications()] do
      first_party = apps |> app_names() |> Enum.filter(&String.starts_with?(&1, "arbor_"))
      ensure(first_party == @first_party, "unexpected loaded or started first-party closure")
    end

    ensure(Enum.all?(@forbidden_modules, &(not Code.ensure_loaded?(&1))), "product module loaded")
    ensure(compiled_applications() == @first_party, "unexpected compiled first-party closure")
  end

  defp protocols! do
    key = key("ES256", "protocol-key")
    nonce = @canary <> ":nonce"

    {wire, report} =
      HTTPFixture.run(
        fn base ->
          token = signed(key, claims(base, %{"nonce" => nonce}))
          token_body = Jason.encode!(%{"id_token" => token, "access_token" => @canary})

          Map.merge(discovery_routes(base), %{
            "/jwks" => {:reply, 200, [], Jason.encode!(%{"keys" => [key.public]})},
            "/code" => {:reply, 200, [], token_body},
            "/device" =>
              {:reply, 200, [],
               Jason.encode!(%{
                 "device_code" => @canary <> ":device",
                 "user_code" => "OWNED",
                 "verification_uri" => base <> "/verify",
                 "expires_in" => 30,
                 "interval" => 1
               })}
          })
        end,
        fn base ->
          config = provider(base)
          state = @canary <> ":state"
          redirect = base <> "/callback"

          {:ok, url, verifier} =
            OIDC.build_authorize_url(config, redirect, state,
              scopes: ["openid", "email"],
              nonce: nonce
            )

          challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
          ensure(byte_size(verifier) == 43, "PKCE verifier shape changed")

          ensure(
            URI.decode_query(URI.parse(url).query) == %{
              "response_type" => "code",
              "client_id" => @client,
              "redirect_uri" => redirect,
              "scope" => "openid email",
              "state" => state,
              "nonce" => nonce,
              "code_challenge" => challenge,
              "code_challenge_method" => "S256"
            },
            "OIDC authorization query changed"
          )

          {generated_verifier, generated_challenge} = OIDC.generate_pkce()

          ensure(
            generated_challenge ==
              Base.url_encode64(:crypto.hash(:sha256, generated_verifier), padding: false),
            "public PKCE generator did not bind its verifier"
          )

          ensure(OIDC.generate_state() != OIDC.generate_state(), "state generator repeated")
          ensure(OIDC.generate_nonce() != OIDC.generate_nonce(), "nonce generator repeated")
          code = @canary <> ":code"
          {:ok, tokens} = OIDC.exchange_code(config, code, redirect, verifier)
          ensure(is_binary(tokens["id_token"]), "code exchange returned no ID token")

          ensure(
            match?(
              {:ok, _},
              OIDC.verify(tokens["id_token"], Map.put(config, :expected_nonce, nonce))
            ),
            "exchanged ID token was not actually verified"
          )

          {:ok, device} = OIDC.start_device_flow(config)
          ensure(device["device_code"] == @canary <> ":device", "device start failed")
          ensure(token_result?(OIDC.poll_device_flow(config, device)), "device poll failed")
          refresh = @canary <> ":refresh"

          ensure(
            token_result?(OIDC.refresh_device_flow(config, refresh)),
            "device refresh failed"
          )

          %{verifier: verifier, redirect: redirect, code: code, refresh: refresh}
        end
      )

    posts = Enum.filter(report.requests, &(&1.method == "POST"))
    ensure(length(posts) == 4, "OIDC did not execute exactly four protocol POSTs")

    expected = [
      {"/code",
       %{
         "grant_type" => "authorization_code",
         "client_id" => @client,
         "client_secret" => @canary <> ":secret",
         "code" => wire.code,
         "redirect_uri" => wire.redirect,
         "code_verifier" => wire.verifier
       }},
      {"/device",
       %{
         "client_id" => @client,
         "client_secret" => @canary <> ":secret",
         "scope" => "openid email"
       }},
      {"/code",
       %{
         "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
         "client_id" => @client,
         "client_secret" => @canary <> ":secret",
         "device_code" => @canary <> ":device"
       }},
      {"/code",
       %{
         "grant_type" => "refresh_token",
         "client_id" => @client,
         "client_secret" => @canary <> ":secret",
         "refresh_token" => wire.refresh
       }}
    ]

    ensure(Enum.map(posts, &{&1.path, &1.form}) == expected, "OIDC protocol wire fields changed")

    ensure(
      Enum.count(report.requests, &(&1.path == "/.well-known/openid-configuration")) == 6,
      "protocols did not use actual discovery"
    )

    ensure(
      Enum.count(report.requests, &(&1.path == "/jwks")) == 1,
      "exchanged token did not use actual JWKS"
    )
  end

  defp signatures! do
    es = key("ES256", "es-key")
    rsa = key("RS256", "rsa-key")

    # This unregistered, fixture-owned Agent controls the remote server's
    # response. It is not a verifier cache and contains no private key or token.
    {:ok, remote} = Agent.start_link(fn -> %{keys: [es.public], fetches: 0} end)

    try do
      {_result, report} =
        HTTPFixture.run(
          fn base ->
            Map.put(discovery_routes(base), "/jwks", fn _request ->
              keys =
                Agent.get_and_update(remote, fn state ->
                  {state.keys, %{state | fetches: state.fetches + 1}}
                end)

              {:reply, 200, [], Jason.encode!(%{"keys" => keys})}
            end)
          end,
          fn base ->
            config = provider(base)
            old_token = signed(es, claims(base))
            new_token = signed(rsa, claims(base))

            ensure(
              match?({:ok, %{"sub" => "portable-subject"}}, OIDC.verify(old_token, config)),
              "initial real HTTP/JWKS signature verification failed"
            )

            ensure(Agent.get(remote, & &1.fetches) == 1, "initial token did not fetch JWKS once")

            :ok = Agent.update(remote, &%{&1 | keys: [rsa.public]})

            ensure(
              match?({:ok, %{"sub" => "portable-subject"}}, OIDC.verify(new_token, config)),
              "rotated key was not accepted from the same HTTP/JWKS URI"
            )

            ensure(
              Agent.get(remote, & &1.fetches) == 2,
              "rotation reused previously fetched JWKS"
            )

            ensure(
              OIDC.verify(old_token, config) == {:error, {:kid_not_found, "es-key"}},
              "removed old key remained acceptable after remote rotation"
            )

            ensure(
              Agent.get(remote, & &1.fetches) == 3,
              "removed-key denial did not fetch fresh JWKS"
            )
          end
        )

      ensure(
        report.accepted == 6 and Enum.all?(report.requests, &(&1.method == "GET")),
        "rotation did not execute exactly six HTTP GETs"
      )

      expected_paths =
        List.duplicate(["/.well-known/openid-configuration", "/jwks"], 3) |> List.flatten()

      ensure(
        Enum.map(report.requests, & &1.path) == expected_paths,
        "rotation did not rediscover and fetch the same JWKS URI for each verification"
      )
    after
      if Process.alive?(remote), do: Agent.stop(remote, :normal, 1_000)
    end

    issuer = "https://owned.invalid"
    config = provider(issuer) |> Map.put(:allow_http, false) |> Map.put(:clock_skew_seconds, 0)
    baseline = claims(issuer, %{"nonce" => @canary <> ":nonce"})
    token = signed(es, baseline)

    {:ok, context} =
      OIDC.prepare_verification(token, Map.put(config, :expected_nonce, @canary <> ":nonce"))

    shown = inspect(context)

    ensure(
      String.contains?(shown, "REDACTED") and not String.contains?(shown, @canary) and
        not String.contains?(shown, token) and not String.contains?(shown, issuer) and
        not String.contains?(shown, "es-key") and not String.contains?(shown, @client),
      "prepared verification inspection disclosed token or provider data"
    )

    jwks = %{"keys" => [es.public]}
    ensure(match?({:ok, _}, OIDC.verify_prepared(context, jwks)), "prepared verification failed")

    ensure(
      match?({:ok, _}, OIDC.decode_unverified(tampered(token))),
      "inspection-only JWT decoding changed"
    )

    ensure(
      denied?(fn -> OIDC.verify_prepared(token, jwks) end),
      "raw token became a prepared context"
    )

    ensure(
      denied?(fn -> OIDC.verify_prepared(context, %{"keys" => []}) end),
      "empty JWKS yielded claims"
    )

    ensure(
      denied?(fn -> OIDC.verify_prepared(context, %{"keys" => [nil]}) end),
      "malformed key material yielded claims"
    )

    ensure(
      denied?(fn ->
        OIDC.verify_prepared(context, %{"keys" => [%{"kid" => "es-key", "alg" => "invalid"}]})
      end),
      "invalid JWKS algorithm yielded claims"
    )

    ensure(
      denied?(fn -> OIDC.verify_prepared(context, %{"keys" => [rsa.public]}) end),
      "unknown key id yielded claims"
    )

    {:ok, tampered_context} = OIDC.prepare_verification(tampered(token), config)

    ensure(
      denied?(fn -> OIDC.verify_prepared(tampered_context, jwks) end),
      "tampered signature yielded claims"
    )

    variants = [
      {%{"iss" => "https://another.invalid"}, config},
      {%{"aud" => "another-client"}, config},
      {%{"exp" => System.os_time(:second) - 3_600}, config},
      {%{"exp" => "later"}, config},
      {%{"nbf" => System.os_time(:second) + 3_600}, config},
      {%{"iat" => System.os_time(:second) + 3_600}, config},
      {%{"aud" => [@client, "other"]}, config},
      {%{"azp" => "other"}, config},
      {%{"nonce" => "wrong"}, Map.put(config, :expected_nonce, @canary <> ":nonce")},
      {%{}, Map.put(config, :expected_nonce, @canary <> ":missing")}
    ]

    Enum.each(variants, fn {overrides, expected} ->
      {:ok, prepared} = OIDC.prepare_verification(signed(es, claims(issuer, overrides)), expected)

      ensure(
        denied?(fn -> OIDC.verify_prepared(prepared, jwks) end),
        "invalid JWT claims were admitted"
      )
    end)

    {:ok, multi} =
      OIDC.prepare_verification(
        signed(
          es,
          claims(
            issuer,
            %{"aud" => [@client, "other"], "azp" => @client}
          )
        ),
        config
      )

    ensure(
      match?({:ok, _}, OIDC.verify_prepared(multi, jwks)),
      "valid authorized party was refused"
    )
  end

  defp endpoint_policy! do
    key = key("ES256", "policy-key")

    {_result, foreign} =
      HTTPFixture.run(%{"/steal" => {:reply, 200, [], "{}"}}, fn foreign_base ->
        {_result, issuer} =
          HTTPFixture.run(
            fn base ->
              document = %{
                "issuer" => base,
                "authorization_endpoint" => foreign_base <> "/steal",
                "token_endpoint" => foreign_base <> "/steal",
                "device_authorization_endpoint" => foreign_base <> "/steal",
                "jwks_uri" => foreign_base <> "/steal"
              }

              %{"/.well-known/openid-configuration" => {:reply, 200, [], Jason.encode!(document)}}
            end,
            fn base ->
              config = provider(base)
              {verifier, _} = OIDC.generate_pkce()

              for operation <- [
                    fn -> OIDC.build_authorize_url(config, base <> "/callback", @canary, []) end,
                    fn -> OIDC.exchange_code(config, @canary, base <> "/callback", verifier) end,
                    fn -> OIDC.start_device_flow(config) end,
                    fn -> OIDC.verify(signed(key, claims(base)), config) end
                  ] do
                ensure(
                  operation.() == {:error, {:untrusted_endpoint, :issuer_origin_mismatch}},
                  "untrusted endpoint was admitted or reflected"
                )
              end
            end
          )

        ensure(
          issuer.accepted == 4 and Enum.all?(issuer.requests, &(&1.method == "GET")),
          "endpoint policy did not reject before credential POST"
        )
      end)

    ensure(foreign.accepted == 0, "credentials or JWKS request crossed an untrusted origin")

    {_result, trusted} =
      HTTPFixture.run(
        %{"/jwks" => {:reply, 200, [], Jason.encode!(%{"keys" => [key.public]})}},
        fn trusted_base ->
          {_result, issuer} =
            HTTPFixture.run(
              fn base ->
                %{
                  "/.well-known/openid-configuration" =>
                    {:reply, 200, [],
                     Jason.encode!(%{
                       "issuer" => base,
                       "jwks_uri" => trusted_base <> "/jwks"
                     })}
                }
              end,
              fn base ->
                ensure(
                  match?(
                    {:ok, _},
                    OIDC.verify(
                      signed(key, claims(base)),
                      Map.put(provider(base), :trusted_origins, [trusted_base])
                    )
                  ),
                  "explicit trusted origin failed"
                )
              end
            )

          ensure(issuer.accepted == 1, "trusted origin skipped issuer discovery")
        end
      )

    ensure(trusted.accepted == 1, "explicit trusted JWKS origin was not fetched")

    {_result, pinned} =
      HTTPFixture.run(
        %{"/jwks" => {:reply, 200, [], Jason.encode!(%{"keys" => [key.public]})}},
        fn base ->
          ensure(
            match?(
              {:ok, _},
              OIDC.verify(
                signed(key, claims(base)),
                Map.put(provider(base), :endpoints, %{jwks_uri: base <> "/jwks"})
              )
            ),
            "pinned same-origin JWKS failed"
          )
        end
      )

    ensure(
      pinned.accepted == 1 and hd(pinned.requests).path == "/jwks",
      "pinned endpoints did not skip discovery"
    )
  end

  defp malformed_inputs! do
    {_result, untouched} =
      HTTPFixture.run(%{}, fn base ->
        ensure(
          OIDC.validate_issuer(base, true) == {:ok, base},
          "public issuer validation changed"
        )

        ensure(
          OIDC.discovery_url(base) == base <> "/.well-known/openid-configuration",
          "public discovery URL changed"
        )

        for issuer <- [nil, "", base <> "/../escape", base <> "?secret=hidden"] do
          ensure(
            match?({:error, _}, OIDC.discover(issuer, allow_http: true)),
            "unsafe issuer admitted"
          )
        end

        ensure(match?({:error, _}, OIDC.discover(base)), "HTTP issuer admitted without opt-in")

        ensure(
          match?(
            {:error, _},
            OIDC.discover(base,
              allow_http: true,
              endpoints: %{token_endpoint: "http://user:secret@127.0.0.1/steal"}
            )
          ),
          "userinfo endpoint admitted"
        )

        ensure(
          match?({:error, _}, OIDC.discover(base, allow_http: true, unexpected: true)),
          "unknown discovery option admitted"
        )
      end)

    ensure(untouched.accepted == 0, "invalid discovery input opened a socket")

    Enum.each(["[]", "not-json", "{}"], fn body ->
      {_result, report} =
        HTTPFixture.run(
          %{"/.well-known/openid-configuration" => {:reply, 200, [], body}},
          fn base ->
            ensure(
              match?({:error, _}, OIDC.discover(base, allow_http: true)),
              "invalid discovery document admitted"
            )
          end
        )

      ensure(report.accepted == 1, "malformed discovery probe did not execute HTTP")
    end)

    Enum.each(["[]", "not-json", Jason.encode!(%{"keys" => []})], fn body ->
      {_result, report} =
        HTTPFixture.run(%{"/jwks" => {:reply, 200, [], body}}, fn base ->
          ensure(
            match?(
              {:error, _},
              OIDC.fetch_jwks_uncached(
                Map.put(provider(base), :endpoints, %{jwks_uri: base <> "/jwks"})
              )
            ),
            "invalid JWKS document was admitted"
          )
        end)

      ensure(report.accepted == 1, "malformed JWKS probe did not execute HTTP")
    end)
  end

  defp transport! do
    Enum.each([[], [{"content-length", Integer.to_string(8_192 * 128)}]], fn headers ->
      {result, report} =
        exchange_http({:body, headers, String.duplicate("b", 8_192), 128, 5}, 8_192)

      ensure(
        result == {:error, {:response_bytes_exceeded, 8_192}},
        "OIDC body budget was not enforced"
      )

      ensure(
        not report.completed? and report.chunks_sent < 128,
        "OIDC fully buffered an oversized body"
      )
    end)

    {result, report} =
      exchange_http({:header, String.duplicate("h", 1_024), 128, 5}, 65_536, 2_000)

    ensure(
      match?({:error, {:http_request_failed, {:transport_error, _}}}, result),
      "OIDC parser header bound was not enforced"
    )

    ensure(not report.completed? and report.chunks_sent < 128, "OIDC buffered unbounded headers")

    Enum.each(
      [[{"x-big", String.duplicate("h", 4_097)}], Enum.map(1..65, &{"x-#{&1}", "v"})],
      fn headers ->
        {result, _report} = exchange_http({:reply, 200, headers, ""})

        ensure(
          result == {:error, {:invalid_response, :invalid_headers}},
          "OIDC header shape was not bounded"
        )
      end
    )

    {result, _report} =
      exchange_http({:reply, 200, [{"content-encoding", "gzip"}], :zlib.gzip(@canary)})

    ensure(
      result == {:error, {:invalid_response, :non_identity_content_encoding}},
      "OIDC accepted compressed response"
    )

    started = System.monotonic_time(:millisecond)

    {result, report} =
      exchange_http({:body, [], String.duplicate("d", 128), 100, 25}, 65_536, 150)

    ensure(
      result == {:error, {:http_request_failed, {:timeout, 150}}},
      "OIDC chunks reset the deadline"
    )

    ensure(
      System.monotonic_time(:millisecond) - started < 1_000 and not report.completed? and
        report.chunks_sent < 100,
      "OIDC deadline did not close its stream"
    )

    for status <- [302, 400, 503] do
      {_result, report} =
        HTTPFixture.run(
          fn base ->
            %{
              "/token" => {:reply, status, [{"location", base <> "/redirected"}], @canary},
              "/redirected" => {:reply, 200, [], @canary}
            }
          end,
          fn base ->
            result = exchange(base)

            ensure(
              result == {:error, {:token_exchange_failed, status}} and
                not String.contains?(inspect(result), @canary),
              "OIDC reflected provider body or followed redirect"
            )
          end
        )

      ensure(report.accepted == 1, "OIDC retried or followed a redirect")
    end

    {_result, discovery_bytes} =
      HTTPFixture.run(
        %{
          "/.well-known/openid-configuration" => {:body, [], String.duplicate("m", 8_192), 128, 5}
        },
        fn base ->
          ensure(
            OIDC.discover(base, allow_http: true, max_response_bytes: 8_192) ==
              {:error, {:response_bytes_exceeded, 8_192}},
            "discovery response byte cap changed"
          )
        end
      )

    ensure(
      not discovery_bytes.completed? and discovery_bytes.chunks_sent < 128,
      "discovery metadata was fully buffered"
    )

    {_result, discovery_deadline} =
      HTTPFixture.run(
        %{
          "/.well-known/openid-configuration" => {:body, [], String.duplicate("m", 128), 100, 25}
        },
        fn base ->
          ensure(
            OIDC.discover(base, allow_http: true, timeout_ms: 150) == {:error, {:timeout, 150}},
            "discovery chunks reset the deadline"
          )
        end
      )

    ensure(
      not discovery_deadline.completed? and discovery_deadline.chunks_sent < 100,
      "discovery deadline did not close the stream"
    )

    {_result, device_error} =
      HTTPFixture.run(
        %{
          "/token" =>
            {:reply, 400, [],
             Jason.encode!(%{
               "error" => "invalid_request",
               "error_description" => @canary
             })}
        },
        fn base ->
          config = Map.put(provider(base), :endpoints, %{token_endpoint: base <> "/token"})

          ensure(
            OIDC.poll_device_flow(config, %{
              "device_code" => @canary,
              "interval" => 1,
              "expires_in" => 30
            }) ==
              {:error, {:token_request_failed, 400}},
            "device error reflected provider response material"
          )
        end
      )

    ensure(device_error.accepted == 1, "device error probe retried")

    {_result, oversized} =
      HTTPFixture.run(%{"/jwks" => {:body, [], String.duplicate("j", 8_192), 128, 5}}, fn base ->
        ensure(
          OIDC.fetch_jwks_uncached(
            Map.put(provider(base), :endpoints, %{jwks_uri: base <> "/jwks"})
          ) ==
            {:error, {:response_bytes_exceeded, 262_144}},
          "JWKS response byte cap changed"
        )
      end)

    ensure(
      not oversized.completed? and oversized.chunks_sent < 128,
      "JWKS body was fully buffered"
    )
  end

  defp discovery_routes(base) do
    %{
      "/.well-known/openid-configuration" =>
        {:reply, 200, [],
         Jason.encode!(%{
           "issuer" => base,
           "authorization_endpoint" => base <> "/authorize",
           "token_endpoint" => base <> "/code",
           "device_authorization_endpoint" => base <> "/device",
           "jwks_uri" => base <> "/jwks"
         })}
    }
  end

  defp provider(issuer),
    do: %{
      issuer: issuer,
      client_id: @client,
      client_secret: @canary <> ":secret",
      allow_http: true,
      scopes: ["openid", "email"],
      timeout_ms: 1_000,
      discovery_timeout_ms: 1_000,
      poll_timeout_ms: 2_000
    }

  defp exchange_http(response, maximum \\ 65_536, timeout \\ 1_000) do
    HTTPFixture.run(%{"/token" => response}, &exchange(&1, maximum, timeout))
  end

  defp exchange(base, maximum \\ 65_536, timeout \\ 1_000) do
    {verifier, _} = OIDC.generate_pkce()

    config =
      provider(base)
      |> Map.put(:endpoints, %{token_endpoint: base <> "/token"})
      |> Map.put(:max_response_bytes, maximum)
      |> Map.put(:timeout_ms, timeout)

    OIDC.exchange_code(config, @canary, base <> "/callback", verifier)
  end

  defp key(algorithm, kid) do
    jwk =
      case algorithm do
        "ES256" -> JOSE.JWK.generate_key({:ec, :secp256r1})
        "RS256" -> JOSE.JWK.generate_key({:rsa, 2_048})
      end

    {_, private} = JOSE.JWK.to_map(jwk)
    {_, public} = JOSE.JWK.to_public_map(jwk)

    %{
      signer: Joken.Signer.create(algorithm, private, %{"kid" => kid}),
      public: Map.merge(public, %{"alg" => algorithm, "kid" => kid})
    }
  end

  defp claims(issuer, overrides \\ %{}),
    do:
      Map.merge(
        %{
          "iss" => issuer,
          "sub" => "portable-subject",
          "aud" => @client,
          "exp" => System.os_time(:second) + 3_600,
          "iat" => System.os_time(:second)
        },
        overrides
      )

  defp signed(key, claims) do
    {:ok, token} = Joken.Signer.sign(claims, key.signer)
    token
  end

  defp tampered(token) do
    [header, payload, signature] = String.split(token, ".")
    {:ok, <<first, rest::binary>>} = Base.url_decode64(signature, padding: false)

    Enum.join(
      [
        header,
        payload,
        Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
      ],
      "."
    )
  end

  defp denied?(operation), do: match?({:error, _}, operation.())

  defp token_result?({:ok, tokens}), do: is_binary(tokens["id_token"])
  defp token_result?(_result), do: false

  defp start_pool! do
    ensure(Process.whereis(Pool.name()) == nil, "pool name was already occupied")
    {:ok, supervisor} = Supervisor.start_link([Pool], strategy: :one_for_one)

    try do
      pool_supervisor =
        case supervisor_children!(supervisor) do
          [{Pool, pid, _type, _modules}] when is_pid(pid) -> pid
          _ -> raise "OIDC qualification failed: pool is not the host's exact child"
        end

      # Finch's child spec defaults to :worker despite returning a supervisor.
      ensure(
        Process.alive?(pool_supervisor) and
          :proc_lib.translate_initial_call(pool_supervisor) == {:supervisor, Finch, 1},
        "pool child is not a live Finch supervisor"
      )

      registered = Process.whereis(Pool.name())

      ensure(
        is_pid(registered) and Process.alive?(registered) and
          supervised_pid?([{pool_supervisor, 0}], registered, 32) and
          Process.whereis(Pool.name()) == registered and Process.alive?(pool_supervisor),
        "registered pool is not owned by the host's Finch supervisor"
      )

      supervisor
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        stop_failed_pool!(supervisor)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp supervised_pid?([], _target, _remaining), do: false
  defp supervised_pid?(_pending, _target, remaining) when remaining <= 0, do: false

  defp supervised_pid?([{supervisor, depth} | pending], target, remaining) do
    children = supervisor_children!(supervisor)
    ensure(length(children) < remaining, "pool supervision tree exceeded its node bound")

    if Enum.any?(children, fn {_id, pid, _type, _modules} -> pid == target end) do
      Process.alive?(target)
    else
      descendants =
        for {_id, pid, :supervisor, _modules} <- children,
            is_pid(pid),
            depth < 4,
            do: {pid, depth + 1}

      supervised_pid?(pending ++ descendants, target, remaining - length(children) - 1)
    end
  end

  defp supervisor_children!(supervisor) do
    children = GenServer.call(supervisor, :which_children, 1_000)
    ensure(is_list(children), "pool child did not expose supervisor children")
    children
  end

  defp stop_failed_pool!(supervisor) do
    # Only this freshly created, locally owned supervisor may be stopped here.
    Supervisor.stop(supervisor, :normal, 10_000)
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp app_names(apps),
    do: apps |> Enum.map(fn {app, _, _} -> Atom.to_string(app) end) |> Enum.sort()

  defp compiled_applications do
    :code.get_path()
    |> Enum.map(&Path.basename(Path.dirname(List.to_string(&1))))
    |> Enum.filter(&String.starts_with?(&1, "arbor_"))
    |> Enum.map(&String.replace(&1, ~r/-\d.*$/, ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ensure(true, _label), do: :ok
  defp ensure(false, label), do: raise("OIDC qualification failed: " <> label)
end
