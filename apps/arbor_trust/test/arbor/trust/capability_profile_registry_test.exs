defmodule Arbor.Trust.CapabilityProfileRegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.CapabilityProfile
  alias Arbor.Trust.CapabilityProfileRegistry

  @moduletag :fast

  defmodule ActionProfileProvider do
    def action_namespace_capability_profiles do
      [
        CapabilityProfile.new!(%{
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
      provider: Application.get_env(:arbor_trust, :action_profile_provider),
      start_children: Application.get_env(:arbor_trust, :start_children),
      kernel_runtime: Application.fetch_env(:arbor_kernel, :kernel_runtime)
    }

    on_exit(fn ->
      restore_env(:action_profile_provider, originals.provider)
      restore_env(:start_children, originals.start_children)

      case originals.kernel_runtime do
        {:ok, value} -> Application.put_env(:arbor_kernel, :kernel_runtime, value)
        :error -> Application.delete_env(:arbor_kernel, :kernel_runtime)
      end

      rebind_trust!()
    end)

    Application.put_env(:arbor_trust, :action_profile_provider, nil)
    rebind_trust!(:full, false)
    :ok
  end

  describe "coverage_rows/0" do
    test "every canonical registered prefix has a profile or explicit owner/reason row" do
      assert CapabilityProfileRegistry.coverage_complete?()
      assert CapabilityProfileRegistry.coverage_gaps() == []
    end

    test "high-risk registered prefixes resolve to contract profiles" do
      assert %CapabilityProfile{owner: :arbor_shell, uri_prefix: "arbor://shell"} =
               CapabilityProfileRegistry.profile_for("arbor://shell/exec")

      assert %CapabilityProfile{owner: :arbor_security, uri_prefix: "arbor://fs/write"} =
               CapabilityProfileRegistry.profile_for("arbor://fs/write")
    end

    test "non-profiled registered prefixes carry owning library annotations" do
      rows = Map.new(CapabilityProfileRegistry.coverage_rows(), &{&1.uri_prefix, &1})

      assert rows["arbor://persistence/read"].owner == :arbor_persistence
      assert rows["arbor://persistence/read"].profile == nil

      assert rows["arbor://persistence/read"].not_profileable_reason =~
               "owned by arbor_persistence"
    end

    test "absent action provider annotates arbor://action ownership without granting a profile" do
      assert CapabilityProfileRegistry.owner_for("arbor://action/browser/navigate") ==
               :arbor_actions

      assert CapabilityProfileRegistry.profile_for("arbor://action/browser/navigate") == nil
      assert CapabilityProfileRegistry.owner_for("arbor://agent/action") == :arbor_agent
      assert CapabilityProfileRegistry.owner_for("arbor://identity/alias") == :arbor_agent
      assert CapabilityProfileRegistry.coverage_complete?()
      assert CapabilityProfileRegistry.coverage_gaps() == []
    end

    test "runtime action profile provider participates in profile resolution after host rebind" do
      Application.put_env(:arbor_trust, :action_profile_provider, ActionProfileProvider)
      rebind_trust!(:full, false)

      assert %CapabilityProfile{
               owner: :arbor_actions,
               uri_prefix: "arbor://action/browser/navigate",
               effect_class: :read
             } = CapabilityProfileRegistry.profile_for("arbor://action/browser/navigate")

      profile_uris =
        CapabilityProfileRegistry.profiles()
        |> Enum.map(& &1.uri_prefix)

      assert "arbor://action/browser/navigate" in profile_uris
    end
  end

  defp rebind_trust!(profile \\ :full, start_children \\ false) do
    Application.put_env(:arbor_trust, :start_children, start_children)
    current = Application.get_env(:arbor_kernel, :kernel_runtime, []) || []

    Application.put_env(
      :arbor_kernel,
      :kernel_runtime,
      Keyword.put(current, :start_profile, profile)
    )

    _ = Application.stop(:arbor_trust)

    if function_exported?(Arbor.Trust.PolicyHost, :release_claim, 0) do
      Arbor.Trust.PolicyHost.release_claim()
    end

    {:ok, _} = Application.ensure_all_started(:arbor_trust)
  end

  defp restore_env(key, nil), do: Application.delete_env(:arbor_trust, key)
  defp restore_env(key, value), do: Application.put_env(:arbor_trust, key, value)
end
