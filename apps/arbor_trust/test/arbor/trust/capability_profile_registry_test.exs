defmodule Arbor.Trust.CapabilityProfileRegistryTest do
  use ExUnit.Case, async: false

  alias Arbor.Contracts.Security.{CapabilityProfile, CapabilityUri}
  alias Arbor.Trust.{CapabilityProfileRegistry, PolicyHost}

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

  defmodule FeaturePrefixProvider do
    def capability_uri_prefixes, do: ["arbor://fixture_feature/review"]
  end

  setup do
    originals = %{
      provider: Application.get_env(:arbor_trust, :action_profile_provider),
      feature_owners: Application.fetch_env(:arbor_trust, :feature_domain_owners),
      start_children: Application.get_env(:arbor_trust, :start_children),
      kernel_runtime: Application.fetch_env(:arbor_kernel, :kernel_runtime)
    }

    on_exit(fn ->
      restore_env(:action_profile_provider, originals.provider)
      restore_env(:start_children, originals.start_children)

      case originals.feature_owners do
        {:ok, value} -> Application.put_env(:arbor_trust, :feature_domain_owners, value)
        :error -> Application.delete_env(:arbor_trust, :feature_domain_owners)
      end

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

      assert rows["arbor://persistence/read"].owner == :arbor_persistence_host
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

  describe "feature-domain ownership" do
    test "security regression: coding has no implicit owner when the feature is absent" do
      Application.delete_env(:arbor_trust, :feature_domain_owners)
      rebind_trust!()

      assert CapabilityProfileRegistry.owner_for("arbor://coding/reconciliation/read") == nil
      assert CapabilityProfileRegistry.profile_for("arbor://coding/reconciliation/read") == nil
      assert CapabilityProfileRegistry.owner_for("arbor://shell/exec") == :arbor_shell
    end

    test "configured feature owners are frozen and cannot override core ownership" do
      owners = %{"coding" => :arbor_orchestrator, "shell" => :feature_shell_shadow}
      Application.put_env(:arbor_trust, :feature_domain_owners, owners)
      rebind_trust!()

      assert {:ok, %{feature_domain_owners: ^owners}} = PolicyHost.snapshot()

      assert CapabilityProfileRegistry.owner_for("arbor://coding/reconciliation/read") ==
               :arbor_orchestrator

      assert CapabilityProfileRegistry.owner_for("arbor://coding_other/reconciliation/read") ==
               nil

      assert CapabilityProfileRegistry.owner_for("arbor://shell/exec") == :arbor_shell
      assert CapabilityProfileRegistry.profile_for("arbor://coding/reconciliation/read") == nil

      Application.put_env(:arbor_trust, :feature_domain_owners, %{
        "coding" => :changed_after_start
      })

      assert CapabilityProfileRegistry.owner_for("arbor://coding/reconciliation/read") ==
               :arbor_orchestrator

      assert {:ok, %{feature_domain_owners: ^owners}} = PolicyHost.snapshot()

      _ = Application.stop(:arbor_trust)
      assert CapabilityProfileRegistry.owner_for("arbor://coding/reconciliation/read") == nil
    end

    test "coverage includes a feature's runtime prefix without granting it a risk profile" do
      refute Process.whereis(Arbor.Security.UriRegistry)
      owners = %{"fixture_feature" => :feature_app}
      Application.put_env(:arbor_trust, :feature_domain_owners, owners)
      rebind_trust!()

      start_supervised!(
        {Arbor.Security.UriRegistry,
         start_profile: :full,
         registration_providers: [FeaturePrefixProvider],
         bootstrap_providers: [FeaturePrefixProvider]}
      )

      prefix = "arbor://fixture_feature/review"
      refute prefix in Arbor.Security.canonical_uri_prefixes()
      assert prefix in Arbor.Security.registered_uri_prefixes()
      rows = CapabilityProfileRegistry.coverage_rows()
      row = Enum.find(rows, &(&1.uri_prefix == prefix))
      assert row.owner == :feature_app
      assert row.profile == nil
      assert row.not_profileable_reason =~ "owned by feature_app"

      expected =
        Arbor.Security.registered_uri_prefixes()
        |> Enum.map(&(CapabilityUri.parse!(&1) |> CapabilityUri.canonical()))
        |> Enum.uniq()
        |> Enum.sort()

      assert Enum.map(rows, & &1.uri_prefix) == expected
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
