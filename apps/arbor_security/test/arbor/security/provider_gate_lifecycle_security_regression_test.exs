defmodule Arbor.Security.ProviderGateLifecycleSecurityRegressionTest do
  @moduledoc """
  Security regression: Security composes the shared name-first provider gate.

  Generic monotonic lifecycle behavior is covered deeply by the Kernel Runtime
  provider-gate suite; this suite pins Security's app-owned declaration.
  """

  use ExUnit.Case, async: false

  @roots [:joken, :joken_jwks, :req]
  @restart_timeout 3_000

  setup do
    start_children = Application.fetch_env(:arbor_security, :start_children)
    runtime = Application.fetch_env(:arbor_kernel, :kernel_runtime)
    current = Application.get_env(:arbor_kernel, :kernel_runtime, [])

    Application.put_env(:arbor_security, :start_children, true)

    Application.put_env(
      :arbor_kernel,
      :kernel_runtime,
      Keyword.put(current, :start_profile, :full)
    )

    _ = Application.stop(:arbor_security)
    assert {:ok, _} = Application.ensure_all_started(:arbor_security)

    on_exit(fn ->
      _ = Application.stop(:arbor_security)
      restore_env(:arbor_security, :start_children, start_children)
      restore_env(:arbor_kernel, :kernel_runtime, runtime)
      :ok = Arbor.Security.TestBootstrap.restore_supervised_tree!()
    end)

    :ok
  end

  test "app-owned module declares the exact shared child specification" do
    assert function_exported?(Arbor.Security.ProviderGate, :child_spec, 1)

    assert %{
             id: Arbor.Security.ProviderGate,
             restart: :permanent,
             type: :worker,
             start:
               {Arbor.KernelRuntime.ProviderGate, :start_link,
                [[name: Arbor.Security.ProviderGate, roots: @roots]]}
           } = Arbor.Security.ProviderGate.child_spec([])
  end

  test "full topology keeps the symbolic gate first and providers admitted" do
    assert is_pid(Process.whereis(Arbor.Security.ProviderGate))

    start_ids =
      Arbor.Security.Supervisor
      |> Supervisor.which_children()
      |> Enum.map(&elem(&1, 0))
      |> Enum.reverse()

    assert hd(start_ids) == Arbor.Security.ProviderGate

    started = Application.started_applications() |> Enum.map(&elem(&1, 0))
    assert Enum.all?(@roots, &(&1 in started))
  end

  test "security regression: full static startup returns only after deferred Registry hydration and authority readiness" do
    :ok = Application.stop(:arbor_security)

    assert {:ok, _} = Application.ensure_all_started(:arbor_security)
    assert is_pid(Process.whereis(Arbor.Security.TerminalLogin))

    agent_id = Arbor.Security.SystemAuthority.agent_id()
    public_key = Arbor.Security.SystemAuthority.public_key()

    assert {:ok, ^public_key} = Arbor.Security.Identity.Registry.lookup(agent_id)
  end

  test "security regression: SystemAuthority crash restores authority before public use and restarts downstream in order" do
    authority = Process.whereis(Arbor.Security.SystemAuthority)
    downstream = Process.whereis(Arbor.Security.DeliveryReceiptBroker)
    expected_ids = supervisor_child_ids()

    assert is_pid(authority)
    assert is_pid(downstream)
    Process.exit(authority, :kill)

    assert eventually(fn ->
             replacement = Process.whereis(Arbor.Security.SystemAuthority)
             replacement_downstream = Process.whereis(Arbor.Security.DeliveryReceiptBroker)

             is_pid(replacement) and replacement != authority and is_pid(replacement_downstream) and
               replacement_downstream != downstream and system_authority_ready?()
           end)

    assert supervisor_child_ids() == expected_ids

    agent_id = Arbor.Security.SystemAuthority.agent_id()
    public_key = Arbor.Security.SystemAuthority.public_key()
    assert {:ok, ^public_key} = Arbor.Security.Identity.Registry.lookup(agent_id)
  end

  test "security regression: conflicting authority role proof stops and removes the partial root" do
    roles = Application.fetch_env!(:arbor_security, :signing_key_owner_roles)
    bad_roles = put_in(roles, [:system_authority, :path], [Arbor.Security.Identity.Registry])

    :ok = Application.stop(:arbor_security)
    Application.put_env(:arbor_security, :signing_key_owner_roles, bad_roles)

    try do
      assert {:error,
              {:arbor_security,
               {{:security_readiness_failed,
                 {:authority_registration_failed, :registration_conflict}},
                {Arbor.Security.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_security)

      refute Process.whereis(Arbor.Security.Supervisor)
      refute Process.whereis(Arbor.Security.SigningAuthorityBroker)
      refute Process.whereis(Arbor.Security.DeliveryReceiptBroker)
    after
      Application.put_env(:arbor_security, :signing_key_owner_roles, roles)
      assert {:ok, _} = Application.ensure_all_started(:arbor_security)
    end
  end

  test "actual gate-name collision keeps the typed error and starts no later child" do
    :ok = Application.stop(:arbor_security)
    {:ok, rogue} = Agent.start_link(fn -> :ok end, name: Arbor.Security.ProviderGate)
    Process.unlink(rogue)

    try do
      assert {:error,
              {:arbor_security,
               {{:provider_gate_name_collision, ^rogue}, {Arbor.Security.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_security)

      refute Process.whereis(Arbor.Security.Supervisor)
      refute Process.whereis(Arbor.Security.CapabilityStore)
    after
      Agent.stop(rogue)
      assert {:ok, _} = Application.ensure_all_started(:arbor_security)
    end
  end

  test "unrelated downstream collision remains an unrelated OTP error" do
    :ok = Application.stop(:arbor_security)
    {:ok, squat} = Agent.start_link(fn -> :ok end, name: Arbor.Security.DeliveryReceiptBroker)
    Process.unlink(squat)

    try do
      assert {:error, {:arbor_security, {reason, {Arbor.Security.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_security)

      refute match?({:provider_gate_name_collision, _}, reason)
      assert inspect(reason) =~ inspect(Arbor.Security.DeliveryReceiptBroker)
      assert Process.alive?(squat)
    after
      Agent.stop(squat)
      assert {:ok, _} = Application.ensure_all_started(:arbor_security)
    end
  end

  defp supervisor_child_ids do
    Arbor.Security.Supervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
  end

  defp system_authority_ready? do
    is_binary(Arbor.Security.SystemAuthority.agent_id()) and
      is_binary(Arbor.Security.SystemAuthority.public_key())
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp eventually(fun, timeout \\ @restart_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
        after
          10 -> eventually_until(fun, deadline)
        end
      end
    end
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
