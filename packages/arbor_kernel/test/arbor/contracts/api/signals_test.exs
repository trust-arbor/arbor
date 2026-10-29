defmodule Arbor.Contracts.API.SignalsTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.API.Signals

  @tag spec: "VP-05D2C3I0C4B"
  test "retained memory signal privacy callbacks are optional facade callbacks" do
    callbacks = Signals.behaviour_info(:callbacks)
    optional = Signals.behaviour_info(:optional_callbacks)

    expected = [
      delete_retained_memory_signal_content_for_agent: 2,
      check_retained_memory_signal_content_absent_for_agent: 2
    ]

    for callback <- expected do
      assert callback in callbacks
      assert callback in optional
    end
  end

  @tag spec: "VP-05D2C3I0C4B"
  test "retained memory privacy types use closed envelopes" do
    source =
      File.read!(Path.expand("../../../../lib/arbor/contracts/api/signals.ex", __DIR__))

    assert source =~
             ~r/@type retained_memory_signal_delete_error ::[\s\S]*?:invalid_agent_id/

    assert source =~
             ~r/@type retained_memory_signal_delete_error ::[\s\S]*?:checkpoint_verification_failed/

    assert source =~ ~r/\{:delete_indeterminate, agent_id\(\)\}/
    assert source =~ ~r/\{:absence_indeterminate, agent_id\(\)\}/

    assert source =~
             ~r/@type retained_memory_signal_absence_result ::[\s\S]*?\{:ok, true\}/
  end
end
