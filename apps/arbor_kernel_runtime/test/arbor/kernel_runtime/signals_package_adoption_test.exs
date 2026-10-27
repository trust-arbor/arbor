defmodule Arbor.KernelRuntime.SignalsPackageAdoptionTest do
  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Contracts.Security.{AuthContext, Taint, TaintEnvelope}
  alias Arbor.KernelRuntime.Adapters.SignalAuthContext
  alias Arbor.Signals

  test "Signals modules have one package owner while the host owns their supervision" do
    package_modules = MapSet.new(Application.spec(:arbor_signals, :modules))
    host_modules = MapSet.new(Application.spec(:arbor_kernel_runtime, :modules))
    assert MapSet.disjoint?(package_modules, host_modules)

    for module <- [Signals, Signals.Bus, Signals.Store, Signals.SubscriptionRegistry] do
      assert Application.get_application(module) == :arbor_signals
      assert module in Application.spec(:arbor_signals, :modules)
      refute module in Application.spec(:arbor_kernel_runtime, :modules)
    end

    assert :arbor_signals in Application.spec(:arbor_kernel_runtime, :included_applications)
    refute :arbor_signals in Application.spec(:arbor_kernel_runtime, :applications)

    signals_supervisor = Process.whereis(Signals.Supervisor)
    assert is_pid(signals_supervisor)

    assert Enum.any?(Supervisor.which_children(Arbor.KernelRuntime.Supervisor), fn
             {Signals.Application, ^signals_supervisor, :supervisor, _modules} -> true
             _ -> false
           end)

    refute Enum.any?(Application.started_applications(), fn {app, _, _} ->
             app == :arbor_signals
           end)
  end

  test "host taint structs, canonical envelopes and legacy hashes remain compatible" do
    assert %Taint{level: :untrusted} = Signals.Taint.from_level(:untrusted)

    assert {:ok, taint} =
             Taint.new(
               level: :derived,
               sensitivity: :confidential,
               sanitizations: 0,
               confidence: :plausible,
               source: "host",
               chain: []
             )

    payload = %{"message" => "host contract compatibility"}
    assert {:ok, envelope} = TaintEnvelope.new(payload, taint)
    assert {:ok, persisted} = TaintEnvelope.to_map(envelope)

    assert Signals.Taint.bind_durable_provenance(payload, taint) == {:ok, persisted}

    assert {:ok, %TaintEnvelope{taint: verified}} =
             Signals.Taint.verify_durable_provenance(persisted, payload)

    assert verified == taint

    expected_hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(taint))
      |> Base.encode16(case: :lower)

    assert Signals.Taint.data_hash(taint) == expected_hash
  end

  test "the host credential adapter admits only the exact host context" do
    context = AuthContext.new("agent_package_host", signed_request: :bound_request)
    assert {:ok, "agent_package_host"} = SignalAuthContext.principal_id(context)
    assert {:ok, :bound_request} = SignalAuthContext.signed_request(context)

    assert {:error, :authenticated_principal_required} =
             SignalAuthContext.principal_id(Map.from_struct(context))

    assert {:error, :authenticated_principal_required} =
             SignalAuthContext.principal_id(
               Arbor.Signals.Contracts.AuthContext.new("agent_package_host")
             )

    assert {:error, :identity_proof_required} =
             SignalAuthContext.signed_request(AuthContext.new("agent_package_host"))
  end
end
