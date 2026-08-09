defmodule Arbor.Agent.TemplateAuthorityPolicyTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Contracts.Security.Capability

  @moduletag :fast

  @coding_like %{
    "name" => "coding_agent",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/write", "description" => "write worktree"},
      %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
      %{"resource" => "arbor://orchestrator/execute"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{
        "arbor://fs/read/**" => "auto",
        "arbor://fs/write" => "ask",
        "arbor://orchestrator/execute" => "auto"
      }
    },
    "template_source" => %{
      "name" => "coding_agent",
      "path" => "/abs/secret/path/coding_agent.md",
      "layer" => "shipped"
    },
    "metadata" => %{
      "runtime" => "acp",
      "model" => "gpt-5.5"
    }
  }

  describe "build/3" do
    test "builds authority-only envelope without exact policy markers" do
      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)

      assert envelope["version"] == 1
      assert envelope["kind"] == "template_authority_policy"
      assert is_binary(envelope["digest"])
      assert byte_size(envelope["digest"]) == 64

      snapshot = TemplateAuthorityPolicy.snapshot(envelope)

      assert Enum.map(TemplateAuthorityPolicy.capabilities(snapshot), & &1["resource"]) == [
               "arbor://fs/read",
               "arbor://fs/write",
               "arbor://orchestrator/execute"
             ]

      assert TemplateAuthorityPolicy.capabilities(snapshot) == [
               %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
               %{"resource" => "arbor://fs/write", "constraints" => %{}},
               %{"resource" => "arbor://orchestrator/execute", "constraints" => %{}}
             ]

      trust = TemplateAuthorityPolicy.trust_preset(snapshot)
      assert trust["baseline"] == "block"

      assert trust["rules"] == %{
               "arbor://fs/read" => "auto",
               "arbor://fs/write" => "ask",
               "arbor://orchestrator/execute" => "auto"
             }

      provenance = TemplateAuthorityPolicy.provenance(snapshot)
      assert provenance == %{"name" => "coding_agent", "layer" => "shipped"}
      refute Map.has_key?(provenance, "path")
    end

    test "normalizes atom keys and atom trust modes" do
      data = %{
        name: "demo",
        required_capabilities: [
          %{resource: "arbor://fs/list", constraints: %{requires_approval: true}}
        ],
        trust_preset: %{
          baseline: :ask,
          rules: %{:"arbor://fs/list" => :allow}
        }
      }

      assert {:ok, envelope} = TemplateAuthorityPolicy.build("demo", data)
      snapshot = TemplateAuthorityPolicy.snapshot(envelope)

      assert TemplateAuthorityPolicy.capabilities(snapshot) == [
               %{"resource" => "arbor://fs/list", "constraints" => %{"requires_approval" => true}}
             ]

      assert TemplateAuthorityPolicy.trust_preset(snapshot) == %{
               "baseline" => "ask",
               "rules" => %{"arbor://fs/list" => "allow"}
             }
    end

    test "canonical capability ordering is deterministic across input shuffle" do
      shuffled = %{
        @coding_like
        | "required_capabilities" => Enum.shuffle(@coding_like["required_capabilities"])
      }

      assert {:ok, a} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)
      assert {:ok, b} = TemplateAuthorityPolicy.build("coding_agent", shuffled)

      assert a["digest"] == b["digest"]
      assert a["snapshot"]["capabilities"] == b["snapshot"]["capabilities"]
    end

    test "digest is deterministic and ignores absolute provenance paths" do
      with_path = @coding_like

      without_path =
        put_in(@coding_like, ["template_source", "path"], "/other/absolute/path.md")

      assert {:ok, a} = TemplateAuthorityPolicy.build("coding_agent", with_path)
      assert {:ok, b} = TemplateAuthorityPolicy.build("coding_agent", without_path)
      assert a["digest"] == b["digest"]
      refute inspect(a["snapshot"]) =~ "/abs/secret/path"
      refute inspect(b["snapshot"]) =~ "/other/absolute/path"

      changed =
        put_in(@coding_like, ["trust_preset", "rules", "arbor://fs/write"], "auto")

      assert {:ok, c} = TemplateAuthorityPolicy.build("coding_agent", changed)
      refute a["digest"] == c["digest"]
    end

    test "does not require ExactTemplatePolicy markers and does not invent them" do
      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)
      snapshot = TemplateAuthorityPolicy.snapshot(envelope)

      refute Map.has_key?(snapshot, "sandbox_level")
      refute Map.has_key?(snapshot, "repo_root")
      refute Map.has_key?(snapshot, "metadata")
      refute match?(%{"runtime_policy" => _}, snapshot)
    end

    test "dedupes identical capability and trust-rule duplicates" do
      data = %{
        @coding_like
        | "required_capabilities" => [
            %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
            %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}}
          ],
          "trust_preset" => %{
            "baseline" => "block",
            "rules" => %{
              "arbor://fs/read/**" => "auto",
              "arbor://fs/read" => "auto"
            }
          }
      }

      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", data)
      snapshot = TemplateAuthorityPolicy.snapshot(envelope)

      assert TemplateAuthorityPolicy.capabilities(snapshot) == [
               %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}}
             ]

      assert TemplateAuthorityPolicy.trust_preset(snapshot)["rules"] == %{
               "arbor://fs/read" => "auto"
             }
    end

    test "rejects invalid inputs" do
      assert {:error, {:template_authority_policy, :capabilities_missing_or_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "required_capabilities" => "nope"
               })

      assert {:error, {:template_authority_policy, :trust_preset_missing_or_invalid}} =
               TemplateAuthorityPolicy.build(
                 "coding_agent",
                 Map.delete(@coding_like, "trust_preset")
               )

      assert {:error, {:template_authority_policy, :trust_mode_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "trust_preset" => %{"baseline" => "maybe", "rules" => %{}}
               })

      assert {:error, {:template_authority_policy, :capability_resource_missing_or_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "required_capabilities" => [%{"resource" => "http://evil"}]
               })

      assert {:error,
              {:template_authority_policy, {:unsupported_capability_constraints, ["ttl"]}}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "required_capabilities" => [
                     %{"resource" => "arbor://fs/read", "constraints" => %{"ttl" => 1}}
                   ]
               })

      assert {:error,
              {:template_authority_policy, {:template_name_mismatch, "other", "coding_agent"}}} =
               TemplateAuthorityPolicy.build("coding_agent", %{@coding_like | "name" => "other"})

      assert {:error, {:template_authority_policy, :invalid_build_options}} =
               TemplateAuthorityPolicy.build("coding_agent", @coding_like, ["not-a-keyword"])
    end

    test "rejects invalid provenance layer and provenance name mismatch" do
      bad_layer = put_in(@coding_like, ["template_source", "layer"], "network")

      assert {:error, {:template_authority_policy, :provenance_layer_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", bad_layer)

      bad_name = put_in(@coding_like, ["template_source", "name"], "other_template")

      assert {:error,
              {:template_authority_policy,
               {:provenance_name_mismatch, "other_template", "coding_agent"}}} =
               TemplateAuthorityPolicy.build("coding_agent", bad_name)
    end
  end

  describe "conflicts and adversarial bounds" do
    test "rejects same-resource capabilities with conflicting constraints" do
      data = %{
        @coding_like
        | "required_capabilities" => [
            %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
            %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 99}}
          ]
      }

      assert {:error,
              {:template_authority_policy, {:capability_resource_conflict, "arbor://fs/read"}}} =
               TemplateAuthorityPolicy.build("coding_agent", data)
    end

    test "rejects trust URIs that canonicalize to one key with conflicting modes" do
      data = %{
        @coding_like
        | "trust_preset" => %{
            "baseline" => "block",
            "rules" => %{
              "arbor://fs/read/**" => "auto",
              "arbor://fs/read" => "ask"
            }
          }
      }

      assert {:error,
              {:template_authority_policy,
               {:trust_rule_conflict, "arbor://fs/read", mode_a, mode_b}}} =
               TemplateAuthorityPolicy.build("coding_agent", data)

      assert MapSet.new([mode_a, mode_b]) == MapSet.new(["auto", "ask"])
    end

    test "rejects oversized resource URI, trust URI, and template name" do
      huge = "arbor://fs/" <> String.duplicate("x", 2_000)

      assert {:error, {:template_authority_policy, :capability_resource_missing_or_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "required_capabilities" => [%{"resource" => huge}]
               })

      assert {:error, {:template_authority_policy, :trust_rule_uri_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "trust_preset" => %{
                     "baseline" => "block",
                     "rules" => %{huge => "auto"}
                   }
               })

      long_name = String.duplicate("a", 300)

      assert {:error, {:template_authority_policy, :template_name_invalid}} =
               TemplateAuthorityPolicy.build(long_name, %{
                 @coding_like
                 | "name" => long_name
               })
    end

    test "rejects malformed capability URIs and non-terminal trust globs" do
      assert {:error, {:template_authority_policy, :capability_resource_missing_or_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "required_capabilities" => [%{"resource" => "arbor://fs//read"}]
               })

      assert {:error, {:template_authority_policy, :trust_rule_uri_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "trust_preset" => %{
                     "baseline" => "block",
                     "rules" => %{"arbor://fs/*/read" => "auto"}
                   }
               })
    end

    test "rejects non-JSON-clean constraint values" do
      assert {:error, {:template_authority_policy, :capability_constraints_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "required_capabilities" => [
                     %{
                       "resource" => "arbor://fs/read",
                       "constraints" => %{"rate_limit" => %{nested: true}}
                     }
                   ]
               })

      assert {:error, {:template_authority_policy, :capability_constraints_invalid}} =
               TemplateAuthorityPolicy.build("coding_agent", %{
                 @coding_like
                 | "required_capabilities" => [
                     %{
                       "resource" => "arbor://fs/read",
                       "constraints" => %{"requires_approval" => "yes"}
                     }
                   ]
               })
    end

    test "normalize_capabilities accepts Capability structs and mixed atom/string maps" do
      assert {:ok, cap} =
               Capability.new(
                 resource_uri: "arbor://fs/read",
                 principal_id: "agent_test_principal",
                 constraints: %{rate_limit: 10}
               )

      assert {:ok, normalized} =
               TemplateAuthorityPolicy.normalize_capabilities([
                 cap,
                 %{resource: "arbor://fs/write", constraints: %{"requires_approval" => true}}
               ])

      assert normalized == [
               %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
               %{
                 "resource" => "arbor://fs/write",
                 "constraints" => %{"requires_approval" => true}
               }
             ]
    end
  end

  describe "envelope round-trip and tamper evidence" do
    test "validate_envelope accepts self-built envelopes" do
      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)
      assert {:ok, ^envelope} = TemplateAuthorityPolicy.validate_envelope(envelope)
    end

    test "from_metadata / put_metadata / marked?" do
      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)
      metadata = TemplateAuthorityPolicy.put_metadata(%{"other" => 1}, envelope)

      assert TemplateAuthorityPolicy.marked?(metadata)
      assert {:ok, ^envelope} = TemplateAuthorityPolicy.from_metadata(metadata)
      assert :not_marked = TemplateAuthorityPolicy.from_metadata(%{})
    end

    test "snapshot content that mismatches the supplied digest is rejected" do
      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)
      tampered = put_in(envelope, ["snapshot", "trust_preset", "baseline"], "allow")

      assert {:error, {:template_authority_policy, :authority_snapshot_digest_mismatch}} =
               TemplateAuthorityPolicy.validate_envelope(tampered)

      # An arbitrary replacement digest also fails the semantic-integrity check.
      replacement_digest =
        :crypto.hash(:sha256, "not-the-semantic-snapshot") |> Base.encode16(case: :lower)

      mismatched = %{tampered | "digest" => replacement_digest}

      assert {:error, {:template_authority_policy, :authority_snapshot_digest_mismatch}} =
               TemplateAuthorityPolicy.validate_envelope(mismatched)
    end

    test "partial envelope claims fail closed instead of becoming raw authority views" do
      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)

      assert {:error, {:template_authority_policy, :digest_missing_or_invalid}} =
               envelope
               |> Map.delete("digest")
               |> TemplateAuthorityPolicy.normalize_authority_view()

      raw_with_digest = %{
        "capabilities" => [],
        "trust_preset" => %{"baseline" => "block", "rules" => %{}},
        "digest" => envelope["digest"]
      }

      assert {:error, {:template_authority_policy, :snapshot_missing_or_invalid}} =
               TemplateAuthorityPolicy.normalize_authority_view(raw_with_digest)
    end

    test "normalize_authority_view validates full envelopes and does not accept tampering" do
      assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @coding_like)
      assert {:ok, view} = TemplateAuthorityPolicy.normalize_authority_view(envelope)
      assert map_size(view) == 2
      assert is_list(view["capabilities"])
      assert is_map(view["trust_preset"])

      tampered = put_in(envelope, ["snapshot", "capabilities"], [])

      assert {:error, {:template_authority_policy, :authority_snapshot_digest_mismatch}} =
               TemplateAuthorityPolicy.normalize_authority_view(tampered)
    end
  end
end
