defmodule Arbor.Orchestrator.Session.PrivateContextTaintTest do
  @moduledoc """
  The private context an authenticated turn installs is labeled with the
  fail-closed `missing_fallback` envelope (sensitivity :restricted) only when
  it holds something.

  Found 2026-11-14 on a fresh install: with no embedding route, private recall
  is always `[]` and the relationship `%{}`, yet both were labeled
  :restricted, so every authenticated chat turn was rerouted away from the
  configured cloud provider and then denied. Non-empty private context must
  stay :restricted.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Identifiers
  alias Arbor.Orchestrator.Session.TurnEgress

  @recall "session.private_recalled_memories"
  @relationship "session.private_relationship"
  @goals "session.private_goal_context"

  setup do
    {:ok, authority} =
      TurnAuthority.new(
        turn_id: Identifiers.generate_id("turn_"),
        authenticated_principal_id:
          "human_" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower),
        disclosure_capability_id: nil
      )

    # What derive_initial_taint/2 gives keys the turn added.
    base = %{@recall => :untrusted, @relationship => :untrusted, @goals => :untrusted}
    %{authority: authority, base: base}
  end

  defp restricted, do: TaintEnvelope.missing_fallback()

  test "an unauthenticated turn installs no private label", %{base: base} do
    values = %{@recall => [%{"text" => "x"}], @relationship => %{}, @goals => "goal"}
    assert TurnEgress.put_private_context_taint(base, values, nil) == base
  end

  test "empty private context keeps the derived label, not :restricted",
       %{authority: authority, base: base} do
    values = %{@recall => [], @relationship => %{}, @goals => ""}
    assert TurnEgress.put_private_context_taint(base, values, authority) == base
  end

  test "security regression: non-empty private recall stays :restricted",
       %{authority: authority, base: base} do
    values = %{
      @recall => [%{"text" => "the human's private note"}],
      @relationship => %{},
      @goals => ""
    }

    taint = TurnEgress.put_private_context_taint(base, values, authority)

    assert taint[@recall] == restricted()
    assert taint[@relationship] == :untrusted
    assert taint[@goals] == :untrusted
  end

  test "security regression: a non-empty relationship or goal section stays :restricted",
       %{authority: authority, base: base} do
    values = %{@recall => [], @relationship => %{"tone" => "warm"}, @goals => "Finish the report"}
    taint = TurnEgress.put_private_context_taint(base, values, authority)

    assert taint[@relationship] == restricted()
    assert taint[@goals] == restricted()
    assert taint[@recall] == :untrusted
  end

  test "security regression: values that are not provably empty fail closed",
       %{authority: authority, base: base} do
    for value <- [" ", "\n", [nil], %{"" => nil}, 0, :none, {:ok, []}] do
      values = %{@recall => value, @relationship => value, @goals => value}
      taint = TurnEgress.put_private_context_taint(base, values, authority)

      assert taint[@recall] == restricted(), "recall #{inspect(value)} was not restricted"
      assert taint[@relationship] == restricted()
      assert taint[@goals] == restricted()
    end
  end

  test "keys the turn did not install are left alone", %{authority: authority} do
    assert TurnEgress.put_private_context_taint(%{"other" => :trusted}, %{}, authority) ==
             %{"other" => :trusted}
  end
end
