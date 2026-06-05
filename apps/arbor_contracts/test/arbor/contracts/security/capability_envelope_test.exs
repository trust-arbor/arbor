defmodule Arbor.Contracts.Security.CapabilityEnvelopeTest do
  @moduledoc """
  Tests for capability envelope enforcement (Phase 1 of the scheduler-privesc
  redesign).

  Envelope enforcement closes a latent gap in the capability system: prior
  to this work, `Capability.delegate/3` merged parent + child constraints
  via `Map.merge` with the child overriding, which let a delegator silently
  widen attenuation. A child cap could be constructed with
  `constraints: %{rate_limit: 1_000_000}` when the parent allowed only 100/sec.

  These tests assert the subset semantics that envelope enforcement now
  guarantees, plus the building blocks (URI subsetting, constraint subsetting)
  reused by the per-pipeline `.caps.json` loader.

  Surfaced 2026-06-05 by the scheduler-privesc-via-dot-authorship inbox item
  and the audit of existing signing infrastructure (delta-from-hardcoded-to-
  signed work).
  """

  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Contracts.Security.Capability

  describe "uri_subset?/2" do
    test "concrete child under wildcard parent" do
      assert Capability.uri_subset?(
               "arbor://fs/write/X",
               "arbor://fs/write/**"
             )
    end

    test "wildcard child under wider wildcard parent" do
      assert Capability.uri_subset?(
               "arbor://fs/write/X/Y/**",
               "arbor://fs/write/X/**"
             )
    end

    test "concrete child equal to concrete parent" do
      assert Capability.uri_subset?(
               "arbor://fs/write/X",
               "arbor://fs/write/X"
             )
    end

    test "concrete child under concrete parent prefix" do
      # Matches grants_access? semantics: parent's prefix covers subpaths.
      assert Capability.uri_subset?(
               "arbor://fs/write/X/Y",
               "arbor://fs/write/X"
             )
    end

    test "wider wildcard child NOT subset of narrower wildcard parent" do
      refute Capability.uri_subset?(
               "arbor://fs/write/**",
               "arbor://fs/write/X/**"
             )
    end

    test "different operation NOT subset" do
      refute Capability.uri_subset?(
               "arbor://fs/write/X",
               "arbor://fs/read/X"
             )
    end

    test "different resource type NOT subset" do
      refute Capability.uri_subset?(
               "arbor://shell/exec/git",
               "arbor://fs/write/git"
             )
    end

    test "deep child under one-level parent (/*) NOT subset" do
      # parent /X/* allows exactly one level; child /X/Y/Z reaches deeper.
      refute Capability.uri_subset?(
               "arbor://fs/write/X/Y/**",
               "arbor://fs/write/X/*"
             )
    end

    test "non-binary inputs return false" do
      refute Capability.uri_subset?(nil, "arbor://fs/write/X")
      refute Capability.uri_subset?("arbor://fs/write/X", nil)
      refute Capability.uri_subset?(:atom, "arbor://fs/write/X")
    end
  end

  describe "constraints_subset?/2" do
    test "child with tighter rate_limit is subset" do
      assert Capability.constraints_subset?(%{rate_limit: 50}, %{rate_limit: 100})
    end

    test "child with equal rate_limit is subset" do
      assert Capability.constraints_subset?(%{rate_limit: 100}, %{rate_limit: 100})
    end

    test "child with looser rate_limit is NOT subset" do
      refute Capability.constraints_subset?(%{rate_limit: 200}, %{rate_limit: 100})
    end

    test "child adding a new key that parent doesn't constrain IS subset" do
      # Parent imposes no limit → child adding a limit is restriction
      assert Capability.constraints_subset?(%{max_size: 1024}, %{})
      assert Capability.constraints_subset?(%{rate_limit: 50}, %{requires_approval: true})
    end

    test "child=true subset of parent=false for :requires_approval" do
      # Child=true is tighter (forces approval that parent didn't require)
      assert Capability.constraints_subset?(
               %{requires_approval: true},
               %{requires_approval: false}
             )
    end

    test "child=false NOT subset of parent=true for :requires_approval" do
      # Removing the approval requirement widens the cap
      refute Capability.constraints_subset?(
               %{requires_approval: false},
               %{requires_approval: true}
             )
    end

    test "equal values for unknown keys are subset" do
      assert Capability.constraints_subset?(
               %{taint_policy: :strict},
               %{taint_policy: :strict}
             )
    end

    test "different opaque values are NOT subset (conservative)" do
      refute Capability.constraints_subset?(
               %{taint_policy: :lax},
               %{taint_policy: :strict}
             )
    end

    test "empty child is subset of any parent" do
      assert Capability.constraints_subset?(%{}, %{rate_limit: 100})
      assert Capability.constraints_subset?(%{}, %{})
    end

    test "non-map inputs return false" do
      refute Capability.constraints_subset?(nil, %{})
      refute Capability.constraints_subset?(%{}, nil)
    end
  end

  describe "envelope_subset?/2 (combo)" do
    test "subset URI + subset constraints" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/write/X/**",
          principal_id: "agent_parent",
          constraints: %{rate_limit: 100}
        )

      {:ok, child} =
        Capability.new(
          resource_uri: "arbor://fs/write/X/Y",
          principal_id: "agent_child",
          constraints: %{rate_limit: 50}
        )

      assert Capability.envelope_subset?(child, parent)
    end

    test "URI widens — NOT subset" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/write/X/**",
          principal_id: "agent_parent",
          constraints: %{rate_limit: 100}
        )

      {:ok, child} =
        Capability.new(
          resource_uri: "arbor://fs/write/**",
          principal_id: "agent_child",
          constraints: %{rate_limit: 50}
        )

      refute Capability.envelope_subset?(child, parent)
    end

    test "constraints widen — NOT subset" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/write/X/**",
          principal_id: "agent_parent",
          constraints: %{rate_limit: 100}
        )

      {:ok, child} =
        Capability.new(
          resource_uri: "arbor://fs/write/X/Y",
          principal_id: "agent_child",
          constraints: %{rate_limit: 1_000_000}
        )

      refute Capability.envelope_subset?(child, parent)
    end
  end

  describe "regression: delegate/3 rejects widening (envelope enforcement)" do
    # Pre-fix, `delegate/3` did `Map.merge(parent.constraints, opts[:constraints])`
    # with opts overriding parent — a delegator could quietly expand
    # rate_limit, max_uses, or any other constraint while still producing a
    # valid-looking signed delegation. The bug was structural: the
    # cryptographic signature chain validated successfully even though the
    # child cap claimed MORE than the parent granted.
    #
    # These tests fail on HEAD~1 (delegate returned {:ok, widened_cap}) and
    # pass on HEAD (delegate returns {:error, :widens_envelope}).

    test "rejects widening rate_limit" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://api/call/openai",
          principal_id: "agent_parent",
          constraints: %{rate_limit: 100}
        )

      result = Capability.delegate(parent, "agent_child", constraints: %{rate_limit: 1000})

      assert {:error, :widens_envelope} = result,
             "delegate/3 must reject attempts to widen parent constraints. " <>
               "Pre-fix this returned {:ok, _} with a silently-expanded rate_limit, " <>
               "leaving the delegation signature valid but the cap envelope broken."
    end

    test "rejects removing requires_approval" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://shell/exec/git",
          principal_id: "agent_parent",
          constraints: %{requires_approval: true}
        )

      result =
        Capability.delegate(parent, "agent_child", constraints: %{requires_approval: false})

      assert {:error, :widens_envelope} = result
    end

    test "allows tightening rate_limit" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://api/call/openai",
          principal_id: "agent_parent",
          constraints: %{rate_limit: 100}
        )

      assert {:ok, child} =
               Capability.delegate(parent, "agent_child", constraints: %{rate_limit: 50})

      assert child.constraints.rate_limit == 50
    end

    test "allows adding a NEW restriction parent didn't impose" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://fs/write/reports/**",
          principal_id: "agent_parent",
          constraints: %{}
        )

      assert {:ok, child} =
               Capability.delegate(parent, "agent_child", constraints: %{rate_limit: 10})

      assert child.constraints.rate_limit == 10
    end

    test "allows no-constraint delegation (inherits parent)" do
      {:ok, parent} =
        Capability.new(
          resource_uri: "arbor://api/call/openai",
          principal_id: "agent_parent",
          constraints: %{rate_limit: 100}
        )

      assert {:ok, child} = Capability.delegate(parent, "agent_child")
      assert child.constraints.rate_limit == 100
    end
  end
end
