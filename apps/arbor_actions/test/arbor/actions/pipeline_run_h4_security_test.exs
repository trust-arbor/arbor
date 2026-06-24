defmodule Arbor.Actions.Pipeline.RunH4SecurityTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Actions.Pipeline.Run

  # H4 (2026-02-16 review): pipeline outcome parsing used String.to_atom on an
  # untrusted "outcome" context value — an atom-exhaustion vector. The fix routes
  # it through SafeAtom.to_allowed against a fixed allowlist, falling back to
  # :unknown. extract_status/1 is the call site (the orchestrator-driven public
  # Run.run/2 path can't execute in arbor_actions' own test BEAM, so we exercise
  # the call site directly — extract_status/1 is @doc false public for this).
  describe "H4 security regression — outcome parsing must not mint atoms" do
    test "an unknown outcome maps to :unknown WITHOUT interning a new atom" do
      weird = "h4_unknown_outcome_#{System.unique_integer([:positive])}"

      # Not an existing atom before the call...
      assert_raise ArgumentError, fn -> String.to_existing_atom(weird) end

      assert Run.extract_status(%{context: %{"outcome" => weird}}) == :unknown

      # ...and STILL not interned after — proving SafeAtom (not String.to_atom)
      # handled it. Pre-fix, String.to_atom would have minted :"h4_unknown_..."
      # and this assert_raise would no longer raise.
      assert_raise ArgumentError, fn -> String.to_existing_atom(weird) end
    end

    test "a known/allowed outcome maps to its atom" do
      assert Run.extract_status(%{context: %{"outcome" => "success"}}) == :success
      assert Run.extract_status(%{context: %{"outcome" => "failure"}}) == :failure
      assert Run.extract_status(%{context: %{"outcome" => "cancelled"}}) == :cancelled
    end
  end
end
