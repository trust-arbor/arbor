defmodule Arbor.Agent.TemplateAuthorityReconciliationCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationCore, as: Core
  alias Arbor.Contracts.Security.Capability

  @moduletag :fast

  @desired_data %{
    "name" => "coding_agent",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
      %{"resource" => "arbor://fs/write"},
      %{"resource" => "arbor://orchestrator/execute"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{
        "arbor://fs/read" => "auto",
        "arbor://fs/write" => "ask",
        "arbor://orchestrator/execute" => "auto"
      }
    }
  }

  setup do
    assert {:ok, desired} = TemplateAuthorityPolicy.build("coding_agent", @desired_data)
    %{desired: desired}
  end

  test "reports unchanged when actual matches desired", %{desired: desired} do
    assert {:ok, diff} = Core.diff(desired, TemplateAuthorityPolicy.snapshot(desired))
    assert Core.unchanged?(diff)

    assert diff["kind"] == "template_authority_reconciliation_diff"
    assert diff["version"] == 1

    assert diff["summary"] == %{
             "capabilities" => %{"retained" => 3, "added" => 0, "removed" => 0, "changed" => 0},
             "trust_rules" => %{"retained" => 3, "added" => 0, "removed" => 0, "changed" => 0},
             "trust_baseline_changed" => false
           }

    resources = Enum.map(diff["capabilities"]["retained"], & &1["resource"])
    assert resources == Enum.sort(resources)
    refute Enum.any?(diff["capabilities"]["retained"], &Map.has_key?(&1, "id"))
  end

  test "classifies added, removed, and changed capabilities with canonical order", %{
    desired: desired
  } do
    actual = %{
      "capabilities" => [
        %{
          "resource" => "arbor://fs/read",
          "constraints" => %{"rate_limit" => 10},
          "id" => "cap_secret"
        },
        %{"resource" => "arbor://fs/write", "constraints" => %{"requires_approval" => true}},
        %{"resource" => "arbor://shell/exec", "id" => "cap_shell"}
      ],
      "trust_preset" => %{
        "baseline" => "block",
        "rules" => %{
          "arbor://fs/read" => "auto",
          "arbor://fs/write" => "ask",
          "arbor://orchestrator/execute" => "auto"
        }
      }
    }

    assert {:ok, diff} = Core.diff(desired, actual)

    assert Enum.map(diff["capabilities"]["retained"], & &1["resource"]) == [
             "arbor://fs/read"
           ]

    assert Enum.map(diff["capabilities"]["added"], & &1["resource"]) == [
             "arbor://orchestrator/execute"
           ]

    assert Enum.map(diff["capabilities"]["removed"], & &1["resource"]) == [
             "arbor://shell/exec"
           ]

    assert diff["capabilities"]["changed"] == [
             %{
               "resource" => "arbor://fs/write",
               "desired" => %{"constraints" => %{}},
               "actual" => %{"constraints" => %{"requires_approval" => true}}
             }
           ]

    refute inspect(diff) =~ "cap_secret"
    refute inspect(diff) =~ "cap_shell"
    assert json_clean?(diff)
  end

  test "classifies trust baseline and rule retained/added/removed/changed", %{desired: desired} do
    actual = %{
      "capabilities" =>
        TemplateAuthorityPolicy.capabilities(TemplateAuthorityPolicy.snapshot(desired)),
      "trust" => %{
        "baseline" => :ask,
        "rules" => %{
          "arbor://fs/read" => "auto",
          "arbor://fs/write" => :auto,
          "arbor://shell/exec" => "ask"
        }
      }
    }

    assert {:ok, diff} = Core.diff(desired, actual)

    assert diff["trust"]["baseline"] == %{
             "status" => "changed",
             "desired" => "block",
             "actual" => "ask"
           }

    assert diff["summary"]["trust_baseline_changed"] == true

    assert diff["trust"]["rules"]["retained"] == [
             %{"uri" => "arbor://fs/read", "mode" => "auto"}
           ]

    assert diff["trust"]["rules"]["added"] == [
             %{"uri" => "arbor://orchestrator/execute", "mode" => "auto"}
           ]

    assert diff["trust"]["rules"]["removed"] == [
             %{"uri" => "arbor://shell/exec", "mode" => "ask"}
           ]

    assert diff["trust"]["rules"]["changed"] == [
             %{"uri" => "arbor://fs/write", "desired" => "ask", "actual" => "auto"}
           ]

    for bucket <- ["retained", "added", "removed", "changed"] do
      uris = Enum.map(diff["trust"]["rules"][bucket], & &1["uri"])
      assert uris == Enum.sort(uris)
    end
  end

  test "accepts atom-keyed actual authority maps and Capability-struct live rows" do
    assert {:ok, live_cap} =
             Capability.new(
               resource_uri: "arbor://fs/read",
               principal_id: "agent_live",
               constraints: %{}
             )

    desired = %{
      capabilities: [%{resource: "arbor://fs/read", constraints: %{}}],
      trust_preset: %{baseline: :block, rules: %{"arbor://fs/read" => :auto}}
    }

    actual = %{
      capabilities: [live_cap],
      trust_preset: %{baseline: :block, rules: %{:"arbor://fs/read" => :auto}}
    }

    assert {:ok, diff} = Core.diff(desired, actual)
    assert Core.unchanged?(diff)
  end

  test "rejects invalid inputs via shared policy normalization" do
    assert {:error, {:template_authority_reconciliation, :invalid_diff_input}} =
             Core.diff("nope", %{})

    assert {:error, {:template_authority_reconciliation, :trust_preset_missing_or_invalid}} =
             Core.diff(%{"capabilities" => []}, %{"capabilities" => []})

    assert {:error, {:template_authority_reconciliation, :trust_mode_invalid}} =
             Core.diff(
               %{
                 "capabilities" => [],
                 "trust_preset" => %{"baseline" => "block", "rules" => %{}}
               },
               %{"capabilities" => [], "trust_preset" => %{"baseline" => "maybe", "rules" => %{}}}
             )

    assert {:error, {:template_authority_reconciliation, :capability_resource_missing_or_invalid}} =
             Core.diff(
               %{
                 "capabilities" => [%{"resource" => ""}],
                 "trust_preset" => %{"baseline" => "block", "rules" => %{}}
               },
               %{"capabilities" => [], "trust_preset" => %{"baseline" => "block", "rules" => %{}}}
             )
  end

  test "rejects capability conflicts, trust conflicts, oversized fields, and non-JSON constraints" do
    base_trust = %{"baseline" => "block", "rules" => %{}}

    assert {:error,
            {:template_authority_reconciliation,
             {:capability_resource_conflict, "arbor://fs/read"}}} =
             Core.diff(
               %{
                 "capabilities" => [
                   %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 1}},
                   %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 2}}
                 ],
                 "trust_preset" => base_trust
               },
               %{"capabilities" => [], "trust_preset" => base_trust}
             )

    assert {:error,
            {:template_authority_reconciliation,
             {:trust_rule_conflict, "arbor://fs/read", mode_a, mode_b}}} =
             Core.diff(
               %{
                 "capabilities" => [],
                 "trust_preset" => %{
                   "baseline" => "block",
                   "rules" => %{
                     "arbor://fs/read/**" => "auto",
                     "arbor://fs/read" => "ask"
                   }
                 }
               },
               %{"capabilities" => [], "trust_preset" => base_trust}
             )

    assert MapSet.new([mode_a, mode_b]) == MapSet.new(["auto", "ask"])

    huge = "arbor://x/" <> String.duplicate("y", 2_000)

    assert {:error, {:template_authority_reconciliation, :capability_resource_missing_or_invalid}} =
             Core.diff(
               %{
                 "capabilities" => [%{"resource" => huge}],
                 "trust_preset" => base_trust
               },
               %{"capabilities" => [], "trust_preset" => base_trust}
             )

    assert {:error, {:template_authority_reconciliation, :capability_constraints_invalid}} =
             Core.diff(
               %{
                 "capabilities" => [
                   %{
                     "resource" => "arbor://fs/read",
                     "constraints" => %{"rate_limit" => [1, 2, 3]}
                   }
                 ],
                 "trust_preset" => base_trust
               },
               %{"capabilities" => [], "trust_preset" => base_trust}
             )
  end

  test "full envelope admission verifies supplied digest and rejects tampering", %{
    desired: desired
  } do
    # Happy path: a self-built envelope vs itself.
    assert {:ok, diff} = Core.diff(desired, desired)
    assert Core.unchanged?(diff)

    # Tampered snapshot with original digest must not be admitted.
    tampered = put_in(desired, ["snapshot", "trust_preset", "baseline"], "allow")

    assert {:error, {:template_authority_reconciliation, :authority_snapshot_digest_mismatch}} =
             Core.diff(desired, tampered)

    # An arbitrary replacement digest also fails the semantic-integrity check.
    replacement_digest =
      :crypto.hash(:sha256, "replacement") |> Base.encode16(case: :lower)

    mismatched = Map.put(tampered, "digest", replacement_digest)

    assert {:error, {:template_authority_reconciliation, :authority_snapshot_digest_mismatch}} =
             Core.diff(desired, mismatched)
  end

  test "diff output is JSON-clean and bounded to string keys", %{desired: desired} do
    assert {:ok, diff} = Core.diff(desired, TemplateAuthorityPolicy.snapshot(desired))
    assert json_clean?(diff)
  end

  test "policy-neutral: ignores nil/missing source metadata and never encodes revoke decisions",
       %{desired: desired} do
    snapshot = TemplateAuthorityPolicy.snapshot(desired)
    template_caps = TemplateAuthorityPolicy.capabilities(snapshot)

    legacy_nil_source =
      Enum.map(template_caps, fn cap ->
        Map.merge(cap, %{
          "id" => "cap_legacy_#{cap["resource"]}",
          "source" => nil,
          "metadata" => %{"source" => nil}
        })
      end)

    baseline_external = %{
      "resource" => "arbor://shell/exec",
      "constraints" => %{},
      "id" => "cap_baseline",
      "source" => "baseline",
      "metadata" => %{"source" => "lifecycle_baseline"}
    }

    mixed_actual = %{
      "capabilities" => legacy_nil_source ++ [baseline_external],
      "trust_preset" => TemplateAuthorityPolicy.trust_preset(snapshot)
    }

    assert {:ok, mixed_diff} = Core.diff(desired, mixed_actual)

    assert Enum.map(mixed_diff["capabilities"]["retained"], & &1["resource"]) ==
             Enum.map(template_caps, & &1["resource"]) |> Enum.sort()

    assert Enum.map(mixed_diff["capabilities"]["removed"], & &1["resource"]) == [
             "arbor://shell/exec"
           ]

    assert mixed_diff["capabilities"]["added"] == []
    assert mixed_diff["capabilities"]["changed"] == []

    refute Map.has_key?(mixed_diff, "actions")
    refute Map.has_key?(mixed_diff, "revoke")
    refute Map.has_key?(mixed_diff, "apply")
    refute Map.has_key?(mixed_diff, "ownership")
    refute Map.has_key?(mixed_diff, "decisions")

    for entry <- mixed_diff["capabilities"]["retained"] ++ mixed_diff["capabilities"]["removed"] do
      refute Map.has_key?(entry, "id")
      refute Map.has_key?(entry, "source")
      refute Map.has_key?(entry, "metadata")
    end

    scoped_actual = %{
      "capabilities" => legacy_nil_source,
      "trust_preset" => TemplateAuthorityPolicy.trust_preset(snapshot)
    }

    assert {:ok, scoped_diff} = Core.diff(desired, scoped_actual)
    assert Core.unchanged?(scoped_diff)
    assert scoped_diff["capabilities"]["removed"] == []
  end

  defp json_clean?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_clean?(values) when is_list(values), do: Enum.all?(values, &json_clean?/1)

  defp json_clean?(map) when is_map(map) and not is_struct(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and json_clean?(value) end)
  end

  defp json_clean?(_value), do: false
end
