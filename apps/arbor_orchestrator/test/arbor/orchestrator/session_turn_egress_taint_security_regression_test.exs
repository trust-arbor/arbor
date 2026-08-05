defmodule Arbor.Orchestrator.SessionTurnEgressTaintSecurityRegressionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Orchestrator.Session.TurnEgress

  @agent_id "agent_turn_egress_taint"

  setup do
    Code.ensure_loaded!(Arbor.Trust)
    test_pid = self()
    tracer = spawn(fn -> trust_trace_owner(test_pid) end)

    assert_receive {:trust_trace_ready, ^tracer}

    on_exit(fn ->
      send(tracer, :stop)
    end)

    :ok
  end

  test "security regression: dynamic hostile and untrusted taint reach Trust exactly" do
    route = local_route()
    authorizer = build_dynamic_authorizer(bindings(route))

    for level <- [:untrusted, :hostile] do
      taint = %Taint{
        level: level,
        sensitivity: :internal,
        sanitizations: 0,
        confidence: :unverified,
        source: "test",
        chain: []
      }

      _result = authorizer.(route, taint)

      assert_receive {:trust_trace, pid, [@agent_id, :on_host, trust_opts]}

      assert pid == self()
      assert Keyword.fetch!(trust_opts, :egress_taint) == level
    end
  end

  test "security regression: malformed and extended taint fails closed before Trust" do
    route = local_route()
    authorizer = build_dynamic_authorizer(bindings(route))

    extended =
      %Taint{level: :hostile}
      |> Map.from_struct()
      |> Map.put(:__struct__, Taint)
      |> Map.put(:caller_extension, :forged)

    malformed = [
      nil,
      :hostile,
      %{level: :hostile},
      %Taint{level: :unknown},
      %Taint{sensitivity: :unknown},
      %Taint{confidence: :unknown},
      %Taint{sanitizations: 256},
      %Taint{source: {:caller, :term}},
      %Taint{chain: ["ok", :caller_term]},
      extended
    ]

    for taint <- malformed do
      assert {:error, {:egress_blocked, :external_provider, :invalid_taint}} =
               authorizer.(route, taint)

      refute_receive {:trust_trace, _, _}, 10
    end
  end

  test "build_authorizer compatibility delegates with conservative untrusted taint" do
    route = local_route()
    authorizer = TurnEgress.build_authorizer(bindings(route))

    _result = authorizer.(route)

    assert_receive {:trust_trace, _, [@agent_id, :on_host, trust_opts]}

    assert Keyword.fetch!(trust_opts, :egress_taint) == :untrusted
  end

  defp local_route do
    %{
      destination: "lmstudio",
      provider: "lmstudio",
      runtime: "arbor",
      model: "local-taint-test"
    }
  end

  defp bindings(route) do
    %{
      fence: TurnEgress.new_fence(),
      frozen_route: route,
      frozen_tier: :on_host,
      agent_id: @agent_id,
      session_id: "session_turn_egress_taint",
      turn_id: nil,
      human_id: nil,
      disclosure_capability_id: nil
    }
  end

  # Base-compatible selector: base's arity-1 authorizer always projects
  # :untrusted. The hostile assertion therefore fails behaviorally on base.
  defp build_dynamic_authorizer(bindings) do
    if function_exported?(TurnEgress, :build_taint_authorizer, 1) do
      apply(TurnEgress, :build_taint_authorizer, [bindings])
    else
      compatibility = TurnEgress.build_authorizer(bindings)
      fn route, _taint -> compatibility.(route) end
    end
  end

  defp trust_trace_owner(test_pid) do
    :erlang.trace(test_pid, true, [:call, {:tracer, self()}])
    :erlang.trace_pattern({Arbor.Trust, :authorize_egress, 3}, true, [])
    send(test_pid, {:trust_trace_ready, self()})
    trust_trace_loop(test_pid)
  end

  defp trust_trace_loop(test_pid) do
    receive do
      {:trace, traced_pid, :call, {Arbor.Trust, :authorize_egress, args}} ->
        send(test_pid, {:trust_trace, traced_pid, args})
        trust_trace_loop(test_pid)

      :stop ->
        :erlang.trace_pattern({Arbor.Trust, :authorize_egress, 3}, false, [])
        :ok

      _other ->
        trust_trace_loop(test_pid)
    end
  end
end
