defmodule Arbor.Agent.Eval.SecurityReview.Manifest do
  @moduledoc """
  Seed manifest for the Security Sentinel **L2 deep-review eval** corpus
  (Phase 0). Each item names a real fix commit; `Corpus` reconstructs the buggy
  "before" snapshot (`git show <commit>^:<path>`) and the fixed "after" snapshot
  (`git show <commit>:<path>`) so we can measure whether a reviewer (model ×
  strategy, or an agentic coding agent) re-finds the bug.

  ## Item shape

      %{
        id:         "kebab id, unique",
        category:   a Finding category atom (see @valid_categories),
        fix_commit: "the commit that FIXED the bug (its parent has the bug)",
        paths:      ["repo-relative file(s) the bug lives in"],
        invariant:  "the security invariant the buggy code violated",
        cross_file: bool — true when the bug is only visible across >1 file
                     (the per-file vs whole-subsystem discriminator),
        expected:   %{note: "what a reviewer should flag"},
        verified:   bool — has a human confirmed the before-state genuinely
                     exhibits the smell? Commit messages that say "close
                     fail-open"/"over-match" are high-confidence; others need a
                     read before flipping this true. Curation is incremental.
      }

  Categories mirror `Arbor.Actions.Security.DiffFindings`'s closed vocabulary so
  the eval's recall-matching can compare a reviewer's reported category to the
  label. Kept as bare atoms here to keep the corpus generator dependency-light.
  """

  @valid_categories ~w(
    fail_open_authz crypto_weakness capability_overmatch serialization_drop
    missing_regression_test unsafe_atom config_fail_open unregistered_uri
    dependency_risk path_traversal secret_exposure injection other
  )a

  @doc "The closed Finding-category vocabulary the corpus labels draw from."
  @spec valid_categories() :: [atom()]
  def valid_categories, do: @valid_categories

  @doc """
  Seed corpus items. High-confidence "close fail-open / over-match" commits, a
  mix of single-file and cross-file across two categories. Expand over time
  (crypto C1/C4/C9/C11, capability C8, config M3, unsafe_atom, the gateway/ai/
  engine fail-open closures) — keeping `verified` honest.
  """
  @spec items() :: [map()]
  def items do
    [
      %{
        id: "taint-check-fail-open",
        category: :fail_open_authz,
        fix_commit: "08bc8aba",
        paths: ["apps/arbor_orchestrator/lib/arbor/orchestrator/middleware/taint_check.ex"],
        invariant:
          "The taint-check middleware must FAIL CLOSED — when taint evaluation " <>
            "errors or a level is absent, deny/quarantine, never allow through.",
        cross_file: false,
        expected: %{note: "a gate path that allows the node when taint is unknown/errored"},
        verified: true,
        difficulty: :easy
      },
      %{
        id: "trust-uri-prefix-overmatch",
        category: :capability_overmatch,
        fix_commit: "50a37699",
        paths: [
          "apps/arbor_trust/lib/arbor/trust/authority.ex",
          "apps/arbor_trust/lib/arbor/trust/profile_resolver.ex"
        ],
        invariant:
          "Capability URI prefix matching must respect path boundaries — " <>
            "`arbor://fs/` must NOT match `arbor://fs-other/` (substring over-match).",
        cross_file: true,
        expected: %{
          note:
            "prefix matching by raw String.starts_with?/contains? without a boundary " <>
              "check, shared between the resolver and the ceiling logic"
        },
        verified: true,
        difficulty: :medium
      },
      %{
        id: "engine-resume-provenance-fail-open",
        category: :fail_open_authz,
        fix_commit: "343f7079",
        paths: [
          "apps/arbor_orchestrator/lib/arbor/orchestrator/engine/checkpoint.ex",
          "apps/arbor_orchestrator/lib/arbor/orchestrator/engine/context.ex"
        ],
        invariant:
          "Taint provenance must persist across checkpoint/resume — on resume, " <>
            "previously-tainted data must not be treated as clean (fail-open at the boundary).",
        cross_file: true,
        expected: %{note: "checkpoint serialization that drops taint/provenance, lost on resume"},
        verified: true,
        difficulty: :medium
      },

      # --- HARD tier (2026-06-19): semantic/crypto/cross-file, to break the recall
      # ceiling and discriminate the strong models. All verified clean exhibits. ---
      %{
        id: "session-token-deserialize-before-verify",
        category: :crypto_weakness,
        fix_commit: "5db34585",
        paths: ["apps/arbor_security/lib/arbor/security/session_token.ex"],
        invariant:
          "A token's MAC must be verified BEFORE its payload is deserialized — " <>
            "never run binary_to_term on unverified, attacker-controlled bytes.",
        cross_file: false,
        expected: %{
          note:
            "decode/deserialize (binary_to_term) happens before signature/MAC verification " <>
              "— unsafe deserialization of unverified bytes (MAC-then-decrypt ordering)"
        },
        verified: true,
        difficulty: :hard
      },
      %{
        id: "ed25519-wrong-digest-mode",
        category: :crypto_weakness,
        fix_commit: "58c6b68d",
        paths: ["apps/arbor_security/lib/arbor/security/crypto.ex"],
        invariant:
          "Pure Ed25519 signing/verification must use the :none digest (RFC 8032 hashes " <>
            "internally); :sha512 risks prehash semantics + breaks standard-verifier interop.",
        cross_file: false,
        expected: %{
          note: ":crypto.sign/verify(:eddsa, :sha512, ...) instead of :none for pure Ed25519"
        },
        verified: true,
        difficulty: :hard
      },
      %{
        id: "capability-unsigned-field-forgeable",
        category: :serialization_drop,
        fix_commit: "875f9417",
        paths: ["apps/arbor_contracts/lib/arbor/contracts/security/capability.ex"],
        invariant:
          "Every security-relevant field the authorizer reads must be in the signed " <>
            "payload — an unsigned field (e.g. metadata.provenance) is forgeable.",
        cross_file: true,
        expected: %{
          note:
            "signing_payload excludes fields the authorizer trusts (metadata/principal_scope/" <>
              "allowed_delegatees), so they can be added/altered without invalidating the signature"
        },
        verified: true,
        difficulty: :hard
      },
      %{
        id: "delegate-constraint-widening",
        category: :capability_overmatch,
        fix_commit: "bfa68148",
        paths: ["apps/arbor_contracts/lib/arbor/contracts/security/capability.ex"],
        invariant:
          "A delegated capability must stay within its parent's envelope — the child's " <>
            "URI + constraints must be a subset; widening must be rejected.",
        cross_file: false,
        expected: %{
          note:
            "delegate/3 does not verify the child capability is a subset of the parent " <>
              "(no envelope/uri_subset? check) — allows URI/constraint widening (privilege escalation)"
        },
        verified: true,
        difficulty: :hard
      }
    ]
  end
end
