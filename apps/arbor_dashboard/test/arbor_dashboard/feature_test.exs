defmodule Arbor.Dashboard.FeatureTest do
  use ExUnit.Case, async: false

  @feature Arbor.Dashboard.Feature
  @forbidden_calls [
    {Application, :get_env, 2},
    {Application, :get_env, 3},
    {Application, :fetch_env, 2},
    {Application, :put_env, 3},
    {Application, :ensure_all_started, 1},
    {Application, :ensure_all_started, 2},
    {Supervisor, :start_link, 2},
    {Supervisor, :child_spec, 2},
    {GenServer, :start_link, 3},
    {Code, :ensure_loaded, 1},
    {Code, :ensure_loaded?, 1},
    {:gen_tcp, :listen, 2},
    {:erlang, :make_ref, 0},
    {:erlang, :spawn, 1},
    {:erlang, :spawn, 3},
    {:erlang, :spawn_link, 1},
    {:erlang, :spawn_link, 3},
    {:erlang, :spawn_monitor, 1},
    {:erlang, :spawn_monitor, 3},
    {Task, :start, 1},
    {:ets, :new, 2},
    {:persistent_term, :put, 2},
    {Phoenix.PubSub, :child_spec, 1},
    {Phoenix.PubSub.Supervisor, :child_spec, 1},
    {Arbor.Dashboard.Endpoint, :child_spec, 1},
    {Arbor.Dashboard.Endpoint, :start_link, 1}
  ]

  test "enabled full maps equal the real PubSub and selected Endpoint producers" do
    expected = [
      Phoenix.PubSub.child_spec(name: Arbor.Dashboard.PubSub),
      Arbor.Dashboard.Endpoint.child_spec([])
    ]

    actual = children(%{start_children: true})
    assert actual == expected
    assert Enum.map(actual, & &1.id) == [Phoenix.PubSub.Supervisor, Arbor.Dashboard.Endpoint]
    assert Enum.all?(actual, &(Enum.sort(Map.keys(&1)) == [:id, :start, :type]))
    assert Enum.at(actual, 1).start == {Arbor.Dashboard.Endpoint, :start_link, [[]]}
    assert children(%{start_children: false}) == []
  end

  test "only an explicit resolved boolean can select the disabled branch" do
    for snapshot <- [
          nil,
          [],
          %{},
          %{start_children: nil},
          %{start_children: :unknown},
          %{start_children: true, child_plan: []},
          %{start_children: false, private: "private-owner-input"},
          %{start_children: true, endpoint: {Code, :eval_string, ["not-code"]}}
        ] do
      assert_redacted(snapshot)
    end
  end

  test "rendering reads no sessions or configuration and calls no producers or starts" do
    apply(@feature, :health, [])

    {enabled, disabled, refusal, routes, health} =
      assert_passive(fn ->
        {
          children(%{start_children: true}),
          children(%{start_children: false}),
          refusal_kind(%{start_children: "private-owner-input"}),
          apply(@feature, :routes, []),
          apply(@feature, :health, [])
        }
      end)

    assert length(enabled) == 2
    assert disabled == []
    assert refusal == :refused
    assert length(routes) == 19
    assert health == %{status: :unobserved}
  end

  test "routes preserve independent source paths and delegated coverage without session values" do
    routes = apply(@feature, :routes, [])
    paths = for %{kind: :live, path: path} <- routes, do: path

    assert paths == [
             "/",
             "/console",
             "/signals",
             "/eval",
             "/consensus",
             "/events",
             "/agents",
             "/monitor",
             "/roadmap",
             "/home",
             "/c/:engagement_id",
             "/conversation/:agent_id",
             "/channels",
             "/memory",
             "/memory/:agent_id",
             "/telemetry",
             "/settings"
           ]

    assert %{
             kind: :route,
             method: "GET",
             path: "/chat",
             owner: Arbor.Dashboard.LegacyChatController,
             action: :index
           } in routes

    assert %{
             kind: :delegated_router_macro,
             owner: Arbor.Web.Router,
             scope: "/",
             coverage: :delegated_unexpanded
           } in routes

    refute Enum.any?(routes, &Map.has_key?(&1, :session))
    assert apply(@feature, :action_modules, []) == []
    assert apply(@feature, :uri_prefixes, []) == []
    assert apply(@feature, :health, []) == %{status: :unobserved}
  end

  test "packaged metadata preserves the fixed Core prerequisite and public IDs" do
    assert apply(@feature, :id, []) == :dashboard
    assert apply(@feature, :requires, []) == [:core]
    refute function_exported?(@feature, :graphs, 0)
    refute function_exported?(@feature, :commands, 0)
    assert Application.fetch_env!(:arbor_dashboard, :arbor_feature) == @feature
    metadata = Application.fetch_env!(:arbor_dashboard, :arbor_feature_metadata)
    assert metadata.id == :dashboard
    assert metadata.requires == [:core]
    assert metadata.dependency_role == :fixed_host_prerequisite
    assert metadata.contribution_scope == :direct_application_entrypoint
    assert metadata.snapshot_required_keys == [:start_children]
    assert metadata.public_child_ids == [Phoenix.PubSub.Supervisor, Arbor.Dashboard.Endpoint]
    refute Map.has_key?(metadata, :start)
    refute Map.has_key?(metadata, :args)
  end

  test "fixed Application and Router pins force a wiring review" do
    assert_source_pin(
      "../../lib/arbor_dashboard/application.ex",
      "38766afcdbb689a24772990b562ab4917f6f9d90da4c57acfad53689ab716117"
    )

    assert_source_pin(
      "../../lib/arbor_dashboard/router.ex",
      "e42d26d7ccae83f5fc66a177d2e043d55cce38993a60d3372ccd441f78f84298"
    )

    assert_source_pin(
      "../../lib/arbor_dashboard/endpoint.ex",
      "7cf875ae11083cbe461584ccc4b2d6240c49c8bf9a4a8f8dc991e1e2f4ef1c04"
    )
  end

  defp assert_passive(fun) do
    caller = self()
    tracer = spawn(fn -> collect_calls([]) end)

    try do
      Enum.each(@forbidden_calls, fn {module, _function, _arity} ->
        Code.ensure_loaded?(module)
      end)

      Enum.each(@forbidden_calls, fn pattern ->
        assert :erlang.trace_pattern(pattern, true, [:local]) > 0
      end)

      :erlang.trace(caller, true, [:call, :arity, {:tracer, tracer}])
      result = fun.()
      :erlang.trace(caller, false, [:call, :arity])
      marker = :erlang.trace_delivered(caller)
      assert_receive {:trace_delivered, ^caller, ^marker}, 1_000
      send(tracer, {:collected, caller})
      assert_receive {:feature_calls, ^tracer, calls}, 1_000
      assert calls == []
      result
    after
      :erlang.trace(caller, false, [:call, :arity])
      Enum.each(@forbidden_calls, &:erlang.trace_pattern(&1, false, [:local]))
      Process.exit(tracer, :kill)
    end
  end

  defp collect_calls(calls) do
    receive do
      {:trace, _pid, :call, {module, function, arity}} when is_integer(arity) ->
        collect_calls([{module, function, arity} | calls])

      {:collected, caller} ->
        send(caller, {:feature_calls, self(), Enum.reverse(calls)})
    end
  end

  defp refusal_kind(snapshot) do
    children(snapshot)
    :accepted
  rescue
    ArgumentError -> :refused
  end

  defp assert_redacted(snapshot) do
    error = assert_raise ArgumentError, fn -> children(snapshot) end
    assert Exception.message(error) == "invalid feature snapshot"
  end

  defp children(snapshot), do: apply(@feature, :children, [snapshot])

  defp assert_source_pin(relative, expected) do
    bytes = File.read!(Path.expand(relative, __DIR__))
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert actual == expected
  end
end
