defmodule Arbor.Actions.BrowserPrincipalSecurityRegressionTest do
  @moduledoc """
  Security regression: Browser Jido actions must not call `jido_browser`
  without an authorized principal.

  Parent behavior (must fail on checkout of the exact parent):
  All 26 `Arbor.Actions.Browser.*` actions call `JidoBrowser` without
  `authorized_principal`. StartSession and Wait ignore context entirely.
  Others fail only on missing session, so a spoofed `browser_session`
  proceeds.

  Fixed behavior: they require `authorized_principal`. The authorized path
  is `Arbor.Actions.authorize_and_execute/4` then the existing
  session/SSRF/`jido_browser` implementation. Missing envelope uses
  `Actions.unauthorized_message/1` and never calls `JidoBrowser.Actions.*.run`.
  Browser is not sent through `Shell.authorize_and_execute/3`. There is no
  host Browser facade. Canonical URIs stay `arbor://action/browser/<op>`.
  """
  use Arbor.Actions.ActionCase, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Browser

  @all_actions [
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

  @session_required_actions @all_actions -- [Browser.StartSession, Browser.Wait]

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

    agent_id = "agent_p1d_browser_#{System.unique_integer([:positive])}"

    on_exit(fn ->
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

    {:ok, agent_id: agent_id}
  end

  test "security regression: Browser action run/2 without the envelope does not call JidoBrowser" do
    unauthorized_runs = unauthorized_runs()
    assert length(unauthorized_runs) == 26

    for {module, params} <- unauthorized_runs do
      {calls, result} =
        with_browser_io_trace(fn ->
          module.run(params, %{})
        end)

      assert {:error, "Unauthorized: :action_principal_authority_required"} = result,
             "#{inspect(module)} direct run/2: #{inspect(result)}"

      assert calls == [], "#{inspect(module)} called JidoBrowser: #{inspect(calls)}"
    end
  end

  test "security regression: Browser action run/2 with a spoofed agent_id does not call JidoBrowser" do
    for {module, params} <- unauthorized_runs() do
      {calls, result} =
        with_browser_io_trace(fn ->
          module.run(params, %{agent_id: "agent_spoof"})
        end)

      assert {:error, "Unauthorized: :action_principal_authority_required"} = result,
             "#{inspect(module)} spoofed agent_id run/2: #{inspect(result)}"

      assert calls == [], "#{inspect(module)} called JidoBrowser: #{inspect(calls)}"
    end
  end

  test "security regression: Browser action run/2 with a fake browser_session does not call JidoBrowser" do
    for {module, params} <- unauthorized_runs() do
      {calls, result} =
        with_browser_io_trace(fn ->
          module.run(params, %{browser_session: :fake})
        end)

      assert {:error, "Unauthorized: :action_principal_authority_required"} = result,
             "#{inspect(module)} fake browser_session run/2: #{inspect(result)}"

      assert calls == [], "#{inspect(module)} called JidoBrowser: #{inspect(calls)}"
    end
  end

  test "security regression: authorized session-required Browser actions still require a session and do not call JidoBrowser or Shell.authorize_and_execute",
       %{agent_id: agent_id} do
    for module <- @session_required_actions do
      authorize_agent(agent_id, Arbor.Actions.canonical_uri_for(module, %{}))

      {calls, result} =
        with_browser_io_trace(fn ->
          Arbor.Actions.authorize_and_execute(
            agent_id,
            module,
            minimal_params(module),
            %{agent_id: agent_id}
          )
        end)

      assert result == {:error, "No browser session in context"},
             "#{inspect(module)} authorized missing-session: #{inspect(result)}"

      refute :authorize_and_execute in calls,
             "#{inspect(module)} called Shell.authorize_and_execute: #{inspect(calls)}"

      refute Enum.any?(calls, &match?({:jido, _}, &1)),
             "#{inspect(module)} called JidoBrowser: #{inspect(calls)}"
    end
  end

  test "security regression: authorized Navigate keeps SSRF via Web.validate_url after the principal gate",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, "arbor://action/browser/navigate")

    blocked = [
      {"http://localhost:8080", "Blocked host"},
      {"http://10.0.0.1/admin", "Blocked private IP"},
      {"http://169.254.169.254/latest", "Blocked host"},
      {"file:///etc/passwd", "Blocked scheme"}
    ]

    for {url, expected} <- blocked do
      {calls, result} =
        with_browser_io_trace(fn ->
          Arbor.Actions.authorize_and_execute(
            agent_id,
            Browser.Navigate,
            %{url: url},
            %{agent_id: agent_id, browser_session: :fake}
          )
        end)

      assert {:error, message} = result,
             "authorized Navigate #{url}: #{inspect(result)}"

      assert message =~ expected, "authorized Navigate #{url}: #{inspect(result)}"

      refute message == "Unauthorized: :action_principal_authority_required",
             "authorized Navigate stayed at principal gate: #{inspect(result)}"

      refute :authorize_and_execute in calls,
             "authorized Navigate called Shell.authorize_and_execute: #{inspect(calls)}"

      refute Enum.any?(calls, &match?({:jido, _}, &1)),
             "authorized Navigate called JidoBrowser: #{inspect(calls)}"
    end
  end

  test "security regression: authorized StartSession uses JidoBrowser and does not call Shell.authorize_and_execute",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, "arbor://action/browser/start_session")

    {calls, result} =
      with_browser_io_trace(fn ->
        try do
          Arbor.Actions.authorize_and_execute(
            agent_id,
            Browser.StartSession,
            %{headless: true, timeout: 1, adapter: :not_a_real_adapter},
            %{agent_id: agent_id}
          )
        rescue
          # Fake adapter is intentional so JidoBrowser cannot launch a browser.
          UndefinedFunctionError -> :undefined_adapter
        end
      end)

    refute result == {:error, "Unauthorized: :action_principal_authority_required"},
           "authorized StartSession stayed at principal gate: #{inspect(result)}"

    assert {:jido, JidoBrowser.Actions.StartSession} in calls,
           "authorized StartSession did not call JidoBrowser.Actions.StartSession.run: #{inspect(calls)}"

    refute :authorize_and_execute in calls,
           "authorized StartSession called Shell.authorize_and_execute: #{inspect(calls)}"
  end

  test "security regression: authorized Wait uses JidoBrowser and does not call Shell.authorize_and_execute",
       %{agent_id: agent_id} do
    authorize_agent(agent_id, "arbor://action/browser/wait")

    {calls, result} =
      with_browser_io_trace(fn ->
        Arbor.Actions.authorize_and_execute(
          agent_id,
          Browser.Wait,
          %{ms: 0},
          %{agent_id: agent_id}
        )
      end)

    refute result == {:error, "Unauthorized: :action_principal_authority_required"},
           "authorized Wait stayed at principal gate: #{inspect(result)}"

    assert {:jido, JidoBrowser.Actions.Wait} in calls,
           "authorized Wait did not call JidoBrowser.Actions.Wait.run: #{inspect(calls)}"

    refute :authorize_and_execute in calls,
           "authorized Wait called Shell.authorize_and_execute: #{inspect(calls)}"
  end

  defp unauthorized_runs do
    Enum.map(@all_actions, fn module -> {module, minimal_params(module)} end)
  end

  defp authorize_agent(agent_id, resource) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: %{resource => :auto}})
    assert {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: resource)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp minimal_params(Browser.Navigate), do: %{url: "https://example.com"}
  defp minimal_params(Browser.Click), do: %{selector: "#btn"}
  defp minimal_params(Browser.Type), do: %{selector: "#input", text: "hello"}
  defp minimal_params(Browser.Hover), do: %{selector: "#el"}
  defp minimal_params(Browser.Focus), do: %{selector: "#el"}
  defp minimal_params(Browser.SelectOption), do: %{selector: "#select", value: "a"}
  defp minimal_params(Browser.Query), do: %{selector: "div"}
  defp minimal_params(Browser.GetText), do: %{selector: "p"}
  defp minimal_params(Browser.GetAttribute), do: %{selector: "a", attribute: "href"}
  defp minimal_params(Browser.IsVisible), do: %{selector: "#el"}
  defp minimal_params(Browser.WaitForSelector), do: %{selector: "#el"}
  defp minimal_params(Browser.Evaluate), do: %{script: "1+1"}
  defp minimal_params(Browser.Wait), do: %{ms: 1}
  defp minimal_params(Browser.StartSession), do: %{headless: true, timeout: 1}
  defp minimal_params(_mod), do: %{}

  defp with_browser_io_trace(fun) do
    parent = self()

    tracer =
      spawn_link(fn ->
        tracer_loop(parent, [])
      end)

    Enum.each(traced_mfas(), fn {mod, fun_name, arity} ->
      Code.ensure_loaded(mod)
      :erlang.trace_pattern({mod, fun_name, arity}, true, [])
    end)

    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      result = fun.()
      send(tracer, :done)

      receive do
        {:browser_io_calls, calls} -> {calls, result}
      after
        1_000 -> flunk("timed out waiting for browser-io tracer")
      end
    after
      :erlang.trace(self(), false, [:call])

      Enum.each(traced_mfas(), fn {mod, fun_name, arity} ->
        :erlang.trace_pattern({mod, fun_name, arity}, false, [])
      end)
    end
  end

  defp traced_mfas do
    jido_mfas =
      Enum.map(@all_actions, fn arbor_mod ->
        {jido_browser_module(arbor_mod), :run, 2}
      end)

    jido_mfas ++ [{Arbor.Shell, :authorize_and_execute, 3}]
  end

  defp jido_browser_module(arbor_module) do
    Module.concat(JidoBrowser.Actions, arbor_module |> Module.split() |> List.last())
  end

  defp tracer_loop(parent, acc) do
    receive do
      {:trace, _pid, :call, {Arbor.Shell, :authorize_and_execute, _args}} ->
        tracer_loop(parent, [:authorize_and_execute | acc])

      {:trace, _pid, :call, {mod, :run, _args}} ->
        tracer_loop(parent, [{:jido, mod} | acc])

      :done ->
        send(parent, {:browser_io_calls, Enum.reverse(acc)})
    after
      1_000 ->
        send(parent, {:browser_io_calls, Enum.reverse(acc)})
    end
  end
end
