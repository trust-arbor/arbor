defmodule Arbor.Trust.ProviderGateLifecycleSecurityRegressionTest do
  @moduledoc """
  Security regression: Trust composes the shared name-first provider gate.

  Generic monotonic lifecycle behavior is covered deeply by the Kernel Runtime
  provider-gate suite; this suite pins Trust's app-owned declaration.
  """

  use ExUnit.Case, async: false

  @roots [:arbor_persistence, :phoenix_pubsub]

  setup do
    start_children = Application.fetch_env(:arbor_trust, :start_children)
    runtime = Application.fetch_env(:arbor_kernel, :kernel_runtime)
    current = Application.get_env(:arbor_kernel, :kernel_runtime, [])

    Application.put_env(:arbor_trust, :start_children, true)

    Application.put_env(
      :arbor_kernel,
      :kernel_runtime,
      Keyword.put(current, :start_profile, :full)
    )

    _ = Application.stop(:arbor_trust)
    release_policy_claim()
    assert {:ok, _} = Application.ensure_all_started(:arbor_trust)

    on_exit(fn ->
      _ = Application.stop(:arbor_trust)
      release_policy_claim()
      restore_env(:arbor_trust, :start_children, start_children)
      restore_env(:arbor_kernel, :kernel_runtime, runtime)
      {:ok, _} = Application.ensure_all_started(:arbor_trust)
    end)

    :ok
  end

  test "app-owned module declares the exact shared child specification" do
    assert function_exported?(Arbor.Trust.ProviderGate, :child_spec, 1)

    assert %{
             id: Arbor.Trust.ProviderGate,
             restart: :permanent,
             type: :worker,
             start:
               {Arbor.KernelRuntime.ProviderGate, :start_link,
                [[name: Arbor.Trust.ProviderGate, roots: @roots]]}
           } = Arbor.Trust.ProviderGate.child_spec([])
  end

  test "full topology keeps the symbolic gate between host and consumers" do
    assert is_pid(Process.whereis(Arbor.Trust.ProviderGate))

    start_ids =
      Arbor.Trust.ApplicationSupervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    assert start_ids == [
             Arbor.Trust.PolicyHost,
             Arbor.Trust.ProviderGate,
             Arbor.Trust.Supervisor
           ]

    started = Application.started_applications() |> Enum.map(&elem(&1, 0))
    assert Enum.all?(@roots, &(&1 in started))
  end

  test "actual gate-name collision keeps the typed error and starts no later child" do
    :ok = Application.stop(:arbor_trust)
    release_policy_claim()
    {:ok, rogue} = Agent.start_link(fn -> :ok end, name: Arbor.Trust.ProviderGate)
    Process.unlink(rogue)

    try do
      assert {:error,
              {:arbor_trust,
               {{:provider_gate_name_collision, ^rogue}, {Arbor.Trust.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_trust)

      refute Process.whereis(Arbor.Trust.ApplicationSupervisor)
      refute Process.whereis(Arbor.Trust.Supervisor)
    after
      Agent.stop(rogue)
      release_policy_claim()
      assert {:ok, _} = Application.ensure_all_started(:arbor_trust)
    end
  end

  test "unrelated downstream collision remains an unrelated OTP error" do
    :ok = Application.stop(:arbor_trust)
    release_policy_claim()
    {:ok, squat} = Agent.start_link(fn -> :ok end, name: Arbor.Trust.Supervisor)
    Process.unlink(squat)

    try do
      assert {:error, {:arbor_trust, {reason, {Arbor.Trust.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_trust)

      refute match?({:provider_gate_name_collision, _}, reason)
      assert inspect(reason) =~ inspect(Arbor.Trust.Supervisor)
      assert Process.alive?(squat)
    after
      Agent.stop(squat)
      release_policy_claim()
      assert {:ok, _} = Application.ensure_all_started(:arbor_trust)
    end
  end

  defp release_policy_claim do
    if function_exported?(Arbor.Trust.PolicyHost, :release_claim, 0) do
      Arbor.Trust.PolicyHost.release_claim()
    end
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
