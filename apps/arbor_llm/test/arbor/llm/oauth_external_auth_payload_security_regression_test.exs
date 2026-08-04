defmodule Arbor.LLM.OAuthExternalAuthPayloadSecurityRegressionTest do
  use ExUnit.Case, async: false

  alias Arbor.LLM.OAuth

  @moduletag :fast
  @moduletag :security_regression
  @moduletag spec: "VOICE-6"

  setup do
    keys = [:oauth_store_dir, :oauth_refresh_fun]
    prior = Map.new(keys, &{&1, Application.get_env(:arbor_llm, &1, :unset)})
    store_dir = Path.join(System.tmp_dir!(), "oauth-external-auth-#{unique_suffix()}")
    File.mkdir_p!(store_dir)
    Application.put_env(:arbor_llm, :oauth_store_dir, store_dir)
    Application.delete_env(:arbor_llm, :oauth_refresh_fun)

    on_exit(fn ->
      Enum.each(prior, fn
        {key, :unset} -> Application.delete_env(:arbor_llm, key)
        {key, value} -> Application.put_env(:arbor_llm, key, value)
      end)

      File.rm_rf!(store_dir)
    end)

    {:ok, store_dir: store_dir}
  end

  test "security regression: exact xAI route emits access token and capped TTL only",
       %{store_dir: store_dir} do
    access = jwt(System.system_time(:second) + 7_200)
    refresh = "refresh-must-not-cross-#{unique_suffix()}"
    publish_xai!(access, refresh)

    assert {:ok, payload} = Arbor.LLM.oauth_external_auth_payload(:xai_oauth)
    assert {:ok, decoded} = Jason.decode(payload)
    assert decoded == %{"access_token" => access, "expires_in" => 300}
    refute payload =~ refresh

    refute payload =~ "owner"
    refute payload =~ "generation"
    refute payload =~ store_dir
  end

  test "security regression: refreshed short-lived JWT retains its positive bounded TTL" do
    short = jwt(System.system_time(:second) + 120)
    write_xai_envelope!(jwt(System.system_time(:second) - 1), "refresh-old")

    Application.put_env(:arbor_llm, :oauth_refresh_fun, fn :xai, _config, "refresh-old" ->
      {:ok, %{"access_token" => short, "refresh_token" => "refresh-new"}}
    end)

    assert {:ok, payload} = Arbor.LLM.oauth_external_auth_payload(:xai_oauth)

    assert {:ok, %{"access_token" => ^short, "expires_in" => ttl} = decoded} =
             Jason.decode(payload)

    assert map_size(decoded) == 2
    assert ttl in 1..120
  end

  test "security regression: aliases and non-xAI routes fail before credential resolution" do
    parent = self()

    Application.put_env(:arbor_llm, :oauth_refresh_fun, fn provider, _config, _refresh ->
      send(parent, {:unexpected_refresh, provider})
      {:error, :must_not_run}
    end)

    for route <- [:xai, :grok, "xai_oauth", :openai_oauth, nil, %{}] do
      assert {:error, :unsupported_oauth_external_auth_route} =
               Arbor.LLM.oauth_external_auth_payload(route)
    end

    refute_received {:unexpected_refresh, _provider}
  end

  test "security regression: source-owned legacy malformed unavailable and expired stores fail closed",
       %{store_dir: store_dir} do
    sentinel = "credential-sentinel-#{unique_suffix()}"
    path = Path.join(store_dir, "xai.json")

    cases = [
      %{
        "version" => 1,
        "provider" => "xai",
        "account_id" => nil,
        "origin" => "external_cli",
        "owner" => "source_owned",
        "source" => "grok_file",
        "generation" => 1,
        "tokens" => %{}
      },
      %{"access_token" => sentinel, "refresh_token" => sentinel},
      arbor_owned_envelope("not-a-jwt", sentinel),
      arbor_owned_envelope(jwt_payload(%{"marker" => "missing-exp"}), sentinel),
      arbor_owned_envelope(jwt_payload(%{"exp" => "not-an-integer"}), sentinel)
    ]

    for envelope <- cases do
      File.write!(path, Jason.encode!(envelope))
      File.chmod!(path, 0o600)

      result = Arbor.LLM.oauth_external_auth_payload(:xai_oauth)
      assert result == {:error, :oauth_external_auth_unavailable}
      refute inspect(result) =~ sentinel
    end

    File.rm!(path)

    assert {:error, :oauth_external_auth_unavailable} =
             Arbor.LLM.oauth_external_auth_payload(:xai_oauth)

    write_xai_envelope!(jwt(System.system_time(:second) - 1), sentinel)
    Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ -> {:error, sentinel} end)

    result = Arbor.LLM.oauth_external_auth_payload(:xai_oauth)
    assert result == {:error, :oauth_external_auth_unavailable}
    refute inspect(result) =~ sentinel
  end

  test "security regression: arbitrary refresh outcomes never escape or disclose token material" do
    access = jwt(System.system_time(:second) - 1)
    refresh = "refresh-secret-#{unique_suffix()}"

    outcomes = [
      fn -> {:ok, %{"unexpected" => access}} end,
      fn -> {:unknown, access} end,
      fn -> raise(access) end,
      fn -> throw({:secret, access}) end,
      fn -> exit({:secret, access}) end
    ]

    for outcome <- outcomes do
      write_xai_envelope!(access, refresh)
      Application.put_env(:arbor_llm, :oauth_refresh_fun, fn _, _, _ -> outcome.() end)

      result = Arbor.LLM.oauth_external_auth_payload(:xai_oauth)
      assert result == {:error, :oauth_external_auth_unavailable}
      refute inspect(result) =~ access
      refute inspect(result) =~ refresh
    end
  end

  defp publish_xai!(access, refresh) do
    assert {:ok, credential} =
             OAuth.AcquiredCredential.new(%{
               provider: :xai,
               access_token: access,
               refresh_token: refresh
             })

    assert :ok = OAuth.publish_arbor_owned(:xai_oauth, credential)
  end

  defp write_xai_envelope!(access, refresh) do
    store_dir = Application.fetch_env!(:arbor_llm, :oauth_store_dir)
    path = Path.join(store_dir, "xai.json")

    File.write!(path, Jason.encode!(arbor_owned_envelope(access, refresh)))

    File.chmod!(path, 0o600)
  end

  defp arbor_owned_envelope(access, refresh) do
    %{
      "version" => 1,
      "provider" => "xai",
      "account_id" => nil,
      "origin" => "arbor_login",
      "owner" => "arbor_owned",
      "source" => "arbor_oauth_store",
      "generation" => 0,
      "tokens" => %{"access_token" => access, "refresh_token" => refresh}
    }
  end

  defp jwt(exp) do
    jwt_payload(%{"exp" => exp})
  end

  defp jwt_payload(payload) do
    header = Base.url_encode64(~s({"alg":"none","typ":"JWT"}), padding: false)
    encoded_payload = Base.url_encode64(Jason.encode!(payload), padding: false)
    "#{header}.#{encoded_payload}.sig"
  end

  defp unique_suffix,
    do: "#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
end
