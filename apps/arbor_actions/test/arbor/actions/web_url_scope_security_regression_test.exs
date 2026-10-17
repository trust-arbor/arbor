defmodule Arbor.Actions.WebUrlScopeSecurityRegressionTest do
  @moduledoc """
  Security regression: Web.Browse and Web.Snapshot must authorize against the
  target URL resource (`arbor://net/http/<encoded-url>`), not the bare class
  URI `arbor://net/http`. Otherwise URL-scoped grants cannot restrict fetches.

  Parent behavior (must fail on checkout of the exact parent): both actions
  bind `arbor://net/http`, so a grant for URL A cannot admit URL A and a
  grant for URL A also cannot distinguish URL B.

  Fixed behavior: grant A admits A and denies B. `arbor://net/http/**`
  still admits any HTTP URL via existing capability wildcard matching.
  """
  use Arbor.Actions.ActionCase, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Web

  @url_a "http://169.254.169.254/latest/meta-data/"
  @url_b "http://127.0.0.1:8080/admin"

  setup do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(Arbor.Trust.Store), do: start_supervised!(Arbor.Trust.Store)

    previous = %{
      reflex: Application.get_env(:arbor_security, :reflex_checking_enabled),
      signing: Application.get_env(:arbor_security, :capability_signing_required),
      identity: Application.get_env(:arbor_security, :identity_verification),
      strict: Application.get_env(:arbor_security, :strict_identity_mode),
      uri: Application.get_env(:arbor_security, :uri_registry_enforcement),
      escalation: Application.get_env(:arbor_security, :consensus_escalation_enabled),
      security_approval: Application.get_env(:arbor_security, :approval_guard_enabled),
      trust_approval: Application.get_env(:arbor_trust, :approval_guard_enabled),
      trust_enforcer: Application.get_env(:arbor_trust, :policy_enforcer_enabled)
    }

    Application.put_env(:arbor_security, :reflex_checking_enabled, false)
    Application.put_env(:arbor_security, :capability_signing_required, false)
    Application.put_env(:arbor_security, :identity_verification, false)
    Application.put_env(:arbor_security, :strict_identity_mode, false)
    Application.put_env(:arbor_security, :uri_registry_enforcement, false)
    Application.put_env(:arbor_security, :consensus_escalation_enabled, false)
    Application.put_env(:arbor_security, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :approval_guard_enabled, false)
    Application.put_env(:arbor_trust, :policy_enforcer_enabled, true)

    agent_id = "agent_web_url_scope_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.revoke_all_fixture(agent_id)
      end

      if Process.whereis(Arbor.Trust.Store) do
        Arbor.Trust.Store.delete_profile(agent_id)
      end

      restore(:arbor_security, :reflex_checking_enabled, previous.reflex)
      restore(:arbor_security, :capability_signing_required, previous.signing)
      restore(:arbor_security, :identity_verification, previous.identity)
      restore(:arbor_security, :strict_identity_mode, previous.strict)
      restore(:arbor_security, :uri_registry_enforcement, previous.uri)
      restore(:arbor_security, :consensus_escalation_enabled, previous.escalation)
      restore(:arbor_security, :approval_guard_enabled, previous.security_approval)
      restore(:arbor_trust, :approval_guard_enabled, previous.trust_approval)
      restore(:arbor_trust, :policy_enforcer_enabled, previous.trust_enforcer)
    end)

    {:ok, agent_id: agent_id}
  end

  test "security regression: URL-scoped grant admits that URL and denies another",
       %{agent_id: agent_id} do
    resource_a = http_resource(@url_a)
    authorize_agent(agent_id, resource_a)

    for module <- [Web.Browse, Web.Snapshot] do
      a_result = execute(agent_id, module, @url_a)
      b_result = execute(agent_id, module, @url_b)

      assert cap_gate_passed?(a_result),
             "#{inspect(module)} URL A should pass capability gate, got #{inspect(a_result)}"

      assert b_result == {:error, :unauthorized},
             "#{inspect(module)} URL B must be denied, got #{inspect(b_result)}"
    end
  end

  test "security regression: arbor://net/http/** still authorizes any HTTP URL",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, "arbor://net/http/**")

    for module <- [Web.Browse, Web.Snapshot] do
      a_result = execute(agent_id, module, @url_a)
      b_result = execute(agent_id, module, @url_b)

      assert cap_gate_passed?(a_result),
             "#{inspect(module)} wildcard grant failed for URL A: #{inspect(a_result)}"

      assert cap_gate_passed?(b_result),
             "#{inspect(module)} wildcard grant failed for URL B: #{inspect(b_result)}"
    end
  end

  test "security regression: exact arbor://net/http does not implicitly cover URLs",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, "arbor://net/http")

    for module <- [Web.Browse, Web.Snapshot] do
      result = execute(agent_id, module, @url_a)

      assert result == {:error, :unauthorized},
             "#{inspect(module)} exact class grant must not cover URL-scoped requests: #{inspect(result)}"
    end
  end

  test "security regression: missing or non-http URL fails closed before authorize" do
    for module <- [Web.Browse, Web.Snapshot] do
      assert {:error, :invalid_web_url} = module.authorization_resource(%{})
      assert {:error, :invalid_web_url} = module.authorization_resource(%{url: ""})

      assert {:error, :invalid_web_url} =
               module.authorization_resource(%{url: "ftp://example.com/"})

      assert {:error, :invalid_web_url} =
               module.authorization_resource(%{url: " https://example.com"})

      assert {:error, :invalid_web_url} =
               module.authorization_resource(%{url: "https://example.com\0evil"})

      assert {:ok, "arbor://net/http/" <> encoded} =
               module.authorization_resource(%{url: @url_a})

      assert encoded == URI.encode(@url_a, &URI.char_unreserved?/1)
      refute String.contains?(encoded, "://")
    end
  end

  defp http_resource(url), do: "arbor://net/http/#{URI.encode(url, &URI.char_unreserved?/1)}"

  defp execute(agent_id, module, url) do
    Arbor.Actions.authorize_and_execute(agent_id, module, %{url: url}, %{agent_id: agent_id})
  end

  defp cap_gate_passed?({:error, :unauthorized}), do: false
  defp cap_gate_passed?({:error, "Unauthorized: :action_principal_authority_required"}), do: false
  defp cap_gate_passed?({:error, reason}) when is_binary(reason), do: true
  defp cap_gate_passed?({:ok, _}), do: true
  defp cap_gate_passed?(_other), do: false

  defp authorize_agent(agent_id, resource) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: %{resource => :auto}})

    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: resource)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
