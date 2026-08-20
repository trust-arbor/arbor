defmodule Arbor.Security.SignalsSubscriptionSessionTokenSecurityRegressionTest do
  @moduledoc """
  Security regression: CapabilityAuthorizer must forward session tokens to
  public Security.authorize/4. A mismatched or invalid token cannot suppress
  identity verification or authorize a restricted subscription.
  """

  use ExUnit.Case, async: false
  @moduletag :fast

  alias Arbor.Security
  alias Arbor.Security.SessionToken
  alias Arbor.Signals
  alias Arbor.Signals.Adapters.CapabilityAuthorizer
  alias Arbor.Signals.Bus

  @resource "arbor://signals/subscribe/security"

  defmodule RejectingSessionToken do
    @moduledoc false
    def verify(_token), do: {:error, :rejected_by_configured_verifier}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:arbor_security)

    backend =
      Application.get_env(:arbor_security, :storage_backend, Arbor.Security.Store.JSONFile)

    for {name, collection} <- [
          {:arbor_security_capabilities, "capabilities"},
          {:arbor_security_identities, "identities"},
          {:arbor_security_signing_keys, "signing_keys"}
        ] do
      child =
        Supervisor.child_spec(
          {Arbor.Security.AuthorityStore, name: name, backend: backend, namespace: collection},
          id: name
        )

      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    for child <- [
          {Arbor.Security.Identity.Registry, []},
          {Arbor.Security.Identity.NonceCache, []},
          {Arbor.Security.SystemAuthority, []},
          {Arbor.Security.Constraint.RateLimiter, []},
          {Arbor.Security.CapabilityStore, []},
          {Arbor.Security.Reflex.Registry, []}
        ] do
      case Supervisor.start_child(Arbor.Security.Supervisor, child) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> :ok
      end
    end

    :ok
  end

  setup do
    prev = %{
      identity_verification: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      secret: Application.get_env(:arbor_security, :session_token_secret),
      token_mod: Application.get_env(:arbor_security, :session_token_module)
    }

    Application.put_env(:arbor_security, :identity_verification, true)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)

    Application.put_env(
      :arbor_security,
      :session_token_secret,
      "k1f-test-secret-#{System.unique_integer([:positive])}"
    )

    Arbor.Signals.Config.Testing.isolate_namespace()
    Arbor.Signals.Config.Testing.put(:security_module, Security)
    Arbor.Signals.Config.Testing.put(:crypto_module, Security)
    Arbor.Signals.Config.Testing.put(:identity_registry_module, Security)
    Arbor.Signals.Config.Testing.put(:authorizer, CapabilityAuthorizer)
    Arbor.Signals.Config.Testing.delete(:allow_open_authorizer)

    ensure_signals_children()

    on_exit(fn ->
      restore_security(:identity_verification, prev.identity_verification)
      restore_security(:strict_identity_mode, prev.strict)
      restore_security(:capability_signing_required, prev.signing)
      restore_security(:reflex_checking_enabled, prev.reflex)
      restore_security(:uri_registry_enforcement, prev.uri)
      restore_security(:session_token_secret, prev.secret)
      restore_security(:session_token_module, prev.token_mod)
    end)

    :ok
  end

  test "security regression: matching token plus grant authorizes subscribe and bus" do
    human_id = register_human!()
    grant!(human_id, @resource)
    assert {:ok, token} = SessionToken.generate(human_id)

    assert {:ok, :authorized} =
             CapabilityAuthorizer.authorize_subscription(human_id, :security,
               session_token: token
             )

    assert {:ok, _sub_id} =
             Bus.subscribe("security.*", fn _signal -> :ok end,
               principal_id: human_id,
               session_token: token
             )
  end

  test "security regression: mismatched session token cannot authorize a restricted subscription" do
    human_id = register_human!()
    other = register_human!()
    grant!(human_id, @resource)
    assert {:ok, wrong_token} = SessionToken.generate(other)

    assert {:error, :no_capability} =
             CapabilityAuthorizer.authorize_subscription(human_id, :security,
               session_token: wrong_token
             )

    assert {:error, :unauthorized} =
             Signals.subscribe("security.*", fn _signal -> :ok end,
               principal_id: human_id,
               session_token: wrong_token
             )
  end

  test "security regression: invalid session token cannot authorize a restricted subscription" do
    human_id = register_human!()
    grant!(human_id, @resource)
    oversized = String.duplicate("a", 4097)

    assert {:error, :no_capability} =
             CapabilityAuthorizer.authorize_subscription(human_id, :security, session_token: nil)

    assert {:error, :no_capability} =
             CapabilityAuthorizer.authorize_subscription(human_id, :security, session_token: "")

    assert {:error, :no_capability} =
             CapabilityAuthorizer.authorize_subscription(human_id, :security,
               session_token: oversized
             )

    assert {:error, :no_capability} =
             CapabilityAuthorizer.authorize_subscription(human_id, :security,
               session_token: "!!!not-base64!!!"
             )
  end

  test "security regression: adapter-local verification cannot bypass the configured verifier" do
    human_id = register_human!()
    grant!(human_id, @resource)
    assert {:ok, token} = SessionToken.generate(human_id)

    Application.put_env(:arbor_security, :session_token_module, RejectingSessionToken)

    assert {:error, _reason} =
             Security.authorize(human_id, @resource, :subscribe, session_token: token)

    assert {:error, :no_capability} =
             CapabilityAuthorizer.authorize_subscription(human_id, :security,
               session_token: token
             )
  end

  defp register_human! do
    n = System.unique_integer([:positive])
    oidc = Arbor.Security.OIDCTestHelper.issue_identity(subject: "k1f-#{n}")
    human_id = oidc.identity.agent_id

    assert :ok =
             Security.register_oidc_identity(oidc.identity, oidc.id_token, oidc.provider)

    on_exit(fn ->
      oidc.cleanup.()
      _ = Security.deregister_identity(human_id)
    end)

    human_id
  end

  defp grant!(principal, resource) do
    assert {:ok, cap} = Security.grant(principal: principal, resource: resource)

    on_exit(fn ->
      _ = Security.revoke(cap.id)
    end)

    cap
  end

  defp ensure_signals_children do
    {:ok, _started} = Application.ensure_all_started(:arbor_kernel_runtime)

    for child <- [
          {Arbor.Signals.Store, []},
          {Arbor.Signals.TopicKeys, []},
          {Arbor.Signals.Channels, []},
          {Arbor.Signals.Bus, []},
          {Arbor.Signals.Relay, []}
        ] do
      case Supervisor.start_child(Arbor.Signals.Supervisor, child) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, :already_present} ->
          {module, _opts} = child
          :ok = Supervisor.delete_child(Arbor.Signals.Supervisor, module)
          {:ok, _pid} = Supervisor.start_child(Arbor.Signals.Supervisor, child)
      end
    end
  end

  defp restore_security(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security(key, value), do: Application.put_env(:arbor_security, key, value)
end
