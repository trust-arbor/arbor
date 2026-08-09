defmodule Arbor.Agent.TemplateAuthorityPreviewCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityPreviewCore, as: Core
  alias Arbor.Contracts.Security.Capability

  @moduletag :fast

  @repo_agent "agent_preview1"

  @template_data %{
    "name" => "scout",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/write"},
      %{"resource" => "arbor://orchestrator/execute"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{
        "arbor://fs/write" => "ask",
        "arbor://orchestrator/execute" => "auto"
      }
    },
    "template_source" => %{"name" => "scout", "layer" => "shipped"}
  }

  @stale_digest String.duplicate("ab", 32)

  setup do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("scout", @template_data)
    snap = TemplateAuthorityPolicy.snapshot(envelope)

    desired_view = %{
      "capabilities" => [
        %{"resource" => "arbor://fs/write", "constraints" => %{}},
        %{"resource" => "arbor://orchestrator/execute/**", "constraints" => %{}}
      ],
      "trust_preset" => TemplateAuthorityPolicy.trust_preset(snap)
    }

    %{envelope: envelope, desired_view: desired_view, digest: envelope["digest"]}
  end

  defp authority_meta(digest, opts \\ []) do
    %{
      source: Keyword.get(opts, :source, :template_authority_policy),
      version: Keyword.get(opts, :version, 1),
      template: Keyword.get(opts, :template, "scout"),
      template_digest: digest
    }
  end

  defp tagged_cap(resource, digest, opts \\ []) do
    {:ok, cap} =
      Capability.new(
        resource_uri: resource,
        principal_id: @repo_agent,
        metadata: authority_meta(digest, opts)
      )

    cap
  end

  defp complete_facts(envelope, desired_view, overrides) do
    Map.merge(
      %{
        target_agent_id: @repo_agent,
        profile_version: 3,
        template_name: "scout",
        desired_envelope: envelope,
        desired_view: desired_view,
        desired_provenance: %{"name" => "scout", "layer" => "shipped"},
        persisted_provenance: %{"name" => "scout", "layer" => "shipped"},
        managed_actual_view: desired_view,
        ownership_rows: [],
        ownership_class: "clean",
        stored_marker: %{state: "valid", digest: envelope["digest"], envelope: envelope},
        reads: %{profile: :ok, template: :ok, capabilities: :ok, trust: :ok}
      },
      overrides
    )
  end

  test "status precedence ranks invalid above unavailable" do
    assert Core.prefer_status("invalid", "unavailable") == "invalid"
    assert Core.prefer_status("unavailable", "invalid") == "invalid"
    assert Core.prefer_status("invalid", "drifted") == "invalid"
    assert Core.prefer_status("unavailable", "drifted") == "unavailable"
    assert Core.prefer_status("drifted", "unmanaged") == "drifted"
    assert Core.prefer_status("unmanaged", "current") == "unmanaged"
    assert Core.prefer_status("current", "current") == "current"
  end

  test "closed authority marker is managed; stale digest/template remain managed", %{
    digest: digest
  } do
    tagged = tagged_cap("arbor://fs/write", digest)
    stale = tagged_cap("arbor://fs/list", @stale_digest, template: "other_template")

    {:ok, scoped} =
      Capability.new(
        resource_uri: "arbor://fs/read",
        principal_id: @repo_agent,
        task_id: "task_1",
        metadata: authority_meta(digest)
      )

    legacy = [%{"resource" => "arbor://other", "constraints" => %{}}]

    assert {:ok, ownership} = Core.classify_ownership([tagged, stale, scoped], legacy)
    assert ownership["ownership"] == "clean"

    assert Enum.map(ownership["managed"], & &1["resource"]) |> Enum.sort() == [
             "arbor://fs/list",
             "arbor://fs/write"
           ]

    assert Enum.map(ownership["rows"], & &1["class"]) |> Enum.sort() == [
             "authority_tagged",
             "authority_tagged",
             "preserved"
           ]

    assert length(ownership["preserved"]) == 1
    assert hd(ownership["preserved"])["resource"] == "arbor://fs/read"
  end

  test "structurally invalid source markers fail closed", %{digest: digest} do
    cases = [
      # incomplete marker (source only)
      %{source: :template_authority_policy},
      # wrong version
      authority_meta(digest, version: 2),
      # empty template
      authority_meta(digest, template: ""),
      # non-hex digest
      authority_meta("zzzz" <> String.duplicate("0", 60)),
      # wrong-length digest
      %{
        source: :template_authority_policy,
        version: 1,
        template: "scout",
        template_digest: "deadbeef"
      },
      # lookalike source
      %{source: "template_authority_policy_extra"},
      # atom/string source conflict (string key first; mixed keyword maps require it)
      %{
        "source" => "baseline",
        source: :template_authority_policy,
        version: 1,
        template: "scout",
        template_digest: digest
      },
      # orphan marker fields without source
      %{version: 1, template: "scout", template_digest: digest}
    ]

    for meta <- cases do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/write",
          principal_id: @repo_agent,
          metadata: meta
        )

      assert {:error, :ownership_invalid} = Core.classify_ownership([cap], []),
             "expected invalid for metadata=#{inspect(meta)}"
    end
  end

  test "adversarial source claims fail closed before lookalike or explicit-other admission" do
    adversarial_sources = [
      nil,
      true,
      false,
      "",
      String.duplicate("x", 513),
      <<0xFF, 0xFE>>,
      "baseline" <> <<0>>,
      "template_authority" <> <<0>> <> "x",
      42,
      %{},
      []
    ]

    for source <- adversarial_sources do
      grant = %{
        resource_uri: "arbor://fs/write",
        principal_id: @repo_agent,
        constraints: %{},
        metadata: %{source: source}
      }

      assert {:error, :ownership_invalid} = Core.classify_ownership([grant], []),
             "expected invalid for source=#{inspect(source)}"
    end

    # Bounded nonblank binary and non-boolean atom remain preserved explicit-other.
    for source <- ["custom_policy", :external, :baseline] do
      grant = %{
        resource_uri: "arbor://fs/write",
        principal_id: @repo_agent,
        constraints: %{},
        metadata: %{source: source}
      }

      assert {:ok, ownership} = Core.classify_ownership([grant], [])
      assert hd(ownership["rows"])["class"] == "preserved"
    end
  end

  test "resource alias and atom/string resource conflicts on live grants fail closed" do
    alias_conflict = %{
      resource: "arbor://fs/write",
      resource_uri: "arbor://fs/read",
      principal_id: @repo_agent,
      constraints: %{}
    }

    assert {:error, :ownership_invalid} = Core.classify_ownership([alias_conflict], [])

    key_conflict = %{
      "resource_uri" => "arbor://fs/write",
      resource_uri: "arbor://fs/read",
      principal_id: @repo_agent,
      constraints: %{}
    }

    assert {:error, :ownership_invalid} = Core.classify_ownership([key_conflict], [])

    alias_agree = %{
      resource: "arbor://fs/write",
      resource_uri: "arbor://fs/write",
      principal_id: @repo_agent,
      constraints: %{}
    }

    assert {:ok, ownership} = Core.classify_ownership([alias_agree], [])
    assert hd(ownership["preserved"])["resource"] == "arbor://fs/write"
  end

  test "metadata and standing-scope atom/string conflicts on live grants fail closed" do
    metadata_conflict = %{
      "metadata" => %{source: "external"},
      resource_uri: "arbor://fs/write",
      principal_id: @repo_agent,
      constraints: %{},
      metadata: %{source: "baseline"}
    }

    assert {:error, :ownership_invalid} =
             Core.classify_ownership([metadata_conflict], [])

    standing_conflict = %{
      "expires_at" => DateTime.utc_now() |> DateTime.add(60, :second),
      resource_uri: "arbor://fs/write",
      principal_id: @repo_agent,
      constraints: %{},
      expires_at: nil
    }

    assert {:error, :ownership_invalid} =
             Core.classify_ownership([standing_conflict], [])
  end

  test "another explicit source is preserved and never falls through to legacy" do
    legacy = [%{"resource" => "arbor://fs/write", "constraints" => %{}}]

    for source <- [:exact_template_policy, "baseline", :external, "custom_policy"] do
      {:ok, cap} =
        Capability.new(
          resource_uri: "arbor://fs/write",
          principal_id: @repo_agent,
          metadata: %{source: source}
        )

      assert {:ok, ownership} = Core.classify_ownership([cap], legacy)
      assert ownership["managed"] == []
      assert length(ownership["preserved"]) == 1
      assert hd(ownership["rows"])["class"] == "preserved"
    end
  end

  test "legacy exact match on effective projection is managed; unrelated preserved" do
    legacy = [
      %{"resource" => "arbor://fs/write", "constraints" => %{}},
      %{"resource" => "arbor://orchestrator/execute/**", "constraints" => %{}}
    ]

    {:ok, match} =
      Capability.new(resource_uri: "arbor://fs/write", principal_id: @repo_agent)

    {:ok, other} =
      Capability.new(resource_uri: "arbor://shell/exec", principal_id: @repo_agent)

    {:ok, temp} =
      Capability.new(
        resource_uri: "arbor://orchestrator/execute/**",
        principal_id: @repo_agent,
        expires_at: DateTime.utc_now() |> DateTime.add(60, :second)
      )

    assert {:ok, ownership} = Core.classify_ownership([match, other, temp], legacy)
    assert Enum.map(ownership["managed"], & &1["resource"]) == ["arbor://fs/write"]
    assert Enum.any?(ownership["rows"], &(&1["class"] == "legacy"))

    preserved_resources = Enum.map(ownership["preserved"], & &1["resource"]) |> Enum.sort()
    assert preserved_resources == ["arbor://orchestrator/execute/**", "arbor://shell/exec"]
  end

  test "scoped grants stay preserved even when resource matches legacy; malformed marker still invalid",
       %{digest: digest} do
    legacy = [
      %{"resource" => "arbor://fs/write", "constraints" => %{}},
      %{"resource" => "arbor://orchestrator/execute/**", "constraints" => %{}}
    ]

    {:ok, delegated} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: @repo_agent,
        parent_capability_id: "cap_parent"
      )

    {:ok, session_bound} =
      Capability.new(
        resource_uri: "arbor://orchestrator/execute/**",
        principal_id: @repo_agent,
        session_id: "sess_1"
      )

    assert {:ok, ownership} = Core.classify_ownership([delegated, session_bound], legacy)
    assert ownership["managed"] == []
    assert length(ownership["preserved"]) == 2

    {:ok, malformed_scoped} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: @repo_agent,
        task_id: "task_x",
        metadata: %{source: :template_authority_policy, template_digest: "nope"}
      )

    assert {:error, :ownership_invalid} = Core.classify_ownership([malformed_scoped], legacy)

    # Valid authority marker on scoped grant → preserved, not managed.
    {:ok, scoped_tagged} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: @repo_agent,
        task_id: "task_y",
        metadata: authority_meta(digest)
      )

    assert {:ok, ownership2} = Core.classify_ownership([scoped_tagged], legacy)
    assert ownership2["managed"] == []
    assert hd(ownership2["rows"])["class"] == "preserved"
  end

  test "ambiguous duplicate live resources fail closed even when constraints match", %{
    digest: digest
  } do
    a = tagged_cap("arbor://fs/write", digest)
    b = tagged_cap("arbor://fs/write", digest)

    assert {:error, :ownership_invalid} = Core.classify_ownership([a, b], [])

    {:ok, legacy_a} =
      Capability.new(resource_uri: "arbor://fs/write", principal_id: @repo_agent)

    {:ok, legacy_b} =
      Capability.new(resource_uri: "arbor://fs/write", principal_id: @repo_agent)

    assert {:error, :ownership_invalid} =
             Core.classify_ownership([legacy_a, legacy_b], [
               %{"resource" => "arbor://fs/write", "constraints" => %{}}
             ])
  end

  test "conflicting managed constraints fail closed", %{digest: digest} do
    {:ok, a} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: @repo_agent,
        constraints: %{rate_limit: 1},
        metadata: authority_meta(digest)
      )

    {:ok, b} =
      Capability.new(
        resource_uri: "arbor://fs/write",
        principal_id: @repo_agent,
        constraints: %{rate_limit: 2},
        metadata: authority_meta(digest)
      )

    assert {:error, :ownership_invalid} = Core.classify_ownership([a, b], [])
  end

  test "malformed live grant is invalid not unknown-preserved" do
    bad = %{resource_uri: "", principal_id: @repo_agent, constraints: %{}}
    assert {:error, :ownership_invalid} = Core.classify_ownership([bad], [])
  end

  test "bounded ownership admission rejects oversize and improper live grant spines" do
    # Plain maps avoid Capability construction cost; admission must fail closed on
    # the list spine before semantic ownership work.
    too_many =
      for _i <- 1..513 do
        %{
          resource_uri: "arbor://fs/write",
          principal_id: @repo_agent,
          constraints: %{}
        }
      end

    assert {:error, {:template_authority_preview, :ownership_too_many}} =
             Core.classify_ownership(too_many, [])

    improper = [
      %{resource_uri: "arbor://fs/write", principal_id: @repo_agent, constraints: %{}}
      | :tail
    ]

    assert {:error, {:template_authority_preview, :invalid_ownership_input}} =
             Core.classify_ownership(improper, [])
  end

  test "compose current when marker matches, persisted provenance agrees, and diff unchanged",
       %{
         envelope: envelope,
         desired_view: desired_view
       } do
    facts =
      complete_facts(envelope, desired_view, %{
        ownership_rows: [
          %{
            "resource" => "arbor://fs/write",
            "constraints" => %{},
            "class" => "authority_tagged"
          },
          %{
            "resource" => "arbor://orchestrator/execute/**",
            "constraints" => %{},
            "class" => "authority_tagged"
          }
        ]
      })

    assert {:ok, report} = Core.compose(facts)
    assert report["status"] == "current"
    assert report["kind"] == "template_authority_preview"
    assert report["version"] == 1
    assert report["desired_declaration_digest"] == envelope["digest"]
    assert report["stored_marker"]["state"] == "current"
    assert is_binary(report["reconciliation_digest"])
    assert byte_size(report["reconciliation_digest"]) == 64
    assert valid_hex64?(report["preserved_unmanaged"]["semantic_digest"])
    assert report["summary"]["authority_tagged_count"] == 2
    assert report["summary"]["legacy_count"] == 0
    refute Map.has_key?(report, "session_token")
    refute inspect(report) =~ "cap_"
  end

  test "compose unmanaged without marker even when content matches", %{
    envelope: envelope,
    desired_view: desired_view
  } do
    facts =
      complete_facts(envelope, desired_view, %{
        profile_version: 1,
        ownership_rows: [
          %{"resource" => "arbor://shell/exec", "constraints" => %{}, "class" => "preserved"}
        ],
        stored_marker: %{state: "absent", digest: nil, envelope: nil}
      })

    assert {:ok, report} = Core.compose(facts)
    assert report["status"] == "unmanaged"
    assert report["preserved_unmanaged"]["count"] == 1
    assert report["preserved_unmanaged"]["resources"] == ["arbor://shell/exec"]
    assert valid_hex64?(report["reconciliation_digest"])
  end

  test "compose drifted when marker stale, provenance drifts, or content differs", %{
    envelope: envelope,
    desired_view: desired_view
  } do
    drifted_actual = %{
      "capabilities" => [%{"resource" => "arbor://fs/write", "constraints" => %{}}],
      "trust_preset" => desired_view["trust_preset"]
    }

    facts =
      complete_facts(envelope, desired_view, %{
        profile_version: 2,
        managed_actual_view: drifted_actual
      })

    assert {:ok, report} = Core.compose(facts)
    assert report["status"] == "drifted"
    assert report["summary"]["diff_unchanged"] == false

    # Persisted provenance drift keeps marker stale / status drifted even if
    # managed content matches.
    match_facts =
      complete_facts(envelope, desired_view, %{
        profile_version: 2,
        managed_actual_view: desired_view,
        persisted_provenance: %{"name" => "scout", "layer" => "user"}
      })

    assert {:ok, drifted_prov} = Core.compose(match_facts)
    assert drifted_prov["status"] == "drifted"
    assert drifted_prov["stored_marker"]["state"] == "stale"
  end

  test "compose unavailable and invalid diagnostics have nil reconciliation_digest", %{
    envelope: envelope
  } do
    assert {:ok, unavailable} =
             Core.compose(%{
               target_agent_id: @repo_agent,
               profile_version: nil,
               template_name: "scout",
               reads: %{profile: :unavailable}
             })

    assert unavailable["status"] == "unavailable"
    assert is_nil(unavailable["reconciliation_digest"])
    assert is_nil(unavailable["desired_declaration_digest"])
    assert is_nil(unavailable["effective_managed_diff"])

    assert {:ok, invalid} =
             Core.compose(%{
               target_agent_id: @repo_agent,
               profile_version: 1,
               template_name: "scout",
               ownership: :invalid,
               desired_envelope: envelope,
               reads: %{profile: :ok, template: :ok, capabilities: :ok, trust: :ok}
             })

    assert invalid["status"] == "invalid"
    assert is_nil(invalid["reconciliation_digest"])
  end

  test "invalid outranks unavailable when both observation signals present" do
    assert {:ok, report} =
             Core.compose(%{
               target_agent_id: @repo_agent,
               profile_version: 1,
               template_name: "scout",
               ownership: :invalid,
               reads: %{profile: :unavailable, ownership: :invalid}
             })

    assert report["status"] == "invalid"
    assert is_nil(report["reconciliation_digest"])
  end

  test "compose rejects incomplete or improper observed facts before semantic traversal", %{
    envelope: envelope,
    desired_view: desired_view
  } do
    # Missing required views → diagnostic invalid, not a crash.
    assert {:ok, missing} =
             Core.compose(%{
               target_agent_id: @repo_agent,
               profile_version: 1,
               template_name: "scout",
               reads: %{profile: :ok, template: :ok, capabilities: :ok, trust: :ok}
             })

    assert missing["status"] == "invalid"
    assert is_nil(missing["reconciliation_digest"])

    improper_rows = [
      %{"resource" => "arbor://fs/write", "constraints" => %{}, "class" => "preserved"}
      | :tail
    ]

    assert {:ok, improper} =
             Core.compose(
               complete_facts(envelope, desired_view, %{ownership_rows: improper_rows})
             )

    assert improper["status"] == "invalid"
    assert is_nil(improper["reconciliation_digest"])

    # Malformed non-map reads must not raise — treated as invalid observation.
    assert {:ok, bad_reads} =
             Core.compose(%{
               target_agent_id: @repo_agent,
               profile_version: 1,
               template_name: "scout",
               reads: :not_a_map
             })

    assert bad_reads["status"] == "invalid"
    assert is_nil(bad_reads["reconciliation_digest"])

    assert {:ok, list_reads} =
             Core.compose(%{
               target_agent_id: @repo_agent,
               profile_version: 1,
               template_name: "scout",
               reads: [profile: :ok]
             })

    assert list_reads["status"] == "invalid"

    # Malformed authority views fail closed to diagnostic invalid.
    assert {:ok, bad_view} =
             Core.compose(
               complete_facts(envelope, desired_view, %{
                 managed_actual_view: %{"capabilities" => :not_a_list}
               })
             )

    assert bad_view["status"] == "invalid"
  end

  test "reconciliation digest binds full preserved semantics and ownership class", %{
    envelope: envelope,
    desired_view: desired_view
  } do
    base = complete_facts(envelope, desired_view, %{profile_version: 4})

    assert {:ok, a} = Core.compose(base)
    assert {:ok, b} = Core.compose(base)
    assert a["reconciliation_digest"] == b["reconciliation_digest"]
    assert a["version"] == 1
    assert a["kind"] == "template_authority_preview"
    assert valid_hex64?(a["reconciliation_digest"])

    assert {:ok, other_target} = Core.compose(%{base | target_agent_id: "agent_other1"})
    refute other_target["reconciliation_digest"] == a["reconciliation_digest"]

    assert {:ok, other_version} = Core.compose(%{base | profile_version: 99})
    refute other_version["reconciliation_digest"] == a["reconciliation_digest"]

    # Desired / actual content binds into the digest.
    drifted_actual = %{
      "capabilities" => [%{"resource" => "arbor://fs/write", "constraints" => %{}}],
      "trust_preset" => desired_view["trust_preset"]
    }

    assert {:ok, content_drift} =
             Core.compose(%{base | managed_actual_view: drifted_actual})

    refute content_drift["reconciliation_digest"] == a["reconciliation_digest"]

    # Marker digest binding.
    assert {:ok, marker_drift} =
             Core.compose(%{
               base
               | stored_marker: %{
                   state: "valid",
                   digest: @stale_digest,
                   envelope: envelope
                 }
             })

    refute marker_drift["reconciliation_digest"] == a["reconciliation_digest"]

    # Provenance binding.
    assert {:ok, prov_drift} =
             Core.compose(%{
               base
               | desired_provenance: %{"name" => "scout", "layer" => "user"}
             })

    refute prov_drift["reconciliation_digest"] == a["reconciliation_digest"]

    # Hidden preserved replacement past display truncation changes digest.
    many =
      for i <- 1..70 do
        %{
          "resource" => "arbor://custom/resource#{i}",
          "constraints" => %{},
          "class" => "preserved"
        }
      end

    assert {:ok, with_many} = Core.compose(%{base | ownership_rows: many})
    assert with_many["preserved_unmanaged"]["count"] == 70
    assert length(with_many["preserved_unmanaged"]["resources"]) == 64

    replaced =
      List.replace_at(many, 69, %{
        "resource" => "arbor://custom/resourcezz",
        "constraints" => %{},
        "class" => "preserved"
      })

    assert {:ok, with_replaced} = Core.compose(%{base | ownership_rows: replaced})
    assert with_replaced["preserved_unmanaged"]["count"] == 70
    assert length(with_replaced["preserved_unmanaged"]["resources"]) == 64

    refute with_replaced["preserved_unmanaged"]["semantic_digest"] ==
             with_many["preserved_unmanaged"]["semantic_digest"]

    refute with_replaced["reconciliation_digest"] == with_many["reconciliation_digest"]

    # Constraint change on a preserved row changes the semantic digest.
    constrained = [
      %{
        "resource" => "arbor://shell/exec",
        "constraints" => %{"rate_limit" => 1},
        "class" => "preserved"
      }
    ]

    unconstrained = [
      %{"resource" => "arbor://shell/exec", "constraints" => %{}, "class" => "preserved"}
    ]

    assert {:ok, c1} = Core.compose(%{base | ownership_rows: constrained})
    assert {:ok, c2} = Core.compose(%{base | ownership_rows: unconstrained})
    refute c1["reconciliation_digest"] == c2["reconciliation_digest"]

    # Ownership reclassification (legacy vs tagged) changes digest at equal resource set.
    legacy_rows = [
      %{"resource" => "arbor://fs/write", "constraints" => %{}, "class" => "legacy"},
      %{
        "resource" => "arbor://orchestrator/execute/**",
        "constraints" => %{},
        "class" => "legacy"
      }
    ]

    tagged_rows = [
      %{
        "resource" => "arbor://fs/write",
        "constraints" => %{},
        "class" => "authority_tagged"
      },
      %{
        "resource" => "arbor://orchestrator/execute/**",
        "constraints" => %{},
        "class" => "authority_tagged"
      }
    ]

    assert {:ok, legacy_report} = Core.compose(%{base | ownership_rows: legacy_rows})
    assert {:ok, tagged_report} = Core.compose(%{base | ownership_rows: tagged_rows})
    refute legacy_report["reconciliation_digest"] == tagged_report["reconciliation_digest"]
    assert legacy_report["summary"]["legacy_count"] == 2
    assert tagged_report["summary"]["authority_tagged_count"] == 2

    # Trust binding: baseline change alters reconciliation digest.
    trust_drift_view = %{
      desired_view
      | "trust_preset" => %{
          "baseline" => "ask",
          "rules" => desired_view["trust_preset"]["rules"]
        }
    }

    assert {:ok, trust_drift} =
             Core.compose(%{
               base
               | managed_actual_view: trust_drift_view
             })

    refute trust_drift["reconciliation_digest"] == a["reconciliation_digest"]

    refute inspect(a) =~ "session_token"
    refute inspect(a) =~ "/abs/"
  end

  test "assert_report rejects open shapes and nested JSON maps that only share top keys", %{
    envelope: envelope,
    desired_view: desired_view
  } do
    assert {:error, {:template_authority_preview, :invalid_report}} =
             Core.assert_report(%{atom: :bad})

    assert {:error, {:template_authority_preview, :invalid_report}} =
             Core.assert_report(%{"version" => 1, "kind" => "nope"})

    assert {:ok, good} =
             Core.compose(complete_facts(envelope, desired_view, %{profile_version: 1}))

    # Nested arbitrary map under an expected key must not pass.
    poisoned =
      put_in(good, ["template", "desired_provenance"], %{
        "name" => "scout",
        "layer" => "shipped",
        "extra" => "nope"
      })

    assert {:error, {:template_authority_preview, :invalid_report}} =
             Core.assert_report(poisoned)

    # Improper list spines are rejected by json_clean admission before structural
    # validators walk the report (must not raise via length/1).
    improper_resources =
      put_in(good, ["preserved_unmanaged", "resources"], ["arbor://shell/exec" | :tail])

    assert {:error, {:template_authority_preview, :invalid_report}} =
             Core.assert_report(improper_resources)

    # Status-dependent: complete observation cannot carry nil CAS digest.
    assert {:error, {:template_authority_preview, :invalid_report}} =
             Core.assert_report(Map.put(good, "reconciliation_digest", nil))

    # Diagnostic invalid must keep reconciliation_digest nil.
    diag = Core.diagnostic_report(status: "invalid", target_agent_id: @repo_agent, code: "x")
    assert {:ok, ^diag} = Core.assert_report(diag)
    assert is_nil(diag["reconciliation_digest"])

    # Fabricated top-level-only lookalike is rejected.
    lookalike = %{
      "version" => 1,
      "kind" => "template_authority_preview",
      "status" => "current",
      "target_agent_id" => @repo_agent,
      "template" => %{"name" => "scout"},
      "desired_declaration_digest" => envelope["digest"],
      "stored_marker" => %{"state" => "current"},
      "effective_managed_diff" => %{"ok" => true},
      "preserved_unmanaged" => %{"count" => 0},
      "summary" => %{"status" => "current"},
      "profile_version" => 1,
      "reconciliation_digest" => envelope["digest"]
    }

    assert {:error, {:template_authority_preview, :invalid_report}} =
             Core.assert_report(lookalike)
  end

  defp valid_hex64?(digest) when is_binary(digest) do
    byte_size(digest) == 64 and String.match?(digest, ~r/^[0-9a-f]{64}$/)
  end

  defp valid_hex64?(_), do: false
end
