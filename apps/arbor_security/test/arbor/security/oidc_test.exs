defmodule Arbor.Security.OIDCTest do
  # async: false because config-clearing tests mutate Application env
  use ExUnit.Case, async: false

  alias Arbor.Security.Crypto
  alias Arbor.Security.Identity.Registry
  alias Arbor.Security.OIDC
  alias Arbor.Security.OIDC.Config

  @moduletag :fast

  defmodule CrossOriginDiscoveryClient do
    @moduledoc false

    def request(%Arbor.Common.OAuth.HttpClient.Request{
          url: "https://idp.example/.well-known/openid-configuration"
        }) do
      {:ok,
       %Arbor.Common.OAuth.HttpClient.Response{
         status: 200,
         body:
           Jason.encode!(%{
             "issuer" => "https://idp.example",
             "jwks_uri" => "https://attacker.example/jwks"
           })
       }}
    end

    def request(_request), do: raise("untrusted JWKS endpoint was fetched")
  end

  describe "Config" do
    setup do
      prev = Application.get_env(:arbor_security, :oidc)
      Application.delete_env(:arbor_security, :oidc)
      on_exit(fn -> if prev, do: Application.put_env(:arbor_security, :oidc, prev) end)
      :ok
    end

    test "enabled? returns false when not configured" do
      refute Config.enabled?()
    end

    test "providers returns empty list by default" do
      assert Config.providers() == []
    end

    test "device_flow returns nil by default" do
      assert Config.device_flow() == nil
    end

    test "token_cache_path has sensible default" do
      path = Config.token_cache_path()
      assert String.contains?(path, ".arbor")
      assert String.contains?(path, "oidc_tokens.enc")
    end
  end

  describe "load_cached_token/0" do
    setup do
      # Point token_cache_path to a non-existent temp file so real cached
      # tokens from previous OIDC sessions don't interfere
      prev = Application.get_env(:arbor_security, :oidc)
      tmp_path = Path.join(System.tmp_dir!(), "arbor_test_oidc_#{:rand.uniform(1_000_000)}.enc")
      Application.put_env(:arbor_security, :oidc, token_cache_path: tmp_path)

      on_exit(fn ->
        File.rm(tmp_path)

        if prev,
          do: Application.put_env(:arbor_security, :oidc, prev),
          else: Application.delete_env(:arbor_security, :oidc)
      end)

      :ok
    end

    test "fails closed because persisted OIDC token reads are retired" do
      assert {:error, :oidc_token_cache_unauthorized} = OIDC.load_cached_token()
    end
  end

  describe "authenticate_device_flow/1" do
    setup do
      prev = Application.get_env(:arbor_security, :oidc)
      Application.delete_env(:arbor_security, :oidc)
      on_exit(fn -> if prev, do: Application.put_env(:arbor_security, :oidc, prev) end)
      :ok
    end

    test "returns error when no device flow configured" do
      assert {:error, :no_device_flow_configured} = OIDC.authenticate_device_flow(nil)
    end
  end

  describe "authenticate_token/2" do
    test "returns error when no matching provider" do
      # A well-formed but unverifiable token
      header = Base.url_encode64(Jason.encode!(%{"alg" => "RS256"}), padding: false)

      payload =
        Base.url_encode64(
          Jason.encode!(%{
            "iss" => "https://unknown-provider.invalid",
            "sub" => "1",
            "exp" => System.os_time(:second) + 3600
          }),
          padding: false
        )

      sig = Base.url_encode64("sig", padding: false)
      token = "#{header}.#{payload}.#{sig}"

      assert {:error, :no_matching_provider} = OIDC.authenticate_token(token, nil)
    end

    @tag :security_regression
    test "security regression: verified OIDC authentication fails closed without Identity.Registry" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      human_id = oidc.identity.agent_id

      assert :ok = Supervisor.terminate_child(Arbor.Security.Supervisor, Registry)
      assert Process.whereis(Registry) == nil

      on_exit(fn ->
        oidc.cleanup.()
        _ = Arbor.Security.delete_signing_key_fixture(human_id)

        case Supervisor.restart_child(Arbor.Security.Supervisor, Registry) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
        end

        _ = Arbor.Security.deregister_identity_fixture(human_id)
      end)

      assert {:error, {:registration_failed, :registration_unavailable}} =
               Arbor.Security.authenticate_oidc_token(oidc.id_token, oidc.provider)
    end

    @tag :security_regression
    test "security regression: public OIDC authentication rejects cross-origin discovery" do
      oidc =
        Arbor.Security.OIDCTestHelper.issue_identity(
          issuer: "https://idp.example",
          provider_overrides: %{http_client: CrossOriginDiscoveryClient}
        )

      # Force verification through the bounded discovery client rather than the
      # helper's seeded JWKS cache. The second callback raises if the verifier
      # ever follows the attacker-controlled endpoint.
      oidc.cleanup.()

      assert {:error, {:untrusted_endpoint, :issuer_origin_mismatch}} =
               Arbor.Security.authenticate_oidc_token(oidc.id_token, oidc.provider)
    end
  end

  describe "Security facade" do
    test "human_identity?/1 detects human prefix" do
      assert Arbor.Security.human_identity?("human_abc123")
      refute Arbor.Security.human_identity?("agent_abc123")
      refute Arbor.Security.human_identity?("system")
    end
  end

  describe "operator signing authority" do
    test "opens a caller-owned authority after token-verified human registration" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      human_id = oidc.identity.agent_id

      assert :ok =
               Arbor.Security.register_oidc_identity(
                 oidc.identity,
                 oidc.id_token,
                 oidc.provider
               )

      assert :ok = Arbor.Security.store_signing_key_fixture(human_id, oidc.identity.private_key)

      on_exit(fn ->
        oidc.cleanup.()
        _ = Arbor.Security.delete_signing_key_fixture(human_id)
        _ = Arbor.Security.deregister_identity_fixture(human_id)
      end)

      assert {:ok, authority} = OIDC.open_operator_authority(oidc.identity)
      refute is_function(authority)
      assert authority.principal_id == human_id

      assert {:ok, signed} =
               Arbor.Security.sign_with_authority(authority, "arbor://test/signing/oidc-test")

      assert signed.agent_id == human_id
      assert signed.payload == "arbor://test/signing/oidc-test"
    end

    @tag :security_regression
    test "security regression: browser session tokens require the matching live authority" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      human_id = oidc.identity.agent_id

      assert :ok =
               Arbor.Security.register_oidc_identity(
                 oidc.identity,
                 oidc.id_token,
                 oidc.provider
               )

      assert :ok = Arbor.Security.store_signing_key_fixture(human_id, oidc.identity.private_key)

      on_exit(fn ->
        oidc.cleanup.()
        _ = Arbor.Security.delete_signing_key_fixture(human_id)
        _ = Arbor.Security.deregister_identity_fixture(human_id)
      end)

      assert {:ok, authority} = OIDC.open_operator_authority(oidc.identity)

      assert {:error, :session_token_issuance_unauthorized} =
               Arbor.Security.issue_human_session_token("human_other", authority)

      assert {:ok, token} = Arbor.Security.issue_human_session_token(human_id, authority)
      assert {:ok, ^human_id} = Arbor.Security.SessionToken.verify(token)

      assert :ok = Arbor.Security.close_signing_authority(authority)

      assert {:error, :session_token_issuance_unauthorized} =
               Arbor.Security.issue_human_session_token(human_id, authority)
    end

    test "security regression: OIDC registration cannot overwrite an existing public-key owner" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      agent_id = Crypto.derive_agent_id(oidc.identity.public_key)
      agent_identity = %{oidc.identity | agent_id: agent_id, metadata: %{}}

      assert :ok = Arbor.Security.register_identity_fixture(agent_identity)

      on_exit(fn ->
        oidc.cleanup.()
        _ = Arbor.Security.deregister_identity_fixture(oidc.identity.agent_id)
        _ = Arbor.Security.deregister_identity_fixture(agent_id)
      end)

      assert {:error, {:public_key_already_registered, ^agent_id}} =
               Arbor.Security.register_oidc_identity(
                 oidc.identity,
                 oidc.id_token,
                 oidc.provider
               )

      assert {:ok, public_key} = Registry.lookup(agent_id)
      assert public_key == oidc.identity.public_key
      assert {:error, :not_found} = Registry.lookup(oidc.identity.agent_id)
    end

    test "security regression: OIDC registration denies an unlisted subject by default" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      previous_mode = Application.get_env(:arbor_security, :oidc_registration_mode)
      previous_oidc = Application.get_env(:arbor_security, :oidc)

      Application.put_env(:arbor_security, :oidc_registration_mode, :allowlist)
      Application.put_env(:arbor_security, :oidc, providers: [oidc.provider])

      on_exit(fn ->
        oidc.cleanup.()
        restore_env(:oidc_registration_mode, previous_mode)
        restore_env(:oidc, previous_oidc)
        _ = Arbor.Security.deregister_identity_fixture(oidc.identity.agent_id)
      end)

      assert {:error, {:registration_denied, :oidc_subject_not_allowlisted}} =
               Arbor.Security.register_oidc_identity(
                 oidc.identity,
                 oidc.id_token,
                 oidc.provider
               )

      assert {:error, :not_found} = Registry.lookup(oidc.identity.agent_id)
    end

    test "security regression: configured OIDC subjects and verified email domains are admitted" do
      previous_mode = Application.get_env(:arbor_security, :oidc_registration_mode)
      previous_oidc = Application.get_env(:arbor_security, :oidc)
      subject_oidc = Arbor.Security.OIDCTestHelper.issue_identity()

      email_oidc =
        Arbor.Security.OIDCTestHelper.issue_identity(claim_overrides: %{"email_verified" => true})

      subject_provider =
        Map.put(subject_oidc.provider, :allowed_subjects, [subject_oidc.claims["sub"]])

      email_provider = Map.put(email_oidc.provider, :allowed_email_domains, ["example.test"])

      Application.put_env(:arbor_security, :oidc_registration_mode, :allowlist)

      Application.put_env(
        :arbor_security,
        :oidc,
        providers: [subject_provider, email_provider]
      )

      on_exit(fn ->
        subject_oidc.cleanup.()
        email_oidc.cleanup.()
        restore_env(:oidc_registration_mode, previous_mode)
        restore_env(:oidc, previous_oidc)
        _ = Arbor.Security.deregister_identity_fixture(subject_oidc.identity.agent_id)
        _ = Arbor.Security.deregister_identity_fixture(email_oidc.identity.agent_id)
      end)

      assert :ok =
               Arbor.Security.register_oidc_identity(
                 subject_oidc.identity,
                 subject_oidc.id_token,
                 subject_provider
               )

      assert :ok =
               Arbor.Security.register_oidc_identity(
                 email_oidc.identity,
                 email_oidc.id_token,
                 email_provider
               )
    end

    test "security regression: OIDC registration proves possession of the human signing key" do
      oidc = Arbor.Security.OIDCTestHelper.issue_identity()
      {:ok, unrelated_identity} = Arbor.Contracts.Security.Identity.generate()

      identity_without_key_possession = %{
        oidc.identity
        | private_key: unrelated_identity.private_key
      }

      on_exit(fn ->
        oidc.cleanup.()
        _ = Arbor.Security.deregister_identity_fixture(oidc.identity.agent_id)
      end)

      assert {:error, :invalid_key_possession} =
               Arbor.Security.register_oidc_identity(
                 identity_without_key_possession,
                 oidc.id_token,
                 oidc.provider
               )

      assert {:error, :not_found} = Registry.lookup(oidc.identity.agent_id)
    end

    @tag :security_regression
    test "security regression: public OIDC registration rejects hostile temporal and nonce claims" do
      now = System.os_time(:second)

      fixtures = [
        {Arbor.Security.OIDCTestHelper.issue_identity(
           claim_overrides: %{"exp" => Integer.to_string(now + 3_600)}
         ), :invalid_exp_claim},
        {Arbor.Security.OIDCTestHelper.issue_identity(
           claim_overrides: %{"iat" => now + 600},
           provider_overrides: %{clock_skew_seconds: 0}
         ), :invalid_iat_claim},
        {Arbor.Security.OIDCTestHelper.issue_identity(
           claim_overrides: %{"nonce" => "attacker-nonce"},
           provider_overrides: %{expected_nonce: "browser-flow-nonce"}
         ), :nonce_mismatch}
      ]

      for {oidc, expected_error} <- fixtures do
        on_exit(oidc.cleanup)

        assert {:error, {:oidc_verification_failed, ^expected_error}} =
                 Arbor.Security.register_oidc_identity(
                   oidc.identity,
                   oidc.id_token,
                   oidc.provider
                 )

        assert {:error, :not_found} = Registry.lookup(oidc.identity.agent_id)
      end
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
