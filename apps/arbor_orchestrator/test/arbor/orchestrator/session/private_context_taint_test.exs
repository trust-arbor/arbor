defmodule Arbor.Orchestrator.Session.PrivateContextTaintTest do
  @moduledoc """
  Labels for the private context an authenticated turn installs.

  Found 2026-11-14 on a fresh install: with no embedding route, private recall
  is always `[]` and the relationship `%{}`, yet both were labeled
  :restricted, so every authenticated chat turn was rerouted away from the
  configured cloud provider and then denied. Empty private context keeps its
  derived label.

  Decided 2026-11-14 by the owner: the human's disclosure lifts the
  local-only floor. Non-empty private context in a turn whose frozen route is
  external and whose authority carries the disclosure issued for it is
  :confidential (reaches only backends trusted with confidential data). Every
  other case — on-host, no bound disclosure, a malformed id, another tier —
  stays :restricted.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Contracts.Security.Taint
  alias Arbor.Contracts.Security.TaintEnvelope
  alias Arbor.Contracts.Session.TurnAuthority
  alias Arbor.Identifiers
  alias Arbor.Orchestrator.Session.TurnEgress

  @recall "session.private_recalled_memories"
  @relationship "session.private_relationship"
  @goals "session.private_goal_context"

  setup do
    attrs = [
      turn_id: Identifiers.generate_id("turn_"),
      authenticated_principal_id:
        "human_" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)
    ]

    {:ok, undisclosed} = TurnAuthority.new(attrs ++ [disclosure_capability_id: nil])

    {:ok, disclosed} =
      TurnAuthority.new(
        attrs ++
          [
            disclosure_capability_id:
              "cap_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
          ]
      )

    # What derive_initial_taint/2 gives keys the turn added.
    base = %{@recall => :untrusted, @relationship => :untrusted, @goals => :untrusted}

    full = %{
      @recall => [%{"text" => "the human's private note"}],
      @relationship => %{"tone" => "warm"},
      @goals => "Finish the report"
    }

    %{undisclosed: undisclosed, disclosed: disclosed, base: base, full: full}
  end

  defp restricted, do: TaintEnvelope.missing_fallback()
  defp disclosed_label, do: TurnEgress.disclosed_private_context_taint()

  defp assert_all(taint, label) do
    for key <- [@recall, @relationship, @goals] do
      assert taint[key] == label, "#{key} was #{inspect(taint[key])}"
    end
  end

  test "an unauthenticated turn installs no private label", %{base: base, full: full} do
    for tier <- [:on_host, :external_provider] do
      assert TurnEgress.put_private_context_taint(base, full, nil, tier) == base
    end
  end

  test "empty private context keeps the derived label on every route",
       %{undisclosed: undisclosed, disclosed: disclosed, base: base} do
    values = %{@recall => [], @relationship => %{}, @goals => ""}

    for authority <- [undisclosed, disclosed], tier <- [:on_host, :external_provider] do
      assert TurnEgress.put_private_context_taint(base, values, authority, tier) == base
    end
  end

  test "a disclosed external turn labels non-empty private context :confidential",
       %{disclosed: disclosed, base: base, full: full} do
    taint = TurnEgress.put_private_context_taint(base, full, disclosed, :external_provider)

    assert_all(taint, disclosed_label())
    assert disclosed_label().sensitivity == :confidential
    assert Taint.validate(disclosed_label()) == :ok
  end

  test "only the keys that hold something are labeled",
       %{disclosed: disclosed, base: base} do
    values = %{@recall => [%{"text" => "note"}], @relationship => %{}, @goals => ""}
    taint = TurnEgress.put_private_context_taint(base, values, disclosed, :external_provider)

    assert taint[@recall] == disclosed_label()
    assert taint[@relationship] == :untrusted
    assert taint[@goals] == :untrusted
  end

  test "security regression: an external turn without a bound disclosure stays :restricted",
       %{undisclosed: undisclosed, base: base, full: full} do
    taint = TurnEgress.put_private_context_taint(base, full, undisclosed, :external_provider)
    assert_all(taint, restricted())
  end

  test "security regression: a malformed disclosure id does not lift the floor",
       %{undisclosed: undisclosed, base: base, full: full} do
    for bogus <- [
          "cap_",
          "cap_xyz",
          "cap_" <> String.duplicate("A", 32),
          "grant_" <> String.duplicate("a", 32),
          :cap,
          1
        ] do
      authority = %{undisclosed | disclosure_capability_id: bogus}
      taint = TurnEgress.put_private_context_taint(base, full, authority, :external_provider)
      assert_all(taint, restricted())
    end
  end

  test "security regression: a disclosure does not lift the floor off the external tier",
       %{disclosed: disclosed, base: base, full: full} do
    for tier <- [:on_host, :on_premises, :external_peer, :none, nil, "external_provider"] do
      taint = TurnEgress.put_private_context_taint(base, full, disclosed, tier)
      assert_all(taint, restricted())
    end
  end

  test "security regression: values that are not provably empty fail closed",
       %{undisclosed: undisclosed, disclosed: disclosed, base: base} do
    for value <- [" ", "\n", [nil], %{"" => nil}, 0, :none, {:ok, []}] do
      values = %{@recall => value, @relationship => value, @goals => value}

      assert_all(
        TurnEgress.put_private_context_taint(base, values, undisclosed, :on_host),
        restricted()
      )

      assert_all(
        TurnEgress.put_private_context_taint(base, values, disclosed, :external_provider),
        disclosed_label()
      )
    end
  end

  test "keys the turn did not install are left alone", %{disclosed: disclosed} do
    for tier <- [:on_host, :external_provider] do
      assert TurnEgress.put_private_context_taint(%{"other" => :trusted}, %{}, disclosed, tier) ==
               %{"other" => :trusted}
    end
  end

  # The point of the label: the router lets disclosed private context reach a
  # backend trusted with confidential data, and still keeps it off the keyless
  # tier and backends rated :internal or lower (config/config.exs).
  test "security regression: disclosed private context reaches confidential backends only" do
    sensitivity = disclosed_label().sensitivity

    assert %{action: :proceed} =
             Arbor.AI.sensitivity_routing_decision(:anthropic, "claude-test", sensitivity)

    for provider <- [:opencode_zen, :openai, :gemini, :qwen] do
      decision = Arbor.AI.sensitivity_routing_decision(provider, "m", sensitivity)
      refute match?(%{action: :proceed}, decision), "#{provider} would see private context"
    end

    for provider <- [:anthropic, :opencode_zen, :openai] do
      decision = Arbor.AI.sensitivity_routing_decision(provider, "m", restricted().sensitivity)
      refute match?(%{action: :proceed}, decision), "#{provider} would see :restricted"
    end
  end
end
