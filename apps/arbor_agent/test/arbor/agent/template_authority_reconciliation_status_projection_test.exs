defmodule Arbor.Agent.TemplateAuthorityReconciliationStatusProjectionTest do
  use ExUnit.Case, async: true

  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy
  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Op
  alias Arbor.Agent.TemplateAuthorityReconciliationStatusProjection, as: Proj

  @moduletag :fast

  @digest String.duplicate("cd", 32)
  @agent "agent_recon_proj_1"
  @caller "agent_recon_proj_caller"
  @op_id "op_proj_1"
  @repo_root "/Users/dev/arbor"

  @template_data %{
    "name" => "scout",
    "required_capabilities" => [
      %{"resource" => "arbor://fs/write"}
    ],
    "trust_preset" => %{
      "baseline" => "block",
      "rules" => %{"arbor://fs/write" => "ask"}
    },
    "template_source" => %{"name" => "scout", "layer" => "user"}
  }

  setup do
    assert {:ok, envelope} = TemplateAuthorityPolicy.build("scout", @template_data)

    facts = %{
      "operation_id" => @op_id,
      "target_agent_id" => @agent,
      "authorizing_caller_id" => @caller,
      "expected_preview_reconciliation_digest" => @digest,
      "desired_authority" => envelope,
      "scope" => "local_owner",
      "durability" => "node_restart",
      "created_at_unix_ms" => 5_000
    }

    assert {:ok, record, _} = Op.new(facts)
    %{record: record, facts: facts}
  end

  test "projects exact scope/durability strings and closed status keyset", %{record: record} do
    assert {:ok, status} = Proj.project(record)

    assert status["kind"] == "template_authority_reconciliation_status"
    assert status["version"] == 1
    assert status["scope"] == "local_owner"
    assert status["durability"] == "node_restart"
    assert is_binary(status["scope"])
    assert is_binary(status["durability"])
    refute is_boolean(status["scope"])
    refute is_boolean(status["durability"])

    assert status["status"] == "active"
    assert status["phase"] == "reserved"
    assert status["operation_id"] == @op_id
    assert status["target_agent_id"] == @agent
    assert status["outstanding"] == true
    assert status["fence_required"] == true
    assert status["replaceable"] == false
    assert status["journal_summary"]["entry_count"] == 0
    assert status["terminal"] == nil

    refute Map.has_key?(status, "desired_authority")
    refute Map.has_key?(status, "journal")
    refute Map.has_key?(status, "fence_state")
    refute Map.has_key?(status, "authorizing_caller_id")
    refute Map.has_key?(status, "profile_cas")
    refute Map.has_key?(status, "frozen_authority")
    refute Map.has_key?(status, "profile_mutation_replay")
    refute Map.has_key?(status, "reconciliation_required")
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

    %{"repo_root" => repo_root, "effective_capabilities" => caps}
  end

  defp profile_mutation_replay do
    %{
      "version" => ProfileAuthorityMutationCore.commitment_version(),
      "kind" => ProfileAuthorityMutationCore.commitment_kind(),
      "algorithm" => ProfileAuthorityMutationCore.commitment_algorithm(),
      "encoding" => ProfileAuthorityMutationCore.commitment_encoding(),
      "domain" => ProfileAuthorityMutationCore.commitment_domain(),
      "anchor_digest" => String.duplicate("11", 32),
      "successor_digest" => String.duplicate("22", 32)
    }
  end

  test "redacts caller identity, profile CAS, frozen authority, capability ids, and private journal payloads",
       %{
         record: record
       } do
    assert {:ok, record, _} =
             Op.acknowledge(record, %{"phase_intent" => "reserved", "at_unix_ms" => 5_001})

    cas = %{"record_id" => "profile_secret_rec", "generation" => 2, "revision" => 9}
    frozen = frozen_authority(record)

    assert {:ok, record, _} =
             Op.prepare(record, %{
               "at_unix_ms" => 5_002,
               "profile_cas" => cas,
               "frozen_authority" => frozen,
               "profile_mutation_replay" => profile_mutation_replay()
             })

    assert {:ok, record, _} =
             Op.acknowledge(record, %{"phase_intent" => "prepared", "at_unix_ms" => 5_003})

    assert {:ok, record, _} =
             Op.acknowledge(record, %{"phase_intent" => "deny_all_intent", "at_unix_ms" => 5_004})

    assert {:ok, record, _} =
             Op.acknowledge(record, %{
               "phase_intent" => "deny_all_installed",
               "at_unix_ms" => 5_005,
               "runtime_was_running" => true
             })

    secret_cap = "cap_secret_should_not_leak"

    assert {:ok, record, _} =
             Op.plan_capability_effects(record, %{
               "at_unix_ms" => 5_006,
               "entries" => [
                 %{
                   "effect_id" => "eff_r1",
                   "effect_type" => "revoke_managed_capability",
                   "payload" => %{
                     "capability_id" => secret_cap,
                     "resource" => "arbor://fs/write"
                   }
                 }
               ]
             })

    assert {:ok, status} = Proj.project(record)
    encoded = Jason.encode!(status)

    refute encoded =~ secret_cap
    refute encoded =~ "capability_id"
    refute encoded =~ @caller
    refute encoded =~ "profile_secret_rec"
    refute encoded =~ "authorizing_caller_id"
    refute encoded =~ "profile_cas"
    refute encoded =~ "frozen_authority"
    refute encoded =~ @repo_root
    refute Map.has_key?(status, "desired_authority")
    refute Map.has_key?(status, "authorizing_caller_id")
    refute Map.has_key?(status, "profile_cas")
    refute Map.has_key?(status, "frozen_authority")
    refute Map.has_key?(status, "profile_mutation_replay")
    assert status["journal_summary"]["entry_count"] == 1
    assert status["journal_summary"]["pending_count"] == 1
    assert status["journal_summary"]["succeeded_count"] == 0
  end

  test "blocked projection retains outstanding and fence_required", %{record: record} do
    assert {:ok, blocked, _} =
             Op.hold_blocked(record, %{"reason_code" => "hold", "at_unix_ms" => 5_001})

    assert {:ok, status} = Proj.project(blocked)
    assert status["status"] == "blocked"
    assert status["outstanding"] == true
    assert status["fence_required"] == true
    assert status["replaceable"] == false
    assert status["terminal"]["blocked_kind"] == "explicit_hold"
    assert status["terminal"]["reason_code"] == "hold"
  end

  test "malformed record fails closed without partial leak" do
    assert {:error, {:template_authority_reconciliation_status, _}} =
             Proj.project(%{"status" => "active"})
  end

  # Direct malformed-status rejection: assert_status/1 must fail closed on any
  # self-inconsistent or ill-formed status/receipt map, not just on a bad record.
  defp base_status do
    %{
      "version" => 1,
      "kind" => "template_authority_reconciliation_status",
      "status" => "active",
      "phase" => "reserved",
      "operation_id" => @op_id,
      "target_agent_id" => @agent,
      "scope" => "local_owner",
      "durability" => "node_restart",
      "outstanding" => true,
      "fence_required" => true,
      "replaceable" => false,
      "retry" => %{"attempt" => 0, "max_attempts" => 3, "last_code" => nil},
      "terminal" => nil,
      "created_at_unix_ms" => 5_000,
      "updated_at_unix_ms" => 5_000,
      "journal_summary" => %{
        "entry_count" => 0,
        "pending_count" => 0,
        "needs_reconcile_count" => 0,
        "succeeded_count" => 0
      }
    }
  end

  defp reject!(label, status) do
    assert {:error, {:template_authority_reconciliation_status, _}} = Proj.assert_status(status),
           "expected rejection for: #{label}"
  end

  test "assert_status accepts a well-formed status" do
    assert {:ok, _} = Proj.assert_status(base_status())
  end

  test "assert_status rejects wrong version/kind and extra/missing keys" do
    reject!("wrong version", %{base_status() | "version" => 2})
    reject!("wrong kind", %{base_status() | "kind" => "other"})
    reject!("extra key", Map.put(base_status(), "leaked", true))
    reject!("missing key", Map.delete(base_status(), "retry"))
  end

  test "assert_status rejects unknown status/phase and incoherent combinations" do
    reject!("unknown status", %{base_status() | "status" => "paused"})
    reject!("unknown phase", %{base_status() | "phase" => "init"})
    reject!("completed+reserved", %{base_status() | "status" => "completed"})
    reject!("active+completed phase", %{base_status() | "phase" => "completed"})
    reject!("aborted non-abortable", %{base_status() | "status" => "aborted_pre_effect"})
  end

  test "assert_status rejects malformed ids and bad time order" do
    reject!("bad operation_id", %{base_status() | "operation_id" => "bad id!"})
    reject!("bad target_agent_id", %{base_status() | "target_agent_id" => "not_an_agent"})
    reject!("updated before created", %{base_status() | "updated_at_unix_ms" => 4_999})
    reject!("non-integer time", %{base_status() | "created_at_unix_ms" => "x"})
  end

  test "assert_status rejects retry bounds and malformed last_code" do
    reject!("attempt > max", %{
      base_status()
      | "retry" => %{"attempt" => 4, "max_attempts" => 3, "last_code" => nil}
    })

    reject!("bad last_code", %{
      base_status()
      | "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => "BadCode!"}
    })

    reject!("retry extra key", %{
      base_status()
      | "retry" => Map.put(base_status()["retry"], "last_effect_id", "eff")
    })
  end

  test "assert_status rejects terminal shape and derived-relationship corruption" do
    # active status must have nil terminal
    reject!("active with terminal", %{
      base_status()
      | "terminal" => %{
          "reason_code" => "completed",
          "at_unix_ms" => 5_000,
          "phase_at_terminal" => "completed",
          "blocked_kind" => nil
        }
    })

    # completed status with inconsistent outstanding/replaceable
    completed =
      %{base_status() | "status" => "completed", "phase" => "completed", "fence_required" => true}
      |> Map.put("terminal", %{
        "reason_code" => "completed",
        "at_unix_ms" => 5_000,
        "phase_at_terminal" => "completed",
        "blocked_kind" => nil
      })

    # outstanding must follow derived rule (completed+fence_required => outstanding true)
    bad_outstanding = %{completed | "outstanding" => false}
    reject!("bad outstanding", bad_outstanding)

    # blocked terminal cannot carry reason_code "completed"
    blocked =
      %{
        base_status()
        | "status" => "blocked",
          "phase" => "reserved",
          "outstanding" => true,
          "replaceable" => false
      }
      |> Map.put("terminal", %{
        "reason_code" => "completed",
        "at_unix_ms" => 5_000,
        "phase_at_terminal" => "reserved",
        "blocked_kind" => "explicit_hold"
      })

    reject!("blocked reason completed", blocked)
  end

  test "assert_status rejects journal-summary count incoherence and bounds" do
    reject!(
      "summary counts do not sum",
      %{
        base_status()
        | "journal_summary" => %{
            "entry_count" => 2,
            "pending_count" => 1,
            "needs_reconcile_count" => 0,
            "succeeded_count" => 0
          }
      }
    )

    reject!(
      "summary extra key",
      %{
        base_status()
        | "journal_summary" => Map.put(base_status()["journal_summary"], "extra", 0)
      }
    )
  end

  test "assert_status rejects active and blocked receipts with fence_required false (security regression)" do
    # active records always retain an installed or pending fence in the core, so
    # a public receipt with fence_required false can never be emitted by
    # project/1 and must be rejected.
    reject!("active with fence_required false", %{base_status() | "fence_required" => false})

    # blocked records likewise always retain the fence (cleanup never runs while
    # blocked), so fence_required false is unreachable there too.
    blocked_no_fence =
      %{
        base_status()
        | "status" => "blocked",
          "phase" => "reserved",
          "outstanding" => true,
          "replaceable" => false,
          "fence_required" => false
      }
      |> Map.put("terminal", %{
        "reason_code" => "hold",
        "at_unix_ms" => 5_000,
        "phase_at_terminal" => "reserved",
        "blocked_kind" => "explicit_hold"
      })

    reject!("blocked with fence_required false", blocked_no_fence)

    # Valid terminal combinations are preserved: completed and aborted_pre_effect
    # genuinely vary fence_required (cleanup may or may not be acked), so both
    # values must still be accepted there.
    completed_no_fence =
      %{
        base_status()
        | "status" => "completed",
          "phase" => "completed",
          "outstanding" => false,
          "replaceable" => true,
          "fence_required" => false
      }
      |> Map.put("terminal", %{
        "reason_code" => "completed",
        "at_unix_ms" => 5_000,
        "phase_at_terminal" => "completed",
        "blocked_kind" => nil
      })

    assert {:ok, _} = Proj.assert_status(completed_no_fence)

    aborted_no_fence =
      %{
        base_status()
        | "status" => "aborted_pre_effect",
          "phase" => "reserved",
          "outstanding" => false,
          "replaceable" => true,
          "fence_required" => false
      }
      |> Map.put("terminal", %{
        "reason_code" => "cancel",
        "at_unix_ms" => 5_000,
        "phase_at_terminal" => "reserved",
        "blocked_kind" => nil
      })

    assert {:ok, _} = Proj.assert_status(aborted_no_fence)
  end

  test "assert_status: fresh retry (attempt 0) requires nil last_code; attempt>0 keeps bounded codes" do
    # attempt 0 with any last_code is unreachable: the core resets last_code to
    # nil on every successful acknowledge before attempt can return to 0.
    reject!("attempt 0 with last_code", %{
      base_status()
      | "retry" => %{"attempt" => 0, "max_attempts" => 3, "last_code" => "timeout"}
    })

    # attempt>0 retains a bounded reason code when present.
    assert {:ok, _} =
             Proj.assert_status(%{
               base_status()
               | "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => "timeout"}
             })

    # attempt>0 with no recorded reason is also valid (a retry may be nil-coded).
    assert {:ok, _} =
             Proj.assert_status(%{
               base_status()
               | "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => nil}
             })

    # attempt>0 still rejects an unbounded last_code.
    reject!("attempt 1 with unbounded last_code", %{
      base_status()
      | "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => "Boom: x"}
    })
  end

  test "assert_status: journal_summary must match the phase the core can emit (security regression)" do
    # Pre-capability phases (reserved..runtime_quiesced) never carry entries.
    reject!("pre-capability phase with journal entries", %{
      base_status()
      | "journal_summary" => %{
          "entry_count" => 1,
          "pending_count" => 1,
          "needs_reconcile_count" => 0,
          "succeeded_count" => 0
        }
    })

    # capability_effects bounds needs_reconcile to at most one (the head).
    reject!("capability_effects needs_reconcile > 1", %{
      base_status()
      | "phase" => "capability_effects",
        "journal_summary" => %{
          "entry_count" => 3,
          "pending_count" => 1,
          "needs_reconcile_count" => 2,
          "succeeded_count" => 0
        }
    })

    # Post-capability phases have every entry succeeded.
    reject!("post-capability phase with pending entry", %{
      base_status()
      | "phase" => "profile_commit",
        "journal_summary" => %{
          "entry_count" => 1,
          "pending_count" => 1,
          "needs_reconcile_count" => 0,
          "succeeded_count" => 0
        }
    })

    reject!("post-capability phase with needs_reconcile entry", %{
      base_status()
      | "phase" => "profile_commit",
        "journal_summary" => %{
          "entry_count" => 1,
          "pending_count" => 0,
          "needs_reconcile_count" => 1,
          "succeeded_count" => 0
        }
    })

    # Positive: active capability_effects with one needs_reconcile head plus a
    # pending tail requires a positive retry attempt — the core only marks a
    # head needs_reconcile via a retryable failure, which increments attempt.
    assert {:ok, _} =
             Proj.assert_status(%{
               base_status()
               | "phase" => "capability_effects",
                 "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => "timeout"},
                 "journal_summary" => %{
                   "entry_count" => 2,
                   "pending_count" => 1,
                   "needs_reconcile_count" => 1,
                   "succeeded_count" => 0
                 }
             })

    # A blocked receipt at capability_effects may legitimately retain a single
    # needs_reconcile head (e.g. hold_blocked during an unresolved reobservation):
    # the bound is needs_reconcile <= 1, not needs_reconcile implies active.
    assert {:ok, _} =
             Proj.assert_status(
               %{
                 base_status()
                 | "status" => "blocked",
                   "phase" => "capability_effects",
                   "outstanding" => true,
                   "replaceable" => false,
                   "fence_required" => true,
                   "journal_summary" => %{
                     "entry_count" => 1,
                     "pending_count" => 0,
                     "needs_reconcile_count" => 1,
                     "succeeded_count" => 0
                   }
               }
               |> Map.put("terminal", %{
                 "reason_code" => "hold",
                 "at_unix_ms" => 5_000,
                 "phase_at_terminal" => "capability_effects",
                 "blocked_kind" => "explicit_hold"
               })
             )
  end

  # ---------------------------------------------------------------------------
  # Final bounded status-projection coherence pass: the four public states
  # assert_status/1 still admitted that OperationCore.admit/1 cannot admit and
  # project/1 therefore cannot emit. Each finding gets a direct malformed-status
  # rejection test plus positive boundary tests for every preserved valid case.
  # ---------------------------------------------------------------------------

  defp aborted_reserved(fence_required) do
    outstanding = fence_required
    replaceable = not fence_required

    %{
      base_status()
      | "status" => "aborted_pre_effect",
        "phase" => "reserved",
        "outstanding" => outstanding,
        "replaceable" => replaceable,
        "fence_required" => fence_required
    }
    |> Map.put("terminal", %{
      "reason_code" => "cancel",
      "at_unix_ms" => 5_000,
      "phase_at_terminal" => "reserved",
      "blocked_kind" => nil
    })
  end

  defp aborted_at_phase(phase, fence_required) do
    outstanding = fence_required
    replaceable = not fence_required

    %{
      base_status()
      | "status" => "aborted_pre_effect",
        "phase" => phase,
        "outstanding" => outstanding,
        "replaceable" => replaceable,
        "fence_required" => fence_required
    }
    |> Map.put("terminal", %{
      "reason_code" => "cancel",
      "at_unix_ms" => 5_000,
      "phase_at_terminal" => phase,
      "blocked_kind" => nil
    })
  end

  # Finding 1: a reserved abort has no installed fence and clears
  # fence_required to false. Fenced/prepared aborts and completed receipts
  # genuinely vary (cleanup may or may not be acked), so fence_required stays
  # free there.
  test "assert_status rejects aborted_pre_effect at reserved with fence_required true" do
    reject!("aborted reserved with fence_required true", aborted_reserved(true))

    # Positive boundary: reserved abort must carry fence_required false.
    assert {:ok, _} = Proj.assert_status(aborted_reserved(false))

    # Positive boundary: fenced abort keeps fence_required free (both values).
    assert {:ok, _} = Proj.assert_status(aborted_at_phase("fenced", true))
    assert {:ok, _} = Proj.assert_status(aborted_at_phase("fenced", false))

    # Positive boundary: prepared abort keeps fence_required free (both values).
    assert {:ok, _} = Proj.assert_status(aborted_at_phase("prepared", true))
    assert {:ok, _} = Proj.assert_status(aborted_at_phase("prepared", false))
  end

  # Finding 2: a positive retry attempt is admissible only in a primary outcome
  # phase (a phase-level retry) or at capability_effects (a journal retry bound
  # to the unresolved head). It is never admissible at runtime_quiesced or
  # completed — no reducer can fire a retry there, and completion/acknowledge
  # reset attempt to 0. The primary retryable vocabulary is sourced from
  # OperationCore so the two modules cannot drift.
  test "assert_status rejects positive retry attempt at runtime_quiesced and completed" do
    reject!("attempt>0 at runtime_quiesced", %{
      base_status()
      | "phase" => "runtime_quiesced",
        "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => "timeout"}
    })

    completed_with_retry =
      %{
        base_status()
        | "status" => "completed",
          "phase" => "completed",
          "outstanding" => true,
          "replaceable" => false,
          "fence_required" => true,
          "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => "timeout"}
      }
      |> Map.put("terminal", %{
        "reason_code" => "completed",
        "at_unix_ms" => 5_000,
        "phase_at_terminal" => "completed",
        "blocked_kind" => nil
      })

    reject!("attempt>0 at completed", completed_with_retry)

    # Positive boundary: attempt>0 is valid at every primary outcome phase. The
    # list is the exact core vocabulary; if the core adds/removes a phase the
    # projection must follow.
    for phase <-
          Op.primary_outcome_phases() -- ["capability_effects"] do
      assert {:ok, _} =
               Proj.assert_status(%{
                 base_status()
                 | "phase" => phase,
                   "retry" => %{"attempt" => 1, "max_attempts" => 3, "last_code" => "timeout"}
               }),
             "expected attempt>0 admissible at primary phase #{phase}"
    end

    # And the vocabulary matches the locked set.
    assert Op.primary_outcome_phases() ==
             ~w(reserved fenced prepared deny_all_intent deny_all_installed profile_commit desired_trust verifying runtime_restore)
  end

  defp capability_status(status, attempt, summary) do
    retry = %{"attempt" => attempt, "max_attempts" => 3, "last_code" => retry_code(attempt)}

    base =
      %{base_status() | "phase" => "capability_effects", "retry" => retry}
      |> Map.put("journal_summary", summary)

    if status == "blocked" do
      base
      |> Map.merge(%{
        "status" => "blocked",
        "outstanding" => true,
        "replaceable" => false,
        "fence_required" => true
      })
      |> Map.put("terminal", %{
        "reason_code" => "retry_exhausted",
        "at_unix_ms" => 5_000,
        "phase_at_terminal" => "capability_effects",
        "blocked_kind" => "retry_exhausted"
      })
    else
      base
    end
  end

  defp retry_code(0), do: nil
  defp retry_code(_), do: "timeout"

  # Finding 3: a positive capability retry requires an unresolved journal head
  # (pending or needs_reconcile) to bind last_effect_id to. A capability_effects
  # receipt with attempt>0 but pending_count + needs_reconcile_count == 0 can
  # never be emitted by project/1.
  test "assert_status rejects capability_effects retry without an unresolved journal head" do
    all_succeeded = %{
      "entry_count" => 1,
      "pending_count" => 0,
      "needs_reconcile_count" => 0,
      "succeeded_count" => 1
    }

    reject!(
      "capability attempt>0 with only succeeded entries",
      capability_status("active", 1, all_succeeded)
    )

    empty_journal = %{
      "entry_count" => 0,
      "pending_count" => 0,
      "needs_reconcile_count" => 0,
      "succeeded_count" => 0
    }

    reject!(
      "capability attempt>0 with empty journal",
      capability_status("active", 1, empty_journal)
    )

    # Positive boundary: capability retry bound to a needs_reconcile head.
    needs_head = %{
      "entry_count" => 2,
      "pending_count" => 1,
      "needs_reconcile_count" => 1,
      "succeeded_count" => 0
    }

    assert {:ok, _} = Proj.assert_status(capability_status("active", 1, needs_head))

    # Positive boundary: capability retry after clear-and-replay — the head is
    # pending (reconciliation cleared) but attempt stays > 0.
    pending_head = %{
      "entry_count" => 2,
      "pending_count" => 2,
      "needs_reconcile_count" => 0,
      "succeeded_count" => 0
    }

    assert {:ok, _} = Proj.assert_status(capability_status("active", 1, pending_head))
  end

  # Finding 4: an active capability_effects receipt carrying a needs_reconcile
  # head implies reconciliation_required, which the core only sets after a retry
  # fired (attempt > 0). Blocked receipts are exempt: their admitted private
  # state may retain a needs-reconcile head with reconciliation redacted.
  test "assert_status rejects active capability_effects needs_reconcile head with attempt 0" do
    needs_head = %{
      "entry_count" => 1,
      "pending_count" => 0,
      "needs_reconcile_count" => 1,
      "succeeded_count" => 0
    }

    reject!(
      "active capability needs_reconcile with attempt 0",
      capability_status("active", 0, needs_head)
    )

    # Positive boundary: active with attempt>0 is the only admissible form.
    assert {:ok, _} = Proj.assert_status(capability_status("active", 1, needs_head))

    # Positive boundary: blocked is exempt — a needs-reconcile head with attempt
    # 0 (or any attempt) and reconciliation redacted is admissible there.
    assert {:ok, _} = Proj.assert_status(capability_status("blocked", 0, needs_head))
    assert {:ok, _} = Proj.assert_status(capability_status("blocked", 1, needs_head))

    # Positive boundary: active capability with a pending head (not needs) and
    # attempt 0 is admissible (a fresh plan, no retry yet).
    pending_head = %{
      "entry_count" => 1,
      "pending_count" => 1,
      "needs_reconcile_count" => 0,
      "succeeded_count" => 0
    }

    assert {:ok, _} = Proj.assert_status(capability_status("active", 0, pending_head))
  end
end
