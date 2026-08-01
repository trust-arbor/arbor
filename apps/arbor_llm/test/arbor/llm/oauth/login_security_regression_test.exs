defmodule Arbor.LLM.OAuth.LoginSecurityRegressionTest do
  @moduledoc """
  Public-boundary security regression for `Arbor.LLM.OAuth.Login`.

  Headless and network-free: HTTP is faked via
  `Arbor.Common.OAuth.HttpClient`'s existing application-config adapter seam
  (never a per-call option -- `Login`'s public API has none), and publication
  is exercised for real against a private temporary store via
  `Arbor.LLM.OAuth`'s existing `:oauth_store_dir` seam. `async: false`
  because both seams are global `Application` config, and because several
  cases directly manipulate the shared, supervised
  `Arbor.LLM.OAuth.Login.PendingStore` singleton via `:sys`.
  """

  use ExUnit.Case, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.LLM.OAuth
  alias Arbor.LLM.OAuth.Login
  alias Arbor.LLM.OAuth.Login.{AuthorizationPrompt, DevicePrompt, PendingStore}

  defmodule StubClient do
    @moduledoc false
    @behaviour Arbor.Common.OAuth.HttpClient

    @impl true
    def request(request) do
      requests = Process.get({__MODULE__, self(), :requests}, [])
      Process.put({__MODULE__, self(), :requests}, [request | requests])

      case Process.get({__MODULE__, self()}) do
        nil ->
          {:error, {:transport_error, :other}}

        [] ->
          {:error, {:transport_error, :other}}

        [response | remaining] ->
          called = Process.get({__MODULE__, self(), :called}, 0)
          Process.put({__MODULE__, self(), :called}, called + 1)
          Process.put({__MODULE__, self()}, remaining)
          {:ok, response}
      end
    end

    def stub(responses) do
      Process.put({__MODULE__, self()}, responses)
      Process.put({__MODULE__, self(), :called}, 0)
      Process.put({__MODULE__, self(), :requests}, [])
    end

    def called_count, do: Process.get({__MODULE__, self(), :called}, 0)
    def requests, do: Process.get({__MODULE__, self(), :requests}, [])

    def clear do
      Process.delete({__MODULE__, self()})
      Process.delete({__MODULE__, self(), :called})
      Process.delete({__MODULE__, self(), :requests})
    end
  end

  alias Arbor.Common.OAuth.HttpClient.Response

  setup do
    prior_adapter = Application.get_env(:arbor_common, :oauth_http_client)
    Application.put_env(:arbor_common, :oauth_http_client, StubClient)
    StubClient.clear()

    prior_store_dir = Application.get_env(:arbor_llm, :oauth_store_dir)

    store_dir =
      Path.join(
        System.tmp_dir!(),
        "arbor-login-regression-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.rm_rf!(store_dir)
    File.mkdir_p!(store_dir)
    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)

    pending_snapshot = :sys.get_state(PendingStore)

    on_exit(fn ->
      case prior_adapter do
        nil -> Application.delete_env(:arbor_common, :oauth_http_client)
        value -> Application.put_env(:arbor_common, :oauth_http_client, value)
      end

      case prior_store_dir do
        nil -> Application.delete_env(:arbor_llm, :oauth_store_dir)
        value -> Application.put_env(:arbor_llm, :oauth_store_dir, value)
      end

      File.rm_rf(store_dir)
      StubClient.clear()
      :sys.replace_state(PendingStore, fn _ -> pending_snapshot end)
    end)

    :ok
  end

  defp response(status, body), do: %Response{status: status, body: Jason.encode!(body)}

  defp fake_id_token(claims) do
    header = Base.url_encode64(Jason.encode!(%{"alg" => "none"}), padding: false)
    payload = Base.url_encode64(Jason.encode!(claims), padding: false)
    "#{header}.#{payload}.sig"
  end

  defp valid_openai_id_token(account_id \\ "acct_abc123") do
    fake_id_token(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => account_id}})
  end

  defp openai_token_response(overrides \\ %{}) do
    Map.merge(
      %{
        "access_token" => "openai-access-token",
        "refresh_token" => "openai-refresh-token",
        "id_token" => valid_openai_id_token(),
        "token_type" => "Bearer"
      },
      overrides
    )
  end

  defp xai_device_response(overrides \\ %{}) do
    Map.merge(
      %{
        "device_code" => "xai-device-code",
        "user_code" => "ABCD-1234",
        "verification_uri" => "https://x.ai/device",
        "expires_in" => 600,
        "interval" => 5
      },
      overrides
    )
  end

  defp xai_token_response(overrides \\ %{}) do
    Map.merge(
      %{
        "access_token" => "xai-access-token",
        "refresh_token" => "xai-refresh-token",
        "token_type" => "Bearer"
      },
      overrides
    )
  end

  # -- Forged / malformed handles -----------------------------------------

  describe "forged and malformed handles" do
    test "complete_openai_login/3 rejects a never-issued handle before any HTTP call" do
      never_issued = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error, :oauth_handle_invalid} =
               Login.complete_openai_login(never_issued, "code", "state")

      assert StubClient.called_count() == 0
      assert {:error, :oauth_login_required} = OAuth.provenance(:openai)
    end

    test "complete_xai_device_login/1 rejects a never-issued handle before any HTTP call" do
      never_issued = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      assert {:error, :oauth_handle_invalid} = Login.complete_xai_device_login(never_issued)
      assert StubClient.called_count() == 0
      assert {:error, :oauth_login_required} = OAuth.provenance(:xai)
    end

    test "malformed handles are rejected without ever reaching HTTP, for both flows" do
      for bad <- ["short", String.duplicate("a", 100), 123, nil] do
        assert {:error, :oauth_handle_invalid} = Login.complete_openai_login(bad, "c", "s")
        assert {:error, :oauth_handle_invalid} = Login.complete_xai_device_login(bad)
      end

      assert StubClient.called_count() == 0
    end
  end

  # -- Replay ---------------------------------------------------------------

  describe "one-shot replay" do
    test "a consumed OpenAI handle cannot be completed a second time" do
      StubClient.stub([response(200, openai_token_response())])
      {:ok, prompt} = Login.start_openai_login()

      assert :ok = Login.complete_openai_login(prompt.handle, "code-1", state_of(prompt))
      assert StubClient.called_count() == 1

      assert {:error, :oauth_handle_invalid} =
               Login.complete_openai_login(prompt.handle, "code-1", state_of(prompt))

      assert StubClient.called_count() == 1
    end

    test "a consumed xAI handle cannot be completed a second time" do
      StubClient.stub([
        response(200, xai_device_response()),
        response(200, xai_token_response())
      ])

      {:ok, prompt} = Login.start_xai_device_login()

      assert :ok = Login.complete_xai_device_login(prompt.handle)
      assert StubClient.called_count() == 2

      assert {:error, :oauth_handle_invalid} = Login.complete_xai_device_login(prompt.handle)
      assert StubClient.called_count() == 2
    end
  end

  describe "xAI durable credential acquisition" do
    test "security regression: device authorization requests refresh and both target scopes" do
      StubClient.stub([response(200, xai_device_response())])

      assert {:ok, _prompt} = Login.start_xai_device_login()

      assert [%{form: form}] = StubClient.requests()

      assert form["scope"] ==
               "openid profile email offline_access api:access grok-cli:access"
    end
  end

  # -- Expiry -----------------------------------------------------------------

  describe "expiry" do
    test "an expired OpenAI handle fails before any HTTP call" do
      {:ok, prompt} = Login.start_openai_login()
      backdate_deadline(:openai, prompt.handle)

      assert {:error, :oauth_handle_expired} =
               Login.complete_openai_login(prompt.handle, "code", "irrelevant")

      assert StubClient.called_count() == 0
    end

    test "xAI's issuance-anchored deadline is not reset by a delayed completion call" do
      StubClient.stub([response(200, xai_device_response(%{"expires_in" => 5}))])
      {:ok, prompt} = Login.start_xai_device_login()

      # Simulate time passing well past the ORIGINAL issuance-relative
      # deadline without ever polling -- a poll-time-reset implementation
      # would incorrectly grant a fresh window here instead of failing.
      backdate_deadline(:xai, prompt.handle)

      # PendingStore.take_xai/1's own expiry gate (backed by the identical
      # issuance-anchored deadline_ms) fires first and reports
      # :oauth_handle_expired; Login's own remaining_window/1 recheck is an
      # additional defense-in-depth layer for the race between a successful
      # take and that recheck a moment later. Either path fails closed
      # before any poll -- which is the property under test.
      assert {:error, :oauth_handle_expired} = Login.complete_xai_device_login(prompt.handle)

      # Only the initial device-authorization request happened; no poll.
      assert StubClient.called_count() == 1
    end

    defp backdate_deadline(:openai, handle) do
      :sys.replace_state(PendingStore, fn state ->
        put_in(state, [:openai, handle, :deadline_ms], System.monotonic_time(:millisecond) - 1)
      end)
    end

    defp backdate_deadline(:xai, handle) do
      :sys.replace_state(PendingStore, fn state ->
        put_in(state, [:xai, handle, :deadline_ms], System.monotonic_time(:millisecond) - 1)
      end)
    end
  end

  # -- OpenAI state / account identity ---------------------------------------

  describe "OpenAI state mismatch and account identity" do
    test "a state mismatch fails before any HTTP call and burns the one-shot handle" do
      {:ok, prompt} = Login.start_openai_login()

      assert {:error, :oauth_state_mismatch} =
               Login.complete_openai_login(prompt.handle, "code", "wrong-state")

      assert StubClient.called_count() == 0

      # The handle is already consumed even though state was wrong -- no
      # second guess at state for a burned flow.
      assert {:error, :oauth_handle_invalid} =
               Login.complete_openai_login(prompt.handle, "code", state_of(prompt))
    end

    test "a missing chatgpt_account_id claim fails before publication" do
      bad_id_token = fake_id_token(%{"https://api.openai.com/auth" => %{}})
      StubClient.stub([response(200, openai_token_response(%{"id_token" => bad_id_token}))])

      {:ok, prompt} = Login.start_openai_login()

      assert {:error, :oauth_account_identity_missing} =
               Login.complete_openai_login(prompt.handle, "code", state_of(prompt))

      assert {:error, :oauth_login_required} = OAuth.provenance(:openai)
    end

    test "an id_token that isn't a well-formed JWT fails before publication" do
      StubClient.stub([response(200, openai_token_response(%{"id_token" => "not-a-jwt"}))])
      {:ok, prompt} = Login.start_openai_login()

      assert {:error, :oauth_account_identity_missing} =
               Login.complete_openai_login(prompt.handle, "code", state_of(prompt))

      assert {:error, :oauth_login_required} = OAuth.provenance(:openai)
    end
  end

  # -- xAI terminal errors -----------------------------------------------------

  describe "xAI terminal errors are closed and body-free" do
    test "access_denied surfaces as a closed atom with no provider body leakage" do
      StubClient.stub([
        response(200, xai_device_response()),
        response(400, %{
          "error" => "access_denied",
          "error_description" => "SECRET_MARKER_should_never_leak"
        })
      ])

      {:ok, prompt} = Login.start_xai_device_login()

      assert {:error, :access_denied} = Login.complete_xai_device_login(prompt.handle)
    end

    test "expired_token surfaces as a closed atom with no provider body leakage" do
      StubClient.stub([
        response(200, xai_device_response()),
        response(400, %{
          "error" => "expired_token",
          "error_description" => "SECRET_MARKER_should_never_leak"
        })
      ])

      {:ok, prompt} = Login.start_xai_device_login()

      result = Login.complete_xai_device_login(prompt.handle)
      assert {:error, :device_code_expired} = result
      refute inspect(result) =~ "SECRET_MARKER_should_never_leak"
    end
  end

  # -- Redirect selector ------------------------------------------------------

  describe "OpenAI redirect_uri selector" do
    test "explicit redirect selector preserves the selected callback port" do
      {:ok, prompt_1455} = Login.start_openai_login(redirect_uri: :port_1455)

      redirect_1455 =
        prompt_1455.authorize_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert redirect_1455 |> Map.fetch!("redirect_uri") |> URI.parse() |> Map.fetch!(:port) ==
               1455

      {:ok, prompt_1457} = Login.start_openai_login(redirect_uri: :port_1457)

      redirect_1457 =
        prompt_1457.authorize_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert redirect_1457 |> Map.fetch!("redirect_uri") |> URI.parse() |> Map.fetch!(:port) ==
               1457

      PendingStore.take_openai(prompt_1455.handle)
      PendingStore.take_openai(prompt_1457.handle)
    end

    test "non-keyword/improper OpenAI start options are rejected before side effects" do
      assert {:error, :keyword_options_required} = Login.start_openai_login(nil)

      assert {:error, :keyword_options_required} =
               Login.start_openai_login(%{"redirect_uri" => :port_1455})

      assert {:error, :improper_openai_options} =
               Login.start_openai_login([%{"redirect_uri" => :port_1455}])

      assert {:error, :improper_openai_options} =
               Login.start_openai_login([{"redirect_uri", :port_1457}])

      assert StubClient.called_count() == 0
    end

    test "unknown option key is rejected without PKCE/state generation or network I/O" do
      assert {:error, :unknown_login_option} =
               Login.start_openai_login(redirect_uri: :port_1455, foo: :bar)

      assert StubClient.called_count() == 0
    end

    test "duplicate option key is rejected before secret generation and network I/O" do
      assert {:error, :duplicate_login_option} =
               Login.start_openai_login(redirect_uri: :port_1455, redirect_uri: :port_1457)

      assert StubClient.called_count() == 0
    end

    test "a bogus selector is refused before any PKCE/state material is stored" do
      assert {:error, :invalid_redirect_uri_selector} =
               Login.start_openai_login(redirect_uri: "http://evil.example/callback")

      assert {:error, :invalid_redirect_uri_selector} =
               Login.start_openai_login(redirect_uri: :not_a_real_port)

      assert StubClient.called_count() == 0
    end
  end

  # -- Inspect redaction --------------------------------------------------------

  describe "Inspect redaction" do
    test "AuthorizationPrompt never renders its authorize_url via inspect/1" do
      {:ok, prompt} = Login.start_openai_login()

      refute inspect(prompt) =~ prompt.authorize_url
      refute inspect(prompt) =~ "auth.openai.com"
      assert AuthorizationPrompt.authorize_url(prompt) == prompt.authorize_url
    end

    test "DevicePrompt never renders user_code/verification_uri via inspect/1" do
      StubClient.stub([response(200, xai_device_response())])
      {:ok, prompt} = Login.start_xai_device_login()

      refute inspect(prompt) =~ prompt.user_code
      refute inspect(prompt) =~ prompt.verification_uri
      assert DevicePrompt.user_code(prompt) == prompt.user_code
      assert DevicePrompt.verification_uri(prompt) == prompt.verification_uri
    end
  end

  # -- Completion revalidates policy -------------------------------------------

  describe "completion revalidates redirect policy from ProviderPolicy" do
    test "the redirect_uri sent to the token endpoint matches the selected port literal" do
      StubClient.stub([response(200, openai_token_response())])
      {:ok, prompt} = Login.start_openai_login(redirect_uri: :port_1457)

      assert :ok = Login.complete_openai_login(prompt.handle, "code-1", state_of(prompt))

      [exchange_request] = StubClient.requests()
      assert exchange_request.form["redirect_uri"] == "http://localhost:1457/auth/callback"
    end
  end

  # -- End-to-end happy path / publish_arbor_owned is the only writer ---------

  describe "end-to-end publication" do
    test "OpenAI: a successful login publishes exactly the arbor_login envelope shape" do
      StubClient.stub([
        response(200, openai_token_response(%{"id_token" => valid_openai_id_token("acct_e2e")}))
      ])

      {:ok, prompt} = Login.start_openai_login()

      assert :ok = Login.complete_openai_login(prompt.handle, "code-1", state_of(prompt))

      path = Path.join(Application.get_env(:arbor_llm, :oauth_store_dir), "openai.json")
      envelope = path |> File.read!() |> Jason.decode!()

      assert envelope["version"] == 1
      assert envelope["provider"] == "openai"
      assert envelope["owner"] == "arbor_owned"
      assert envelope["origin"] == "arbor_login"
      assert envelope["source"] == "arbor_oauth_store"
      assert envelope["generation"] == 0
      assert envelope["account_id"] == "acct_e2e"
      assert envelope["tokens"]["access_token"] == "openai-access-token"
      assert envelope["tokens"]["refresh_token"] == "openai-refresh-token"

      assert {:ok, "openai-access-token"} = OAuth.access_token(:openai)
    end

    test "xAI: a successful login publishes exactly the arbor_login envelope shape" do
      StubClient.stub([
        response(200, xai_device_response()),
        response(200, xai_token_response())
      ])

      {:ok, prompt} = Login.start_xai_device_login()
      assert :ok = Login.complete_xai_device_login(prompt.handle)

      path = Path.join(Application.get_env(:arbor_llm, :oauth_store_dir), "xai.json")
      envelope = path |> File.read!() |> Jason.decode!()

      assert envelope["version"] == 1
      assert envelope["provider"] == "xai"
      assert envelope["owner"] == "arbor_owned"
      assert envelope["origin"] == "arbor_login"
      assert envelope["source"] == "arbor_oauth_store"
      assert envelope["generation"] == 0
      assert envelope["account_id"] == nil
      assert envelope["tokens"]["access_token"] == "xai-access-token"
      assert envelope["tokens"]["refresh_token"] == "xai-refresh-token"

      assert {:ok, "xai-access-token"} = OAuth.access_token(:xai)
    end
  end

  describe "xAI refresh-token evidence is enforced before publication" do
    test "missing refresh token fails with a dedicated error and never publishes credentials" do
      StubClient.stub([
        response(200, xai_device_response()),
        response(200, xai_token_response() |> Map.delete("refresh_token"))
      ])

      {:ok, prompt} = Login.start_xai_device_login()

      assert {:error, :oauth_refresh_token_required} =
               Login.complete_xai_device_login(prompt.handle)

      assert {:error, :oauth_login_required} = OAuth.provenance(:xai)

      refute File.exists?(
               Path.join(Application.get_env(:arbor_llm, :oauth_store_dir), "xai.json")
             )
    end

    test "blank or whitespace refresh token fails with the same dedicated error" do
      StubClient.stub([
        response(200, xai_device_response()),
        response(200, xai_token_response(%{"refresh_token" => ""}))
      ])

      {:ok, prompt} = Login.start_xai_device_login()

      assert {:error, :oauth_refresh_token_required} =
               Login.complete_xai_device_login(prompt.handle)

      StubClient.stub([
        response(200, xai_device_response()),
        response(200, xai_token_response(%{"refresh_token" => "   "}))
      ])

      {:ok, prompt} = Login.start_xai_device_login()

      assert {:error, :oauth_refresh_token_required} =
               Login.complete_xai_device_login(prompt.handle)
    end

    test "valid opaque refresh-token bytes are preserved exactly" do
      refresh_token = " xai-refresh-token "

      StubClient.stub([
        response(200, xai_device_response()),
        response(200, xai_token_response(%{"refresh_token" => refresh_token}))
      ])

      {:ok, prompt} = Login.start_xai_device_login()
      assert :ok = Login.complete_xai_device_login(prompt.handle)

      path = Path.join(Application.get_env(:arbor_llm, :oauth_store_dir), "xai.json")
      envelope = path |> File.read!() |> Jason.decode!()

      assert envelope["tokens"]["refresh_token"] == refresh_token
    end
  end

  # -- Aggregate cap ------------------------------------------------------------

  describe "aggregate pending-login cap" do
    test "the 256-entry cap is combined across both flows, not 256 per flow" do
      :sys.replace_state(PendingStore, fn _ -> %{openai: %{}, xai: %{}} end)

      future = System.monotonic_time(:millisecond) + 60_000

      for _ <- 1..200, do: {:ok, _} = PendingStore.issue_openai(:port_1455, future)
      for n <- 1..56, do: {:ok, _} = PendingStore.issue_xai("device-#{n}", 5, future)

      assert {:error, :too_many_pending_logins} = PendingStore.issue_openai(:port_1455, future)

      assert {:error, :too_many_pending_logins} =
               PendingStore.issue_xai("device-overflow", 5, future)
    end
  end

  # -- format_status redaction --------------------------------------------------
  #
  # Scope: format_status/1 redacts :state/:message/:reason/:log for ORDINARY
  # :sys.get_status/1,2 output and crash-log formatting only. It is not an
  # access-control boundary -- see .claude/skills/applied-learning-otp-
  # ownership-cleanup.md ("GenServer.format_status/1 cannot sanitize an
  # explicitly enabled :sys debug ring"). The next test documents that
  # boundary directly: :sys.get_state/1 bypasses format_status/1 and
  # returns the raw secret-bearing state, exactly as OTP specifies. Never
  # enable :sys logging (or any other :sys debug handler) on this process
  # in production.

  describe "PendingStore format_status redaction" do
    test ":sys.get_state/1 bypasses format_status/1 -- this is the known, accepted boundary" do
      {:ok, issuance} =
        PendingStore.issue_openai(:port_1455, System.monotonic_time(:millisecond) + 60_000)

      raw_state = :sys.get_state(PendingStore)
      assert inspect(raw_state) =~ issuance.state

      PendingStore.take_openai(issuance.handle)
    end

    test ":sys.get_status/1 never exposes stored correlation secrets" do
      {:ok, issuance} =
        PendingStore.issue_openai(:port_1455, System.monotonic_time(:millisecond) + 60_000)

      raw_state = :sys.get_state(PendingStore)
      raw_entry = Map.fetch!(raw_state.openai, issuance.handle)

      status = :sys.get_status(PendingStore)

      refute inspect(status) =~ issuance.state
      refute inspect(status) =~ raw_entry.code_verifier
      refute inspect(status) =~ raw_entry.code_challenge

      PendingStore.take_openai(issuance.handle)
    end

    test "format_status redacts known keys for crash-report-style state formatting" do
      status =
        PendingStore.format_status(%{
          state: %{code_verifier: "state-secret"},
          reason: {:exit, "refresh-secret"},
          message: {:call, :handle},
          log: [{:event, "log-secret"}],
          other: "public"
        })

      assert status.state == "#Arbor.LLM.OAuth.Login.PendingStore<redacted>"
      assert status.reason == "#Arbor.LLM.OAuth.Login.PendingStore<redacted>"
      assert status.message == "#Arbor.LLM.OAuth.Login.PendingStore<redacted>"
      assert status.log == "#Arbor.LLM.OAuth.Login.PendingStore<redacted>"
      assert status.other == "public"
    end

    test "unknown direct calls never expose secret-bearing in-flight data" do
      {:ok, pid} = PendingStore.start_link(name: :pending_store_call_probe)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :invalid_pending_request} =
                   GenServer.call(
                     pid,
                     {:issue, :not_a_real_flow, %{state: "CALL_PROBE_SECRET_STATE"}}
                   )
        end)

      assert Process.alive?(pid)
      refute log =~ "CALL_PROBE_SECRET_STATE"
    end

    test "a crash report never exposes stored correlation secrets" do
      # start_link/1 links the probe to this test process; trap_exit turns
      # the propagated EXIT into a mailbox message instead of killing this
      # test. Each ExUnit test runs in its own fresh process, so this flag
      # never leaks to other tests.
      Process.flag(:trap_exit, true)
      {:ok, pid} = PendingStore.start_link(name: :pending_store_crash_probe)

      :sys.replace_state(pid, fn state ->
        Map.put(state, :security_regression_probe, "CRASH_PROBE_SECRET_STATE")
      end)

      ref = Process.monitor(pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          GenServer.cast(pid, :invalid_pending_request)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
          Process.sleep(50)
        end)

      refute log =~ "CRASH_PROBE_SECRET_STATE"
    end
  end

  defp state_of(%AuthorizationPrompt{authorize_url: url}) do
    %URI{query: query} = URI.parse(url)
    query |> URI.decode_query() |> Map.fetch!("state")
  end
end
