defmodule Arbor.KernelRuntime.FeatureTest do
  use ExUnit.Case, async: false

  @feature Arbor.KernelRuntime.Feature
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
    {Arbor.KernelRuntime.ProviderGate, :child_spec, 1},
    {Arbor.KernelRuntime, :start_provider_gate_supervisor, 3}
  ]

  test "both admitted profiles match literal owner wiring and the actual gate producer" do
    owner = %{
      id: Arbor.KernelRuntime.BootProfileBinding,
      start: {Arbor.KernelRuntime.BootProfileBinding, :start_link, [[]]},
      type: :worker,
      restart: :permanent
    }

    assert children(%{start_profile: :activation_only, profile_admission: :admitted}) == [owner]

    expected = [
      owner,
      Arbor.KernelRuntime.ProviderGate.child_spec([]),
      %{
        id: Arbor.Common.Application,
        start: {Arbor.Common.Application, :start, [:normal, []]},
        type: :supervisor
      },
      %{
        id: Arbor.Signals.Application,
        start: {Arbor.Signals.Application, :start, [:normal, []]},
        type: :supervisor
      },
      %{
        id: Arbor.Monitor.Application,
        start: {Arbor.Monitor.Application, :start, [:normal, []]},
        type: :supervisor
      }
    ]

    actual = children(%{start_profile: :full, profile_admission: :admitted})
    assert actual == expected
    assert Enum.map(actual, & &1.id) == Enum.map(expected, & &1.id)
    assert Enum.sort(Map.keys(Enum.at(actual, 1))) == [:id, :restart, :start, :type]
    assert Enum.sort(Map.keys(Enum.at(actual, 2))) == [:id, :start, :type]
  end

  test "missing refused unknown and injected-plan inputs all fail with fixed redaction" do
    for snapshot <- [
          nil,
          [],
          %{},
          %{start_profile: :full},
          %{profile_admission: :admitted},
          %{start_profile: :other, profile_admission: :admitted},
          %{start_profile: :full, profile_admission: :refused},
          %{start_profile: :full, profile_admission: :not_observed},
          %{start_profile: :full, profile_admission: :admitted, child_plan: []},
          %{start_profile: :full, profile_admission: :admitted, private: fn -> "secret" end}
        ] do
      assert_redacted(snapshot)
    end
  end

  test "rendering both profiles and redacted refusal does not call runtime producers or effects" do
    apply(@feature, :health, [])

    {activation, full, refusal, health} =
      assert_passive(fn ->
        {
          children(%{start_profile: :activation_only, profile_admission: :admitted}),
          children(%{start_profile: :full, profile_admission: :admitted}),
          refusal_kind(%{start_profile: :full, profile_admission: "private-owner-input"}),
          apply(@feature, :health, [])
        }
      end)

    assert length(activation) == 1
    assert length(full) == 5
    assert refusal == :refused
    assert health == %{status: :unobserved}
  end

  test "static metadata is the fixed host declaration with public child IDs only" do
    assert apply(@feature, :id, []) == :core
    assert apply(@feature, :requires, []) == []
    refute function_exported?(@feature, :graphs, 0)
    refute function_exported?(@feature, :commands, 0)
    assert apply(@feature, :action_modules, []) == []
    assert apply(@feature, :uri_prefixes, []) == []
    assert apply(@feature, :routes, []) == []
    assert apply(@feature, :health, []) == %{status: :unobserved}

    assert Application.fetch_env!(:arbor_kernel_runtime, :arbor_feature) == @feature
    metadata = Application.fetch_env!(:arbor_kernel_runtime, :arbor_feature_metadata)
    assert metadata.id == :core
    assert metadata.requires == []
    assert metadata.dependency_role == :fixed_host
    assert metadata.contribution_scope == :direct_application_entrypoint
    assert metadata.snapshot_required_keys == [:start_profile, :profile_admission]

    assert metadata.public_child_ids == [
             Arbor.KernelRuntime.BootProfileBinding,
             Arbor.KernelRuntime.ProviderGate,
             Arbor.Common.Application,
             Arbor.Signals.Application,
             Arbor.Monitor.Application
           ]

    refute Map.has_key?(metadata, :start)
    refute Map.has_key?(metadata, :args)
  end

  test "fixed wiring and gate source pins force review when either source changes" do
    assert_source_pin(
      "../../../lib/arbor/kernel_runtime/application.ex",
      "6f2a075b1f38b82fdb64e9ee3941b312bbc5c832c497749c58a244e800884255"
    )

    assert_source_pin(
      "../../../lib/arbor/kernel_runtime.ex",
      "da089a7d574ff2b84821123093f5dc9746c117b5419f62e631b9978665e48277"
    )

    assert_source_pin(
      "../../../lib/arbor/kernel_runtime/provider_gate.ex",
      "bcb0c827dfa4aadf76036d7ce3c3d2e38936d9abb8508a8fa7ba5167724d9be9"
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
