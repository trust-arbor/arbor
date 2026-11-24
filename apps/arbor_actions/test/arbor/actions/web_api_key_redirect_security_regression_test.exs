defmodule Arbor.Actions.WebApiKeyRedirectSecurityRegressionTest do
  @moduledoc """
  Security regression: Exa and Tinyfish send `x-api-key` through Req, which
  follows redirects by default and only strips `authorization` on a
  cross-origin hop. A 302 to another host must not carry the API key.

  Parent behavior (must fail on checkout of the exact parent): both actions
  follow the redirect and replay `x-api-key` to the foreign host.

  Fixed behavior: credentialed provider calls disable automatic redirects, so
  the follow-up request never happens.
  """
  use Arbor.Actions.ActionCase, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Web

  @api_key "exa-tinyfish-redirect-secret"
  @foreign_host "evil.example"

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

    previous_keys = %{
      exa: System.get_env("EXA_API_KEY"),
      tinyfish: System.get_env("TINYFISH_API_KEY")
    }

    System.put_env("EXA_API_KEY", @api_key)
    System.put_env("TINYFISH_API_KEY", @api_key)

    agent_id = "agent_web_api_key_redirect_#{System.unique_integer([:positive])}"
    Req.Test.set_req_test_to_shared()
    observer = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(observer, {:provider_http, conn.host, conn.req_headers})

      if conn.host in ["api.exa.ai", "api.search.tinyfish.ai"] do
        conn
        |> Plug.Conn.put_resp_header("location", "https://#{@foreign_host}/steal")
        |> Plug.Conn.send_resp(302, "")
      else
        Req.Test.json(conn, %{"results" => []})
      end
    end)

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
      restore_env("EXA_API_KEY", previous_keys.exa)
      restore_env("TINYFISH_API_KEY", previous_keys.tinyfish)
    end)

    {:ok, agent_id: agent_id}
  end

  test "security regression: Exa search does not send x-api-key to another host on redirect",
       %{agent_id: agent_id} do
    authorize_agent(agent_id)

    _ =
      Arbor.Actions.authorize_and_execute(
        agent_id,
        Web.ExaSearch,
        %{query: "redirect-leak"},
        %{
          agent_id: agent_id,
          req_http_options: [plug: {Req.Test, __MODULE__}, retry: false]
        }
      )

    assert_receive {:provider_http, "api.exa.ai", origin_headers}
    assert api_key_header?(origin_headers)
    refute_foreign_host_received_api_key()
  end

  test "security regression: Tinyfish search does not send x-api-key to another host on redirect",
       %{agent_id: agent_id} do
    authorize_agent(agent_id)

    _ =
      Arbor.Actions.authorize_and_execute(
        agent_id,
        Web.TinyfishSearch,
        %{query: "redirect-leak"},
        %{
          agent_id: agent_id,
          req_http_options: [plug: {Req.Test, __MODULE__}, retry: false]
        }
      )

    assert_receive {:provider_http, "api.search.tinyfish.ai", origin_headers}
    assert api_key_header?(origin_headers)
    refute_foreign_host_received_api_key()
  end

  defp refute_foreign_host_received_api_key do
    receive do
      {:provider_http, @foreign_host, headers} ->
        refute api_key_header?(headers),
               "cross-origin redirect carried x-api-key to #{@foreign_host}"
    after
      100 -> :ok
    end
  end

  defp api_key_header?(headers) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(to_string(name)) == "x-api-key" and value == @api_key
    end)
  end

  defp authorize_agent(agent_id) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: %{"arbor://net/search" => :auto}})

    assert {:ok, _capability} =
             Arbor.Security.grant_fixture(principal: agent_id, resource: "arbor://net/search")
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
