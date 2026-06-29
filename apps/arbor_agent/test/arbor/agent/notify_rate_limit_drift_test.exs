defmodule Arbor.Agent.NotifyRateLimitDriftTest do
  # Cross-app drift guard for the A1 notify channel's rate-limit budget.
  #
  # The value lives in two places that CAN'T reference each other directly
  # (arbor_trust L4 is below arbor_actions L6 in the hierarchy):
  #   * the GRANT constraint, in Arbor.Trust.Config base_capabilities/0
  #     (what actually gets enforced), and
  #   * the action's declared budget, Arbor.Actions.Comms.NotifySession.default_rate_limit/0.
  # arbor_agent deps both, so this is the natural home to assert they stay in sync.
  use ExUnit.Case, async: true

  alias Arbor.Actions.Comms.NotifySession
  alias Arbor.Trust.Config

  @moduletag :fast

  test "granted notify rate-limit matches NotifySession.default_rate_limit/0" do
    notify =
      Config.base_capabilities()
      |> Enum.find(&(&1.resource_uri == "arbor://comms/notify/session"))

    assert notify, "notify capability not in the universal baseline"

    assert notify.constraints[:rate_limit] == NotifySession.default_rate_limit(),
           """
           A1 notify rate-limit drift: the baseline grant constraint
           (#{inspect(notify.constraints[:rate_limit])}) and
           NotifySession.default_rate_limit/0 (#{inspect(NotifySession.default_rate_limit())})
           disagree. Update both (Arbor.Trust.Config @notify_session_rate_limit and the
           :arbor_actions, :notify_session_rate_limit config / its default) to match.
           """
  end
end
