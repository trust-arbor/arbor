defmodule Arbor.Agent.Eval.ProviderRoutePinTest do
  use ExUnit.Case, async: true
  @moduletag :fast

  alias Arbor.Agent.Eval.ProviderRoutePin

  @reviewed %{
    concurrency: %{
      "openai_oauth" => %{"arbor" => 2},
      "xai_oauth" => %{"arbor" => 2}
    },
    ceilings: %{
      "openai_oauth" => 1.0,
      "xai_oauth" => 1.0
    },
    capacity: %{
      "openai_oauth" => "available",
      "xai_oauth" => "available"
    }
  }

  test "pinning a catalog model also writes the three policy rows" do
    pin =
      ProviderRoutePin.build("x-preview-f-free", :opencode_zen, @reviewed,
        now: ~U[2026-08-23 12:00:00Z]
      )

    assert pin.profile.catalog_model_ids == ["x-preview-f-free"]
    assert hd(pin.profile.scoreboard).provider == "opencode_zen"
    assert hd(pin.profile.scoreboard).runtime == "arbor"

    assert pin.concurrency["opencode_zen"] == %{"arbor" => 2}
    assert pin.ceilings["opencode_zen"] == 1.0
    assert pin.capacity["opencode_zen"] == "available"

    assert pin.catalog_overlays["x-preview-f-free"] == %{
             provider: "opencode_zen",
             auth: "none"
           }

    assert pin.probe_ids == ["x-preview-f-free"]
  end

  test "non-zen providers do not mint an OpenCode Zen probe allowlist" do
    pin = ProviderRoutePin.build("gpt-5.6-sol", :openai_oauth, @reviewed)
    assert pin.probe_ids == []
  end

  test "existing reviewed-profile providers are preserved, not replaced" do
    pin = ProviderRoutePin.build("x-preview-f-free", "opencode_zen", @reviewed)

    assert pin.concurrency["openai_oauth"] == %{"arbor" => 2}
    assert pin.concurrency["xai_oauth"] == %{"arbor" => 2}
    assert pin.ceilings["openai_oauth"] == 1.0
    assert pin.capacity["xai_oauth"] == "available"
  end

  test "atom-keyed current rows for the pinned provider are dropped, not duplicated" do
    current = %{
      concurrency: %{"openai_oauth" => %{"arbor" => 2}, opencode_zen: %{"arbor" => 1}},
      ceilings: %{opencode_zen: 0.5},
      capacity: %{opencode_zen: "unknown"}
    }

    pin = ProviderRoutePin.build("x-preview-f-free", :opencode_zen, current)

    refute Map.has_key?(pin.concurrency, :opencode_zen)
    refute Map.has_key?(pin.ceilings, :opencode_zen)
    refute Map.has_key?(pin.capacity, :opencode_zen)
    assert pin.concurrency["opencode_zen"] == %{"arbor" => 2}
    assert pin.ceilings["opencode_zen"] == 1.0
    assert pin.capacity["opencode_zen"] == "available"
    assert pin.concurrency["openai_oauth"] == %{"arbor" => 2}
  end

  test "missing or malformed current policy maps start empty rather than crashing" do
    pin = ProviderRoutePin.build("x-preview-f-free", :opencode_zen, %{concurrency: :not_a_map})

    assert pin.concurrency == %{"opencode_zen" => %{"arbor" => 2}}
    assert pin.ceilings == %{"opencode_zen" => 1.0}
    assert pin.capacity == %{"opencode_zen" => "available"}
  end

  test "eval pin does not use spend 0.0 or capacity unknown (those exclude the route)" do
    pin = ProviderRoutePin.build("x-preview-f-free", :opencode_zen, %{})

    refute pin.ceilings["opencode_zen"] == 0
    refute pin.ceilings["opencode_zen"] == 0.0
    refute pin.capacity["opencode_zen"] in [nil, "unknown"]
  end
end
