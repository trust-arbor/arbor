defmodule Arbor.Common.OAuth.AuthCodeTest do
  @moduledoc """
  Focused, fully deterministic tests for the provider-neutral OAuth primitive.

  No network: every case is either pure, or uses a stub adapter, or points at a
  port bound-then-closed on loopback. Nothing here exposes a token, a token
  hash, a raw provider body, an account id, or a credential path.
  """

  use ExUnit.Case, async: true

  alias Arbor.Common.OAuth.AuthCode
  alias Arbor.Common.OAuth.HttpClient.Response

  @moduletag :fast

  @endpoint "https://idp.example/authorize"
  @token_endpoint "https://idp.example/token"
  @schema %{"id_token" => :required_string, "expires_in" => :optional_integer}

  defmodule StubClient do
    @moduledoc false
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(_request) do
      case Process.get({__MODULE__, self()}) do
        nil -> {:error, {:transport_error, :other}}
        fun -> fun.()
      end
    end

    def stub(fun), do: Process.put({__MODULE__, self()}, fun)
    def clear, do: Process.delete({__MODULE__, self()})
  end

  defp stub(fun) do
    StubClient.stub(fun)
    on_exit(fn -> StubClient.clear() end)
    StubClient
  end

  defp base_exchange(overrides) do
    Keyword.merge(
      [
        token_endpoint: @token_endpoint,
        client_id: "client-1",
        code: "code-1",
        redirect_uri: "https://app.example/cb",
        code_verifier: "verifier-1",
        response_schema: @schema
      ],
      overrides
    )
  end

  defp base_authorize(overrides) do
    Keyword.merge(
      [
        authorization_endpoint: @endpoint,
        client_id: "client-1",
        redirect_uri: "https://app.example/cb",
        state: "state-1",
        code_challenge: "challenge-1",
        scopes: ["openid", "email"]
      ],
      overrides
    )
  end

  defp dead_endpoint do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(listen)
    :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}/token"
  end

  describe "generate_pkce/0" do
    test "returns a 43-char verifier and its S256 challenge" do
      {verifier, challenge} = AuthCode.generate_pkce()

      assert String.length(verifier) == 43
      assert challenge == Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
      assert verifier != challenge
    end

    test "generates a unique pair per call" do
      {v1, c1} = AuthCode.generate_pkce()
      {v2, c2} = AuthCode.generate_pkce()

      assert v1 != v2
      assert c1 != c2
    end
  end

  describe "generate_state/0" do
    test "returns a non-empty, unique base64url value" do
      s1 = AuthCode.generate_state()
      s2 = AuthCode.generate_state()

      assert byte_size(s1) > 0
      assert s1 != s2
    end
  end

  describe "verify_state/2" do
    test "accepts a match" do
      state = AuthCode.generate_state()
      assert :ok = AuthCode.verify_state(state, state)
    end

    test "rejects a mismatch, a length mismatch, and non-binary input without raising" do
      assert {:error, :state_mismatch} = AuthCode.verify_state("abc", "abd")
      assert {:error, :state_mismatch} = AuthCode.verify_state("abc", "abcd")
      assert {:error, :state_mismatch} = AuthCode.verify_state(nil, "abc")
      assert {:error, :state_mismatch} = AuthCode.verify_state("abc", nil)
      assert {:error, :state_mismatch} = AuthCode.verify_state("", "")
      assert {:error, :state_mismatch} = AuthCode.verify_state({:tuple}, "abc")
      assert {:error, :state_mismatch} = AuthCode.verify_state(123, 123)
    end
  end

  describe "build_authorize_url/1 composition" do
    test "appends to an endpoint with no query" do
      assert {:ok, url} = AuthCode.build_authorize_url(base_authorize([]))

      assert String.starts_with?(url, "https://idp.example/authorize?")
      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert query["response_type"] == "code"
      assert query["client_id"] == "client-1"
      assert query["redirect_uri"] == "https://app.example/cb"
      assert query["state"] == "state-1"
      assert query["code_challenge"] == "challenge-1"
      assert query["code_challenge_method"] == "S256"
      assert query["scope"] == "openid email"
    end

    test "preserves an existing benign query verbatim instead of corrupting it" do
      endpoint = "https://idp.example/authorize?tenant=acme&p=B2C_1_signup"

      assert {:ok, url} =
               AuthCode.build_authorize_url(base_authorize(authorization_endpoint: endpoint))

      # The parent produced "...?tenant=acme?response_type=code" — a corrupt URL.
      assert url =~ "?tenant=acme&p=B2C_1_signup&"
      refute url =~ "signup?"

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["tenant"] == "acme"
      assert query["p"] == "B2C_1_signup"
      assert query["response_type"] == "code"
    end

    test "rejects a reserved OAuth key already planted in the endpoint query" do
      for key <- AuthCode.reserved_query_keys() do
        endpoint = "https://idp.example/authorize?#{key}=https%3A%2F%2Fevil.example%2Fcb"

        assert {:error, {:invalid_endpoint, {:reserved_query_key, ^key}}} =
                 AuthCode.build_authorize_url(base_authorize(authorization_endpoint: endpoint))
      end
    end

    test "rejects a fragment, a bad scheme, a missing host, and userinfo" do
      assert {:error, {:invalid_endpoint, :fragment_not_allowed}} =
               AuthCode.build_authorize_url(
                 base_authorize(authorization_endpoint: "https://idp.example/authorize#frag")
               )

      assert {:error, {:invalid_endpoint, :scheme_not_allowed}} =
               AuthCode.build_authorize_url(
                 base_authorize(authorization_endpoint: "ftp://idp.example/authorize")
               )

      assert {:error, {:invalid_endpoint, :scheme_not_allowed}} =
               AuthCode.build_authorize_url(
                 base_authorize(authorization_endpoint: "http://idp.example/authorize")
               )

      assert {:error, {:invalid_endpoint, :userinfo_not_allowed}} =
               AuthCode.build_authorize_url(
                 base_authorize(authorization_endpoint: "https://u:p@idp.example/authorize")
               )

      assert {:error, {:invalid_endpoint, :binary_required}} =
               AuthCode.build_authorize_url(
                 base_authorize(
                   authorization_endpoint: %URI{
                     scheme: "http",
                     host: "127.0.0.1",
                     path: "/authorize"
                   },
                   allow_http: false
                 )
               )

      assert {:error, {:invalid_endpoint, :binary_required}} =
               AuthCode.build_authorize_url(
                 base_authorize(
                   authorization_endpoint: %URI{
                     scheme: "http",
                     host: "127.0.0.1",
                     path: "/authorize"
                   },
                   allow_http: true
                 )
               )
    end

    test "honours allow_http for a loopback endpoint" do
      assert {:ok, _url} =
               AuthCode.build_authorize_url(
                 base_authorize(
                   authorization_endpoint: "http://127.0.0.1:9/authorize",
                   allow_http: true
                 )
               )
    end

    test "rejects an unknown parameter key without reflecting it" do
      assert {:error, {:invalid_params, :unknown_key}} =
               AuthCode.build_authorize_url(base_authorize(nope: 1))

      canary = "UNKNOWN-KEY-#{System.unique_integer([:positive])}"
      result = AuthCode.build_authorize_url(base_authorize([]) ++ [{{:attacker, canary}, 1}])

      assert {:error, {:invalid_params, :unknown_key}} = result
      refute inspect(result) =~ canary
    end

    test "treats explicit nil scopes as no scope parameter" do
      assert {:ok, url} = AuthCode.build_authorize_url(base_authorize(scopes: nil))

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      refute Map.has_key?(query, "scope")
    end

    test "rejects raw whitespace in URI fields and invalid explicit endpoint ports" do
      assert {:error, {:invalid_endpoint, :unsafe_characters}} =
               AuthCode.build_authorize_url(
                 base_authorize(authorization_endpoint: "https://idp.example/authorize path")
               )

      assert {:error, {:invalid_params, :unsafe_characters}} =
               AuthCode.build_authorize_url(
                 base_authorize(redirect_uri: "https://app.example/cb path")
               )

      assert {:error, {:invalid_endpoint, :invalid_port}} =
               AuthCode.build_authorize_url(
                 base_authorize(authorization_endpoint: "https://idp.example:0/authorize")
               )

      assert {:error, {:invalid_endpoint, _reason}} =
               AuthCode.build_authorize_url(
                 base_authorize(authorization_endpoint: "https://idp.example:65536/authorize")
               )
    end

    test "rejects atom/string alias collision in options" do
      assert {:error, {:invalid_params, :duplicate_key}} =
               AuthCode.build_authorize_url(base_authorize(state: "alpha") ++ [{"state", "beta"}])
    end
  end

  describe "extra_query validation" do
    test "accepts well-formed pairs and places them before the reserved params" do
      assert {:ok, url} =
               AuthCode.build_authorize_url(
                 base_authorize(
                   extra_query: [{"prompt", "consent"}, {:login_hint, "a@b.example"}]
                 )
               )

      query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["prompt"] == "consent"
      assert query["login_hint"] == "a@b.example"
      assert query["response_type"] == "code"
    end

    test "rejects arbitrary key terms without raising" do
      for key <- [{:a, :b}, self(), make_ref(), [1 | 2], 123, 1.5, ["x"]] do
        assert {:error, {:invalid_extra_query, :invalid_key_type}} =
                 AuthCode.build_authorize_url(base_authorize(extra_query: [{key, "v"}]))
      end
    end

    test "rejects arbitrary value terms without raising" do
      for value <- [{:a}, self(), make_ref(), 123, 1.5, :atom, nil, ["x"]] do
        assert {:error, {:invalid_extra_query, :invalid_value_type}} =
                 AuthCode.build_authorize_url(base_authorize(extra_query: [{"k", value}]))
      end
    end

    test "rejects any reserved key" do
      for key <- AuthCode.reserved_query_keys() do
        assert {:error, {:invalid_extra_query, {:reserved_key, ^key}}} =
                 AuthCode.build_authorize_url(base_authorize(extra_query: [{key, "x"}]))
      end
    end

    test "rejects duplicates, including an atom/binary collision" do
      canary = "DUPLICATE-KEY-CANARY"

      result =
        AuthCode.build_authorize_url(base_authorize(extra_query: [{canary, "a"}, {canary, "b"}]))

      assert {:error, {:invalid_extra_query, :duplicate_key}} = result
      refute inspect(result) =~ canary
    end

    test "accepts max-size extra query lists and rejects max+1" do
      max_query = Enum.map(1..16, &{"k#{&1}", "v#{&1}"})

      assert {:ok, _url} = AuthCode.build_authorize_url(base_authorize(extra_query: max_query))

      assert {:error, {:invalid_extra_query, :too_many_pairs}} =
               AuthCode.build_authorize_url(
                 base_authorize(extra_query: max_query ++ [{"k17", "v17"}])
               )
    end

    test "accepts max-size scopes and rejects max+1" do
      max_scopes = Enum.map(1..32, &"scope-#{&1}")

      assert {:ok, _url} = AuthCode.build_authorize_url(base_authorize(scopes: max_scopes))

      assert {:error, {:invalid_params, :too_many_scopes}} =
               AuthCode.build_authorize_url(base_authorize(scopes: max_scopes ++ ["scope-33"]))
    end

    test "rejects CRLF, control characters, oversize values, and too many pairs" do
      assert {:error, {:invalid_extra_query, :value_unsafe_characters}} =
               AuthCode.build_authorize_url(
                 base_authorize(extra_query: [{"k", "a\r\nHost: evil"}])
               )

      assert {:error, {:invalid_extra_query, :key_unsafe_characters}} =
               AuthCode.build_authorize_url(base_authorize(extra_query: [{"k\nx", "v"}]))

      assert {:error, {:invalid_extra_query, :value_length}} =
               AuthCode.build_authorize_url(
                 base_authorize(extra_query: [{"k", String.duplicate("v", 2_049)}])
               )

      assert {:error, {:invalid_extra_query, :key_length}} =
               AuthCode.build_authorize_url(
                 base_authorize(extra_query: [{String.duplicate("k", 129), "v"}])
               )

      too_many = Enum.map(1..17, &{"k#{&1}", "v"})

      assert {:error, {:invalid_extra_query, :too_many_pairs}} =
               AuthCode.build_authorize_url(base_authorize(extra_query: too_many))
    end

    test "rejects a non-pair list and a non-collection term" do
      assert {:error, {:invalid_extra_query, :pair_required}} =
               AuthCode.build_authorize_url(base_authorize(extra_query: ["bare"]))

      assert {:error, {:invalid_extra_query, :map_or_list_required}} =
               AuthCode.build_authorize_url(base_authorize(extra_query: "prompt=consent"))
    end
  end

  describe "response_schema fails closed before any IO" do
    setup do
      # A port bound then closed: if validation leaked into IO we would see a
      # transport error instead of the schema error.
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)
      %{dead_endpoint: "http://127.0.0.1:#{port}/token"}
    end

    test "rejects a malformed schema without opening a socket", %{dead_endpoint: endpoint} do
      malformed = [
        {nil, :required},
        {%{}, :empty},
        {"not a map", :map_required},
        {[{"id_token", :required_string}], :map_required}
      ]

      for {schema, detail} <- malformed do
        assert {:error, {:invalid_response_schema, ^detail}} =
                 AuthCode.exchange_code(
                   base_exchange(
                     token_endpoint: endpoint,
                     allow_http: true,
                     response_schema: schema
                   )
                 )
      end

      assert {:error, {:invalid_response_schema, :non_binary_field}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   allow_http: true,
                   response_schema: %{:id_token => :required_string}
                 )
               )

      canary = "SCHEMA-TYPE-CANARY"

      result =
        AuthCode.exchange_code(
          base_exchange(
            token_endpoint: endpoint,
            allow_http: true,
            response_schema: %{canary => :whatever}
          )
        )

      assert {:error, {:invalid_response_schema, :unknown_type}} = result
      refute inspect(result) =~ canary
    end

    test "rejects oversized schema field counts and oversized field names without opening sockets",
         %{
           dead_endpoint: endpoint
         } do
      oversize_name = String.duplicate("a", 129)

      assert {:error, {:invalid_response_schema, :too_many_fields}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   allow_http: true,
                   response_schema:
                     1..65
                     |> Enum.into(%{}, fn i -> {"field_#{i}", :optional_string} end)
                 )
               )

      assert {:error, {:invalid_response_schema, :field_name_too_long}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   allow_http: true,
                   response_schema: %{oversize_name => :required_string}
                 )
               )

      assert {:error, {:invalid_response_schema, :unsafe_field_name}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   allow_http: true,
                   response_schema: %{"id_token\nsecret" => :required_string}
                 )
               )

      assert {:error, {:invalid_response_schema, :unsafe_field_name}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   allow_http: true,
                   response_schema: %{<<255>> => :required_string}
                 )
               )
    end

    test "rejects non-map schemas as map_required", %{dead_endpoint: endpoint} do
      assert {:error, {:invalid_response_schema, :map_required}} =
               AuthCode.validate_response_schema("not a map")

      assert {:error, {:invalid_response_schema, :map_required}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   allow_http: true,
                   response_schema: 1_234
                 )
               )
    end
  end

  describe "pre-I/O request validation rejects unsafe settings" do
    setup do
      %{dead_endpoint: dead_endpoint()}
    end

    test "rejects malformed request settings before transport is attempted", %{
      dead_endpoint: endpoint
    } do
      assert {:error, {:invalid_params, :invalid_allow_http}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   allow_http: "yes",
                   response_schema: @schema
                 )
               )

      assert {:error, {:invalid_params, :invalid_client_secret}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   client_secret: "",
                   response_schema: @schema
                 )
               )

      for secret <- ["line1\nline2", <<255>>] do
        assert {:error, {:invalid_params, :invalid_client_secret}} =
                 AuthCode.exchange_code(
                   base_exchange(
                     token_endpoint: endpoint,
                     client_secret: secret,
                     response_schema: @schema
                   )
                 )
      end

      assert {:error, {:invalid_params, :invalid_client_secret}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   client_secret: String.duplicate("x", 4_097),
                   response_schema: @schema
                 )
               )

      assert {:error, {:invalid_params, {:max_response_bytes, :invalid_range}}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   max_response_bytes: 1_048_577,
                   response_schema: @schema
                 )
               )

      assert {:error, {:invalid_params, {:timeout_ms, :invalid_range}}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   timeout_ms: 120_001,
                   response_schema: @schema
                 )
               )

      assert {:error, {:invalid_params, :invalid_http_client}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: endpoint,
                   http_client: self(),
                   response_schema: @schema
                 )
               )
    end
  end

  describe "scope validation is bounded and safe" do
    test "rejects too many scopes and non-safe scope text" do
      too_many = Enum.to_list(1..33) |> Enum.map(&"s#{&1}")

      assert {:error, {:invalid_params, :too_many_scopes}} =
               AuthCode.build_authorize_url(base_authorize(scopes: too_many))

      assert {:error, {:invalid_params, :invalid_scopes}} =
               AuthCode.build_authorize_url(base_authorize(scopes: ["\n", "openid"]))

      assert {:error, {:invalid_params, :invalid_scopes}} =
               AuthCode.build_authorize_url(base_authorize(scopes: ["", "openid"]))

      assert {:error, {:invalid_params, :invalid_scopes}} =
               AuthCode.build_authorize_url(base_authorize(scopes: ["open id", "email"]))

      assert {:error, {:invalid_params, :invalid_scopes}} =
               AuthCode.build_authorize_url(
                 base_authorize(scopes: ["open" <> <<0xC2, 0xA0>> <> "id", "email"])
               )
    end
  end

  describe "exchange_code/1 response handling" do
    test "returns the full decoded body, preserving undeclared fields" do
      client =
        stub(fn ->
          {:ok,
           %Response{
             status: 200,
             body:
               Jason.encode!(%{
                 "id_token" => "eyJ.a.b",
                 "expires_in" => 3600,
                 "provider_specific" => "kept"
               })
           }}
        end)

      assert {:ok, tokens} =
               AuthCode.exchange_code(base_exchange(http_client: client))

      assert tokens["id_token"] == "eyJ.a.b"
      assert tokens["expires_in"] == 3600
      # The schema validates; it must not project.
      assert tokens["provider_specific"] == "kept"
    end

    test "accepts the historical empty code_verifier sentinel" do
      client =
        stub(fn ->
          {:ok, %Response{status: 200, body: Jason.encode!(%{"id_token" => "eyJ.a.b"})}}
        end)

      assert {:ok, %{"id_token" => "eyJ.a.b"}} =
               AuthCode.exchange_code(base_exchange(code_verifier: "", http_client: client))
    end

    test "reports schema failures without reflecting field names" do
      canary = "APPLY-SCHEMA-CANARY"
      schema = %{canary => :required_string}
      client = stub(fn -> {:ok, %Response{status: 200, body: Jason.encode!(%{"other" => 1})}} end)

      result =
        AuthCode.exchange_code(base_exchange(http_client: client, response_schema: schema))

      assert {:error, {:invalid_token_response, :missing_field}} = result
      refute inspect(result) =~ canary

      client = stub(fn -> {:ok, %Response{status: 200, body: Jason.encode!(%{canary => 42})}} end)

      result =
        AuthCode.exchange_code(base_exchange(http_client: client, response_schema: schema))

      assert {:error, {:invalid_token_response, :field_type}} = result
      refute inspect(result) =~ canary
    end

    test "rejects malformed JSON and a non-object body" do
      client = stub(fn -> {:ok, %Response{status: 200, body: "{not json"}} end)

      assert {:error, {:invalid_token_response, :malformed_json}} =
               AuthCode.exchange_code(base_exchange(http_client: client))

      client = stub(fn -> {:ok, %Response{status: 200, body: "[1,2,3]"}} end)

      assert {:error, {:invalid_token_response, :object_required}} =
               AuthCode.exchange_code(base_exchange(http_client: client))
    end

    test "rejects a structurally oversized body whole, rather than trimming it" do
      deep = %{"id_token" => "t", "a" => %{"b" => %{"c" => %{"d" => %{"e" => 1}}}}}
      client = stub(fn -> {:ok, %Response{status: 200, body: Jason.encode!(deep)}} end)

      assert {:error, {:invalid_token_response, :depth}} =
               AuthCode.exchange_code(base_exchange(http_client: client))

      wide = Map.new(1..65, &{"k#{&1}", "v"})
      client = stub(fn -> {:ok, %Response{status: 200, body: Jason.encode!(wide)}} end)

      assert {:error, {:invalid_token_response, :keys}} =
               AuthCode.exchange_code(base_exchange(http_client: client))

      big = %{"id_token" => String.duplicate("t", 8_193)}
      client = stub(fn -> {:ok, %Response{status: 200, body: Jason.encode!(big)}} end)

      assert {:error, {:invalid_token_response, :value_bytes}} =
               AuthCode.exchange_code(base_exchange(http_client: client))
    end

    test "a non-200 returns the status only — the body never escapes" do
      canary = "CANARY-#{System.unique_integer([:positive])}"

      client =
        stub(fn ->
          {:ok,
           %Response{
             status: 400,
             body: Jason.encode!(%{"error_description" => canary})
           }}
        end)

      result = AuthCode.exchange_code(base_exchange(http_client: client))

      assert {:error, {:token_exchange_failed, 400}} = result
      refute inspect(result) =~ canary
    end

    test "normalizes timeout and transport failures" do
      client = stub(fn -> {:error, {:timeout, 250}} end)

      assert {:error, {:timeout, 250}} =
               AuthCode.exchange_code(base_exchange(http_client: client))

      client = stub(fn -> {:error, {:transport_error, :econnrefused}} end)

      assert {:error, {:transport_error, :econnrefused}} =
               AuthCode.exchange_code(base_exchange(http_client: client))
    end

    test "surfaces a real econnrefused against a closed loopback port" do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listen)
      :gen_tcp.close(listen)

      assert {:error, {:transport_error, :econnrefused}} =
               AuthCode.exchange_code(
                 base_exchange(
                   token_endpoint: "http://127.0.0.1:#{port}/token",
                   allow_http: true
                 )
               )
    end
  end

  describe "redaction" do
    test "inspecting params masks every credential-bearing field" do
      {:ok, params} =
        AuthCode.build_authorize_url(base_authorize([]))
        |> then(fn {:ok, _url} ->
          {:ok,
           struct(AuthCode.Params,
             client_id: "client-1",
             client_secret: "super-secret-value",
             code: "code-secret-value",
             code_verifier: "verifier-secret-value",
             state: "state-secret-value"
           )}
        end)

      rendered = inspect(params)

      refute rendered =~ "super-secret-value"
      refute rendered =~ "code-secret-value"
      refute rendered =~ "verifier-secret-value"
      refute rendered =~ "state-secret-value"

      assert rendered =~ "[REDACTED]"
      # Non-secret fields stay visible for debugging.
      assert rendered =~ "client-1"
    end

    test "a nil credential renders as nil rather than a fake redaction" do
      rendered = inspect(struct(AuthCode.Params, client_id: "c"))
      assert rendered =~ "client_secret: nil"
    end
  end
end
