defmodule Arbor.Contracts.Security.CapabilityProfileTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.CapabilityProfile

  @valid_attrs %{
    uri_prefix: "arbor://fs/write/",
    owner: :arbor_security,
    blast_radius: :high,
    reversibility: :reversible,
    effect_class: :local_write,
    data_class: :confidential,
    arg_dependent: true,
    default_approval: :require_human,
    delegable: false,
    cost_class: :cheap,
    graduation_eligible: true
  }

  describe "new/1" do
    test "constructs a canonical profile with default optional fields" do
      assert {:ok, profile} = CapabilityProfile.new(@valid_attrs)

      assert %CapabilityProfile{} = profile
      assert profile.uri_prefix == "arbor://fs/write"
      assert profile.compensation == nil
      assert profile.default_constraints == %{}
    end

    test "accepts the full post-tier-retirement field set" do
      attrs =
        Map.merge(@valid_attrs, %{
          compensation: %{undo_action: "file.restore", undo_window_seconds: 300},
          default_constraints: %{ttl_seconds: 300, rate_limit: %{count: 5, window_seconds: 60}}
        })

      assert {:ok, profile} = CapabilityProfile.new(attrs)
      assert profile.compensation.undo_action == "file.restore"
      assert profile.default_constraints.ttl_seconds == 300
    end

    test "rejects retired trust_floor field instead of silently preserving tier drift" do
      attrs = Map.put(@valid_attrs, :trust_floor, :trusted)

      assert {:error, {:unknown_fields, [:trust_floor]}} = CapabilityProfile.new(attrs)
    end

    test "rejects invalid enum values" do
      attrs = Map.put(@valid_attrs, :effect_class, :shell_like)

      assert {:error, {:invalid_enum, :effect_class, :shell_like, _allowed}} =
               CapabilityProfile.new(attrs)
    end

    test "rejects wildcard and traversal-like URI prefixes" do
      assert {:error, {:invalid_uri_prefix, :wildcard_prefix_not_allowed}} =
               @valid_attrs
               |> Map.put(:uri_prefix, "arbor://fs/write/**")
               |> CapabilityProfile.new()

      assert {:error, {:invalid_uri_prefix, :traversal_segment}} =
               @valid_attrs
               |> Map.put(:uri_prefix, "arbor://fs/write/../secret")
               |> CapabilityProfile.new()
    end
  end

  describe "merge/2" do
    test "layers operator overrides over inline defaults and revalidates" do
      profile = CapabilityProfile.new!(@valid_attrs)

      assert {:ok, overridden} =
               CapabilityProfile.merge(profile,
                 default_approval: :forbid,
                 default_constraints: %{ttl_seconds: 60}
               )

      assert overridden.uri_prefix == profile.uri_prefix
      assert overridden.default_approval == :forbid
      assert overridden.default_constraints.ttl_seconds == 60
    end

    test "does not allow overrides to retarget the profile URI key" do
      profile = CapabilityProfile.new!(@valid_attrs)

      assert {:error, :cannot_override_uri_prefix} =
               CapabilityProfile.merge(profile, uri_prefix: "arbor://fs/read")
    end
  end
end
