defmodule OAuthStandaloneConsumer do
  @moduledoc """
  Real protocol and transport qualification without any Arbor product runtime.
  """

  alias Arbor.Common.OAuth.{AuthCode, DeviceCode, HttpClient}
  alias Arbor.Common.OAuth.HttpClient.{Pool, Request, Response}
  alias OAuthStandaloneConsumer.HTTPFixture

  @canary "standalone-oauth-sensitive-canary"
  @schema %{"access_token" => :required_string, "expires_in" => :optional_integer}
  @modules [AuthCode, DeviceCode, HttpClient, Pool, Arbor.Common.OAuth.HttpClient.Req]
  @forbidden_modules [
    Arbor.Contracts,
    Arbor.KernelRuntime,
    Arbor.Security,
    Arbor.Common,
    Arbor.Common.Config
  ]

  defmodule MarkerAdapter do
    @moduledoc false
    def request(_request), do: {:ok, %Response{status: 218, body: "configured"}}
  end

  def verify!(opts \\ []) do
    if Keyword.get(opts, :require_no_mix, false) do
      ensure(not Code.ensure_loaded?(Mix), "Mix code was present in the release")
      ensure(:code.lib_dir(:mix) == {:error, :bad_name}, "Mix application metadata was present")
    end

    {:ok, _started} = Application.ensure_all_started(:arbor_oauth)
    assert_passive!()
    assert_no_product!()
    configuration!()
    redaction!()

    providers =
      Enum.flat_map([:req, :finch, :mint], fn app ->
        {:ok, started} = Application.ensure_all_started(app)
        started
      end)

    try do
      protocols_and_transport!()
      assert_no_product!()
    after
      Enum.each(Enum.reverse(providers), &Application.stop/1)
    end

    ensure(Process.whereis(Pool.name()) == nil, "host pool survived its supervisor")
    :ok = Application.stop(:arbor_oauth)
    {:ok, _restarted} = Application.ensure_all_started(:arbor_oauth)
    assert_passive!()
    assert_no_product!()

    paths = Map.new(@modules, &{Atom.to_string(&1), List.to_string(:code.which(&1))})

    Enum.each(@modules, fn module ->
      ensure(:application.get_application(module) == {:ok, :arbor_oauth}, "wrong module owner")
    end)

    %{
      package: "arbor_oauth",
      version: Application.spec(:arbor_oauth, :vsn) |> List.to_string(),
      checks: [
        "passive application and explicit provider/pool ownership",
        "flat configuration priority and legacy data compatibility",
        "request, response and all protocol Params redaction",
        "PKCE and authorization-code exchange over actual HTTP",
        "device start, poll and refresh over actual HTTP",
        "schema and HTTP opt-in validation before socket IO",
        "status-only protocol errors; no redirects or retries",
        "raw bounded bodies with and without Content-Length",
        "parser, header-field and header-count bounds",
        "non-identity encoding refusal and whole-request deadline",
        "pool stop, unavailable call and explicit restart"
      ],
      code_paths: paths,
      compiled_applications: compiled_applications(),
      loaded_applications: app_names(Application.loaded_applications()),
      started_applications: app_names(Application.started_applications()),
      mix_available: Code.ensure_loaded?(Mix)
    }
  end

  defp assert_passive! do
    ensure(Application.spec(:arbor_oauth, :mod) in [nil, []], "OAuth has an application callback")
    started = app_names(Application.started_applications())

    ensure(
      Enum.all?(["req", "finch", "mint"], &(&1 not in started)),
      "HTTP providers auto-started"
    )

    ensure(Process.whereis(Pool.name()) == nil, "passive OAuth started a pool")
  end

  defp assert_no_product! do
    loaded =
      Application.loaded_applications()
      |> app_names()
      |> Enum.filter(&String.starts_with?(&1, "arbor_"))

    started =
      Application.started_applications()
      |> app_names()
      |> Enum.filter(&String.starts_with?(&1, "arbor_"))

    ensure(loaded == ["arbor_oauth"], "unexpected first-party application loaded")
    ensure(started == ["arbor_oauth"], "unexpected first-party application started")
    ensure(Enum.all?(@forbidden_modules, &(not Code.ensure_loaded?(&1))), "product module loaded")
    ensure(compiled_applications() == ["arbor_oauth"], "unexpected first-party compiled closure")
  end

  defp configuration! do
    flat = Application.fetch_env(:arbor_oauth, :http_client)
    legacy = Application.fetch_env(:arbor_kernel, :common)
    request = request("http://127.0.0.1:0/unused", 128, 100)

    try do
      Application.delete_env(:arbor_oauth, :http_client)
      Application.put_env(:arbor_kernel, :common, oauth_http_client: MarkerAdapter)
      ensure(marker?(HttpClient.request(request)), "legacy adapter data was not honored")

      Enum.each([nil, false, "invalid"], fn value ->
        Application.put_env(:arbor_oauth, :http_client, value)

        ensure(
          HttpClient.request(request) == {:error, {:invalid_request, :invalid_http_client}},
          "explicit invalid flat configuration fell through"
        )
      end)

      Application.put_env(:arbor_oauth, :http_client, MarkerAdapter)
      Application.put_env(:arbor_kernel, :common, :malformed)
      ensure(marker?(HttpClient.request(request)), "flat adapter did not outrank legacy data")
    after
      restore(:arbor_oauth, :http_client, flat)
      restore(:arbor_kernel, :common, legacy)
    end
  end

  defp marker?({:ok, %Response{status: 218, body: "configured"}}), do: true
  defp marker?(_result), do: false

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  defp redaction! do
    values = [
      %Request{
        method: :post,
        url: "https://owned.invalid",
        headers: [{"authorization", @canary}],
        form: %{"secret" => @canary},
        max_response_bytes: 128,
        timeout_ms: 100
      },
      %Response{status: 200, headers: [{"cookie", @canary}], body: @canary},
      struct(AuthCode.Params,
        client_secret: @canary,
        code: @canary,
        code_verifier: @canary,
        state: @canary
      ),
      struct(DeviceCode.StartParams,
        client_secret: @canary,
        device_authorization_endpoint: @canary
      ),
      struct(DeviceCode.PollParams,
        client_secret: @canary,
        device_code: @canary,
        token_endpoint: @canary
      ),
      struct(DeviceCode.RefreshParams,
        client_secret: @canary,
        refresh_token: @canary,
        token_endpoint: @canary
      )
    ]

    ensure(
      Enum.all?(values, &(not String.contains?(inspect(&1), @canary))),
      "credential inspection leaked"
    )
  end

  defp protocols_and_transport! do
    supervisor = start_pool!()

    try do
      protocols!()
      negative_protocols!()
      transport!()
    after
      Supervisor.stop(supervisor)
    end

    ensure(Process.whereis(Pool.name()) == nil, "pool was not stopped")

    {_result, absent} =
      HTTPFixture.run(%{"/probe" => {:reply, 200, [], "raw"}}, fn base ->
        ensure(
          match?({:error, _reason}, HttpClient.request(request(base <> "/probe"))),
          "missing pool did not deny"
        )
      end)

    ensure(absent.accepted == 0, "unavailable pool unexpectedly opened a socket")
    restarted = start_pool!()

    try do
      {result, report} = http({:reply, 200, [], "raw"})

      ensure(
        response?(result, 200, "raw") and report.accepted == 1,
        "restarted pool did not serve HTTP"
      )
    after
      Supervisor.stop(restarted)
    end
  end

  defp start_pool! do
    ensure(Process.whereis(Pool.name()) == nil, "pool name was already occupied")
    {:ok, supervisor} = Supervisor.start_link([Pool], strategy: :one_for_one)

    try do
      pool_supervisor =
        case supervisor_children!(supervisor) do
          [{Pool, pid, _type, _modules}] when is_pid(pid) -> pid
          _ -> raise "OAuth qualification failed: pool is not the host's exact child"
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
    try do
      Supervisor.stop(supervisor, :normal, 10_000)
    catch
      :exit, {:noproc, _call} -> :ok
    end
  end

  defp protocols! do
    token = Jason.encode!(%{"access_token" => @canary, "expires_in" => 30})

    {wire, report} =
      HTTPFixture.run(
        fn base ->
          %{
            "/code" => {:reply, 200, [], token},
            "/device" =>
              {:reply, 200, [],
               Jason.encode!(%{
                 "device_code" => @canary,
                 "user_code" => "OWNED",
                 "verification_uri" => base <> "/verify",
                 "expires_in" => 30,
                 "interval" => 1
               })},
            "/poll" => {:reply, 200, [], token},
            "/refresh" => {:reply, 200, [], token}
          }
        end,
        fn base ->
          {verifier, challenge} = AuthCode.generate_pkce()
          ensure(byte_size(verifier) == 43 and byte_size(challenge) == 43, "PKCE shape changed")
          expected_challenge = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
          ensure(challenge == expected_challenge, "PKCE challenge did not bind the verifier")
          redirect_uri = base <> "/callback"
          client_secret = @canary <> ":client-secret"
          code = @canary <> ":code"
          refresh_token = @canary <> ":refresh-token"

          url_result =
            AuthCode.build_authorize_url(
              authorization_endpoint: base <> "/authorize",
              client_id: "standalone",
              redirect_uri: redirect_uri,
              state: @canary,
              scopes: ["openid"],
              code_challenge: challenge,
              allow_http: true
            )

          ensure(match?({:ok, _url}, url_result), "authorization URL was not built")
          {:ok, url} = url_result
          query = URI.decode_query(URI.parse(url).query)

          expected_query = %{
            "response_type" => "code",
            "client_id" => "standalone",
            "redirect_uri" => redirect_uri,
            "scope" => "openid",
            "state" => @canary,
            "code_challenge" => expected_challenge,
            "code_challenge_method" => "S256"
          }

          ensure(query == expected_query, "PKCE authorization query changed")

          exchange_options =
            code_options(base <> "/code", verifier, redirect_uri)
            |> Keyword.merge(client_secret: client_secret, code: code)

          ensure(token?(AuthCode.exchange_code(exchange_options)), "code exchange failed")

          start =
            DeviceCode.start(
              device_authorization_endpoint: base <> "/device",
              client_id: "standalone",
              client_secret: client_secret,
              scopes: ["openid"],
              allow_http: true,
              timeout_ms: 1_000
            )

          ensure(device?(start), "device start failed")

          poll =
            DeviceCode.poll(
              token_endpoint: base <> "/poll",
              client_id: "standalone",
              client_secret: client_secret,
              device_code: @canary,
              response_schema: @schema,
              interval: 1,
              expires_in: 30,
              poll_timeout_ms: 2_000,
              timeout_ms: 1_000,
              allow_http: true
            )

          ensure(token?(poll), "device poll failed")

          refresh =
            DeviceCode.refresh(
              token_endpoint: base <> "/refresh",
              client_id: "standalone",
              client_secret: client_secret,
              refresh_token: refresh_token,
              response_schema: @schema,
              timeout_ms: 1_000,
              allow_http: true
            )

          ensure(token?(refresh), "refresh failed")

          %{
            verifier: verifier,
            redirect_uri: redirect_uri,
            client_secret: client_secret,
            code: code,
            refresh_token: refresh_token
          }
        end
      )

    ensure(report.accepted == 4, "protocols did not execute exactly four HTTP requests")
    ensure(Enum.all?(report.requests, &(&1.method == "POST")), "protocol method changed")
    forms = Map.new(report.requests, &{&1.path, &1.form})

    expected_forms = %{
      "/code" => %{
        "grant_type" => "authorization_code",
        "client_id" => "standalone",
        "client_secret" => wire.client_secret,
        "code" => wire.code,
        "redirect_uri" => wire.redirect_uri,
        "code_verifier" => wire.verifier
      },
      "/device" => %{
        "client_id" => "standalone",
        "client_secret" => wire.client_secret,
        "scope" => "openid"
      },
      "/poll" => %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "client_id" => "standalone",
        "client_secret" => wire.client_secret,
        "device_code" => @canary
      },
      "/refresh" => %{
        "grant_type" => "refresh_token",
        "client_id" => "standalone",
        "client_secret" => wire.client_secret,
        "refresh_token" => wire.refresh_token
      }
    }

    ensure(forms == expected_forms, "protocol wire fields changed")
  end

  defp negative_protocols! do
    {verifier, _challenge} = AuthCode.generate_pkce()

    {_result, untouched} =
      HTTPFixture.run(%{}, fn base ->
        options = code_options(base <> "/token", verifier)

        ensure(
          match?(
            {:error, _},
            AuthCode.exchange_code(Keyword.put(options, :response_schema, nil))
          ),
          "missing schema was admitted"
        )

        ensure(
          match?({:error, _}, AuthCode.exchange_code(Keyword.put(options, :allow_http, false))),
          "HTTP was admitted without opt-in"
        )
      end)

    ensure(untouched.accepted == 0, "invalid protocol input opened a socket")

    {_result, report} =
      HTTPFixture.run(%{"/token" => {:reply, 400, [], @canary}}, fn base ->
        ensure(
          AuthCode.exchange_code(code_options(base <> "/token", verifier)) ==
            {:error, {:token_exchange_failed, 400}},
          "protocol error reflected body material"
        )
      end)

    ensure(report.accepted == 1, "token error path did not execute HTTP")
  end

  defp transport! do
    raw_json = Jason.encode!(%{"raw" => "undecoded"})
    {result, report} = http({:reply, 200, [{"content-type", "application/json"}], raw_json})
    ensure(response?(result, 200, raw_json) and report.accepted == 1, "raw response changed")

    Enum.each([[], [{"content-length", Integer.to_string(8_192 * 128)}]], fn headers ->
      {result, report} = http({:body, headers, String.duplicate("b", 8_192), 128, 5}, 8_192)

      ensure(
        result == {:error, {:response_bytes_exceeded, 8_192}},
        "transport byte budget was not enforced"
      )

      ensure(
        not report.completed? and report.chunks_sent < 128,
        "oversize body was fully buffered"
      )
    end)

    {result, report} = http({:header, String.duplicate("h", 1_024), 128, 5}, 65_536, 2_000)

    ensure(
      match?({:error, {:transport_error, _}}, result),
      "parser header bound was not enforced"
    )

    ensure(
      not report.completed? and report.chunks_sent < 128,
      "unterminated headers were fully buffered"
    )

    Enum.each(
      [[{"x-big", String.duplicate("h", 4_097)}], Enum.map(1..65, &{"x-#{&1}", "v"})],
      fn headers ->
        {result, _report} = http({:reply, 200, headers, ""})

        ensure(
          result == {:error, {:invalid_response, :invalid_headers}},
          "response header shape was not bounded"
        )
      end
    )

    {result, _report} = http({:reply, 200, [{"content-encoding", "gzip"}], :zlib.gzip(@canary)})

    ensure(
      result == {:error, {:invalid_response, :non_identity_content_encoding}},
      "compressed response was accepted"
    )

    started = System.monotonic_time(:millisecond)
    {result, report} = http({:body, [], String.duplicate("d", 128), 100, 25}, 65_536, 150)
    ensure(result == {:error, {:timeout, 150}}, "slow chunks reset the deadline")

    ensure(
      System.monotonic_time(:millisecond) - started < 1_000,
      "whole request deadline was exceeded"
    )

    ensure(
      not report.completed? and report.chunks_sent < 100,
      "deadline did not close the stream"
    )

    {_result, redirect} =
      HTTPFixture.run(
        fn base ->
          %{
            "/probe" => {:reply, 302, [{"location", base <> "/redirected"}], ""},
            "/redirected" => {:reply, 200, [], @canary}
          }
        end,
        fn base ->
          ensure(
            response?(HttpClient.request(request(base <> "/probe")), 302, ""),
            "redirect was followed"
          )
        end
      )

    ensure(redirect.accepted == 1, "redirect opened another connection")
    {result, retry} = http({:reply, 503, [], ""})
    ensure(response?(result, 503, "") and retry.accepted == 1, "transport retried a request")
  end

  defp http(response, maximum \\ 65_536, timeout \\ 1_000) do
    HTTPFixture.run(%{"/probe" => response}, fn base ->
      HttpClient.request(request(base <> "/probe", maximum, timeout))
    end)
  end

  defp request(url, maximum \\ 65_536, timeout \\ 1_000),
    do: %Request{
      method: :get,
      url: url,
      headers: [],
      max_response_bytes: maximum,
      timeout_ms: timeout
    }

  defp code_options(endpoint, verifier, redirect_uri \\ "http://127.0.0.1/callback"),
    do: [
      token_endpoint: endpoint,
      client_id: "standalone",
      client_secret: @canary,
      code: @canary,
      redirect_uri: redirect_uri,
      code_verifier: verifier,
      response_schema: @schema,
      allow_http: true,
      timeout_ms: 1_000
    ]

  defp response?({:ok, %Response{} = response}, status, body),
    do: response.status == status and response.body == body

  defp response?(_result, _status, _body), do: false
  defp token?({:ok, value}) when is_map(value), do: value["access_token"] == @canary
  defp token?(_result), do: false
  defp device?({:ok, value}) when is_map(value), do: value["device_code"] == @canary
  defp device?(_result), do: false

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
  defp ensure(false, label), do: raise("OAuth qualification failed: " <> label)
end
