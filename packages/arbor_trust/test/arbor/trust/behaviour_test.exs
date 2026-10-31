defmodule Arbor.Trust.BehaviourTest do
  use ExUnit.Case, async: true

  alias Arbor.Trust.Behaviour

  @moduletag :fast

  # The trust-tier band was retired (tiers-retirement phase 3c). The behaviour
  # now only declares the @callback contract that Trust.Manager implements;
  # the tier-threshold/tier-sufficiency helpers were removed.
  describe "behaviour contract" do
    test "declares the expected callbacks" do
      callbacks = Behaviour.behaviour_info(:callbacks)

      assert {:get_trust_profile, 1} in callbacks
      assert {:create_trust_profile, 1} in callbacks
      assert {:freeze_trust, 2} in callbacks
      assert {:unfreeze_trust, 1} in callbacks
      assert {:record_trust_event, 3} in callbacks
    end
  end
end
