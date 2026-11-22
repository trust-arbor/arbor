defmodule Arbor.LLM.LoginCliCoreTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.LLM.OAuthHealth
  alias Arbor.LLM.LoginCliCore

  describe "new/1" do
    test "constructs openai, xai, and status commands" do
      assert {:ok, %{action: :openai, manual: false, browser: true, timeout_ms: 600_000}} =
               LoginCliCore.new(["openai"])

      assert {:ok, %{action: :openai, manual: false, browser: false}} =
               LoginCliCore.new(["openai", "--no-browser"])

      assert {:ok, %{action: :openai, manual: true, timeout_ms: 1_500}} =
               LoginCliCore.new(["openai", "--manual", "--timeout", "1500"])

      assert {:ok, %{action: :xai, manual: false, browser: true}} =
               LoginCliCore.new(["xai"])

      assert {:ok, %{action: :status, manual: false, browser: false}} =
               LoginCliCore.new(["status"])
    end

    test "rejects unknown commands, options, and invalid combinations" do
      assert {:error, :unknown_command} = LoginCliCore.new(["anthropic"])
      assert {:error, :command_required} = LoginCliCore.new([])
      assert {:error, :too_many_commands} = LoginCliCore.new(["openai", "xai"])
      assert {:error, :unknown_option} = LoginCliCore.new(["openai", "--browser"])
      assert {:error, :manual_openai_only} = LoginCliCore.new(["xai", "--manual"])
      assert {:error, :status_takes_no_login_options} = LoginCliCore.new(["status", "--manual"])
      assert {:error, :invalid_timeout} = LoginCliCore.new(["openai", "--timeout", "0"])
    end
  end

  describe "parse_callback_url/1" do
    test "extracts code and state and ignores extra query params and fragment" do
      url =
        "http://localhost:1455/auth/callback?code=the-code&state=the-state&session=1#frag"

      assert {:ok, {"the-code", "the-state"}} = LoginCliCore.parse_callback_url(url)
    end

    test "accepts a bare query string and URL-encoded values" do
      assert {:ok, {"a b", "s"}} =
               LoginCliCore.parse_callback_url("code=a+b&state=s&scope=openid")
    end

    test "rejects missing code or state" do
      assert {:error, :invalid_callback_url} =
               LoginCliCore.parse_callback_url("http://localhost:1455/auth/callback?code=only")

      assert {:error, :invalid_callback_url} = LoginCliCore.parse_callback_url("")
      assert {:error, :invalid_callback_url} = LoginCliCore.parse_callback_url(:not_a_url)
    end
  end

  describe "show/format" do
    test "formats health, status, and closed errors without token material" do
      {:ok, health} =
        OAuthHealth.new(%{
          route: "openai_oauth",
          backend: "openai",
          status: "ready",
          owner: "arbor_owned",
          origin: "arbor_login",
          source: "arbor_oauth_store",
          generation: 1
        })

      rendered = LoginCliCore.format_health(health)
      assert rendered =~ "openai_oauth status=ready"
      assert rendered =~ "owner=arbor_owned"
      refute rendered =~ "token"

      status =
        LoginCliCore.format_status([
          {"openai_oauth", {:ok, health}},
          {"xai_oauth", {:error, :login_required}}
        ])

      assert status =~ "openai_oauth status=ready"
      assert status =~ "xai_oauth login_required"

      assert LoginCliCore.format_error({:access_denied, :access_denied}) ==
               "access_denied: access_denied"

      assert LoginCliCore.format_error({:callback_failed, :server_error}) ==
               "callback_failed: server_error"

      assert LoginCliCore.format_error(:timeout) == "timeout"
      assert LoginCliCore.format_error({:loopback_busy, make_ref()}) == "loopback_busy"

      assert LoginCliCore.format_openai_instructions("https://auth.example/authorize?x=1") =~
               "https://auth.example/authorize?x=1"

      assert LoginCliCore.format_xai_instructions("https://x.ai/device", "ABCD") =~
               "https://x.ai/device"

      assert LoginCliCore.format_xai_instructions("https://x.ai/device", "ABCD") =~ "ABCD"

      {:ok, command} = LoginCliCore.new(["openai", "--no-browser"])
      assert LoginCliCore.show(command) =~ "openai"
      assert LoginCliCore.oauth_routes() == ["openai_oauth", "xai_oauth"]
    end
  end

  test "functional core contains no impurity" do
    path = Path.expand("../../../lib/arbor/llm/login_cli_core.ex", __DIR__)
    src = File.read!(path)

    forbidden = [
      ~r/DateTime\.utc_now/,
      ~r/System\.(monotonic|os|system)_time/,
      ~r/:rand\./,
      ~r/:erlang\.unique_integer/,
      ~r/\bmake_ref\s*\(/,
      ~r/Application\.get_env/,
      ~r/GenServer\.(call|cast|reply|start_link|start)\b/,
      ~r/\bRepo\./,
      ~r/:ets\./,
      ~r/\bLogger\./,
      ~r/\bFile\.(read|write|open|rm|ls)/,
      ~r/Mix\.shell/,
      ~r/IO\.(puts|write)/
    ]

    for re <- forbidden do
      refute Regex.match?(re, src),
             "impure pattern #{inspect(re.source)} found in #{Path.relative_to_cwd(path)}"
    end
  end
end
