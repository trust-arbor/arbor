defmodule Arbor.Scheduler.RoutineCatalogEffectCheckSecurityRegressionTest do
  @moduledoc """
  Security regression: group U — every catalog action must call the
  per-effect check. The runtime gate in arbor_actions fails closed even
  when a new action skips the call; this test keeps the catalog list
  honest so a second admitted action cannot land unwired.
  """
  use ExUnit.Case, async: true

  @moduletag :fast
  @moduletag :security_regression

  @catalog_actions %{
    "arbor://action/reports/build_morning_digest" =>
      {"apps/arbor_actions/lib/arbor/actions/reports/build_morning_digest.ex",
       "authorize_routine_effect"}
  }

  test "security regression: every catalog action source calls authorize_routine_effect" do
    assert Arbor.Scheduler.catalog_action_uri() in Map.keys(@catalog_actions)
    assert map_size(@catalog_actions) == 1

    for {uri, {relative, needle}} <- @catalog_actions do
      source = File.read!(Path.expand("../../../../../#{relative}", __DIR__))
      assert uri == Arbor.Scheduler.RoutineCatalog.action_uri()
      assert source =~ needle
    end
  end
end
