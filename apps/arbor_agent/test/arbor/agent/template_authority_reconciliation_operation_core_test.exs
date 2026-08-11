defmodule Arbor.Agent.TemplateAuthorityReconciliationOperationCoreTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Core

  @moduletag :fast

  @digest String.duplicate("ab", 32)
  @agent "agent_recon_op_1"
  @caller "agent_recon_caller_1"
  @op_id "op_recon_1"
  @repo_root "/Users/dev/arbor"

  @template_data %{
    "name" => "coding_agent",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/read", "constraints" => %{"rate_limit" => 10}},
      %{"resource" => "arbor://fs/write"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{
        "arbor://fs/read" => "auto",
        "arbor://fs/write" => "ask"
      }
    },
    "template_source" => %{"name" => "coding_agent", "layer" => "shipped"}
  }

  setup do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("coding_agent", @template_data)

    facts = %{
      "operation_id" => @op_id,
      "target_agent_id" => @agent,
      "authorizing_caller_id" => @caller,
      "expected_preview_reconciliation_digest" => @digest,
      "desired_authority" => %{"envelope" => envelope},
      "scope" => "local_owner",
      "durability" => "node_restart",
      "created_at_unix_ms" => 1_000
    }

    %{envelope: envelope, facts: facts}
  end

  defp t(n), do: 1_000 + n

  # Canonical capability id: cap_ + 32 lowercase hex (Security fence grammar).
  defp cap_id(seed) when is_binary(seed) and byte_size(seed) == 2 do
    "cap_" <> String.duplicate(seed, 16)
  end

  defp closed_fence!(cap_id, principal_id, resource_uri, opts \\ []) do
    fence = %{
      "kind" => "acknowledged_revoke_fence",
      "version" => 1,
      "capability_id" => cap_id,
      "principal_id" => principal_id,
      "resource_uri" => resource_uri,
      "record_id" => Keyword.get(opts, :record_id, "rec_fence_1"),
      "generation" => Keyword.get(opts, :generation, 1),
      "revision" => Keyword.get(opts, :revision, 1),
      "capability_digest" => Keyword.get(opts, :capability_digest, String.duplicate("ab", 32))
    }

    assert {:ok, canonical} =
             Arbor.Security.admit_acknowledged_revoke_fence(fence, %{
               capability_id: cap_id,
               principal_id: principal_id,
               resource_uri: resource_uri
             })

    canonical
  end

  defp revoke_payload(cap_id, resource, principal \\ @agent, opts \\ []) do
    fence = closed_fence!(cap_id, principal, resource, opts)

    %{
      "capability_id" => cap_id,
      "resource" => resource,
      "revocation_fence" => fence
    }
  end

  defp profile_cas(gen \\ 1, rev \\ 1) do
    %{
      "record_id" => "profile_rec_1",
      "generation" => gen,
      "revision" => rev
    }
  end

  defp replay_commitment(opts \\ []) do
    %{
      "version" => ProfileAuthorityMutationCore.commitment_version(),
      "kind" => ProfileAuthorityMutationCore.commitment_kind(),
      "algorithm" => ProfileAuthorityMutationCore.commitment_algorithm(),
      "encoding" => ProfileAuthorityMutationCore.commitment_encoding(),
      "domain" => ProfileAuthorityMutationCore.commitment_domain(),
      "anchor_digest" => Keyword.get(opts, :anchor, String.duplicate("aa", 32)),
      "successor_digest" => Keyword.get(opts, :successor, String.duplicate("bb", 32))
    }
  end

  defp frozen_authority(record, repo_root \\ @repo_root) do
    envelope = record["desired_authority"]["envelope"]
    snap = TemplateAuthorityPolicy.snapshot(envelope)
    declared = TemplateAuthorityPolicy.capabilities(snap)

    assert {:ok, caps} =
             TemplateAuthorityCapabilityProjection.project_normalized(
               declared,
               record["target_agent_id"],
               repo_root: repo_root
             )

    %{
      "repo_root" => repo_root,
      "effective_capabilities" => caps
    }
  end

  defp assert_admitted!(record) do
    assert {:ok, admitted} = Core.admit(record)
    assert admitted == record
    admitted
  end

  defp new!(facts) do
    assert {:ok, record, effects} = Core.new(facts)
    assert_admitted!(record)
    {record, effects}
  end

  defp ack!(record, phase, at, extra \\ %{}) do
    facts =
      Map.merge(
        %{"phase_intent" => phase, "at_unix_ms" => at},
        extra
      )

    assert {:ok, record, effects} = Core.acknowledge(record, facts)
    assert_admitted!(record)
    {record, effects}
  end

  defp prepare!(record, at, cas \\ profile_cas(), replay \\ replay_commitment()) do
    frozen = frozen_authority(record)

    assert {:ok, record, effects} =
             Core.prepare(record, %{
               "at_unix_ms" => at,
               "profile_cas" => cas,
               "frozen_authority" => frozen,
               "profile_mutation_replay" => replay
             })

    assert_admitted!(record)
    {record, effects}
  end

  defp walk_to_runtime_quiesced(facts) do
    {record, _} = new!(facts)
    {record, _} = ack!(record, "reserved", t(1))
    {record, _} = prepare!(record, t(2))
    {record, _} = ack!(record, "prepared", t(3))
    {record, _} = ack!(record, "deny_all_intent", t(4))
    {record, _} = ack!(record, "deny_all_installed", t(5), %{"runtime_was_running" => true})
    record
  end

  defp walk_to_capability_effects(facts, entries) do
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{"at_unix_ms" => t(10), "entries" => entries})

    record
  end

  defp walk_to_completed(facts) do
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{"at_unix_ms" => t(10), "entries" => []})

    {record, _} = ack!(record, "capability_effects", t(11))
    {record, _} = ack!(record, "profile_commit", t(12))
    {record, _} = ack!(record, "desired_trust", t(13))
    {record, _} = ack!(record, "verifying", t(14))
    {record, _} = ack!(record, "runtime_restore", t(15))
    record
  end

  test "constructs reserved operation with fence effect and closed JSON record", %{facts: facts} do
    {record, effects} = new!(facts)

    assert record["version"] == 4
    assert record["kind"] == "template_authority_reconciliation_operation"
    assert record["phase"] == "reserved"
    assert record["status"] == "active"
    assert record["scope"] == "local_owner"
    assert record["durability"] == "node_restart"
    assert record["expected_preview_reconciliation_digest"] == @digest
    assert record["authorizing_caller_id"] == @caller
    assert record["profile_cas"] == nil
    assert record["frozen_authority"] == nil
    assert record["profile_mutation_replay"] == nil
    assert record["reconciliation_required"] == nil

    assert record["fence_state"] == %{
             "required" => true,
             "installed" => false,
             "cleanup_acked" => false
           }

    assert Core.outstanding?(record)
    assert Core.fence_required?(record)
    refute Core.replaceable?(record)

    assert [effect] = effects
    assert effect["effect_type"] == "install_target_dispatch_fence"
    assert effect["phase_intent"] == "reserved"
    refute Map.has_key?(effect, "authorizing_caller_id")
    refute Map.has_key?(effect, "profile_cas")
    assert json_clean?(record)
    assert json_clean?(effect)

    # Determinism
    assert {:ok, record2, effects2} = Core.new(facts)
    assert record2 == record
    assert effects2 == effects
  end

  test "requires authorizing_caller_id and keeps it immutable across transitions", %{
    facts: facts
  } do
    assert {:error, {:template_authority_reconciliation_operation, :invalid_new_input}} =
             Core.new(Map.delete(facts, "authorizing_caller_id"))

    assert {:error, {:template_authority_reconciliation_operation, :invalid_new_input}} =
             Core.new(%{facts | "authorizing_caller_id" => "human_not_agent"})

    {record, _} = new!(facts)
    assert record["authorizing_caller_id"] == @caller

    # No reducer ever rewrites the authorizing caller: every transition carries
    # the original caller identity forward unchanged.
    assert {:ok, advanced, _} =
             Core.acknowledge(record, %{"phase_intent" => "reserved", "at_unix_ms" => t(1)})

    assert advanced["authorizing_caller_id"] == @caller

    frozen = frozen_authority(advanced)

    assert {:ok, record_fenced, _} =
             Core.acknowledge(advanced, %{
               "phase_intent" => "fenced",
               "at_unix_ms" => t(2),
               "profile_cas" => profile_cas(),
               "frozen_authority" => frozen,
               "profile_mutation_replay" => replay_commitment()
             })

    assert record_fenced["authorizing_caller_id"] == @caller
  end

  test "prepare requires profile_cas and freezes it before prepared", %{facts: facts} do
    {record, _} = new!(facts)
    {record, _} = ack!(record, "reserved", t(1))
    frozen = frozen_authority(record)
    replay = replay_commitment()

    assert {:error, {:template_authority_reconciliation_operation, :profile_cas_required}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "frozen_authority" => frozen,
               "profile_mutation_replay" => replay
             })

    assert {:error, {:template_authority_reconciliation_operation, :frozen_authority_required}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => profile_cas(),
               "profile_mutation_replay" => replay
             })

    assert {:error,
            {:template_authority_reconciliation_operation, :profile_mutation_replay_required}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => profile_cas(),
               "frozen_authority" => frozen
             })

    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => profile_cas(),
               "frozen_authority" => frozen,
               "profile_mutation_replay" => replay,
               "capability_id" => "cap_should_reject"
             })

    cas = profile_cas(3, 7)
    {record, effects} = prepare!(record, t(2), cas, replay)
    assert record["phase"] == "prepared"
    assert record["profile_cas"] == cas
    assert record["frozen_authority"] == frozen
    assert record["profile_mutation_replay"] == replay
    assert hd(effects)["effect_type"] == "record_deny_all_intent"
    refute Map.has_key?(hd(effects), "profile_cas")
    refute Map.has_key?(hd(effects), "frozen_authority")
    refute Map.has_key?(hd(effects), "profile_mutation_replay")
    refute Map.has_key?(hd(effects), "repo_root")

    assert {:ok, admitted} = Core.admit(record)
    assert admitted["profile_cas"] == cas
    assert admitted["frozen_authority"] == frozen
    assert admitted["profile_mutation_replay"] == replay

    # profile_cas, frozen_authority, and replay commitment remain immutable
    {record, _} = ack!(record, "prepared", t(3))
    assert record["profile_cas"] == cas
    assert record["frozen_authority"] == frozen
    assert record["profile_mutation_replay"] == replay
  end

  test "prepare rejects effective-projection mismatch, noncanonical root, and v1 records", %{
    facts: facts
  } do
    {record, _} = new!(facts)
    {record, _} = ack!(record, "reserved", t(1))
    cas = profile_cas()
    frozen = frozen_authority(record)

    mismatched = put_in(frozen, ["effective_capabilities"], [])

    replay = replay_commitment()

    assert {:error, {:template_authority_reconciliation_operation, :frozen_authority_invalid}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => cas,
               "frozen_authority" => mismatched,
               "profile_mutation_replay" => replay
             })

    bad_root = %{frozen | "repo_root" => "relative/path"}

    assert {:error, {:template_authority_reconciliation_operation, :frozen_authority_invalid}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => cas,
               "frozen_authority" => bad_root,
               "profile_mutation_replay" => replay
             })

    # Trailing-slash / whitespace root aliases are not rewritten before equality.
    alias_root = %{frozen | "repo_root" => @repo_root <> "/"}

    assert {:error, {:template_authority_reconciliation_operation, :frozen_authority_invalid}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => cas,
               "frozen_authority" => alias_root,
               "profile_mutation_replay" => replay
             })

    spaced_root = %{frozen | "repo_root" => "  " <> @repo_root}

    assert {:error, {:template_authority_reconciliation_operation, :frozen_authority_invalid}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => cas,
               "frozen_authority" => spaced_root,
               "profile_mutation_replay" => replay
             })

    # Atom-key alias on frozen map is rejected (closed binary keys only).
    atom_keyed = %{
      repo_root: @repo_root,
      effective_capabilities: frozen["effective_capabilities"]
    }

    assert {:error, {:template_authority_reconciliation_operation, reason}} =
             Core.prepare(record, %{
               "at_unix_ms" => t(2),
               "profile_cas" => cas,
               "frozen_authority" => atom_keyed,
               "profile_mutation_replay" => replay
             })

    assert reason in [:frozen_authority_invalid, :invalid_record]

    # Reordered / non-canonical supplied caps fail exact equality (no pre-normalize).
    caps = frozen["effective_capabilities"]

    if length(caps) > 1 do
      reordered = %{frozen | "effective_capabilities" => Enum.reverse(caps)}

      assert {:error, {:template_authority_reconciliation_operation, :frozen_authority_invalid}} =
               Core.prepare(record, %{
                 "at_unix_ms" => t(2),
                 "profile_cas" => cas,
                 "frozen_authority" => reordered,
                 "profile_mutation_replay" => replay
               })
    end

    {prepared, _} = prepare!(record, t(2), cas, replay)

    tampered =
      put_in(prepared, ["frozen_authority", "effective_capabilities"], [
        %{"resource" => "arbor://tampered", "constraints" => %{}}
      ])

    assert {:error, {:template_authority_reconciliation_operation, :frozen_authority_invalid}} =
             Core.admit(tampered)

    # Honest shape-only trust boundary: a well-formed digest substitution (still
    # closed keys + constants + distinct lowercase 64-hex digests) is admissible
    # without the private Record. OperationCore does not re-derive digests, so
    # it must not claim a substituted-but-well-formed pair is detectable here.
    substituted =
      put_in(prepared, ["profile_mutation_replay", "anchor_digest"], String.duplicate("cc", 32))

    assert {:ok, admitted_sub} = Core.admit(substituted)

    assert admitted_sub["profile_mutation_replay"]["anchor_digest"] ==
             String.duplicate("cc", 32)

    # Malformed shape / constants / aliases remain rejected.
    shape_drift =
      put_in(prepared, ["profile_mutation_replay", "extra"], "nope")

    assert {:error,
            {:template_authority_reconciliation_operation, :profile_mutation_replay_invalid}} =
             Core.admit(shape_drift)

    bad_domain =
      put_in(prepared, ["profile_mutation_replay", "domain"], "other.domain")

    assert {:error,
            {:template_authority_reconciliation_operation, :profile_mutation_replay_invalid}} =
             Core.admit(bad_domain)

    uppercase =
      put_in(
        prepared,
        ["profile_mutation_replay", "anchor_digest"],
        String.duplicate("AA", 32)
      )

    assert {:error,
            {:template_authority_reconciliation_operation, :profile_mutation_replay_invalid}} =
             Core.admit(uppercase)

    atom_alias =
      put_in(prepared, ["profile_mutation_replay"], %{
        :version => 1,
        "kind" => ProfileAuthorityMutationCore.commitment_kind(),
        "algorithm" => ProfileAuthorityMutationCore.commitment_algorithm(),
        "encoding" => ProfileAuthorityMutationCore.commitment_encoding(),
        "domain" => ProfileAuthorityMutationCore.commitment_domain(),
        "anchor_digest" => String.duplicate("aa", 32),
        "successor_digest" => String.duplicate("bb", 32)
      })

    assert {:error,
            {:template_authority_reconciliation_operation, :profile_mutation_replay_invalid}} =
             Core.admit(atom_alias)

    v1 = Map.put(prepared, "version", 1)

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(v1)

    v2 = Map.put(prepared, "version", 2)

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(v2)

    # v3 records fail closed with no migration/synthesis.
    v3 = Map.put(prepared, "version", 3)

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(v3)
  end

  test "admits Policy envelope and rejects bad digests", %{facts: facts, envelope: envelope} do
    bad = %{facts | "expected_preview_reconciliation_digest" => "sha256:" <> @digest}

    assert {:error, {:template_authority_reconciliation_operation, :digest_missing_or_invalid}} =
             Core.new(bad)

    short = %{facts | "expected_preview_reconciliation_digest" => "abcd"}

    assert {:error, {:template_authority_reconciliation_operation, :digest_missing_or_invalid}} =
             Core.new(short)

    # Desired envelope must validate
    bad_env =
      put_in(facts, ["desired_authority", "envelope"], Map.put(envelope, "digest", @digest))

    assert {:error, {:template_authority_reconciliation_operation, _}} = Core.new(bad_env)
  end

  test "rejects declaration_digest and provenance conflicts with validated envelope", %{
    facts: facts,
    envelope: envelope
  } do
    conflicting_digest =
      put_in(facts, ["desired_authority"], %{
        "envelope" => envelope,
        "declaration_digest" => @digest
      })

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.new(conflicting_digest)

    conflicting_prov =
      put_in(facts, ["desired_authority"], %{
        "envelope" => envelope,
        "provenance" => %{"name" => "other_template", "layer" => "shipped"}
      })

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.new(conflicting_prov)

    {record, _} = new!(facts)
    assert record["desired_authority"]["declaration_digest"] == envelope["digest"]

    assert record["desired_authority"]["provenance"] ==
             envelope["snapshot"]["provenance"]
  end

  test "rejects atom/string field conflicts and invalid scope/durability", %{facts: facts} do
    conflicted = Map.put(facts, :operation_id, "other_op")

    assert {:error, {:template_authority_reconciliation_operation, :duplicate_field_conflict}} =
             Core.new(Map.merge(facts, conflicted))

    assert {:error, {:template_authority_reconciliation_operation, :scope_invalid}} =
             Core.new(%{facts | "scope" => true})

    assert {:error, {:template_authority_reconciliation_operation, :durability_invalid}} =
             Core.new(%{facts | "durability" => "ephemeral"})
  end

  test "rejects unexpected event fields on public reducers", %{facts: facts} do
    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.new(Map.put(facts, "extra", true))

    {record, _} = new!(facts)

    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.acknowledge(record, %{
               "phase_intent" => "reserved",
               "at_unix_ms" => t(1),
               "backend_error" => "boom"
             })
  end

  test "happy-path forward phases to completed with cleanup and replaceability", %{facts: facts} do
    {record, effects} = new!(facts)
    assert hd(effects)["effect_type"] == "install_target_dispatch_fence"

    {record, effects} = ack!(record, "reserved", t(1))
    assert record["phase"] == "fenced"
    assert record["fence_state"]["installed"] == true
    assert hd(effects)["effect_type"] == "prepare_operation"

    {record, effects} = prepare!(record, t(2))
    assert record["phase"] == "prepared"
    assert record["profile_cas"] == profile_cas()
    assert hd(effects)["effect_type"] == "record_deny_all_intent"

    {record, effects} = ack!(record, "prepared", t(3))
    assert record["phase"] == "deny_all_intent"
    assert hd(effects)["effect_type"] == "install_deny_all_trust"

    {record, effects} = ack!(record, "deny_all_intent", t(4))
    assert record["phase"] == "deny_all_installed"
    assert hd(effects)["effect_type"] == "quiesce_runtime"

    {record, effects} =
      ack!(record, "deny_all_installed", t(5), %{"runtime_was_running" => false})

    assert record["phase"] == "runtime_quiesced"
    assert record["runtime_was_running"] == false
    assert effects == []

    assert {:ok, record, effects} =
             Core.plan_capability_effects(record, %{"at_unix_ms" => t(6), "entries" => []})

    assert record["phase"] == "capability_effects"
    assert effects == []

    {record, effects} = ack!(record, "capability_effects", t(7))
    assert record["phase"] == "profile_commit"
    assert hd(effects)["effect_type"] == "commit_profile_marker"

    {record, effects} = ack!(record, "profile_commit", t(8))
    assert record["phase"] == "desired_trust"
    assert hd(effects)["effect_type"] == "install_desired_trust"

    {record, effects} = ack!(record, "desired_trust", t(9))
    assert record["phase"] == "verifying"
    assert hd(effects)["effect_type"] == "verify_authority"

    {record, effects} = ack!(record, "verifying", t(10))
    assert record["phase"] == "runtime_restore"
    assert hd(effects)["effect_type"] == "restore_runtime"

    {record, effects} = ack!(record, "runtime_restore", t(11))
    assert record["status"] == "completed"
    assert record["phase"] == "completed"
    assert Core.fence_required?(record)
    assert Core.outstanding?(record)
    refute Core.replaceable?(record)
    assert [cleanup] = effects
    assert cleanup["effect_type"] == "remove_target_dispatch_fence"
    assert cleanup["phase_intent"] == "terminal_cleanup"

    # Terminal cleanup replay after crash
    assert {:ok, admitted} = Core.admit(record)
    assert Core.cleanup_effects(admitted) == effects

    assert {:ok, record, []} = Core.ack_cleanup(record, %{"at_unix_ms" => t(12)})
    refute Core.fence_required?(record)
    refute Core.outstanding?(record)
    assert Core.replaceable?(record)
    assert Core.cleanup_effects(record) == []
  end

  test "rejects skip, backward, wrong phase_intent, and terminal rewrites", %{facts: facts} do
    {record, _} = new!(facts)

    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.acknowledge(record, %{"phase_intent" => "prepared", "at_unix_ms" => t(1)})

    {record, _} = ack!(record, "reserved", t(1))

    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.acknowledge(record, %{"phase_intent" => "reserved", "at_unix_ms" => t(2)})

    {record, _} = prepare!(record, t(2))

    assert {:ok, aborted, _} =
             Core.abort_pre_effect(record, %{"reason_code" => "user_cancel", "at_unix_ms" => t(3)})

    assert aborted["status"] == "aborted_pre_effect"

    assert {:error, {:template_authority_reconciliation_operation, :status_not_active}} =
             Core.acknowledge(aborted, %{"phase_intent" => "prepared", "at_unix_ms" => t(4)})
  end

  test "abort is legal only before deny_all_intent", %{facts: facts} do
    {record, _} = new!(facts)

    assert {:ok, aborted, []} =
             Core.abort_pre_effect(record, %{"reason_code" => "cancel", "at_unix_ms" => t(1)})

    assert aborted["status"] == "aborted_pre_effect"
    refute Core.fence_required?(aborted)
    assert Core.replaceable?(aborted)

    {record, _} = new!(facts)
    {record, _} = ack!(record, "reserved", t(1))

    assert {:ok, aborted, effects} =
             Core.abort_pre_effect(record, %{"reason_code" => "cancel", "at_unix_ms" => t(2)})

    assert aborted["status"] == "aborted_pre_effect"
    assert Core.fence_required?(aborted)
    assert [cleanup] = effects
    assert cleanup["effect_type"] == "remove_target_dispatch_fence"
    assert Core.cleanup_effects(aborted) == effects

    record = walk_to_runtime_quiesced(facts)

    # Walk back conceptually: from deny_all_intent abort is illegal
    {record2, _} = new!(facts)
    {record2, _} = ack!(record2, "reserved", t(1))
    {record2, _} = prepare!(record2, t(2))
    {record2, _} = ack!(record2, "prepared", t(3))

    assert record2["phase"] == "deny_all_intent"

    assert {:error, {:template_authority_reconciliation_operation, :abort_after_authority_intent}} =
             Core.abort_pre_effect(record2, %{"reason_code" => "cancel", "at_unix_ms" => t(4)})

    assert record["phase"] == "runtime_quiesced"
  end

  test "crash-before-call resumes same next_effects identity", %{facts: facts} do
    {record, effects} = new!(facts)
    assert {:ok, admitted} = Core.admit(record)
    assert Core.next_effects(admitted) == effects
    assert admitted["phase"] == "reserved"
  end

  test "phase uncertain is restart-stable and clear_reconcile retries same identity", %{
    facts: facts
  } do
    {record, primary} = new!(facts)
    assert hd(primary)["effect_type"] == "install_target_dispatch_fence"

    assert {:ok, record, [reobserve]} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(1)
             })

    assert record["status"] == "active"
    assert record["phase"] == "reserved"
    assert record["retry"]["attempt"] == 1
    assert record["reconciliation_required"] == %{"phase" => "reserved", "effect_id" => nil}
    assert reobserve["effect_type"] == "reobserve_reconcile"
    assert reobserve["phase_intent"] == "reserved"
    # Phase-level reobserve: no journal payload binding.
    refute Map.has_key?(reobserve, "payload")

    # Restart: admit + next_effects must keep reobserve, not primary fence install
    assert {:ok, admitted} = Core.admit(record)
    assert [restart_reobserve] = Core.next_effects(admitted)
    assert restart_reobserve["effect_type"] == "reobserve_reconcile"
    assert restart_reobserve["operation_id"] == @op_id
    refute restart_reobserve["effect_type"] == "install_target_dispatch_fence"
    refute Map.has_key?(restart_reobserve, "payload")

    # Observation proves not-applied: clear and re-emit same primary identity
    assert {:ok, record, [retry_primary]} =
             Core.clear_reconcile(admitted, %{"at_unix_ms" => t(2)})

    assert record["reconciliation_required"] == nil
    assert retry_primary["effect_type"] == "install_target_dispatch_fence"
    assert retry_primary["operation_id"] == @op_id
    assert retry_primary["phase_intent"] == "reserved"
    assert retry_primary["idempotent_replay"] == true

    # Successful observation uses acknowledge path
    assert {:ok, record, _} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(3)
             })

    assert {:ok, record, [next]} =
             Core.acknowledge(record, %{"phase_intent" => "reserved", "at_unix_ms" => t(4)})

    assert record["reconciliation_required"] == nil
    assert record["phase"] == "fenced"
    assert next["effect_type"] == "prepare_operation"
  end

  test "uncertain grant/revoke retries same effect_id and does not block", %{facts: facts} do
    record = walk_to_runtime_quiesced(facts)
    rev_cap = cap_id("11")
    rev_resource = "arbor://fs/write"
    rev_payload = revoke_payload(rev_cap, rev_resource)
    fence = rev_payload["revocation_fence"]

    assert {:ok, record, effects} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_revoke_1",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => rev_payload
                 },
                 %{
                   "effect_id" => "eff_grant_1",
                   "effect_type" => "grant_managed_capability",
                   "payload" => %{
                     "resource" => "arbor://fs/read",
                     "constraints" => %{"rate_limit" => 10}
                   }
                 }
               ]
             })

    assert record["phase"] == "capability_effects"
    assert [eff] = effects
    assert eff["effect_type"] == "revoke_managed_capability"
    assert eff["effect_id"] == "eff_revoke_1"
    assert eff["payload"]["capability_id"] == rev_cap
    assert eff["payload"]["revocation_fence"] == fence

    grant = Enum.at(record["journal"]["entries"], 1)
    assert grant["payload"]["provenance"]["source"] == "template_authority_policy"
    assert grant["payload"]["provenance"]["template"] == "coding_agent"

    assert grant["payload"]["provenance"]["template_digest"] ==
             record["desired_authority"]["declaration_digest"]

    assert {:ok, record, [reobserve]} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_revoke_1",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(11)
             })

    assert record["status"] == "active"
    assert record["phase"] == "capability_effects"
    assert record["retry"]["attempt"] == 1
    assert record["retry"]["last_effect_id"] == "eff_revoke_1"

    assert record["reconciliation_required"] == %{
             "phase" => "capability_effects",
             "effect_id" => "eff_revoke_1"
           }

    assert reobserve["effect_type"] == "reobserve_reconcile"
    assert reobserve["effect_id"] == "eff_revoke_1"
    head = hd(record["journal"]["entries"])
    assert reobserve["payload"] == head["payload"]
    assert reobserve["payload"]["revocation_fence"] == fence

    assert head["state"] == "needs_reconcile"
    assert head["effect_id"] == "eff_revoke_1"

    # Restart after journal uncertain keeps reobserve with exact fence
    assert {:ok, admitted} = Core.admit(record)
    assert [restart_reobserve] = Core.next_effects(admitted)
    assert restart_reobserve["effect_type"] == "reobserve_reconcile"
    assert restart_reobserve["effect_id"] == "eff_revoke_1"
    assert restart_reobserve["payload"] == head["payload"]
    assert restart_reobserve["payload"]["revocation_fence"] == fence

    # clear_reconcile re-emits same journal effect identity + fence
    assert {:ok, record, [retry_eff]} =
             Core.clear_reconcile(admitted, %{"at_unix_ms" => t(12)})

    assert record["reconciliation_required"] == nil
    assert hd(record["journal"]["entries"])["state"] == "pending"
    assert retry_eff["effect_id"] == "eff_revoke_1"
    assert retry_eff["effect_type"] == "revoke_managed_capability"
    assert retry_eff["operation_id"] == @op_id
    assert retry_eff["payload"]["revocation_fence"] == fence

    # Success-before-ack style: acknowledge after reobserve cycle
    assert {:ok, record, [reobserve2]} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_revoke_1",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(13)
             })

    assert reobserve2["effect_id"] == "eff_revoke_1"
    assert reobserve2["payload"]["revocation_fence"] == fence

    assert {:ok, record, [next]} =
             Core.acknowledge_effect(record, %{
               "effect_id" => "eff_revoke_1",
               "at_unix_ms" => t(14)
             })

    assert next["effect_id"] == "eff_grant_1"
    assert next["effect_type"] == "grant_managed_capability"
    refute Map.has_key?(next["payload"], "capability_id")
    assert record["retry"]["attempt"] == 0
    assert record["reconciliation_required"] == nil

    # Grant reconciliation retains the v3 ID-only reobserve contract.
    assert {:ok, record, [grant_reobserve]} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_grant_1",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(15)
             })

    assert grant_reobserve["effect_type"] == "reobserve_reconcile"
    assert grant_reobserve["effect_id"] == "eff_grant_1"
    refute Map.has_key?(grant_reobserve, "payload")

    assert {:ok, admitted} = Core.admit(record)
    assert [restart_grant_reobserve] = Core.next_effects(admitted)
    assert restart_grant_reobserve["effect_id"] == "eff_grant_1"
    refute Map.has_key?(restart_grant_reobserve, "payload")
  end

  test "retry exhaustion and non-retryable conflict enter blocked with fence retained", %{
    facts: facts
  } do
    # Fresh new/1 retry input configures max_attempts only; attempt is always 0.
    facts = Map.put(facts, "retry", %{"max_attempts" => 1})
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_1",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => revoke_payload(cap_id("22"), "arbor://fs/write")
                 }
               ]
             })

    assert {:ok, record, _} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_1",
               "outcome" => "retryable_failure",
               "reason_code" => "busy",
               "at_unix_ms" => t(11)
             })

    assert record["status"] == "active"
    assert record["retry"]["attempt"] == 1

    # A repeated uncertain/retryable report while reconciliation_required is
    # already set is rejected — the caller must clear-and-retry first.
    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_1",
               "outcome" => "uncertain",
               "reason_code" => "still_busy",
               "at_unix_ms" => t(12)
             })

    # Clear-and-retry re-emits the same effect identity (recon cleared), then a
    # second uncertain outcome exhausts the single allowed attempt.
    assert {:ok, record, [retry_eff]} =
             Core.clear_reconcile(record, %{"at_unix_ms" => t(12)})

    assert retry_eff["effect_id"] == "eff_1"
    assert record["reconciliation_required"] == nil

    assert {:ok, blocked, []} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_1",
               "outcome" => "uncertain",
               "reason_code" => "still_busy",
               "at_unix_ms" => t(13)
             })

    assert blocked["status"] == "blocked"
    assert blocked["terminal"]["blocked_kind"] == "retry_exhausted"
    assert Core.outstanding?(blocked)
    assert Core.fence_required?(blocked)
    refute Core.replaceable?(blocked)
    assert Core.next_effects(blocked) == []
    assert Core.cleanup_effects(blocked) == []

    # Startup resume: fence retained, no cleanup
    assert {:ok, admitted} = Core.admit(blocked)
    assert Core.fence_required?(admitted)
    assert Core.cleanup_effects(admitted) == []

    assert {:error, {:template_authority_reconciliation_operation, :status_blocked}} =
             Core.acknowledge(admitted, %{
               "phase_intent" => admitted["phase"],
               "at_unix_ms" => t(14)
             })
  end

  test "explicit hold blocks without rollback", %{facts: facts} do
    {record, _} = new!(facts)
    {record, _} = ack!(record, "reserved", t(1))

    assert {:ok, blocked, []} =
             Core.hold_blocked(record, %{"reason_code" => "operator_hold", "at_unix_ms" => t(2)})

    assert blocked["status"] == "blocked"
    assert blocked["terminal"]["blocked_kind"] == "explicit_hold"
    assert Core.fence_required?(blocked)
    refute Core.replaceable?(blocked)
  end

  test "non-retryable conflict blocks immediately", %{facts: facts} do
    {record, _} = new!(facts)

    assert {:ok, blocked, []} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "non_retryable_conflict",
               "reason_code" => "cas_mismatch",
               "at_unix_ms" => t(1)
             })

    assert blocked["status"] == "blocked"
    assert blocked["terminal"]["blocked_kind"] == "non_retryable_conflict"
    assert Core.fence_required?(blocked)
  end

  test "phase-level uncertain increments retry and emits reobserve", %{facts: facts} do
    {record, _} = new!(facts)

    assert {:ok, record, [reobserve]} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(1)
             })

    assert record["status"] == "active"
    assert record["phase"] == "reserved"
    assert record["retry"]["attempt"] == 1
    assert reobserve["effect_type"] == "reobserve_reconcile"
  end

  test "grant plan rejects capability_id and unknown constraint fields", %{facts: facts} do
    record = walk_to_runtime_quiesced(facts)

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_g",
                   "effect_type" => "grant_managed_capability",
                   "payload" => %{
                     "capability_id" => "cap_should_not",
                     "resource" => "arbor://fs/read"
                   }
                 }
               ]
             })

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_g2",
                   "effect_type" => "grant_managed_capability",
                   "payload" => %{
                     "resource" => "arbor://fs/read",
                     "constraints" => %{"ttl" => 30}
                   }
                 }
               ]
             })
  end

  test "rejects free-form reason codes and deeply malformed persisted records", %{
    facts: facts,
    envelope: envelope
  } do
    {record, _} = new!(facts)

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.abort_pre_effect(record, %{
               "reason_code" => "PostgresError: boom",
               "at_unix_ms" => t(1)
             })

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "uncertain",
               "reason_code" => "ECONNRESET: backend said no",
               "at_unix_ms" => t(1)
             })

    # Deep admit rejects conflicting persisted declaration_digest
    bad_digest_record =
      put_in(record, ["desired_authority", "declaration_digest"], @digest)

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_digest_record)

    # Deep admit rejects conflicting provenance
    bad_prov =
      put_in(record, ["desired_authority", "provenance"], %{
        "name" => "not_coding_agent",
        "layer" => "shipped"
      })

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_prov)

    # Deep admit rejects unknown nested constraint-like grant payload fields
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_g",
                   "effect_type" => "grant_managed_capability",
                   "payload" => %{"resource" => "arbor://fs/read"}
                 }
               ]
             })

    [entry] = record["journal"]["entries"]

    bad_payload =
      put_in(entry, ["payload", "extra_field"], "nope")

    bad_journal =
      put_in(record, ["journal", "entries"], [bad_payload])

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_journal)

    # Impossible status/phase/runtime combination
    impossible =
      record
      |> Map.put("phase", "reserved")
      |> Map.put("runtime_was_running", true)
      |> Map.put("profile_cas", nil)
      |> Map.put("frozen_authority", nil)
      |> Map.put("profile_mutation_replay", nil)
      |> Map.put("journal", %{"version" => 1, "entries" => []})
      |> Map.put("reconciliation_required", nil)
      |> put_in(["fence_state", "installed"], false)

    assert {:error, {:template_authority_reconciliation_operation, _}} = Core.admit(impossible)

    # Malformed grant provenance on persisted record
    [good_entry] = record["journal"]["entries"]

    bad_grant_prov =
      put_in(good_entry, ["payload", "provenance", "template"], "other")

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(put_in(record, ["journal", "entries"], [bad_grant_prov]))

    # Keep envelope reference used
    assert is_map(envelope)
  end

  test "predicate matrix for replaceability", %{facts: facts} do
    {active, _} = new!(facts)
    assert Core.outstanding?(active)
    assert Core.fence_required?(active)
    refute Core.replaceable?(active)

    assert {:ok, aborted_reserved, _} =
             Core.abort_pre_effect(active, %{"reason_code" => "x", "at_unix_ms" => t(1)})

    assert_admitted!(aborted_reserved)
    refute Core.outstanding?(aborted_reserved)
    refute Core.fence_required?(aborted_reserved)
    assert Core.replaceable?(aborted_reserved)
  end

  test "phase outcomes reject capability_effects; note_retry binds journal head only", %{
    facts: facts
  } do
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_1",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => revoke_payload(cap_id("33"), "arbor://fs/write")
                 }
               ]
             })

    assert_admitted!(record)

    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.report_outcome(record, %{
               "phase_intent" => "capability_effects",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(11)
             })

    assert {:error, {:template_authority_reconciliation_operation, :journal_effect_not_head}} =
             Core.note_retry(record, %{
               "at_unix_ms" => t(11),
               "reason_code" => "timeout",
               "effect_id" => "eff_other"
             })

    assert {:ok, record, [reobserve]} =
             Core.note_retry(record, %{
               "at_unix_ms" => t(11),
               "reason_code" => "timeout"
             })

    assert_admitted!(record)
    assert reobserve["effect_id"] == "eff_1"
    assert record["reconciliation_required"]["effect_id"] == "eff_1"
    assert hd(record["journal"]["entries"])["state"] == "needs_reconcile"
  end

  test "rejects malformed journal, reconcile pointer, retry, terminal, and fence shapes", %{
    facts: facts
  } do
    {record, _} = new!(facts)

    # Journal must be empty before capability phase
    with_journal =
      put_in(record, ["journal", "entries"], [
        %{
          "effect_id" => "eff_x",
          "seq" => 0,
          "effect_type" => "revoke_managed_capability",
          "state" => "pending",
          "payload" => revoke_payload(cap_id("44"), "arbor://fs/write"),
          "acked_at_unix_ms" => nil
        }
      ])

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(with_journal)

    # Reconcile pointer without matching journal head
    bad_recon =
      record
      |> Map.put("reconciliation_required", %{"phase" => "reserved", "effect_id" => "eff_x"})
      |> put_in(["retry", "attempt"], 1)
      |> put_in(["retry", "last_code"], "timeout")

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_recon)

    # attempt > max_attempts
    bad_retry =
      put_in(record, ["retry"], %{
        "attempt" => 4,
        "max_attempts" => 3,
        "last_code" => "timeout",
        "last_effect_id" => nil
      })

    assert {:error, {:template_authority_reconciliation_operation, :retry_bounds_invalid}} =
             Core.admit(bad_retry)

    # attempt 0 with stale last_code
    stale_retry =
      put_in(record, ["retry"], %{
        "attempt" => 0,
        "max_attempts" => 3,
        "last_code" => "timeout",
        "last_effect_id" => nil
      })

    assert {:error, {:template_authority_reconciliation_operation, :retry_bounds_invalid}} =
             Core.admit(stale_retry)

    # completed terminal must be exact
    completed_bad_terminal =
      record
      |> Map.put("status", "completed")
      |> Map.put("phase", "completed")
      |> Map.put("runtime_was_running", false)
      |> Map.put("profile_cas", profile_cas())
      |> Map.put("terminal", %{
        "reason_code" => "done",
        "at_unix_ms" => t(1),
        "phase_at_terminal" => "completed",
        "blocked_kind" => nil
      })
      |> Map.put("fence_state", %{
        "required" => true,
        "installed" => true,
        "cleanup_acked" => false
      })
      |> Map.put("updated_at_unix_ms", t(1))

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(completed_bad_terminal)

    # blocked fence must never be cleaned
    blocked_cleaned =
      record
      |> Map.put("status", "blocked")
      |> Map.put("terminal", %{
        "reason_code" => "hold",
        "at_unix_ms" => t(1),
        "phase_at_terminal" => "reserved",
        "blocked_kind" => "explicit_hold"
      })
      |> Map.put("fence_state", %{
        "required" => false,
        "installed" => false,
        "cleanup_acked" => true
      })
      |> Map.put("updated_at_unix_ms", t(1))

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(blocked_cleaned)

    # capability journal: needs_reconcile only at unresolved head
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(20),
               "entries" => [
                 %{
                   "effect_id" => "eff_a",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => revoke_payload(cap_id("55"), "arbor://fs/write")
                 },
                 %{
                   "effect_id" => "eff_b",
                   "effect_type" => "grant_managed_capability",
                   "payload" => %{"resource" => "arbor://fs/read"}
                 }
               ]
             })

    [a, b] = record["journal"]["entries"]

    bad_shape =
      put_in(record, ["journal", "entries"], [
        Map.put(a, "state", "pending"),
        Map.put(b, "state", "needs_reconcile")
      ])

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_shape)

    # needs_reconcile head without recon pointer
    needs_only =
      put_in(record, ["journal", "entries"], [
        Map.put(a, "state", "needs_reconcile"),
        Map.put(b, "state", "pending")
      ])

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(needs_only)
  end

  test "successful reducer outputs remain admit-stable across restart-sensitive paths", %{
    facts: facts
  } do
    {record, _} = new!(facts)

    assert {:ok, record, _} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(1)
             })

    assert_admitted!(record)

    assert {:ok, record, _} = Core.clear_reconcile(record, %{"at_unix_ms" => t(2)})
    assert_admitted!(record)

    assert {:ok, record, _} =
             Core.acknowledge(record, %{"phase_intent" => "reserved", "at_unix_ms" => t(3)})

    assert_admitted!(record)

    assert {:ok, blocked, _} =
             Core.hold_blocked(record, %{"reason_code" => "operator_hold", "at_unix_ms" => t(4)})

    assert_admitted!(blocked)
    assert blocked["fence_state"]["cleanup_acked"] == false
    assert blocked["fence_state"]["required"] == true
  end

  test "security regression: abort_pre_effect rejects unresolved reconciliation_required", %{
    facts: facts
  } do
    {record, _} = new!(facts)

    # An uncertain reserved-phase dispatch-fence outcome sets reconciliation_required.
    assert {:ok, record, [reobserve]} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(1)
             })

    assert record["reconciliation_required"] == %{"phase" => "reserved", "effect_id" => nil}
    assert reobserve["effect_type"] == "reobserve_reconcile"

    # Abort must be rejected while the uncertain outcome is unresolved: the
    # caller must acknowledge-as-applied or clear-and-retry first.
    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.abort_pre_effect(record, %{"reason_code" => "cancel", "at_unix_ms" => t(2)})

    # After clear-and-retry, abort is admissible again (recon cleared).
    assert {:ok, record, _} = Core.clear_reconcile(record, %{"at_unix_ms" => t(2)})

    assert {:ok, aborted, _} =
             Core.abort_pre_effect(record, %{"reason_code" => "cancel", "at_unix_ms" => t(3)})

    assert aborted["status"] == "aborted_pre_effect"
  end

  test "security regression: deep canonical envelope equality rejects unknown nested fields", %{
    facts: facts,
    envelope: envelope
  } do
    # Unknown top-level envelope field is rejected at new/1 (not silently dropped).
    extra_envelope = Map.put(envelope, "backend_hint", "pg")

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.new(put_in(facts, ["desired_authority", "envelope"], extra_envelope))

    # Unknown snapshot field is rejected.
    extra_snapshot =
      put_in(
        facts,
        ["desired_authority", "envelope", "snapshot"],
        Map.put(envelope["snapshot"], "source_path", "/x")
      )

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.new(extra_snapshot)

    # Unknown capability field (capability_id) is rejected after canonical
    # normalization strips it: the input envelope no longer equals canonical.
    caps = envelope["snapshot"]["capabilities"]
    modified_caps = [Map.put(hd(caps), "capability_id", "cap_leak") | tl(caps)]

    cap_with_id =
      put_in(facts, ["desired_authority", "envelope", "snapshot", "capabilities"], modified_caps)

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.new(cap_with_id)

    # Persisted admit/1 rejects the same unknown nested envelope field.
    {record, _} = new!(facts)

    bad_persisted =
      put_in(record, ["desired_authority", "envelope"], Map.put(envelope, "extra", true))

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_persisted)

    # The happy-path canonical envelope admits and is preserved exactly.
    {record, _} = new!(facts)
    assert record["desired_authority"]["envelope"] == envelope
    assert {:ok, ^record} = Core.admit(record)
  end

  test "phase-specific acknowledge keysets reject irrelevant facts", %{facts: facts} do
    {record, _} = new!(facts)

    # profile_cas / frozen_authority are only admissible for fenced→prepared.
    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.acknowledge(record, %{
               "phase_intent" => "reserved",
               "at_unix_ms" => t(1),
               "profile_cas" => profile_cas()
             })

    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.acknowledge(record, %{
               "phase_intent" => "reserved",
               "at_unix_ms" => t(1),
               "frozen_authority" => frozen_authority(record)
             })

    {record, _} = ack!(record, "reserved", t(1))
    {record, _} = prepare!(record, t(2))
    {record, _} = ack!(record, "prepared", t(3))

    # runtime_was_running is only admissible for deny_all_installed; supplying
    # it while acknowledging deny_all_intent (base keyset) is rejected.
    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.acknowledge(record, %{
               "phase_intent" => "deny_all_intent",
               "at_unix_ms" => t(4),
               "runtime_was_running" => true
             })
  end

  test "retry admission coherence: attempt 0 requires nil recon and last fields", %{
    facts: facts
  } do
    {record, _} = new!(facts)

    # attempt=0 with a reconciliation map is rejected (retry coherence).
    bad_recon =
      record
      |> Map.put("reconciliation_required", %{"phase" => "reserved", "effect_id" => nil})

    assert {:error, {:template_authority_reconciliation_operation, :retry_bounds_invalid}} =
             Core.admit(bad_recon)

    # Fresh new/1 retry input only accepts max_attempts; attempt/last_* rejected.
    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.new(Map.put(facts, "retry", %{"attempt" => 1, "max_attempts" => 3}))

    assert {:error, {:template_authority_reconciliation_operation, :unexpected_field}} =
             Core.new(Map.put(facts, "retry", %{"last_code" => "timeout"}))

    assert {:ok, record, _} = Core.new(Map.put(facts, "retry", %{"max_attempts" => 2}))
    assert record["retry"]["attempt"] == 0
    assert record["retry"]["last_code"] == nil
    assert record["retry"]["last_effect_id"] == nil
    assert record["retry"]["max_attempts"] == 2
  end

  test "note_retry with effect_id in a primary phase returns transition_illegal", %{
    facts: facts
  } do
    {record, _} = new!(facts)

    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.note_retry(record, %{
               "at_unix_ms" => t(1),
               "reason_code" => "timeout",
               "effect_id" => "eff_should_not_apply"
             })
  end

  test "blocked terminal rejects reason_code completed", %{facts: facts} do
    {record, _} = new!(facts)

    blocked_completed =
      record
      |> Map.put("status", "blocked")
      |> Map.put("terminal", %{
        "reason_code" => "completed",
        "at_unix_ms" => t(1),
        "phase_at_terminal" => "reserved",
        "blocked_kind" => "explicit_hold"
      })
      |> Map.put("fence_state", %{
        "required" => true,
        "installed" => true,
        "cleanup_acked" => false
      })
      |> Map.put("updated_at_unix_ms", t(1))

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(blocked_completed)
  end

  test "succeeded journal ack timestamps are bounded and nondecreasing by seq", %{
    facts: facts
  } do
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_a",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => revoke_payload(cap_id("66"), "arbor://fs/write")
                 },
                 %{
                   "effect_id" => "eff_b",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => revoke_payload(cap_id("77"), "arbor://fs/read")
                 }
               ]
             })

    assert {:ok, record, _} =
             Core.acknowledge_effect(record, %{"effect_id" => "eff_a", "at_unix_ms" => t(11)})

    assert {:ok, record, _} =
             Core.acknowledge_effect(record, %{"effect_id" => "eff_b", "at_unix_ms" => t(12)})

    assert record["phase"] == "profile_commit"

    assert {:ok, ^record} = Core.admit(record)

    # Out-of-range ack timestamp (before created_at) is rejected.
    [a, b] = record["journal"]["entries"]
    a_before = put_in(a, ["acked_at_unix_ms"], 999)

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.admit(put_in(record, ["journal", "entries"], [a_before, b]))

    # Nondecreasing violation: earlier entry acked later than its successor.
    a_late = put_in(a, ["acked_at_unix_ms"], t(13))
    b_ok = put_in(b, ["acked_at_unix_ms"], t(12))

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(put_in(record, ["journal", "entries"], [a_late, b_ok]))
  end

  test "note_retry rejects a second retry while reconciliation_required is set (primary + journal forms)",
       %{facts: facts} do
    # --- Primary phase form ---
    {record, _} = new!(facts)

    # Happy path: a first note_retry (no reconciliation set) advances the retry.
    assert {:ok, record, [reobserve]} =
             Core.note_retry(record, %{"at_unix_ms" => t(1), "reason_code" => "timeout"})

    assert record["retry"]["attempt"] == 1
    assert record["reconciliation_required"] == %{"phase" => "reserved", "effect_id" => nil}
    assert reobserve["effect_type"] == "reobserve_reconcile"

    # A second note_retry while reconciliation_required is set is rejected,
    # without incrementing the attempt or re-emitting an effect. The caller must
    # acknowledge-as-applied or clear-and-retry first.
    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.note_retry(record, %{"at_unix_ms" => t(2), "reason_code" => "still_timeout"})

    assert {:ok, ^record} = Core.admit(record)
    assert record["retry"]["attempt"] == 1

    # --- Journal-effect form ---
    record = walk_to_runtime_quiesced(facts)

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_1",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => revoke_payload(cap_id("88"), "arbor://fs/write")
                 }
               ]
             })

    # Happy path: a first note_retry marks the journal head needs_reconcile.
    assert {:ok, record, _} =
             Core.note_retry(record, %{"at_unix_ms" => t(11), "reason_code" => "timeout"})

    assert record["reconciliation_required"]["effect_id"] == "eff_1"
    assert record["retry"]["attempt"] == 1
    assert hd(record["journal"]["entries"])["state"] == "needs_reconcile"

    # A second note_retry on the same unresolved head is rejected.
    assert {:error, {:template_authority_reconciliation_operation, :transition_illegal}} =
             Core.note_retry(record, %{"at_unix_ms" => t(12), "reason_code" => "still_timeout"})

    assert {:ok, ^record} = Core.admit(record)
    assert record["retry"]["attempt"] == 1
  end

  test "C3B3 non-disclosure: effects and status omit replay commitment and profile material", %{
    facts: facts
  } do
    alias Arbor.Agent.TemplateAuthorityReconciliationStatusProjection, as: Status

    {record, _} = new!(facts)
    {record, effects} = ack!(record, "reserved", t(1))
    refute Enum.any?(effects, &Map.has_key?(&1, "profile_mutation_replay"))

    replay = replay_commitment()
    {record, effects} = prepare!(record, t(2), profile_cas(), replay)
    assert record["profile_mutation_replay"] == replay
    assert is_map(record["profile_mutation_replay"])

    effect = hd(effects)
    refute Map.has_key?(effect, "profile_mutation_replay")
    refute Map.has_key?(effect, "profile_cas")
    refute Map.has_key?(effect, "frozen_authority")
    refute Map.has_key?(effect, "anchor_digest")
    refute Map.has_key?(effect, "successor_digest")

    assert {:ok, status} = Status.project(record)
    refute Map.has_key?(status, "profile_mutation_replay")
    refute Map.has_key?(status, "profile_cas")
    refute Map.has_key?(status, "frozen_authority")
    refute Map.has_key?(status, "desired_authority")
    refute inspect(status) =~ replay["anchor_digest"]
    assert Core.version() == 4
  end

  test "primary retryable phase vocabulary locks the retry-phase admission boundary (source of truth for the projection)",
       %{facts: facts} do
    # The status projection sources its retry-phase coherence from this exact
    # list, so lock it here to prevent drift. capability_effects is excluded: it
    # is a journal retry bound to the unresolved head, not a primary phase retry.
    assert Core.primary_outcome_phases() ==
             ~w(reserved fenced prepared deny_all_intent deny_all_installed profile_commit desired_trust verifying runtime_restore)

    # attempt>0 at runtime_quiesced (pre-capability, non-primary) is not
    # admissible: no reducer can fire a retry there.
    quiesced = walk_to_runtime_quiesced(facts)

    bad_quiesced =
      put_in(quiesced, ["retry"], %{
        "attempt" => 1,
        "max_attempts" => 3,
        "last_code" => "timeout",
        "last_effect_id" => nil
      })

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_quiesced)

    # attempt>0 at completed is not admissible: completion resets attempt to 0.
    completed = walk_to_completed(facts)

    bad_completed =
      put_in(completed, ["retry"], %{
        "attempt" => 1,
        "max_attempts" => 3,
        "last_code" => "timeout",
        "last_effect_id" => nil
      })

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(bad_completed)

    # Positive boundary: attempt>0 IS admissible at a primary outcome phase with
    # reconciliation_required set (a phase-level retry) and is restart-stable.
    {record, _} = new!(facts)

    assert {:ok, record, _} =
             Core.report_outcome(record, %{
               "phase_intent" => "reserved",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(1)
             })

    assert record["retry"]["attempt"] == 1
    assert {:ok, ^record} = Core.admit(record)

    # Positive boundary: attempt>0 IS admissible at capability_effects when bound
    # to an unresolved (needs_reconcile) journal head, and restart-stable.
    record =
      walk_to_capability_effects(facts, [
        %{
          "effect_id" => "eff_1",
          "effect_type" => "revoke_managed_capability",
          "payload" => revoke_payload(cap_id("99"), "arbor://fs/write")
        }
      ])

    assert {:ok, record, _} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_1",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(11)
             })

    assert record["retry"]["attempt"] == 1
    assert {:ok, ^record} = Core.admit(record)

    # Negative boundary: at capability_effects, attempt>0 with an empty journal
    # (no head to bind last_effect_id to) is not admissible.
    empty_cap = walk_to_capability_effects(facts, [])

    bad_empty_cap =
      put_in(empty_cap, ["retry"], %{
        "attempt" => 1,
        "max_attempts" => 3,
        "last_code" => "timeout",
        "last_effect_id" => nil
      })

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.admit(bad_empty_cap)
  end

  test "revoke_managed_capability requires Security-admitted revocation_fence; mismatches fail closed",
       %{facts: facts} do
    record = walk_to_runtime_quiesced(facts)
    cap = cap_id("a1")
    resource = "arbor://fs/write"
    good = revoke_payload(cap, resource)

    # Missing fence (v3 ID-only shape)
    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_nofence",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{"capability_id" => cap, "resource" => resource}
                 }
               ]
             })

    # Unknown extra payload key
    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_extra",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => Map.put(good, "extra", "nope")
                 }
               ]
             })

    # Atom-keyed fence map (Security requires binary keys only)
    f = good["revocation_fence"]

    atom_fence = %{
      kind: f["kind"],
      version: f["version"],
      capability_id: f["capability_id"],
      principal_id: f["principal_id"],
      resource_uri: f["resource_uri"],
      record_id: f["record_id"],
      generation: f["generation"],
      revision: f["revision"],
      capability_digest: f["capability_digest"]
    }

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_atom",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => cap,
                     "resource" => resource,
                     "revocation_fence" => atom_fence
                   }
                 }
               ]
             })

    # Malformed fence (wrong kind)
    bad_kind = Map.put(good["revocation_fence"], "kind", "not_a_fence")

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_kind",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => cap,
                     "resource" => resource,
                     "revocation_fence" => bad_kind
                   }
                 }
               ]
             })

    # Oversized digest
    oversized =
      Map.put(good["revocation_fence"], "capability_digest", String.duplicate("ab", 40))

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_over",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => cap,
                     "resource" => resource,
                     "revocation_fence" => oversized
                   }
                 }
               ]
             })

    # Principal mismatch (fence principal ≠ target_agent_id)
    wrong_principal =
      closed_fence!(cap, "agent_other_principal", resource)

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_prin",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => cap,
                     "resource" => resource,
                     "revocation_fence" => wrong_principal
                   }
                 }
               ]
             })

    # Resource mismatch
    wrong_resource_fence = closed_fence!(cap, @agent, "arbor://fs/read")

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_res",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => cap,
                     "resource" => resource,
                     "revocation_fence" => wrong_resource_fence
                   }
                 }
               ]
             })

    # Capability id mismatch
    other_cap = cap_id("b2")
    wrong_cap_fence = closed_fence!(other_cap, @agent, resource)

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_cap",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => cap,
                     "resource" => resource,
                     "revocation_fence" => wrong_cap_fence
                   }
                 }
               ]
             })

    # Unknown key *inside* revocation_fence (not merely outer payload)
    nested_extra = Map.put(good["revocation_fence"], "extra_nested", "nope")

    assert {:error, {:template_authority_reconciliation_operation, _}} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_nested",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => cap,
                     "resource" => resource,
                     "revocation_fence" => nested_extra
                   }
                 }
               ]
             })

    # Happy path still works; grants unchanged
    assert {:ok, planned, [eff]} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_ok",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => good
                 },
                 %{
                   "effect_id" => "eff_grant",
                   "effect_type" => "grant_managed_capability",
                   "payload" => %{"resource" => "arbor://fs/read"}
                 }
               ]
             })

    assert_admitted!(planned)
    assert eff["payload"]["revocation_fence"] == good["revocation_fence"]
    assert Enum.at(planned["journal"]["entries"], 1)["effect_type"] == "grant_managed_capability"

    # Tampered stored fence cannot be laundered through Core.admit/1 (restart gate).
    [entry | rest] = planned["journal"]["entries"]

    # Nested unknown key inside the stored fence fails closed on re-admit.
    nested_tampered =
      Map.put(entry["payload"]["revocation_fence"], "forged_field", "x")

    nested_entry = put_in(entry, ["payload", "revocation_fence"], nested_tampered)
    nested_record = put_in(planned, ["journal", "entries"], [nested_entry | rest])

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(nested_record)

    # Principal mismatch against operation target_agent_id fails closed on re-admit.
    principal_tampered =
      Map.put(entry["payload"]["revocation_fence"], "principal_id", "agent_forged_other")

    principal_entry = put_in(entry, ["payload", "revocation_fence"], principal_tampered)
    principal_record = put_in(planned, ["journal", "entries"], [principal_entry | rest])

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(principal_record)

    # Resource URI mismatch fails closed on re-admit.
    resource_tampered =
      Map.put(entry["payload"]["revocation_fence"], "resource_uri", "arbor://fs/read")

    resource_entry = put_in(entry, ["payload", "revocation_fence"], resource_tampered)
    resource_record = put_in(planned, ["journal", "entries"], [resource_entry | rest])

    assert {:error, {:template_authority_reconciliation_operation, :invalid_record}} =
             Core.admit(resource_record)
  end

  test "journal-scoped reobserve never emits effect_id-only when payload lookup fails", %{
    facts: facts
  } do
    record = walk_to_runtime_quiesced(facts)
    payload = revoke_payload(cap_id("c0"), "arbor://fs/write")

    assert {:ok, record, _} =
             Core.plan_capability_effects(record, %{
               "at_unix_ms" => t(10),
               "entries" => [
                 %{
                   "effect_id" => "eff_bind",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => payload
                 }
               ]
             })

    assert {:ok, record, [reobserve]} =
             Core.report_effect_outcome(record, %{
               "effect_id" => "eff_bind",
               "outcome" => "uncertain",
               "reason_code" => "timeout",
               "at_unix_ms" => t(11)
             })

    assert Map.has_key?(reobserve, "payload")
    assert reobserve["payload"]["revocation_fence"] == payload["revocation_fence"]

    # Reachable fail-closed: strip payload from the journal entry while recon
    # still points at the effect_id. next_effects must not invent ID-only reobserve.
    [entry] = record["journal"]["entries"]
    stripped = Map.put(entry, "payload", "not-a-map")
    broken = put_in(record, ["journal", "entries"], [stripped])

    effects = Core.next_effects(broken)
    assert effects == []
    refute Enum.any?(effects, &(&1["effect_type"] == "reobserve_reconcile"))

    # Unknown effect_id recon binding also yields no executable effect
    orphan =
      record
      |> Map.put("reconciliation_required", %{
        "phase" => "capability_effects",
        "effect_id" => "eff_missing"
      })

    assert Core.next_effects(orphan) == []
  end

  defp json_clean?(value), do: match?({:ok, _}, Jason.encode(value))
end
