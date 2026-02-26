defmodule Arbor.Trust.ConfirmationMatrixTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.ConfirmationMatrix

  @moduletag :fast

  # ===========================================================================
  # Bundle resolution
  # ===========================================================================

  describe "resolve_bundle/1" do
    test "code read URIs → codebase_read" do
      assert ConfirmationMatrix.resolve_bundle("arbor://code/read/self/*") == :codebase_read

      assert ConfirmationMatrix.resolve_bundle("arbor://code/read/agent_123/file.ex") ==
               :codebase_read

      assert ConfirmationMatrix.resolve_bundle("arbor://roadmap/read/self/*") == :codebase_read
      assert ConfirmationMatrix.resolve_bundle("arbor://git/read/self/log") == :codebase_read
      assert ConfirmationMatrix.resolve_bundle("arbor://activity/emit/self") == :codebase_read
    end

    test "code write URIs → codebase_write" do
      assert ConfirmationMatrix.resolve_bundle("arbor://code/write/self/sandbox/*") ==
               :codebase_write

      assert ConfirmationMatrix.resolve_bundle("arbor://code/write/self/impl/*") ==
               :codebase_write

      assert ConfirmationMatrix.resolve_bundle("arbor://code/compile/self/*") == :codebase_write
      assert ConfirmationMatrix.resolve_bundle("arbor://code/reload/self/*") == :codebase_write
      assert ConfirmationMatrix.resolve_bundle("arbor://test/write/self/*") == :codebase_write
      assert ConfirmationMatrix.resolve_bundle("arbor://docs/write/self/*") == :codebase_write
      assert ConfirmationMatrix.resolve_bundle("arbor://roadmap/write/self/*") == :codebase_write

      assert ConfirmationMatrix.resolve_bundle("arbor://roadmap/move/self/discarded") ==
               :codebase_write
    end

    test "shell URIs → shell" do
      assert ConfirmationMatrix.resolve_bundle("arbor://shell/exec/ls") == :shell
      assert ConfirmationMatrix.resolve_bundle("arbor://shell/exec/anything") == :shell
    end

    test "network URIs → network" do
      assert ConfirmationMatrix.resolve_bundle("arbor://network/request/https://example.com") ==
               :network

      assert ConfirmationMatrix.resolve_bundle("arbor://signals/subscribe/agent_123") == :network
    end

    test "AI URIs → ai_generate" do
      assert ConfirmationMatrix.resolve_bundle("arbor://ai/request/claude") == :ai_generate
      assert ConfirmationMatrix.resolve_bundle("arbor://extension/request/self/*") == :ai_generate
    end

    test "config URIs → system_config" do
      assert ConfirmationMatrix.resolve_bundle("arbor://config/write/self/*") == :system_config
      assert ConfirmationMatrix.resolve_bundle("arbor://install/execute/self") == :system_config
    end

    test "governance URIs → governance" do
      assert ConfirmationMatrix.resolve_bundle("arbor://capability/request/self/*") == :governance

      assert ConfirmationMatrix.resolve_bundle("arbor://capability/delegate/self/*") ==
               :governance

      assert ConfirmationMatrix.resolve_bundle("arbor://governance/change/self/*") == :governance
      assert ConfirmationMatrix.resolve_bundle("arbor://consensus/propose/self") == :governance
    end

    test "unknown URIs → nil" do
      assert ConfirmationMatrix.resolve_bundle("arbor://unknown/action") == nil
      assert ConfirmationMatrix.resolve_bundle("not-a-uri") == nil
    end
  end

  # ===========================================================================
  # Matrix lookup
  # ===========================================================================

  describe "lookup/2" do
    test "codebase_read is auto at all tiers" do
      for tier <- ConfirmationMatrix.policy_tiers() do
        assert ConfirmationMatrix.lookup(:codebase_read, tier) == :auto,
               "codebase_read should be :auto at #{tier}"
      end
    end

    test "codebase_write progression: deny → gated → auto" do
      assert ConfirmationMatrix.lookup(:codebase_write, :restricted) == :deny
      assert ConfirmationMatrix.lookup(:codebase_write, :standard) == :gated
      assert ConfirmationMatrix.lookup(:codebase_write, :elevated) == :auto
      assert ConfirmationMatrix.lookup(:codebase_write, :autonomous) == :auto
    end

    test "shell is NEVER auto (security invariant)" do
      for tier <- ConfirmationMatrix.policy_tiers() do
        mode = ConfirmationMatrix.lookup(:shell, tier)
        assert mode != :auto, "shell must NEVER be :auto at #{tier}, got #{mode}"
      end
    end

    test "shell progression: deny → gated" do
      assert ConfirmationMatrix.lookup(:shell, :restricted) == :deny
      assert ConfirmationMatrix.lookup(:shell, :standard) == :gated
      assert ConfirmationMatrix.lookup(:shell, :elevated) == :gated
      assert ConfirmationMatrix.lookup(:shell, :autonomous) == :gated
    end

    test "governance requires confirmation even at autonomous" do
      assert ConfirmationMatrix.lookup(:governance, :autonomous) == :gated
    end

    test "unknown bundle → deny" do
      assert ConfirmationMatrix.lookup(:nonexistent_bundle, :standard) == :deny
    end

    test "unknown tier → deny" do
      assert ConfirmationMatrix.lookup(:codebase_read, :nonexistent_tier) == :deny
    end
  end

  # ===========================================================================
  # Combined mode_for
  # ===========================================================================

  describe "mode_for/2" do
    test "code read at standard → auto" do
      assert ConfirmationMatrix.mode_for("arbor://code/read/agent_1/foo", :standard) == :auto
    end

    test "code write at standard → gated" do
      assert ConfirmationMatrix.mode_for("arbor://code/write/agent_1/impl/foo", :standard) ==
               :gated
    end

    test "shell at elevated → gated" do
      assert ConfirmationMatrix.mode_for("arbor://shell/exec/ls", :elevated) == :gated
    end

    test "unknown URI → deny" do
      assert ConfirmationMatrix.mode_for("arbor://unknown/something", :autonomous) == :deny
    end
  end

  # ===========================================================================
  # Tier mapping
  # ===========================================================================

  describe "to_policy_tier/1" do
    test "untrusted → restricted" do
      assert ConfirmationMatrix.to_policy_tier(:untrusted) == :restricted
    end

    test "probationary → restricted (collapsed)" do
      assert ConfirmationMatrix.to_policy_tier(:probationary) == :restricted
    end

    test "trusted → standard" do
      assert ConfirmationMatrix.to_policy_tier(:trusted) == :standard
    end

    test "veteran → elevated" do
      assert ConfirmationMatrix.to_policy_tier(:veteran) == :elevated
    end

    test "autonomous → autonomous" do
      assert ConfirmationMatrix.to_policy_tier(:autonomous) == :autonomous
    end

    test "unknown tier → restricted (fail closed)" do
      assert ConfirmationMatrix.to_policy_tier(:some_future_tier) == :restricted
    end
  end

  # ===========================================================================
  # Accessors
  # ===========================================================================

  describe "bundles/0" do
    test "returns all 7 bundles" do
      bundles = ConfirmationMatrix.bundles()
      assert length(bundles) == 7
      assert :codebase_read in bundles
      assert :shell in bundles
      assert :governance in bundles
    end
  end

  describe "policy_tiers/0" do
    test "returns 4 tiers in order" do
      assert ConfirmationMatrix.policy_tiers() == [:restricted, :standard, :elevated, :autonomous]
    end
  end

  # ===========================================================================
  # Security invariants
  # ===========================================================================

  describe "security invariants" do
    test "no bundle is :auto at restricted tier except codebase_read and ai_generate" do
      for bundle <- ConfirmationMatrix.bundles() do
        mode = ConfirmationMatrix.lookup(bundle, :restricted)

        if bundle in [:codebase_read] do
          assert mode == :auto, "#{bundle} should be :auto at restricted"
        else
          assert mode in [:gated, :deny],
                 "#{bundle} should be :gated or :deny at restricted, got #{mode}"
        end
      end
    end

    test "matrix is monotonically permissive (higher tier never more restrictive)" do
      tiers = ConfirmationMatrix.policy_tiers()
      mode_order = %{deny: 0, gated: 1, auto: 2}

      for bundle <- ConfirmationMatrix.bundles() do
        modes = Enum.map(tiers, &ConfirmationMatrix.lookup(bundle, &1))
        orders = Enum.map(modes, &Map.fetch!(mode_order, &1))

        for [a, b] <- Enum.chunk_every(orders, 2, 1, :discard) do
          assert a <= b,
                 "#{bundle} violates monotonicity: tier progression should never become more restrictive"
        end
      end
    end
  end

  # ===========================================================================
  # Doctests
  # ===========================================================================

  doctest Arbor.Trust.ConfirmationMatrix
end
