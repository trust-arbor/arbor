defmodule Arbor.Trust.PresetsHistorianSecurityCategoryTest do
  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Trust.Presets

  # The historian `security` category (taint traces, grant/denial events) is
  # never self-scoped and is not for the average agent. Presets open the
  # historian domain (`arbor://historian => :auto`); this pins the category
  # behind approval under longest-prefix matching (2026-08-25).
  test "cautious, balanced and hands_off keep the security category at :ask" do
    for preset <- [:cautious, :balanced, :hands_off] do
      {_baseline, rules} = Presets.preset_rules(preset)
      assert rules["arbor://historian/query/security"] == :ask, "#{preset}"
    end
  end

  test "full_trust is the operator's explicit choice and is left alone" do
    {_baseline, rules} = Presets.preset_rules(:full_trust)
    refute Map.has_key?(rules, "arbor://historian/query/security")
  end
end
