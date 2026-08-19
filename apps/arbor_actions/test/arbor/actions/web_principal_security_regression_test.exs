defmodule Arbor.Actions.WebPrincipalSecurityRegressionTest do
  @moduledoc """
  Security regression: Web Jido actions must not perform network I/O or
  credential use without an authorized principal.

  Parent behavior (must fail on checkout of the exact parent):
  Browse, Search, Snapshot, ExaSearch, and TinyfishSearch ignore context
  and hit `jido_browser` or `Req` plus env API keys, so a direct `run/2`
  proceeds past the principal gate.

  Fixed behavior: they require `authorized_principal`. The authorized path
  is `Arbor.Actions.authorize_and_execute/4` then the existing
  network/credential implementation. Missing envelope uses
  `Actions.unauthorized_message/1` and never calls `Req.post`/`Req.get` or
  `jido_browser`. Web is not sent through `Shell.authorize_and_execute/3`.
  There is no host Web facade.
  """
  use Arbor.Actions.ActionCase, async: false

  @moduletag :fast
  @moduletag :security_regression

  alias Arbor.Actions.Web

  @unauthorized_runs [
    {Web.Browse, %{url: "https://example.com"}},
    {Web.Search, %{query: "p1d-e"}},
    {Web.Snapshot, %{url: "https://example.com"}},
    {Web.ExaSearch, %{query: "p1d-e"}},
    {Web.TinyfishSearch, %{query: "p1d-e"}}
  ]

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
      tinyfish: System.get_env("TINYFISH_API_KEY"),
      brave: System.get_env("BRAVE_SEARCH_API_KEY"),
      brave_app: Application.get_env(:jido_browser, :brave_api_key)
    }

    System.delete_env("EXA_API_KEY")
    System.delete_env("TINYFISH_API_KEY")
    System.delete_env("BRAVE_SEARCH_API_KEY")
    Application.delete_env(:jido_browser, :brave_api_key)

    agent_id = "agent_p1d_web_#{System.unique_integer([:positive])}"

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
      restore_env("EXA_API_KEY", previous_keys.exa)
      restore_env("TINYFISH_API_KEY", previous_keys.tinyfish)
      restore_env("BRAVE_SEARCH_API_KEY", previous_keys.brave)
      restore(:jido_browser, :brave_api_key, previous_keys.brave_app)
    end)

    {:ok, agent_id: agent_id}
  end

  test "security regression: Web action run/2 without the envelope does not call Req or jido_browser" do
    for {module, params} <- @unauthorized_runs do
      {calls, result} =
        with_web_io_trace(fn ->
          module.run(params, %{})
        end)

      assert {:error, "Unauthorized: :action_principal_authority_required"} = result,
             "#{inspect(module)} direct run/2: #{inspect(result)}"

      assert calls == [], "#{inspect(module)} performed network I/O: #{inspect(calls)}"
    end
  end

  test "security regression: Web action run/2 with a spoofed agent_id does not call Req or jido_browser" do
    for {module, params} <- @unauthorized_runs do
      {calls, result} =
        with_web_io_trace(fn ->
          module.run(params, %{agent_id: "agent_spoof"})
        end)

      assert {:error, "Unauthorized: :action_principal_authority_required"} = result,
             "#{inspect(module)} spoofed agent_id run/2: #{inspect(result)}"

      assert calls == [], "#{inspect(module)} performed network I/O: #{inspect(calls)}"
    end
  end

  test "security regression: authorized Web actions use existing implementation and do not call Shell.authorize_and_execute",
       %{agent_id: agent_id} do
    authorized_runs = [
      {Web.Browse, "arbor://net/http", %{url: "http://169.254.169.254/latest/meta-data/"}},
      {Web.Search, "arbor://net/search", %{query: "p1d-e"}},
      {Web.Snapshot, "arbor://net/http", %{url: "http://127.0.0.1:8080/admin"}},
      {Web.ExaSearch, "arbor://net/search", %{query: "p1d-e"}},
      {Web.TinyfishSearch, "arbor://net/search", %{query: "p1d-e"}}
    ]

    for {module, resource, params} <- authorized_runs do
      authorize_agent(agent_id, resource)

      {calls, result} =
        with_web_io_trace(fn ->
          Arbor.Actions.authorize_and_execute(
            agent_id,
            module,
            params,
            %{agent_id: agent_id}
          )
        end)

      assert {:error, message} = result,
             "#{inspect(module)} authorized path: #{inspect(result)}"

      assert is_binary(message), "#{inspect(module)} authorized path: #{inspect(result)}"

      refute message == "Unauthorized: :action_principal_authority_required",
             "#{inspect(module)} authorized path stayed at principal gate: #{inspect(result)}"

      refute :authorize_and_execute in calls,
             "#{inspect(module)} called Shell.authorize_and_execute: #{inspect(calls)}"
    end
  end

  defp authorize_agent(agent_id, resource) do
    {:ok, profile} = Arbor.Contracts.Trust.Profile.new(agent_id)
    :ok = Arbor.Trust.Store.store_profile(%{profile | rules: %{resource => :auto}})
    assert {:ok, _capability} = Arbor.Security.grant(principal: agent_id, resource: resource)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp with_web_io_trace(fun) do
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
        {:web_io_calls, calls} -> {calls, result}
      after
        1_000 -> flunk("timed out waiting for web-io tracer")
      end
    after
      :erlang.trace(self(), false, [:call])

      Enum.each(traced_mfas(), fn {mod, fun_name, arity} ->
        :erlang.trace_pattern({mod, fun_name, arity}, false, [])
      end)
    end
  end

  defp traced_mfas do
    [
      {Req, :post, 1},
      {Req, :post, 2},
      {Req, :get, 1},
      {Req, :get, 2},
      {Req, :request, 1},
      {Req, :request, 2},
      {JidoBrowser.Actions.ReadPage, :run, 2},
      {JidoBrowser.Actions.SearchWeb, :run, 2},
      {JidoBrowser.Actions.SnapshotUrl, :run, 2},
      {Arbor.Shell, :authorize_and_execute, 3}
    ]
  end

  defp tracer_loop(parent, acc) do
    receive do
      {:trace, _pid, :call, {Req, fun, _args}} when fun in [:post, :get, :request] ->
        tracer_loop(parent, [fun | acc])

      {:trace, _pid, :call, {JidoBrowser.Actions.ReadPage, :run, _args}} ->
        tracer_loop(parent, [:read_page | acc])

      {:trace, _pid, :call, {JidoBrowser.Actions.SearchWeb, :run, _args}} ->
        tracer_loop(parent, [:search_web | acc])

      {:trace, _pid, :call, {JidoBrowser.Actions.SnapshotUrl, :run, _args}} ->
        tracer_loop(parent, [:snapshot_url | acc])

      {:trace, _pid, :call, {Arbor.Shell, :authorize_and_execute, _args}} ->
        tracer_loop(parent, [:authorize_and_execute | acc])

      :done ->
        send(parent, {:web_io_calls, Enum.reverse(acc)})
    after
      1_000 ->
        send(parent, {:web_io_calls, Enum.reverse(acc)})
    end
  end
end
