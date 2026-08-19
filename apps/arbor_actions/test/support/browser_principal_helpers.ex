defmodule Arbor.Actions.BrowserPrincipalHelpers do
  @moduledoc false

  alias Arbor.Actions.Browser

  @agent_key {__MODULE__, :agent_id}

  @browser_actions [
    Browser.StartSession,
    Browser.EndSession,
    Browser.GetStatus,
    Browser.Navigate,
    Browser.Back,
    Browser.Forward,
    Browser.Reload,
    Browser.GetUrl,
    Browser.GetTitle,
    Browser.Click,
    Browser.Type,
    Browser.Hover,
    Browser.Focus,
    Browser.Scroll,
    Browser.SelectOption,
    Browser.Query,
    Browser.GetText,
    Browser.GetAttribute,
    Browser.IsVisible,
    Browser.ExtractContent,
    Browser.Screenshot,
    Browser.Snapshot,
    Browser.Wait,
    Browser.WaitForSelector,
    Browser.WaitForNavigation,
    Browser.Evaluate
  ]

  @doc """
  Start security/trust, grant derived `arbor://action/browser/<op>` URIs, and
  remember the principal for `run/3` on this test process.
  """
  def install_agent do
    {:ok, _} = Application.ensure_all_started(:arbor_security)
    {:ok, _} = Application.ensure_all_started(:arbor_trust)

    unless Process.whereis(Arbor.Trust.Store) do
      ExUnit.Callbacks.start_supervised!(Arbor.Trust.Store)
    end

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

    agent_id = "agent_p1d_browser_#{System.unique_integer([:positive])}"
    resources = Enum.map(@browser_actions, &Arbor.Actions.canonical_uri_for(&1, %{}))
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    rules = Map.new(resources, &{&1, :auto})
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: rules})

    Enum.each(resources, fn resource ->
      {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: resource)
    end)

    Process.put(@agent_key, agent_id)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.whereis(Arbor.Security.CapabilityStore) do
        Arbor.Security.CapabilityStore.revoke_all(agent_id)
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

    {:ok, browser_agent_id: agent_id}
  end

  def run(module, params, context \\ %{}) do
    agent_id = Process.get(@agent_key)

    Arbor.Actions.authorize_and_execute(
      agent_id,
      module,
      params,
      Map.put(context, :agent_id, agent_id)
    )
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
