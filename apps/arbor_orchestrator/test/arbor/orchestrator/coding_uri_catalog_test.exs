defmodule Arbor.Orchestrator.CodingUriCatalogTest do
  use ExUnit.Case, async: true

  alias Arbor.Contracts.Security.CapabilityUri
  alias Arbor.Orchestrator
  alias Arbor.Orchestrator.CodingUriCatalog

  @moduletag :fast

  test "the feature facade exposes only its fixed reconciliation operations" do
    expected = [
      "arbor://coding/reconciliation/read",
      "arbor://coding/reconciliation/apply"
    ]

    assert Orchestrator.capability_uri_prefixes() == expected
    assert CodingUriCatalog.capability_uri_prefixes() == expected

    for uri <- [
          "arbor://coding/reconciliation/read/task_1",
          "arbor://coding/reconciliation/apply/validation_resource/validation_" <>
            String.duplicate("a", 32),
          "arbor://coding/reconciliation/apply/pending_approval/approval_" <>
            String.duplicate("a", 64),
          "arbor://coding/reconciliation/apply/apple_container_unit/acu_v1_" <>
            String.duplicate("a", 32)
        ] do
      assert Enum.any?(
               Orchestrator.capability_uri_prefixes(),
               &CapabilityUri.prefix_match?(&1, uri)
             )
    end

    for uri <- [
          "arbor://coding",
          "arbor://coding/reconciliation/reader/task_1",
          "arbor://coding/reconciliation/applyx/resource_1",
          "arbor://coding/reconciliation/application/resource_1",
          "arbor://coding/reconciliation/applyer/resource_1"
        ] do
      refute Enum.any?(
               Orchestrator.capability_uri_prefixes(),
               &CapabilityUri.prefix_match?(&1, uri)
             )
    end
  end
end
