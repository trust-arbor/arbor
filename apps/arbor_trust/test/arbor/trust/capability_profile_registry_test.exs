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
    previous = Application.get_env(:arbor_trust, :action_profile_provider)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:arbor_trust, :action_profile_provider)
      else
        Application.put_env(:arbor_trust, :action_profile_provider, previous)
      end
    end)

    Application.delete_env(:arbor_trust, :action_profile_provider)
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

    test "runtime action profile provider participates in profile resolution" do
      Application.put_env(:arbor_trust, :action_profile_provider, ActionProfileProvider)

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
end
