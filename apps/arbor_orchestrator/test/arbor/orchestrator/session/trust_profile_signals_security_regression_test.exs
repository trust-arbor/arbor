defmodule Arbor.Orchestrator.Session.TrustProfileSignalsSecurityRegressionTest do
  @moduledoc """
  Security regression: a session must hear trust profile changes.

  Until 2026-11-21 `Session` subscribed with a map where the signal bus
  requires a handler function. The call raised, a `rescue` swallowed it, and
  no session ever received a profile change. Its handler, which revokes the
  session's capabilities, was unreachable.

  This test covers the delivery from a real trust broadcast to the exact
  message shape `Session.handle_info/2` matches. It does not cover the
  revocation that handler then performs.
  """
  use ExUnit.Case, async: false

  alias Arbor.Orchestrator.Session.TrustProfileSignals

  @moduletag :fast
  @moduletag :security_regression

  test "security regression: a trust profile update reaches the subscribed session process" do
    agent_id = "agent_profile_signal_#{System.unique_integer([:positive])}"

    assert {:ok, subscription_id} = TrustProfileSignals.subscribe()
    on_exit(fn -> Arbor.Signals.unsubscribe(subscription_id) end)

    Arbor.Signals.emit(:trust, :profile_updated, %{agent_id: agent_id, origin_node: node()})

    # The same pattern as the Session.handle_info/2 clause.
    assert_receive {:signal_received,
                    %{category: :trust, type: :profile_updated, data: %{agent_id: ^agent_id}}},
                   1_000
  end

  test "the session source subscribes through this module with no silent rescue" do
    source =
      File.read!(Path.expand("../../../../lib/arbor/orchestrator/session.ex", __DIR__))

    assert source =~ "TrustProfileSignals.subscribe()"
    refute source =~ ~s|Arbor.Signals.subscribe("trust.profile_updated", %{|
  end
end
