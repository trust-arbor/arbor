defmodule Arbor.Agent.ProfileAuthorityMutationCoreTest do
  @moduledoc """
  Pure unit tests for `Arbor.Agent.ProfileAuthorityMutationCore`.

  Covers governed overlay (template_authority_policy + template_source),
  exact_template_policy preservation, Policy bind, commit_prepared_mutation,
  classify_restart, and Phase 4B current-marker regression.
  """

  use ExUnit.Case, async: true

  @moduletag :fast

  alias Arbor.Agent.ProfileAuthorityMutationCore, as: Core
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Contracts.Persistence.Record

  @template_data %{
    "name" => "scout",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{"arbor://fs/read" => "auto"}
    },
    "template_source" => %{"name" => "scout", "layer" => "shipped"}
  }

  setup do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("scout", @template_data)
    snap = TemplateAuthorityPolicy.snapshot(envelope)
    caps = TemplateAuthorityPolicy.capabilities(snap)
    prov = TemplateAuthorityPolicy.provenance(snap)

    governed = %{
      "template" => "scout",
      "initial_capabilities" => caps,
      "metadata" => %{
        TemplateAuthorityPolicy.metadata_key() => envelope,
        "template_source" => prov
      }
    }

    %{envelope: envelope, governed: governed, caps: caps, prov: prov}
  end

  defp observed_data(opts \\ []) do
    base = %{
      "agent_id" => "agent_test_1",
      "version" => 1,
      "display_name" => "Scout Unit",
      "character" => %{"name" => "Scout"},
      "sandbox_level" => "strict",
      "initial_goals" => [],
      "identity" => nil,
      "keychain_ref" => nil,
      "auto_start" => false,
      "created_at" => "2026-01-01T00:00:00Z",
      "template" => "legacy_template",
      "initial_capabilities" => [
        %{"resource" => "arbor://legacy/read", "constraints" => %{}}
      ],
      "metadata" => %{
        "last_model_config" => %{"provider" => "ollama"},
        "external_agent" => true,
        "exact_template_policy" => %{"old" => true, "runtime" => "keep"},
        "template_source" => %{"name" => "legacy_template", "layer" => "user"},
        "arbitrary_sibling" => "preserved"
      }
    }

    case Keyword.get(opts, :metadata) do
      nil -> base
      meta -> %{base | "metadata" => meta}
    end
  end

  defp record(data, gen, rev, opts \\ []) do
    %Record{
      id: Keyword.get(opts, :id, "rec_test"),
      key: Keyword.get(opts, :key, "agent_test_1"),
      data: data,
      metadata: Keyword.get(opts, :metadata, %{}),
      generation: gen,
      revision: rev,
      inserted_at: Keyword.get(opts, :inserted_at),
      updated_at: Keyword.get(opts, :updated_at)
    }
  end

  defp cas_for(%Record{} = r) do
    %{"record_id" => r.id, "generation" => r.generation, "revision" => r.revision}
  end

  # ─────────────────────────────────────────────────────────────────────
  # prepare/2 — overlay + preservation
  # ─────────────────────────────────────────────────────────────────────

  describe "prepare/2 overlay and preservation" do
    test "overlays governed template, caps, policy marker, and template_source", %{
      governed: governed,
      envelope: envelope,
      caps: caps,
      prov: prov
    } do
      observed = observed_data()
      {:ok, intended} = Core.prepare(observed, governed)

      assert intended["template"] == "scout"
      assert intended["initial_capabilities"] == caps
      assert intended["metadata"][TemplateAuthorityPolicy.metadata_key()] == envelope
      assert intended["metadata"]["template_source"] == prov
    end

    test "preserves exact_template_policy and unrelated fields", %{governed: governed} do
      observed = observed_data()
      original_exact = observed["metadata"]["exact_template_policy"]
      {:ok, intended} = Core.prepare(observed, governed)

      for key <- [
            "agent_id",
            "version",
            "display_name",
            "character",
            "sandbox_level",
            "initial_goals",
            "identity",
            "keychain_ref",
            "auto_start",
            "created_at"
          ] do
        assert intended[key] === observed[key]
      end

      assert intended["metadata"]["exact_template_policy"] === original_exact
      assert intended["metadata"]["last_model_config"] == %{"provider" => "ollama"}
      assert intended["metadata"]["external_agent"] == true
      assert intended["metadata"]["arbitrary_sibling"] == "preserved"
      assert intended["display_name"] == observed["display_name"]
      assert intended["agent_id"] == observed["agent_id"]
    end

    test "preserves absence of exact_template_policy", %{governed: governed} do
      meta = Map.delete(observed_data()["metadata"], "exact_template_policy")
      observed = observed_data(metadata: meta)
      {:ok, intended} = Core.prepare(observed, governed)
      refute Map.has_key?(intended["metadata"], "exact_template_policy")
    end

    test "does not mutate observed metadata in place", %{governed: governed} do
      observed = observed_data()
      original_meta = observed["metadata"]
      {:ok, _intended} = Core.prepare(observed, governed)
      assert observed["metadata"] == original_meta
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # prepare/2 — Policy bind + layer gates
  # ─────────────────────────────────────────────────────────────────────

  describe "prepare/2 policy bind and layer rejection" do
    test "rejects authority_inconsistent when template mismatches envelope", %{
      governed: governed
    } do
      bad = %{governed | "template" => "other_name"}
      assert {:error, :authority_inconsistent} = Core.prepare(observed_data(), bad)
    end

    test "rejects authority_inconsistent when caps mismatch envelope", %{governed: governed} do
      bad = %{
        governed
        | "initial_capabilities" => [
            %{"resource" => "arbor://other", "constraints" => %{}}
          ]
      }

      assert {:error, :authority_inconsistent} = Core.prepare(observed_data(), bad)
    end

    test "rejects authority_inconsistent when template_source mismatches provenance", %{
      governed: governed
    } do
      bad =
        put_in(governed, ["metadata", "template_source"], %{
          "name" => "scout",
          "layer" => "user"
        })

      assert {:error, :authority_inconsistent} = Core.prepare(observed_data(), bad)
    end

    test "rejects nil template_source layer", %{envelope: envelope, caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => envelope,
          "template_source" => %{"name" => "scout", "layer" => nil}
        }
      }

      assert {:error, :provenance_layer_invalid} = Core.prepare(observed_data(), governed)
    end

    test "rejects missing template_source layer key", %{envelope: envelope, caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => envelope,
          "template_source" => %{"name" => "scout"}
        }
      }

      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects invalid policy envelope digest", %{governed: governed} do
      bad =
        put_in(
          governed,
          ["metadata", TemplateAuthorityPolicy.metadata_key(), "digest"],
          String.duplicate("ff", 32)
        )

      assert {:error, :policy_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects legacy exact_template_policy-only governed metadata", %{caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{"exact_template_policy" => %{"version" => 1}}
      }

      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects atom alias of template_authority_policy in observed metadata", %{
      governed: governed
    } do
      observed =
        observed_data(
          metadata: Map.put(observed_data()["metadata"], :template_authority_policy, %{})
        )

      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed)
    end

    test "rejects atom alias of template_source in observed metadata", %{governed: governed} do
      observed =
        observed_data(metadata: Map.put(observed_data()["metadata"], :template_source, %{}))

      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed)
    end
  end

  describe "prepare/2 malformed containers" do
    test "rejects observed_data that is not a plain map", %{governed: governed} do
      assert {:error, :observed_not_map} = Core.prepare("not a map", governed)
      assert {:error, :observed_not_map} = Core.prepare(nil, governed)
    end

    test "rejects missing observed metadata", %{governed: governed} do
      observed = Map.delete(observed_data(), "metadata")
      assert {:error, :malformed_container} = Core.prepare(observed, governed)
    end

    test "rejects empty template", %{governed: governed} do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), %{governed | "template" => ""})
    end

    test "rejects non-list capabilities", %{governed: governed} do
      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), %{governed | "initial_capabilities" => "nope"})
    end

    test "rejects atom keys in governed update", %{governed: governed} do
      bad = Map.put(Map.delete(governed, "template"), :template, "scout")
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), bad)
    end

    test "rejects atom alias coexisting with the string governed key", %{governed: governed} do
      bad = Map.put(governed, :template, "scout")
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), bad)
    end

    test "rejects extra top-level governed keys", %{governed: governed} do
      bad = Map.put(governed, "display_name", "nope")
      assert {:error, :governed_shape} = Core.prepare(observed_data(), bad)
    end

    test "rejects missing governed metadata", %{caps: caps} do
      bad = %{"template" => "scout", "initial_capabilities" => caps}
      assert {:error, :governed_shape} = Core.prepare(observed_data(), bad)
    end

    test "rejects atom alias of template on observed data", %{governed: governed} do
      observed = Map.put(Map.delete(observed_data(), "template"), :template, "legacy")
      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed)
    end

    test "rejects capability item missing resource", %{governed: governed, caps: caps} do
      bad_caps = [%{"constraints" => %{}} | caps]
      bad = %{governed | "initial_capabilities" => bad_caps}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects oversized template name", %{governed: governed} do
      bad = %{governed | "template" => String.duplicate("t", 300)}
      assert {:error, :template_invalid} = Core.prepare(observed_data(), bad)
    end

    # ── Restored pre-C3B3 prepare rejection inventory (adapted fixtures) ──

    test "rejects observed metadata that is nil", %{governed: governed} do
      observed = Map.put(observed_data(), "metadata", nil)
      assert {:error, :malformed_container} = Core.prepare(observed, governed)
    end

    test "rejects observed metadata that is a scalar", %{governed: governed} do
      observed = Map.put(observed_data(), "metadata", "not-a-map")
      assert {:error, :malformed_container} = Core.prepare(observed, governed)
    end

    test "rejects observed metadata that is a struct", %{governed: governed} do
      observed = Map.put(observed_data(), "metadata", DateTime.utc_now())
      assert {:error, :malformed_container} = Core.prepare(observed, governed)
    end

    test "rejects atom alias of initial_capabilities on observed data", %{governed: governed} do
      observed =
        observed_data()
        |> Map.delete("initial_capabilities")
        |> Map.put(:initial_capabilities, [])

      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed)
    end

    test "rejects atom alias of metadata on observed data", %{governed: governed} do
      meta = observed_data()["metadata"]

      observed =
        observed_data()
        |> Map.delete("metadata")
        |> Map.put(:metadata, meta)

      assert {:error, :ambiguous_keys} = Core.prepare(observed, governed)
    end

    test "rejects atom alias of initial_capabilities in governed", %{governed: governed} do
      caps = governed["initial_capabilities"]

      bad =
        governed
        |> Map.delete("initial_capabilities")
        |> Map.put(:initial_capabilities, caps)

      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), bad)
    end

    test "rejects atom alias of metadata in governed", %{governed: governed} do
      meta = governed["metadata"]

      bad =
        governed
        |> Map.delete("metadata")
        |> Map.put(:metadata, meta)

      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), bad)
    end

    test "rejects arbitrary atom key in governed metadata", %{governed: governed} do
      bad_meta = Map.put(governed["metadata"], :extra, true)
      bad = %{governed | "metadata" => bad_meta}
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), bad)
    end

    test "rejects governed metadata that is a struct", %{governed: governed} do
      bad = %{governed | "metadata" => DateTime.utc_now()}
      assert {:error, :governed_shape} = Core.prepare(observed_data(), bad)
    end

    test "rejects nil and non-binary templates", %{governed: governed} do
      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), %{governed | "template" => nil})

      assert {:error, :template_invalid} =
               Core.prepare(observed_data(), %{governed | "template" => :scout})
    end

    test "rejects non-UTF-8 template", %{governed: governed} do
      bad = %{governed | "template" => <<0xFF, 0xFE, 0xFD>>}
      assert {:error, :template_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects template with embedded NUL", %{governed: governed} do
      bad = %{governed | "template" => "sco\x00ut"}
      assert {:error, :template_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects improper capabilities list", %{governed: governed} do
      bad = %{
        governed
        | "initial_capabilities" => [%{"resource" => "a", "constraints" => %{}} | :tail]
      }

      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects more than 256 capabilities", %{governed: governed} do
      item = %{"resource" => "arbor://fs/read", "constraints" => %{}}
      too_many = Enum.map(1..257, fn _ -> item end)
      bad = %{governed | "initial_capabilities" => too_many}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects oversized capability resource", %{governed: governed} do
      item = %{"resource" => String.duplicate("r", 1025), "constraints" => %{}}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects non-UTF-8 capability resource", %{governed: governed} do
      item = %{"resource" => <<0xFF, 0xFE>>, "constraints" => %{}}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects capability resource with embedded NUL", %{governed: governed} do
      item = %{"resource" => "arbor://x\x00y", "constraints" => %{}}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects capability constraints that are a struct", %{governed: governed} do
      item = %{"resource" => "arbor://fs/read", "constraints" => DateTime.utc_now()}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects capability item structs and scalar constraints", %{governed: governed} do
      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), %{
                 governed
                 | "initial_capabilities" => [DateTime.utc_now()]
               })

      item = %{"resource" => "arbor://fs/read", "constraints" => "nope"}

      assert {:error, :capabilities_invalid} =
               Core.prepare(observed_data(), %{governed | "initial_capabilities" => [item]})
    end

    test "rejects capability item with atom resource alias", %{governed: governed} do
      item = %{:resource => "arbor://fs/read", "constraints" => %{}}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), bad)
    end

    test "rejects capability item with atom constraints alias", %{governed: governed} do
      item = %{"resource" => "arbor://fs/read", :constraints => %{}}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :ambiguous_keys} = Core.prepare(observed_data(), bad)
    end

    test "rejects empty capability resource", %{governed: governed} do
      item = %{"resource" => "", "constraints" => %{}}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects missing capability constraints key", %{governed: governed} do
      item = %{"resource" => "arbor://fs/read"}
      bad = %{governed | "initial_capabilities" => [item]}
      assert {:error, :capabilities_invalid} = Core.prepare(observed_data(), bad)
    end

    test "rejects governed that is a struct", %{governed: governed} do
      assert {:error, :governed_shape} = Core.prepare(observed_data(), DateTime.utc_now())
      _ = governed
    end

    test "rejects governed that is a list", %{governed: governed} do
      assert {:error, :governed_shape} = Core.prepare(observed_data(), [])
      _ = governed
    end

    test "rejects policy envelope that is not a map", %{envelope: envelope, caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => "not-a-map",
          "template_source" => %{"name" => "scout", "layer" => "shipped"}
        }
      }

      assert {:error, :policy_invalid} = Core.prepare(observed_data(), governed)
      _ = envelope
    end

    test "rejects policy envelope that is a struct", %{caps: caps, prov: prov} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => DateTime.utc_now(),
          "template_source" => prov
        }
      }

      assert {:error, :policy_invalid} = Core.prepare(observed_data(), governed)
    end

    test "rejects template_source that is not a map", %{envelope: envelope, caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => envelope,
          "template_source" => "shipped"
        }
      }

      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects invalid provenance layer string", %{envelope: envelope, caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => envelope,
          "template_source" => %{"name" => "scout", "layer" => "unknown_layer"}
        }
      }

      assert {:error, :provenance_layer_invalid} = Core.prepare(observed_data(), governed)
    end

    test "rejects empty template_source name", %{envelope: envelope, caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => envelope,
          "template_source" => %{"name" => "", "layer" => "shipped"}
        }
      }

      assert {:error, :template_invalid} = Core.prepare(observed_data(), governed)
    end

    test "rejects extra template_source keys", %{envelope: envelope, caps: caps} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => envelope,
          "template_source" => %{"name" => "scout", "layer" => "shipped", "path" => "/x"}
        }
      }

      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects extra governed metadata keys", %{envelope: envelope, caps: caps, prov: prov} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{
          TemplateAuthorityPolicy.metadata_key() => envelope,
          "template_source" => prov,
          "extra" => true
        }
      }

      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects missing template_authority_policy marker key", %{caps: caps, prov: prov} do
      governed = %{
        "template" => "scout",
        "initial_capabilities" => caps,
        "metadata" => %{"template_source" => prov}
      }

      assert {:error, :governed_shape} = Core.prepare(observed_data(), governed)
    end

    test "rejects missing template top-level key", %{governed: governed} do
      bad = Map.delete(governed, "template")
      assert {:error, :governed_shape} = Core.prepare(observed_data(), bad)
    end

    test "rejects missing initial_capabilities top-level key", %{governed: governed} do
      bad = Map.delete(governed, "initial_capabilities")
      assert {:error, :governed_shape} = Core.prepare(observed_data(), bad)
    end

    test "rejects observed_data that is a struct", %{governed: governed} do
      assert {:error, :observed_not_map} = Core.prepare(DateTime.utc_now(), governed)
    end

    test "rejects observed_data that is a list", %{governed: governed} do
      assert {:error, :observed_not_map} = Core.prepare([], governed)
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # commit_prepared_mutation / classify_restart
  # ─────────────────────────────────────────────────────────────────────

  describe "commit_prepared_mutation/2" do
    test "is deterministic and binds timestamps-excluded envelopes", %{governed: governed} do
      data = observed_data()

      a =
        record(data, 2, 4,
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        )

      b =
        record(data, 2, 4,
          inserted_at: ~U[2026-02-02 00:00:00Z],
          updated_at: ~U[2026-03-03 00:00:00Z]
        )

      assert {:ok, r1} = Core.commit_prepared_mutation(a, governed)
      assert {:ok, r2} = Core.commit_prepared_mutation(b, governed)
      assert r1.commitment == r2.commitment
      assert r1.intended_data == r2.intended_data

      cmt = r1.commitment
      assert cmt["version"] == Core.commitment_version()
      assert cmt["kind"] == Core.commitment_kind()
      assert cmt["algorithm"] == Core.commitment_algorithm()
      assert cmt["encoding"] == Core.commitment_encoding()
      assert cmt["domain"] == Core.commitment_domain()
      assert byte_size(cmt["anchor_digest"]) == 64
      assert byte_size(cmt["successor_digest"]) == 64
      assert cmt["anchor_digest"] != cmt["successor_digest"]
      assert {:ok, ^cmt} = Core.admit_commitment(cmt)
    end

    test "refuses invalid governed before hashing", %{governed: governed} do
      r = record(observed_data(), 1, 1)
      bad = %{governed | "template" => "nope"}
      assert {:error, :authority_inconsistent} = Core.commit_prepared_mutation(r, bad)
    end

    test "rejects non-durable record shape", %{governed: governed} do
      r = %Record{id: "x", key: "agent_test_1", data: observed_data(), generation: 0, revision: 1}
      assert {:error, :invalid_record} = Core.commit_prepared_mutation(r, governed)
    end

    test "rejects a record whose successor revision exceeds the JSON-safe bound", %{
      governed: governed
    } do
      r = record(observed_data(), 1, 9_007_199_254_740_991)
      assert {:error, :invalid_record} = Core.commit_prepared_mutation(r, governed)
    end
  end

  describe "classify_restart/4 matrix" do
    setup %{governed: governed} do
      anchor = record(observed_data(), 2, 4)

      assert {:ok, %{intended_data: intended, commitment: cmt}} =
               Core.commit_prepared_mutation(anchor, governed)

      successor =
        record(intended, anchor.generation, anchor.revision + 1,
          id: anchor.id,
          key: anchor.key,
          metadata: anchor.metadata
        )

      %{
        anchor: anchor,
        intended: intended,
        cmt: cmt,
        successor: successor,
        cas: cas_for(anchor),
        target: anchor.key
      }
    end

    test "not_applied when reobserved equals the anchor", ctx do
      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, ctx.anchor}) ==
               :not_applied
    end

    test "already_applied when reobserved is the exact successor", ctx do
      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, ctx.successor}) ==
               :already_applied
    end

    test "conflict on ABA generation", ctx do
      aba =
        record(ctx.intended, ctx.anchor.generation + 1, 1,
          id: ctx.anchor.id,
          key: ctx.anchor.key,
          metadata: ctx.anchor.metadata
        )

      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, aba}) == :conflict
    end

    test "conflict on later revision", ctx do
      later =
        record(ctx.intended, ctx.anchor.generation, ctx.anchor.revision + 2,
          id: ctx.anchor.id,
          key: ctx.anchor.key,
          metadata: ctx.anchor.metadata
        )

      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, later}) == :conflict
    end

    test "conflict when unrelated field drifts on successor tokens", ctx do
      drifted = Map.put(ctx.intended, "display_name", "drifted")

      r =
        record(drifted, ctx.anchor.generation, ctx.anchor.revision + 1,
          id: ctx.anchor.id,
          key: ctx.anchor.key,
          metadata: ctx.anchor.metadata
        )

      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, r}) == :conflict
    end

    test "conflict when slot is absent", ctx do
      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, :not_found) == :conflict
    end

    test "outcome_unknown on unreadable reobservation", ctx do
      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:error, :backend_unavailable}) ==
               :outcome_unknown
    end

    test "outcome_unknown on wrong identity", ctx do
      wrong = %{ctx.successor | key: "agent_other"}
      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, wrong}) == :outcome_unknown
    end

    test "outcome_unknown on malformed occupant", ctx do
      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, %{not: :record}}) ==
               :outcome_unknown
    end

    test "cas mismatch with matching envelope is not a success class", ctx do
      bad_cas = %{ctx.cas | "revision" => ctx.cas["revision"] + 9}
      outcome = Core.classify_restart(ctx.target, bad_cas, ctx.cmt, {:ok, ctx.anchor})
      assert outcome in [:conflict, :outcome_unknown]
      refute outcome in [:not_applied, :already_applied]
    end

    test "classify_restart is deterministic", ctx do
      assert Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, ctx.successor}) ==
               Core.classify_restart(ctx.target, ctx.cas, ctx.cmt, {:ok, ctx.successor})
    end
  end

  describe "classify/3 matrix still works" do
    test "not_applied when reobserved equals observed" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}
      assert Core.classify(anchor, intended, {:ok, anchor}) == :not_applied
    end

    test "already_applied when reobserved is exact intended successor" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}

      successor =
        record(intended, anchor.generation, anchor.revision + 1,
          id: anchor.id,
          key: anchor.key,
          metadata: anchor.metadata
        )

      assert Core.classify(anchor, intended, {:ok, successor}) == :already_applied
    end

    test "conflict when reobserved data diverges" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}
      other = record(%{"template" => "other"}, 2, 5, id: anchor.id, key: anchor.key)
      assert Core.classify(anchor, intended, {:ok, other}) == :conflict
    end

    test "conflict when reobserved generation is ABA" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}

      aba =
        record(intended, anchor.generation + 1, 1,
          id: anchor.id,
          key: anchor.key,
          metadata: anchor.metadata
        )

      assert Core.classify(anchor, intended, {:ok, aba}) == :conflict
    end

    test "conflict when reobserved revision is later than successor" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}

      later =
        record(intended, anchor.generation, anchor.revision + 2,
          id: anchor.id,
          key: anchor.key,
          metadata: anchor.metadata
        )

      assert Core.classify(anchor, intended, {:ok, later}) == :conflict
    end

    test "conflict when slot is absent for classify" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}
      assert Core.classify(anchor, intended, :not_found) == :conflict
    end

    test "outcome_unknown when reobservation errors for classify" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}
      assert Core.classify(anchor, intended, {:error, :backend_unavailable}) == :outcome_unknown
    end

    test "outcome_unknown when reobserved key mismatches for classify" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}

      wrong =
        record(intended, anchor.generation, anchor.revision + 1,
          id: anchor.id,
          key: "agent_other",
          metadata: anchor.metadata
        )

      assert Core.classify(anchor, intended, {:ok, wrong}) == :outcome_unknown
    end

    test "outcome_unknown when reobserved is non-Record for classify" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}
      assert Core.classify(anchor, intended, {:ok, %{not: :record}}) == :outcome_unknown
    end

    test "conflict when successor tokens match but metadata differs" do
      anchor = record(%{"template" => "old"}, 2, 4, metadata: %{"a" => 1})
      intended = %{"template" => "new", "metadata" => %{}}

      successor =
        record(intended, anchor.generation, anchor.revision + 1,
          id: anchor.id,
          key: anchor.key,
          metadata: %{"a" => 2}
        )

      assert Core.classify(anchor, intended, {:ok, successor}) == :conflict
    end

    test "conflict when successor tokens match but id differs" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}

      successor =
        record(intended, anchor.generation, anchor.revision + 1,
          id: "other_id",
          key: anchor.key,
          metadata: anchor.metadata
        )

      assert Core.classify(anchor, intended, {:ok, successor}) == :conflict
    end

    test "not_applied and already_applied with live intended data" do
      anchor = record(%{"template" => "old"}, 2, 4)
      intended = %{"template" => "new", "metadata" => %{}}
      assert Core.classify(anchor, intended, {:ok, anchor}) == :not_applied

      successor =
        record(intended, anchor.generation, anchor.revision + 1,
          id: anchor.id,
          key: anchor.key,
          metadata: anchor.metadata
        )

      assert Core.classify(anchor, intended, {:ok, successor}) == :already_applied
    end
  end

  describe "envelope_stable?/2" do
    test "true when stable fields equal ignoring timestamps" do
      a = record(%{"x" => 1}, 3, 5, inserted_at: ~U[2026-01-01 00:00:00Z])
      b = record(%{"x" => 1}, 3, 5, updated_at: ~U[2026-02-02 00:00:00Z])
      assert Core.envelope_stable?(a, b)
    end

    test "false when data differs" do
      refute Core.envelope_stable?(record(%{"x" => 1}, 3, 5), record(%{"x" => 2}, 3, 5))
    end

    test "false when id differs" do
      a = record(%{"x" => 1}, 3, 5, id: "a")
      b = record(%{"x" => 1}, 3, 5, id: "b")
      refute Core.envelope_stable?(a, b)
    end

    test "false when key differs" do
      a = record(%{"x" => 1}, 3, 5, key: "agent_a")
      b = record(%{"x" => 1}, 3, 5, key: "agent_b")
      refute Core.envelope_stable?(a, b)
    end

    test "false when generation differs" do
      refute Core.envelope_stable?(record(%{"x" => 1}, 3, 5), record(%{"x" => 1}, 4, 5))
    end

    test "false when revision differs" do
      refute Core.envelope_stable?(record(%{"x" => 1}, 3, 5), record(%{"x" => 1}, 3, 6))
    end

    test "false when metadata differs" do
      a = record(%{"x" => 1}, 3, 5, metadata: %{"m" => 1})
      b = record(%{"x" => 1}, 3, 5, metadata: %{"m" => 2})
      refute Core.envelope_stable?(a, b)
    end

    test "false when current is not a Record" do
      refute Core.envelope_stable?(record(%{"x" => 1}, 3, 5), %{not: :record})
    end

    test "false when observed is not a Record" do
      refute Core.envelope_stable?(%{not: :record}, record(%{"x" => 1}, 3, 5))
    end
  end

  # ─────────────────────────────────────────────────────────────────────
  # Phase 4B current-marker regression
  # ─────────────────────────────────────────────────────────────────────

  describe "Phase 4B current marker regression" do
    test "successor marker/provenance match desired while exact_template_policy preserved", %{
      governed: governed,
      envelope: envelope,
      prov: prov
    } do
      exact = %{"version" => 9, "markers" => ["runtime"], "keep" => true}

      observed =
        observed_data(
          metadata: %{
            "exact_template_policy" => exact,
            "template_source" => %{"name" => "legacy", "layer" => "user"},
            "template_authority_policy" => %{"stale" => true},
            "sibling" => "ok"
          }
        )

      r = record(observed, 3, 7)

      assert {:ok, %{intended_data: intended, commitment: cmt}} =
               Core.commit_prepared_mutation(r, governed)

      meta = intended["metadata"]
      assert meta["exact_template_policy"] === exact
      assert meta["sibling"] == "ok"

      assert {:ok, stored_env} = TemplateAuthorityPolicy.from_metadata(meta)
      assert stored_env["digest"] == envelope["digest"]
      assert stored_env === envelope

      assert meta["template_source"] === prov
      assert is_binary(prov["layer"])
      assert prov["layer"] in ~w(user shipped legacy_json)

      stored_prov =
        TemplateAuthorityPolicy.provenance(TemplateAuthorityPolicy.snapshot(stored_env))

      assert stored_prov === prov

      # Pure Phase 4B current predicates: digests + three provenances agree, non-nil.
      desired_digest = envelope["digest"]
      desired_prov = prov
      assert is_binary(desired_digest)
      assert stored_env["digest"] == desired_digest
      assert desired_prov == stored_prov
      assert desired_prov == meta["template_source"]
      assert not is_nil(desired_prov)

      # Commitment classifies exact successor as already_applied.
      successor =
        record(intended, r.generation, r.revision + 1, id: r.id, key: r.key, metadata: r.metadata)

      assert Core.classify_restart(r.key, cas_for(r), cmt, {:ok, successor}) == :already_applied
    end
  end

  describe "admit_commitment/1" do
    test "rejects uppercase digests and wrong domain" do
      base = %{
        "version" => 1,
        "kind" => Core.commitment_kind(),
        "algorithm" => "sha256",
        "encoding" => "hex_lower",
        "domain" => Core.commitment_domain(),
        "anchor_digest" => String.duplicate("aa", 32),
        "successor_digest" => String.duplicate("bb", 32)
      }

      assert {:ok, _} = Core.admit_commitment(base)

      assert {:error, :commitment_shape} =
               Core.admit_commitment(%{
                 base
                 | "anchor_digest" => String.duplicate("AA", 32)
               })

      assert {:error, :commitment_shape} =
               Core.admit_commitment(%{base | "domain" => "other.domain"})

      assert {:error, :commitment_shape} =
               Core.admit_commitment(Map.put(base, "extra", 1))
    end
  end

  describe "oversized / malformed canonicalization" do
    test "rejects atom keys inside observed data during commit", %{governed: governed} do
      data = Map.put(observed_data(), "weird", %{:atom_key => 1})
      r = record(data, 1, 1)
      # prepare may succeed (atom key is unrelated top-level value map); commit
      # canonicalization of full envelope must fail closed.
      case Core.commit_prepared_mutation(r, governed) do
        {:error, reason} ->
          assert reason in [:canonicalization_failed, :oversized]

        {:ok, _} ->
          # If prepare rejects atom keys in nested maps via other paths, also ok
          # to fail earlier — but success would leak non-JSON terms into digest.
          flunk("commit must not succeed with atom map keys in envelope data")
      end
    end

    test "rejects overlong list during commit", %{governed: governed} do
      # max_list_len is 512; one extra element must fail closed.
      long = Enum.map(0..512, & &1)
      data = Map.put(observed_data(), "bulk", long)
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:oversized, :canonicalization_failed]
    end

    test "rejects over-wide map during commit", %{governed: governed} do
      # max_map_keys is 256; map_size is checked before key materialization.
      wide =
        0..256
        |> Enum.map(fn i -> {"k_#{i}", i} end)
        |> Map.new()

      data = Map.put(observed_data(), "wide", wide)
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:oversized, :canonicalization_failed]
    end

    test "rejects over-deep nesting during commit", %{governed: governed} do
      # max_depth is 12; wrap one level past the ceiling.
      deep =
        Enum.reduce(1..14, "leaf", fn _, acc ->
          %{"n" => acc}
        end)

      data = Map.put(observed_data(), "deep", deep)
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:oversized, :canonicalization_failed]
    end

    test "rejects overlong string before UTF-8 scan during commit", %{governed: governed} do
      # max_string_bytes is 65_536; one byte past must fail as oversized.
      huge = :binary.copy("a", 65_537)
      data = Map.put(observed_data(), "blob", huge)
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:oversized, :canonicalization_failed]
    end

    test "rejects oversized total preimage assembled from many bounded strings", %{
      governed: governed
    } do
      # Each string is under the per-string ceiling, but together they exceed
      # the total preimage budget (262_144) before term_to_binary allocates.
      chunk = :binary.copy("x", 60_000)
      bulk = Enum.map(1..6, fn i -> {"c_#{i}", chunk} end) |> Map.new()
      data = Map.put(observed_data(), "bulk_map", bulk)
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:oversized, :canonicalization_failed]
    end

    # Non-finite floats are not constructible on BEAM without ArithmeticError
    # (:math.acos/1 and overflow raise; binary_to_term rejects nonfinite ETF).
    # Finite floats remain admitted; unsupported non-JSON terms cover the rest.

    test "admits finite floats during commit", %{governed: governed} do
      data = Map.put(observed_data(), "num", 1.5)
      r = record(data, 1, 1)
      assert {:ok, _} = Core.commit_prepared_mutation(r, governed)
    end

    test "rejects unsupported terms (tuples, pids, refs, atoms as values)", %{
      governed: governed
    } do
      for bad <- [{:tuple, 1}, self(), make_ref(), :atom_value] do
        data = Map.put(observed_data(), "bad", bad)
        r = record(data, 1, 1)

        assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
        assert reason in [:canonicalization_failed, :oversized]
      end
    end

    test "rejects JSON-unsafe integers beyond the safe magnitude", %{governed: governed} do
      too_big = 9_007_199_254_740_992
      data = Map.put(observed_data(), "big", too_big)
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:oversized, :canonicalization_failed]
    end

    test "rejects non-UTF-8 binary values during commit", %{governed: governed} do
      data = Map.put(observed_data(), "bin", <<0xFF, 0xFE, 0xFD>>)
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:canonicalization_failed, :oversized]
    end

    test "rejects improper lists during commit", %{governed: governed} do
      data = Map.put(observed_data(), "improper", [1 | 2])
      r = record(data, 1, 1)

      assert {:error, reason} = Core.commit_prepared_mutation(r, governed)
      assert reason in [:canonicalization_failed, :oversized]
    end
  end

  describe "admit_commitment/1 shape-only honesty" do
    test "accepts well-formed digests without re-deriving against a private Record" do
      base = %{
        "version" => 1,
        "kind" => Core.commitment_kind(),
        "algorithm" => "sha256",
        "encoding" => "hex_lower",
        "domain" => Core.commitment_domain(),
        "anchor_digest" => String.duplicate("11", 32),
        "successor_digest" => String.duplicate("22", 32)
      }

      # Shape-only: any pair of distinct lowercase 64-hex digests is admissible.
      # Correctness relative to a Record is not claimed here.
      assert {:ok, admitted} = Core.admit_commitment(base)
      assert admitted["anchor_digest"] == base["anchor_digest"]
      assert admitted["successor_digest"] == base["successor_digest"]
    end

    test "rejects atom-key aliases and equal digests" do
      base = %{
        "version" => 1,
        "kind" => Core.commitment_kind(),
        "algorithm" => "sha256",
        "encoding" => "hex_lower",
        "domain" => Core.commitment_domain(),
        "anchor_digest" => String.duplicate("11", 32),
        "successor_digest" => String.duplicate("22", 32)
      }

      atom_alias = Map.put(Map.delete(base, "version"), :version, 1)
      assert {:error, :ambiguous_keys} = Core.admit_commitment(atom_alias)

      coexisting_alias = Map.put(base, :version, 1)
      assert {:error, :ambiguous_keys} = Core.admit_commitment(coexisting_alias)

      equal =
        Map.put(base, "successor_digest", base["anchor_digest"])

      assert {:error, :commitment_shape} = Core.admit_commitment(equal)
    end
  end
end
