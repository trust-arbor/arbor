defmodule Arbor.Scheduler.IdentityTest do
  @moduledoc """
  Unit-level checks for Arbor.Scheduler.Identity.

  Full provisioning (keypair generation + persistence + capability
  grant + Registry registration) requires the arbor_security
  supervision tree, which the test config disables. Those paths are
  exercised by manual end-to-end verification post-restart.

  The signer/agent_id assertions here are the **regression test** for
  the bypass route: when no Identity is running, both must return
  `nil` (not crash, not silently fall back to a permissive default).
  The PipelineRunner then passes `nil` through to the orchestrator,
  where CapabilityCheck halts with `:missing_signed_request` — the
  correct fail-closed shape. Any future "fix" that makes signer/0
  return a permissive default re-opens the auto-execution hole this
  module was created to close.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Scheduler.Identity

  describe "signer/0 without a running GenServer" do
    test "security regression: returns nil rather than a permissive fallback" do
      refute Process.whereis(Identity), "Identity must not be running in :fast tests"
      assert is_nil(Identity.signer())
    end
  end

  describe "agent_id/0 without a running GenServer" do
    test "security regression: returns nil rather than a hardcoded id" do
      # Mirrors the signer/0 contract: no live identity means no
      # caller can spoof one. A hardcoded fallback string would let
      # a misconfigured node masquerade as a valid scheduler.
      refute Process.whereis(Identity), "Identity must not be running in :fast tests"
      assert is_nil(Identity.agent_id())
    end
  end
end
