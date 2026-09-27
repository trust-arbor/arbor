defmodule Arbor.Dashboard.OidcConversationIdentityTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias Arbor.Dashboard.OidcAuth
  alias Arbor.Security
  alias Arbor.Security.OIDC.IdentityStore

  @moduletag :fast

  defmodule TokenHTTP do
    @behaviour Arbor.Common.OAuth.HttpClient
    def request(_request) do
      {:ok,
       %Arbor.Common.OAuth.HttpClient.Response{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(%{"id_token" => Process.get(:dashboard_oidc_id_token)})
       }}
    end
  end

  setup do
    uid = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "arbor-dashboard-oidc-#{uid}")
    File.mkdir_p!(root)

    env =
      Map.new(
        [:oidc, :master_key_path, :session_token_secret],
        &{&1, Application.fetch_env(:arbor_security, &1)}
      )

    previous_home = System.get_env("ARBOR_HOME")
    System.put_env("ARBOR_HOME", root)
    Application.put_env(:arbor_security, :master_key_path, Path.join(root, "master.key"))

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "dashboard-oidc-regression-secret"
    )

    if Process.whereis(:arbor_security_signing_keys) == nil do
      start_supervised!(
        {Arbor.Security.AuthorityStore,
         name: :arbor_security_signing_keys,
         backend: nil,
         namespace: "signing_keys",
         hydration_limit: 100}
      )
    end

    if Process.whereis(Arbor.Security.Identity.Registry) == nil do
      start_supervised!(Arbor.Security.Identity.Registry)
    end

    if Process.whereis(:arbor_user_config) == nil do
      start_supervised!({Arbor.Persistence.BufferedStore, name: :arbor_user_config, backend: nil})
    end

    issuer = "https://dashboard-oidc.example/#{uid}"

    claims = %{
      "iss" => issuer,
      "sub" => "operator",
      "aud" => "dashboard",
      "iat" => System.os_time(:second),
      "exp" => System.os_time(:second) + 3600
    }

    key = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_, private} = JOSE.JWK.to_map(key)
    {_, public} = JOSE.JWK.to_public_map(key)
    kid = "dashboard-test-key"
    signer = Joken.Signer.create("ES256", private, %{"kid" => kid})
    {:ok, token} = Joken.Signer.sign(claims, signer)
    Process.put(:dashboard_oidc_id_token, token)

    table = :arbor_oidc_jwks_cache

    if :ets.whereis(table) == :undefined do
      :ets.new(table, [:named_table, :public, :set])
    end

    :ets.insert(
      table,
      {issuer, %{"keys" => [Map.merge(public, %{"alg" => "ES256", "kid" => kid})]},
       System.monotonic_time(:millisecond) + 60_000}
    )

    provider = %{
      issuer: issuer,
      client_id: "dashboard",
      http_client: TokenHTTP,
      endpoints: %{token_endpoint: issuer <> "/token"}
    }

    Application.put_env(:arbor_security, :oidc, providers: [provider])
    subject = IdentityStore.derive_agent_id(claims)

    on_exit(fn ->
      if Process.whereis(Arbor.Security.Identity.Registry),
        do: Security.deregister_identity(subject)

      if Process.whereis(:arbor_security_signing_keys),
        do: Security.SigningKeyStore.delete(subject)

      if Process.whereis(:arbor_user_config),
        do: Arbor.Persistence.BufferedStore.delete("alias:" <> subject, name: :arbor_user_config)

      if :ets.whereis(table) != :undefined, do: :ets.delete(table, issuer)

      Enum.each(env, fn
        {key, {:ok, value}} -> Application.put_env(:arbor_security, key, value)
        {key, :error} -> Application.delete_env(:arbor_security, key)
      end)

      if previous_home,
        do: System.put_env("ARBOR_HOME", previous_home),
        else: System.delete_env("ARBOR_HOME")

      File.rm_rf!(root)
    end)

    %{subject: subject, claims: claims, id_token: token, provider: provider}
  end

  test "security regression: OIDC callback registers the verified subject and does not mint proof for its alias",
       %{subject: subject} do
    alias_key = "alias:" <> subject

    record =
      Arbor.Contracts.Persistence.Record.new(
        alias_key,
        %{primary_id: "human_primary_alias", secondary_id: subject},
        id: "identity_alias:" <> subject
      )

    :ok = Arbor.Persistence.BufferedStore.put(alias_key, record, name: :arbor_user_config)

    conn = callback()
    assert conn.status == 302
    assert get_session(conn, "agent_id") == subject
    assert {:ok, ^subject} = Security.SessionToken.verify(get_session(conn, "session_token"))
    assert Security.identity_active?(subject)

    # Existing active registration must also permit another real login.
    assert callback().status == 302
  end

  test "security regression: an inactive registered subject cannot obtain a new dashboard proof",
       %{subject: subject, claims: claims, id_token: id_token, provider: provider} do
    # Establish the prior registered login independently of callback registration,
    # so the predecessor fails at the inactive-login gate itself.
    assert {:ok, identity, _} = IdentityStore.load_or_create(claims)
    assert :ok = Security.register_oidc_identity(identity, id_token, provider)
    assert callback().status == 302
    assert :ok = Security.suspend_identity(subject)

    denied =
      callback(%{
        "agent_id" => subject,
        "session_token" => "older-session-proof",
        "user_display_name" => "Previous login",
        "local_dev_operator" => true
      })

    assert denied.status == 401
    refute get_session(denied, "session_token")
    refute get_session(denied, "agent_id")
    refute get_session(denied, "user_display_name")
    refute get_session(denied, "local_dev_operator")
  end

  defp callback(previous_session \\ %{}) do
    session =
      Map.merge(previous_session, %{
        "oidc_state" => "state",
        "oidc_code_verifier" => String.duplicate("v", 43)
      })

    conn(:get, "/auth/callback?code=code&state=state")
    |> init_test_session(session)
    |> OidcAuth.call([])
  end
end
