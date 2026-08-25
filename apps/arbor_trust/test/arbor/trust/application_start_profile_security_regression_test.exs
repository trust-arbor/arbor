defmodule Arbor.Trust.ApplicationStartProfileSecurityRegressionTest do
  @moduledoc """
  P1B-1: KernelRuntime start-profile selects the Trust policy host, freezes
  ceilings, and fails closed when the host is gone. Public callers cannot
  weaken host ceilings with opts or post-start Application env.
  """

  use ExUnit.Case, async: false

  @moduletag :fast

  alias Arbor.Trust.Policy

  @invalid_start_profiles [:unknown, "full", "activation_only", nil, 1, %{}]
  @provider_names [
    Arbor.Trust.Manager,
    Arbor.Trust.Store,
    Arbor.Trust.EventStore,
    Arbor.Trust.EventHandler,
    Arbor.Trust.CapabilitySync,
    Arbor.Trust.ConfirmationTracker,
    Arbor.Trust.CircuitBreaker,
    :arbor_trust_profiles
  ]

  defmodule ActionProfileProvider do
    def action_namespace_capability_profiles do
      :persistent_term.put({__MODULE__, :invoked}, true)

      [
        Arbor.Contracts.Security.CapabilityProfile.new!(%{
          uri_prefix: "arbor://action/browser/navigate",
          owner: :arbor_actions,
          blast_radius: :medium,
          reversibility: :read_only,
          effect_class: :read,
          data_class: :internal,
          arg_dependent: true,
          default_approval: :require_human,
          delegable: false,
          cost_class: :cheap,
          graduation_eligible: true
        })
      ]
    end
  end

  setup do
    originals = %{
      start_children: Application.get_env(:arbor_trust, :start_children),
      kernel_runtime: Application.fetch_env(:arbor_kernel, :kernel_runtime),
      security_ceilings: Application.get_env(:arbor_trust, :security_ceilings),
      default_egress_modes: Application.get_env(:arbor_trust, :default_egress_modes),
      allow_permissive_baseline: Application.get_env(:arbor_trust, :allow_permissive_baseline),
      action_profile_provider: Application.get_env(:arbor_trust, :action_profile_provider)
    }

    on_exit(fn -> restore_trust_app(originals) end)
    :ok
  end

  test "activation_only starts only the policy host and stays healthy without providers" do
    assert {:ok, _} = restart_trust!(:activation_only, true)

    assert application_child_ids() == MapSet.new([Arbor.Trust.PolicyHost])
    refute_providers()
    assert Arbor.Trust.healthy?()

    assert {:ok, _} = Arbor.Trust.start_link([])
    refute Process.whereis(Arbor.Trust.Manager)

    unknown = "agent_activation_#{System.unique_integer([:positive])}"
    assert Policy.effective_mode(unknown, "arbor://shell/exec/ls") == :ask
    assert Policy.egress_mode(unknown, :external_provider) == :ask
  end

  test "post-start env and action providers cannot weaken an activation-only host" do
    assert {:ok, _} = restart_trust!(:activation_only, true)

    unknown = "agent_frozen_#{System.unique_integer([:positive])}"

    Application.put_env(:arbor_trust, :default_egress_modes, %{external_provider: :allow})
    Application.put_env(:arbor_trust, :security_ceilings, %{"arbor://shell" => :auto})
    Application.put_env(:arbor_trust, :allow_permissive_baseline, true)
    Application.put_env(:arbor_trust, :action_profile_provider, ActionProfileProvider)

    assert Policy.egress_mode(unknown, :external_provider) == :ask
    assert Policy.effective_mode(unknown, "arbor://shell/exec/ls") == :ask

    profile_uris =
      Arbor.Trust.CapabilityProfileRegistry.profiles()
      |> Enum.map(& &1.uri_prefix)

    refute "arbor://action/browser/navigate" in profile_uris
  end

  test ":full starts the policy host plus the provider tree" do
    assert {:ok, _} = restart_trust!(:full, true)

    ids = application_child_ids()
    assert MapSet.member?(ids, Arbor.Trust.PolicyHost)
    assert MapSet.member?(ids, Arbor.Trust.Supervisor)
    assert Process.whereis(Arbor.Trust.Manager)
    assert Arbor.Trust.healthy?()
  end

  test "caller more-specific :auto cannot weaken the frozen shell ceiling" do
    assert {:ok, _} = restart_trust!(:full, true)

    agent_id = "agent_ceiling_#{System.unique_integer([:positive])}"
    assert {:ok, _} = Arbor.Trust.create_trust_profile(agent_id)

    {:ok, _} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{
          profile
          | baseline: :ask,
            rules: %{
              "arbor://shell" => :auto,
              "arbor://shell/exec/ls" => :auto
            }
        }
      end)

    assert Policy.effective_mode(agent_id, "arbor://shell/exec/ls",
             security_ceilings: %{"arbor://shell/exec/ls" => :auto}
           ) == :ask

    assert Policy.effective_mode(agent_id, "arbor://shell/exec/ls", security_ceilings: %{}) ==
             :ask
  end

  test "unknown or malformed start profiles fail closed even when start_children is false" do
    Enum.each(@invalid_start_profiles, fn value ->
      Application.put_env(:arbor_trust, :start_children, false)
      put_kernel_runtime(start_profile: value)
      _ = Application.stop(:arbor_trust)
      maybe_release_claim()

      assert {:error, {:arbor_trust, {reason, {Arbor.Trust.Application, :start, _}}}} =
               Application.ensure_all_started(:arbor_trust)

      assert reason == {:invalid_start_profile, value}
      refute Process.whereis(Arbor.Trust.ApplicationSupervisor)
    end)
  end

  test "host loss fails closed" do
    assert {:ok, _} = restart_trust!(:activation_only, true)
    _ = Application.stop(:arbor_trust)

    assert Policy.effective_mode("agent_lost", "arbor://shell/exec/ls") == :block
    refute Arbor.Trust.healthy?()
  end

  test "bind rejects a frozen start_profile that does not match the requested profile" do
    assert Code.ensure_loaded?(Arbor.Trust.PolicyHost)
    _ = Application.stop(:arbor_trust)
    maybe_release_claim()

    {:ok, snapshot} = Arbor.Trust.Config.startup_policy_snapshot(:activation_only)

    assert {:error, {:policy_host_profile_mismatch, :activation_only, :full}} =
             Arbor.Trust.PolicyHost.start_link(start_profile: :full, snapshot: snapshot)
  end

  test "preconfigured action provider is not invoked on activation_only" do
    :persistent_term.erase({ActionProfileProvider, :invoked})
    Application.put_env(:arbor_trust, :action_profile_provider, ActionProfileProvider)
    assert {:ok, _} = restart_trust!(:activation_only, true)

    _ = Arbor.Trust.CapabilityProfileRegistry.profiles()
    refute :persistent_term.get({ActionProfileProvider, :invoked}, false)

    profile_uris =
      Arbor.Trust.CapabilityProfileRegistry.profiles()
      |> Enum.map(& &1.uri_prefix)

    refute "arbor://action/browser/navigate" in profile_uris
  end

  test "post-start permissive-baseline env cannot weaken a frozen host" do
    assert {:ok, _} = restart_trust!(:full, true)

    agent_id = "agent_baseline_#{System.unique_integer([:positive])}"
    assert {:ok, _} = Arbor.Trust.create_trust_profile(agent_id)

    {:ok, _} =
      Arbor.Trust.Store.update_profile(agent_id, fn profile ->
        %{profile | baseline: :allow, rules: %{}}
      end)

    assert Policy.effective_mode(agent_id, "arbor://code/read") == :block
    Application.put_env(:arbor_trust, :allow_permissive_baseline, true)
    assert Policy.effective_mode(agent_id, "arbor://code/read") == :block
  end

  test "malformed startup egress overrides fail closed" do
    Application.put_env(:arbor_trust, :start_children, true)
    Application.put_env(:arbor_trust, :default_egress_modes, %{external_provider: :not_a_mode})
    put_kernel_runtime(start_profile: :activation_only)
    _ = Application.stop(:arbor_trust)
    maybe_release_claim()

    assert {:error, _} = Application.ensure_all_started(:arbor_trust)
    refute Process.whereis(Arbor.Trust.ApplicationSupervisor)
  end

  test "caller egress_mode cannot weaken authorize_egress or authorize" do
    previous_enforcing = Application.get_env(:arbor_security, :egress_gate_enforcing)
    Application.put_env(:arbor_security, :egress_gate_enforcing, true)

    on_exit(fn ->
      restore_security_env(:egress_gate_enforcing, previous_enforcing)
    end)

    assert {:ok, _} = restart_trust!(:activation_only, true)
    unknown = "agent_egress_#{System.unique_integer([:positive])}"

    assert Arbor.Trust.authorize_egress(unknown, :external_provider, egress_mode: :auto) ==
             {:requires_approval, :egress}

    assert {:error, :malformed_policy_opts} =
             Arbor.Trust.authorize(unknown, "arbor://ai/generate", :execute,
               egress_tier: :external_provider,
               egress_mode: :bogus
             )
  end

  test "malformed ceiling and permissive opts fail closed" do
    assert {:ok, _} = restart_trust!(:activation_only, true)
    unknown = "agent_opts_#{System.unique_integer([:positive])}"

    assert Policy.effective_mode(unknown, "arbor://shell/exec/ls", security_ceilings: :not_a_map) ==
             :block

    assert Policy.effective_mode(unknown, "arbor://shell/exec/ls",
             allow_permissive_baseline: :yes
           ) == :block

    assert {:error, {:egress_blocked, :external_provider, :malformed_policy_opts}} =
             Arbor.Trust.authorize_egress(unknown, :external_provider, egress_mode: :invalid)
  end

  defp restart_trust!(profile, start_children) do
    Application.put_env(:arbor_trust, :start_children, start_children)
    put_kernel_runtime(start_profile: profile)
    _ = Application.stop(:arbor_trust)
    maybe_release_claim()
    Application.ensure_all_started(:arbor_trust)
  end

  defp put_kernel_runtime(updates) do
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []
    value = Enum.reduce(updates, current, fn {key, item}, acc -> Keyword.put(acc, key, item) end)
    Application.put_env(:arbor_kernel, :kernel_runtime, value)
  end

  defp application_child_ids do
    Arbor.Trust.ApplicationSupervisor
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp refute_providers do
    Enum.each(@provider_names, fn name ->
      refute Process.whereis(name)
    end)
  end

  defp maybe_release_claim do
    if function_exported?(Arbor.Trust.PolicyHost, :release_claim, 0) do
      Arbor.Trust.PolicyHost.release_claim()
    end
  end

  defp restore_trust_app(originals) do
    _ = Application.stop(:arbor_trust)
    maybe_release_claim()
    :persistent_term.erase({ActionProfileProvider, :invoked})

    restore_env(:start_children, originals.start_children)
    restore_env(:security_ceilings, originals.security_ceilings)
    restore_env(:default_egress_modes, originals.default_egress_modes)
    restore_env(:allow_permissive_baseline, originals.allow_permissive_baseline)
    restore_env(:action_profile_provider, originals.action_profile_provider)

    case originals.kernel_runtime do
      {:ok, value} -> Application.put_env(:arbor_kernel, :kernel_runtime, value)
      :error -> Application.delete_env(:arbor_kernel, :kernel_runtime)
    end

    {:ok, _} = Application.ensure_all_started(:arbor_trust)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_trust, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_trust, key, value)

  defp restore_security_env(key, nil), do: Application.delete_env(:arbor_security, key)
  defp restore_security_env(key, value), do: Application.put_env(:arbor_security, key, value)
end
