defmodule Arbor.Agent.TemplateAuthorityReconciliationStore do
  @moduledoc false

  # Agent-owned durable record store and linearizable CAS/idempotency boundary
  # for Phase 4C template-authority reconciliation operations (C1B).
  #
  # A thin imperative persistence shell around the pure
  # TemplateAuthorityReconciliationOperationCore reducer. It wraps each
  # operation map in Arbor.Contracts.Persistence.Record, keys every record by
  # its exact target_agent_id, admits every candidate and every persisted
  # payload through the core before use (failing closed on malformed, wrong-key,
  # or wrong-envelope records without replacement), and serializes every
  # mutation through authoritative compare-and-swap fenced on the structured
  # Record generation+revision.
  #
  # The production store name is fixed (:arbor_agent_template_authority_reconciliation,
  # wired in Arbor.Agent.Application). No public/runtime function accepts a
  # caller-selected store, collaborator, backend, PID, or module — authority is
  # a deployment property, never a caller argument.
  #
  # One durable slot per target. Same (target, expected preview digest) is
  # idempotent: it returns the existing operation while outstanding, or the
  # terminal receipt once settled. A different digest cannot replace an
  # outstanding operation; only a core-replaceable terminal record may be
  # replaced through authoritative CAS.
  #
  # The internal compare-and-swap update boundary carries the exact structured
  # Record observed by the caller. Before writing it authoritatively re-fetches
  # the current durable Record and requires the full stable envelope
  # (id/key/data/metadata/generation/revision) to equal the observed snapshot,
  # then submits the caller's ORIGINAL observed Record (its generation+
  # revision) as the expected CAS anchor — never the refetched anchor. Because
  # Record CAS fences on generation+revision only, the envelope precondition
  # also refuses a caller who tampers the observed data while preserving its
  # tokens, and an ABA advance (revision bumped while operation data is
  # restored) still conflicts on the stale observed snapshot.
  #
  # Errors are bounded atoms and redacted. This boundary never logs, signals,
  # or returns caller identity, desired authority, profile CAS anchors,
  # capability IDs, journal payloads, backend records, or backend exception
  # text.

  alias Arbor.Agent.RuntimeRestoreAdmissionClaimCore, as: ClaimCore
  alias Arbor.Agent.TemplateAuthorityReconciliationOperationCore, as: Core
  alias Arbor.Contracts.Persistence.Record
  alias Arbor.Persistence

  # Fixed production store name — wired in Arbor.Agent.Application before
  # TaskStore. Authority is a deployment property; callers cannot select it.
  @store :arbor_agent_template_authority_reconciliation

  # Match the core's target-agent bound: valid UTF-8, at most 256 bytes, then
  # the agent_id grammar. The byte bound is checked before the regex so a
  # pathologically large key never reaches the matcher.
  @max_agent_id_bytes 256
  @agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/

  # A persisted Record's logical id must be a nonempty valid-UTF-8 binary within
  # this fixed byte bound (defense in depth — backends generate rec_ ids well
  # inside it). decode_record/2 enforces it so every authoritative read and
  # outcome-unknown reobservation fails closed on a malformed id.
  @max_record_id_bytes 256

  # Immutable operation identity fields preserved across every in-flight CAS
  # update. The core reducers never change these; the update boundary rejects
  # any next-operation whose identity diverges from the observed snapshot, so a
  # caller can never swap a different operation under an observed CAS anchor.
  @identity_keys ~w(
    operation_id
    target_agent_id
    authorizing_caller_id
    expected_preview_reconciliation_digest
    desired_authority
    scope
    durability
    created_at_unix_ms
  )

  # Bounded re-observation attempts after a CAS conflict on open. Each attempt
  # re-reads authoritative durable state and re-decides; the limit keeps the
  # boundary total under sustained contention instead of looping forever.
  @max_open_attempts 4

  @type operation :: Core.record()

  @type redacted_error ::
          :authority_not_durable
          | :authority_unavailable
          | :backend_unavailable
          | :invalid_record
          | :invalid_request
          | :invalid_candidate
          | :operation_outstanding
          | :cas_conflict
          | :identity_changed
          | :outcome_unknown
          | :restore_claim_protected
          | :claim_settled
          | :stale_claim
          | :claim_not_found
          | :invalid_claim
          | :restore_fence_required
          | :restore_phase_illegal
          | :already_settled
          | :not_found
          | :not_owner
          | :restore_claim_inventory_unavailable

  # -------------------------------------------------------------------------
  # Authority attestation
  # -------------------------------------------------------------------------

  @doc """
  Attest the fixed production store carries an attested `:node_restart` backend.

  Production operation storage protects authority and must never run against
  nil, ephemeral, process-lifetime, application-restart, unknown, or
  unavailable authority. Returns `:ok` only for an attested node-restart
  backend; every other mode fails closed.
  """
  @spec attest_authority() ::
          :ok | {:error, :authority_not_durable | :authority_unavailable}
  def attest_authority do
    case Persistence.buffered_store_authority_mode(@store) do
      {:ok, {:backend, :node_restart}} ->
        :ok

      {:ok, _insufficient} ->
        {:error, :authority_not_durable}

      {:error, _reason} ->
        {:error, :authority_unavailable}

      _other ->
        {:error, :authority_unavailable}
    end
  end

  # -------------------------------------------------------------------------
  # Authoritative fetch (operation-map projection)
  # -------------------------------------------------------------------------

  @doc """
  Authoritatively fetch one operation by exact target_agent_id.

  Returns the operation map (the ordinary projection for C2/C3 seeding). Never
  falls back to cache after a backend failure. Fails closed on a missing,
  malformed, wrong-key, or wrong-envelope record.
  """
  @spec fetch(String.t()) ::
          {:ok, operation()} | {:error, :not_found | redacted_error()}
  def fetch(target_agent_id) do
    with :ok <- attest_authority(),
         :ok <- validate_target(target_agent_id),
         {:ok, record} <- fetch_record(target_agent_id) do
      decode_operation(record, target_agent_id)
    end
  end

  @doc """
  Return the internal validated structured Record snapshot for one target.

  This is the CAS-anchor bridge for the reducer step: it carries the exact
  authoritative generation+revision the caller observed. `fetch/1` stays an
  operation-map projection; `snapshot/1` exposes the fencing envelope that
  `compare_and_swap/2` requires.
  """
  @spec snapshot(String.t()) ::
          {:ok, Record.t()} | {:error, :not_found | redacted_error()}
  def snapshot(target_agent_id) do
    with :ok <- attest_authority(),
         :ok <- validate_target(target_agent_id),
         {:ok, record} <- fetch_record(target_agent_id),
         {:ok, _operation} <- decode_operation(record, target_agent_id) do
      {:ok, record}
    end
  end

  # -------------------------------------------------------------------------
  # Deterministic outstanding-operation inventory (operation-map projection)
  # -------------------------------------------------------------------------

  @doc """
  Deterministic outstanding-operation inventory for C2/C3 startup seeding.

  Reads every record authoritatively, admits each through the core, and
  returns the outstanding operations sorted by target_agent_id. Fails the whole
  inventory on any malformed durable state or backend failure — never falls
  back to cache.
  """
  @spec list_outstanding() :: {:ok, [operation()]} | {:error, redacted_error()}
  def list_outstanding do
    with :ok <- attest_authority(),
         {:ok, keys} <- authoritative_keys(),
         {:ok, records} <- fetch_all(keys),
         {:ok, operations} <- decode_inventory(records) do
      {:ok, operations |> Enum.filter(&Core.outstanding?/1)}
    end
  end

  # -------------------------------------------------------------------------
  # Idempotent open / resume / replace
  # -------------------------------------------------------------------------

  @doc """
  Idempotently open, resume, or replace the operation for one target.

  `facts` is the full `TemplateAuthorityReconciliationOperationCore.new/1`
  input. The target slot is `facts["target_agent_id"]`; the idempotency key is
  `(target, facts["expected_preview_reconciliation_digest"])`.

  - No slot: claim it once via authoritative CAS insert.
  - Outstanding slot, same digest: return the existing operation.
  - Outstanding slot, different digest: fail `:operation_outstanding` (no
    replacement).
  - Settled replaceable terminal, same digest: return the terminal receipt.
  - Settled replaceable terminal, different digest: replace via authoritative
    CAS.

  Admission is linearizable and idempotent: exactly one operation exists per
  target slot. Same (target, digest) always returns the same operation; a
  different digest cannot replace an outstanding operation.
  """
  @spec open(map()) :: {:ok, operation()} | {:error, redacted_error()}
  def open(facts) when is_map(facts) do
    with :ok <- attest_authority() do
      case Core.new(facts) do
        {:ok, candidate, _effects} ->
          target = candidate["target_agent_id"]
          digest = candidate["expected_preview_reconciliation_digest"]

          with :ok <- validate_target(target) do
            do_open(target, digest, candidate, 0)
          end

        {:error, _reason} ->
          # Candidate input rejected by the pure core. No durable state was
          # touched; redact the core vocabulary to a single bounded atom.
          {:error, :invalid_candidate}
      end
    end
  end

  def open(_facts), do: {:error, :invalid_request}

  defp do_open(target, digest, candidate, depth) when depth < @max_open_attempts do
    case fetch_record(target) do
      {:error, :not_found} ->
        attempt_open_insert(target, candidate, depth)

      {:error, _reason} = error ->
        error

      {:ok, record} ->
        with {:ok, existing} <- decode_operation(record, target) do
          cond do
            Core.outstanding?(existing) ->
              if idempotent?(existing, target, digest),
                do: {:ok, existing},
                else: {:error, :operation_outstanding}

            Core.replaceable?(existing) ->
              if idempotent?(existing, target, digest) do
                {:ok, existing}
              else
                attempt_open_replace(target, record, candidate, depth)
              end

            true ->
              # An admissible record is always outstanding or replaceable; any
              # other shape is corrupt durable state. Fail closed, no replace.
              {:error, :invalid_record}
          end
        end
    end
  end

  defp do_open(_target, _digest, _candidate, _depth), do: {:error, :cas_conflict}

  defp idempotent?(operation, target, digest) do
    operation["target_agent_id"] == target and
      operation["expected_preview_reconciliation_digest"] == digest
  end

  defp attempt_open_insert(target, candidate, depth) do
    replacement = replacement_record(target, candidate, nil)

    case acknowledged_cas(target, :not_found, replacement) do
      {:ok, stored} ->
        decode_operation(stored, target)

      {:conflict} ->
        # A concurrent writer won the empty slot. Re-observe the now-filled slot
        # once; the winner may have opened our exact (target, digest).
        reopen_after_conflict(target, candidate, depth)

      {:outcome_unknown} ->
        reconcile_open_insert(target, candidate)

      {:unavailable} ->
        {:error, :backend_unavailable}
    end
  end

  defp attempt_open_replace(target, record, candidate, depth) do
    replacement = replacement_record(target, candidate, record.id)

    case acknowledged_cas(target, {:value, record}, replacement) do
      {:ok, stored} ->
        decode_operation(stored, target)

      {:conflict} ->
        # The terminal record moved (cleanup advanced or a concurrent replacer
        # won). Re-observe and re-decide once before surrendering.
        if depth + 1 < @max_open_attempts do
          do_open(
            target,
            candidate["expected_preview_reconciliation_digest"],
            candidate,
            depth + 1
          )
        else
          {:error, :cas_conflict}
        end

      {:outcome_unknown} ->
        reconcile_open_replace(target, record, replacement)

      {:unavailable} ->
        {:error, :backend_unavailable}
    end
  end

  defp reopen_after_conflict(target, candidate, depth) do
    case fetch_record(target) do
      {:ok, record} ->
        with {:ok, existing} <- decode_operation(record, target) do
          digest = candidate["expected_preview_reconciliation_digest"]

          cond do
            Core.outstanding?(existing) and idempotent?(existing, target, digest) ->
              {:ok, existing}

            Core.replaceable?(existing) and idempotent?(existing, target, digest) ->
              {:ok, existing}

            Core.outstanding?(existing) ->
              {:error, :operation_outstanding}

            Core.replaceable?(existing) ->
              # A concurrent winner settled under a different digest; one more
              # bounded replace attempt, then surrender.
              attempt_open_replace(target, record, candidate, depth + 1)

            true ->
              {:error, :invalid_record}
          end
        end

      {:error, :not_found} ->
        # Slot vanished between the conflicting insert and reobservation — the
        # conflict was not ours to win. Surface conflict, never phantom success.
        {:error, :cas_conflict}

      {:error, _reason} = error ->
        error
    end
  end

  # An acknowledged insert mutation returned outcome_unknown. Re-observe
  # authoritatively: the insert applied iff the slot is a first-generation,
  # first-revision record carrying exactly the candidate. Matching data under a
  # later generation (a delete/reinsert) is NOT proof our insert applied — that
  # remains genuinely ambiguous. No path inserts a second operation: every
  # mutation is a single CAS fenced on one slot.
  defp reconcile_open_insert(target, candidate) do
    # Decode/admit the authoritative backend value BEFORE any Record field
    # access — a plain map, malformed struct, wrong key, invalid fence token,
    # or invalid operation data returns bounded :invalid_record and never
    # raises. The insert applied iff the slot is a first-generation,
    # first-revision record carrying exactly the candidate. Matching data under
    # a later generation (a delete/reinsert) is NOT proof our insert applied —
    # that remains genuinely ambiguous. No path inserts a second operation.
    case fetch_record(target) do
      {:ok, value} ->
        with {:ok, record} <- decode_record(value, target) do
          if record.generation == 1 and record.revision == 1 and
               record.data == candidate do
            {:ok, candidate}
          else
            {:error, :outcome_unknown}
          end
        end

      {:error, :not_found} ->
        {:error, :outcome_unknown}

      {:error, _reason} = error ->
        error
    end
  end

  # An acknowledged terminal-replace mutation returned outcome_unknown. Re-
  # observe authoritatively: the replace applied iff the durable record is the
  # exact successor of the observed terminal anchor: same logical id,
  # generation, physical key, and replacement metadata; revision advanced by
  # exactly one; and data equal to the candidate. A delete/reinsert or
  # concurrent equal-data write with envelope drift remains ambiguous.
  defp reconcile_open_replace(target, anchor, replacement) do
    # Decode the authoritative backend value before any field access (malformed
    # values return bounded :invalid_record, never raise). The replace applied
    # iff the durable record is the exact successor of the observed terminal
    # anchor — same logical id+generation, exact next revision, the same
    # physical key, the replacement metadata, and the candidate data. Matching
    # data under a different generation/key/metadata (a delete/reinsert or a
    # concurrent equal-data write) remains ambiguous.
    case fetch_record(target) do
      {:ok, value} ->
        with {:ok, record} <- decode_record(value, target) do
          if successor_applied?(record, anchor, replacement) do
            {:ok, replacement.data}
          else
            {:error, :outcome_unknown}
          end
        end

      {:error, :not_found} ->
        {:error, :outcome_unknown}

      {:error, _reason} = error ->
        error
    end
  end

  # -------------------------------------------------------------------------
  # Internal compare-and-swap update boundary
  # -------------------------------------------------------------------------

  @doc """
  Internal compare-and-swap update boundary for in-flight reducer application.

  `observed` is the exact structured `%Arbor.Contracts.Persistence.Record{}`
  previously read from the store (obtained via `snapshot/1` or the committed
  Record returned by a prior `compare_and_swap/2`). `next` is the operation map
  produced by applying a core reducer to `observed.data`.

  The boundary first authoritatively re-fetches the current durable Record
  and requires the full stable envelope (id/key/data/metadata/generation/
  revision) to equal the observed snapshot, then submits the caller's ORIGINAL
  observed Record (its generation+revision) as the expected CAS anchor — never
  the refetched anchor. Because Record CAS fences on generation+revision only,
  the envelope precondition refuses a caller who tampers the observed data
  while preserving its tokens, and an ABA advance (revision bumped while
  operation data is restored) still conflicts on the stale observed snapshot.
  The boundary confirms the next operation admits, shares the same target, and
  preserves the immutable operation identity fields, then applies the update
  atomically. The committed Record is returned as the validated snapshot for
  the next reducer step; logical Record identity (id) is preserved across the
  update. Stale writers are reported as `:cas_conflict`.
  """
  @spec compare_and_swap(Record.t(), operation()) ::
          {:ok, Record.t()} | {:error, redacted_error()}
  def compare_and_swap(%Record{} = observed, next) when is_map(next) do
    with :ok <- attest_authority(),
         :ok <- validate_target(observed.key),
         {:ok, observed_op} <- decode_operation(observed, observed.key),
         :ok <- reject_generic_claim_transition(observed_op, next),
         {:ok, next_op} <- admit(next),
         :ok <- reject_generic_claim_transition(observed_op, next_op),
         :ok <- same_target?(observed_op, next_op),
         :ok <- identity_preserved?(observed_op, next_op) do
      target = observed.key
      do_update(target, observed, next_op)
    end
  end

  def compare_and_swap(_observed, _next), do: {:error, :invalid_request}

  # Generic CAS must never create, preserve-and-advance, mutate, settle, or clear
  # a restore-admission claim — including equality-preserving claim copies with
  # phase/status/journal/terminal changes. Dedicated claim APIs only.
  defp reject_generic_claim_transition(observed_op, next_op) do
    claims = [
      Map.get(observed_op, "runtime_restore_admission"),
      Map.get(observed_op, :runtime_restore_admission),
      Map.get(next_op, "runtime_restore_admission"),
      Map.get(next_op, :runtime_restore_admission)
    ]

    if Enum.any?(claims, &ClaimCore.claim_present?/1) do
      {:error, :restore_claim_protected}
    else
      :ok
    end
  end

  # -------------------------------------------------------------------------
  # Dedicated runtime-restore admission claim transitions (C3C1a1)
  # -------------------------------------------------------------------------

  # Hard ceiling for claim inventory projections (fail closed on overflow).
  @max_restore_claim_inventory 256

  @doc """
  Mint or resume a durable runtime-restore admission claim for `target`.

  Requires active operation in phase `runtime_restore` with installed fence.
  Concurrent same-transition CAS conflict reobserves an existing non-settled
  claim (begin idempotency); foreign successors remain conflict/unknown.

  Callers **must** supply the exact expected `operation_id`. It must equal the
  durable operation's `operation_id` (and any existing claim's `operation_id`)
  **before** mint/resume; mismatches fail closed without durable mutation.
  There is no 1-arity / `:from_durable_slot` begin — operation identity is
  always bound at the begin boundary.
  """
  @spec begin_runtime_restore_admission(String.t(), String.t()) ::
          {:ok, operation()} | {:error, redacted_error()}
  def begin_runtime_restore_admission(target_agent_id, expected_operation_id)
      when is_binary(target_agent_id) and is_binary(expected_operation_id) do
    with :ok <- attest_authority(),
         :ok <- validate_target(target_agent_id),
         {:ok, observed} <- snapshot(target_agent_id),
         {:ok, op} <- decode_operation(observed, target_agent_id),
         :ok <- match_expected_operation_id(op, expected_operation_id) do
      case Map.get(op, "runtime_restore_admission") do
        claim when is_map(claim) ->
          resume_existing_begin_claim(op, claim, expected_operation_id)

        nil ->
          with :ok <- require_restore_begin_preconditions(op),
               # Randomness is an imperative-shell fact (CRC): mint here, inject into pure core.
               token = mint_restore_admission_token(),
               at = System.system_time(:millisecond),
               {:ok, claim} <-
                 ClaimCore.mint(
                   %{
                     "operation_id" => op["operation_id"],
                     "target_agent_id" => op["target_agent_id"],
                     "at_unix_ms" => at
                   },
                   token
                 ),
               next = Map.put(op, "runtime_restore_admission", claim) do
            # Begin idempotency: concurrent mint races reobserve any non-settled
            # claim for this op (exact token match optional — first writer wins).
            commit_claim_transition(observed, next, fn durable_op ->
              reobserve_begin_claim_successor(durable_op, expected_operation_id)
            end)
          end

        _ ->
          {:error, :invalid_claim}
      end
    end
  end

  def begin_runtime_restore_admission(_, _), do: {:error, :invalid_request}

  defp match_expected_operation_id(%{"operation_id" => op_id}, expected)
       when is_binary(op_id) and is_binary(expected) do
    if op_id == expected, do: :ok, else: {:error, :not_owner}
  end

  defp match_expected_operation_id(_, _), do: {:error, :invalid_claim}

  defp resume_existing_begin_claim(op, claim, expected_operation_id)
       when is_binary(expected_operation_id) do
    case ClaimCore.admit_claim(claim) do
      {:ok, %{"claim_phase" => "settled"}} ->
        {:error, :claim_settled}

      {:ok, admitted} when is_map(admitted) ->
        case match_claim_operation_id(admitted, op, expected_operation_id) do
          :ok ->
            {:ok, Map.put(op, "runtime_restore_admission", admitted)}

          {:error, _} = err ->
            err
        end

      {:error, _} ->
        {:error, :invalid_claim}
    end
  end

  defp match_claim_operation_id(claim, op, expected) when is_binary(expected) do
    cond do
      claim["operation_id"] != expected ->
        {:error, :not_owner}

      op["operation_id"] != expected ->
        {:error, :not_owner}

      true ->
        :ok
    end
  end

  defp reobserve_begin_claim_successor(durable_op, expected_operation_id) do
    case Map.get(durable_op, "runtime_restore_admission") do
      %{"claim_phase" => "settled"} ->
        {:error, :claim_settled}

      claim when is_map(claim) ->
        case ClaimCore.admit_claim(claim) do
          {:ok, admitted} when is_map(admitted) ->
            if Map.get(admitted, "claim_phase") == "settled" do
              {:error, :claim_settled}
            else
              case match_claim_operation_id(admitted, durable_op, expected_operation_id) do
                :ok ->
                  {:ok, Map.put(durable_op, "runtime_restore_admission", admitted)}

                {:error, _} = err ->
                  err
              end
            end

          {:ok, _} ->
            {:error, :claim_settled}

          {:error, _} ->
            {:error, :invalid_claim}
        end

      nil ->
        {:error, :cas_conflict}

      _ ->
        {:error, :invalid_claim}
    end
  end

  defp require_restore_begin_preconditions(%{
         "status" => "active",
         "phase" => "runtime_restore",
         "fence_state" => %{"installed" => true, "cleanup_acked" => false}
       }),
       do: :ok

  defp require_restore_begin_preconditions(%{"fence_state" => %{"installed" => false}}),
    do: {:error, :restore_fence_required}

  defp require_restore_begin_preconditions(_), do: {:error, :restore_phase_illegal}

  # Shell-owned restore token mint (exact claim grammar). Randomness stays out
  # of RuntimeRestoreAdmissionClaimCore; pure `mint/2` receives the token.
  defp mint_restore_admission_token do
    "rrt_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @doc """
  Bind store-minted intent_id + fingerprint onto the durable claim.

  Accepts minted→bound or exact already-bound only (§2.2). Never reports bind
  success for `outcome_unknown` or settled (not release permission).
  """
  @spec bind_runtime_restore_intent(String.t(), String.t(), String.t()) ::
          {:ok, operation()} | {:error, redacted_error()}
  def bind_runtime_restore_intent(target_agent_id, token, intent_id)
      when is_binary(target_agent_id) and is_binary(token) and is_binary(intent_id) do
    with :ok <- attest_authority(),
         :ok <- validate_target(target_agent_id),
         {:ok, observed} <- snapshot(target_agent_id),
         {:ok, op} <- decode_operation(observed, target_agent_id),
         {:ok, claim} <- require_claim(op),
         true <- claim["token"] == token,
         fingerprint =
           ClaimCore.fingerprint(
             claim["operation_id"],
             claim["target_agent_id"],
             claim["fence_operation_id"],
             token,
             intent_id
           ),
         at = System.system_time(:millisecond),
         {:ok, next_claim} <- ClaimCore.bind_intent(claim, intent_id, fingerprint, at),
         next = Map.put(op, "runtime_restore_admission", next_claim) do
      if claim == next_claim do
        # Exact already-bound idempotency: reobserve durable so concurrent
        # mark/settle between snapshot and return cannot report bind success.
        reobserve_claim_transition(
          target_agent_id,
          fn durable_op ->
            reobserve_bound_claim(durable_op, token, intent_id, fingerprint)
          end,
          :cas_conflict
        )
      else
        commit_claim_transition(observed, next, fn durable_op ->
          reobserve_bound_claim(durable_op, token, intent_id, fingerprint)
        end)
      end
    else
      false -> {:error, :stale_claim}
      {:error, _} = err -> err
      _ -> {:error, :stale_claim}
    end
  end

  def bind_runtime_restore_intent(_, _, _), do: {:error, :invalid_request}

  # Bind CAS/idempotent reobserve: only exact unsettled `bound` is a successful
  # same-transition successor. outcome_unknown/settled are foreign for bind
  # (do not report as bind success — not release permission).
  defp reobserve_bound_claim(durable_op, token, intent_id, fingerprint) do
    case Map.get(durable_op, "runtime_restore_admission") do
      %{
        "token" => ^token,
        "intent_id" => ^intent_id,
        "fingerprint" => ^fingerprint,
        "claim_phase" => "bound",
        "settlement" => nil
      } = c ->
        case ClaimCore.admit_claim(c) do
          {:ok, admitted} when is_map(admitted) ->
            {:ok, Map.put(durable_op, "runtime_restore_admission", admitted)}

          _ ->
            {:error, :invalid_claim}
        end

      %{
        "token" => ^token,
        "claim_phase" => "outcome_unknown"
      } ->
        # Concurrent mark won, or snapshot was already unknown — not bind success.
        {:error, :restore_phase_illegal}

      %{
        "token" => ^token,
        "claim_phase" => "settled"
      } ->
        {:error, :claim_settled}

      %{"token" => ^token} ->
        {:error, :cas_conflict}

      _ ->
        {:error, :cas_conflict}
    end
  end

  @doc "Mark a bound claim outcome_unknown after post-handoff indeterminate observation."
  @spec mark_runtime_restore_outcome_unknown(String.t(), String.t()) ::
          {:ok, operation()} | {:error, redacted_error()}
  def mark_runtime_restore_outcome_unknown(target_agent_id, token)
      when is_binary(target_agent_id) and is_binary(token) do
    with :ok <- attest_authority(),
         :ok <- validate_target(target_agent_id),
         {:ok, observed} <- snapshot(target_agent_id),
         {:ok, op} <- decode_operation(observed, target_agent_id),
         {:ok, claim} <- require_claim(op),
         true <- claim["token"] == token,
         at = System.system_time(:millisecond),
         {:ok, next_claim} <- ClaimCore.mark_outcome_unknown(claim, at),
         next = Map.put(op, "runtime_restore_admission", next_claim) do
      if claim == next_claim do
        {:ok, next}
      else
        commit_claim_transition(observed, next, fn durable_op ->
          reobserve_outcome_unknown_claim(durable_op, token, claim)
        end)
      end
    else
      false -> {:error, :stale_claim}
      {:error, _} = err -> err
      _ -> {:error, :stale_claim}
    end
  end

  def mark_runtime_restore_outcome_unknown(_, _), do: {:error, :invalid_request}

  defp reobserve_outcome_unknown_claim(durable_op, token, prior_claim) do
    prior_intent_id = Map.get(prior_claim, "intent_id")
    prior_fingerprint = Map.get(prior_claim, "fingerprint")

    case Map.get(durable_op, "runtime_restore_admission") do
      %{
        "token" => ^token,
        "claim_phase" => "outcome_unknown",
        "intent_id" => ^prior_intent_id,
        "fingerprint" => ^prior_fingerprint
      } = c ->
        case ClaimCore.admit_claim(c) do
          {:ok, admitted} when is_map(admitted) ->
            {:ok, Map.put(durable_op, "runtime_restore_admission", admitted)}

          _ ->
            {:error, :invalid_claim}
        end

      _ ->
        {:error, :cas_conflict}
    end
  end

  @doc """
  First-settlement-wins durable settle for a restore-admission claim.

  Settlement legality is derived only from durable claim phase (no caller
  handoff flags): `not_applied` only when claim is still `minted`; `applied`
  only with exact bound identity.
  """
  @spec settle_runtime_restore_admission(String.t(), String.t(), map()) ::
          {:ok, operation()} | {:error, redacted_error()}
  def settle_runtime_restore_admission(target_agent_id, token, settlement)
      when is_binary(target_agent_id) and is_binary(token) and is_map(settlement) do
    with :ok <- attest_authority(),
         :ok <- validate_target(target_agent_id),
         {:ok, observed} <- snapshot(target_agent_id),
         {:ok, op} <- decode_operation(observed, target_agent_id),
         {:ok, claim} <- require_claim(op),
         true <- claim["token"] == token,
         {:ok, next_claim} <- ClaimCore.settle(claim, settlement),
         next = Map.put(op, "runtime_restore_admission", next_claim) do
      if claim == next_claim do
        {:ok, next}
      else
        commit_claim_transition(observed, next, fn durable_op ->
          reobserve_settled_claim(durable_op, token, next_claim["settlement"])
        end)
      end
    else
      false -> {:error, :stale_claim}
      {:error, _} = err -> err
      _ -> {:error, :stale_claim}
    end
  end

  def settle_runtime_restore_admission(_, _, _), do: {:error, :invalid_request}

  defp reobserve_settled_claim(durable_op, token, expected_settlement) do
    case Map.get(durable_op, "runtime_restore_admission") do
      %{"token" => ^token, "claim_phase" => "settled", "settlement" => settlement} = c
      when is_map(settlement) ->
        cond do
          # Same outcome+reason: first timestamp/record is the exact logical successor.
          ClaimCore.settlement_same_terminal?(settlement, expected_settlement) ->
            case ClaimCore.admit_claim(c) do
              {:ok, admitted} when is_map(admitted) ->
                {:ok, Map.put(durable_op, "runtime_restore_admission", admitted)}

              _ ->
                {:error, :invalid_claim}
            end

          true ->
            # First settlement wins — different terminal is not our successor.
            {:error, :already_settled}
        end

      %{"token" => ^token} ->
        {:error, :cas_conflict}

      _ ->
        {:error, :cas_conflict}
    end
  end

  @doc """
  Clear a settled restore-admission claim (exact token).

  A **nil** claim does **not** authorize clear — returns `{:error, :not_found}`.
  Only an exact-token claim that satisfies `ClaimCore.clear_precondition?/1`
  (settled) may be cleared.
  """
  @spec clear_runtime_restore_admission(String.t(), String.t()) ::
          {:ok, operation()} | {:error, redacted_error()}
  def clear_runtime_restore_admission(target_agent_id, token)
      when is_binary(target_agent_id) and is_binary(token) do
    with :ok <- attest_authority(),
         :ok <- validate_target(target_agent_id),
         {:ok, observed} <- snapshot(target_agent_id),
         {:ok, op} <- decode_operation(observed, target_agent_id) do
      case Map.get(op, "runtime_restore_admission") do
        nil ->
          # Nil claim cannot authorize clear (not idempotent success).
          {:error, :not_found}

        claim when is_map(claim) ->
          cond do
            claim["token"] != token ->
              {:error, :stale_claim}

            not ClaimCore.clear_precondition?(claim) ->
              {:error, :restore_phase_illegal}

            true ->
              next = Map.put(op, "runtime_restore_admission", nil)

              commit_claim_transition(observed, next, fn durable_op ->
                case Map.get(durable_op, "runtime_restore_admission") do
                  nil ->
                    {:ok, durable_op}

                  %{"token" => ^token} ->
                    {:error, :cas_conflict}

                  _ ->
                    {:error, :cas_conflict}
                end
              end)
          end

        _ ->
          {:error, :invalid_claim}
      end
    end
  end

  def clear_runtime_restore_admission(_, _), do: {:error, :invalid_request}

  @doc """
  Non-settled runtime-restore admission claims across all authoritative slots.

  Inspects every decoded operation slot (not only `outstanding?/1` operations),
  so a non-settled claim on a non-outstanding record is never silently omitted.
  Fails closed on malformed state or inventory overflow.
  """
  @spec list_outstanding_runtime_restore_claims() ::
          {:ok, [map()]} | {:error, redacted_error()}
  def list_outstanding_runtime_restore_claims do
    with :ok <- attest_authority(),
         {:ok, keys} <- authoritative_keys(),
         true <- length(keys) <= @max_restore_claim_inventory,
         {:ok, records} <- fetch_all(keys),
         {:ok, operations} <- decode_inventory(records) do
      operations
      |> Enum.reduce_while({:ok, []}, fn op, {:ok, acc} ->
        if length(acc) >= @max_restore_claim_inventory do
          {:halt, {:error, :restore_claim_inventory_unavailable}}
        else
          case Map.get(op, "runtime_restore_admission") do
            nil ->
              {:cont, {:ok, acc}}

            claim when is_map(claim) ->
              # Full operation admit already ran in decode_inventory (claim vs op).
              case ClaimCore.admit_claim(claim) do
                {:ok, %{"claim_phase" => "settled"}} ->
                  {:cont, {:ok, acc}}

                {:ok, admitted} when is_map(admitted) ->
                  {:cont, {:ok, [project_claim(admitted) | acc]}}

                {:error, _} ->
                  {:halt, {:error, :restore_claim_inventory_unavailable}}
              end

            _ ->
              {:halt, {:error, :restore_claim_inventory_unavailable}}
          end
        end
      end)
      |> case do
        {:ok, list} ->
          {:ok,
           list
           |> Enum.reverse()
           |> Enum.sort_by(& &1["target_agent_id"])}

        {:error, _} = err ->
          err
      end
    else
      false ->
        {:error, :restore_claim_inventory_unavailable}

      {:error, _} = err ->
        case err do
          {:error, :authority_not_durable} = e -> e
          {:error, :authority_unavailable} = e -> e
          _ -> {:error, :restore_claim_inventory_unavailable}
        end
    end
  end

  defp project_claim(claim) do
    %{
      "operation_id" => claim["operation_id"],
      "target_agent_id" => claim["target_agent_id"],
      "token" => claim["token"],
      "intent_id" => claim["intent_id"],
      "fingerprint" => claim["fingerprint"],
      "claim_phase" => claim["claim_phase"],
      "fence_operation_id" => claim["fence_operation_id"]
    }
  end

  defp require_claim(op) do
    case Map.get(op, "runtime_restore_admission") do
      nil ->
        {:error, :claim_not_found}

      claim when is_map(claim) ->
        case ClaimCore.admit_claim(claim) do
          {:ok, admitted} when is_map(admitted) -> {:ok, admitted}
          {:error, _} -> {:error, :invalid_claim}
        end

      _ ->
        {:error, :invalid_claim}
    end
  end

  # Commit a dedicated claim transition. On success return the admitted durable
  # operation. On cas_conflict/outcome_unknown, reobserve via `accept_fn` so
  # concurrent same-transition successors are idempotent; foreign successors
  # remain conflict/unknown.
  defp commit_claim_transition(%Record{} = observed, next_op, accept_fn)
       when is_map(next_op) and is_function(accept_fn, 1) do
    target = observed.key

    case claim_cas(observed, next_op) do
      {:ok, %Record{} = stored} ->
        case decode_operation(stored, target) do
          {:ok, op} -> {:ok, op}
          {:error, _} = err -> err
        end

      {:error, reason} when reason in [:cas_conflict, :outcome_unknown] ->
        reobserve_claim_transition(target, accept_fn, reason)

      {:error, _} = err ->
        err
    end
  end

  defp reobserve_claim_transition(target, accept_fn, original_reason) do
    case fetch_record(target) do
      {:ok, record} ->
        case decode_operation(record, target) do
          {:ok, op} ->
            case accept_fn.(op) do
              {:ok, _} = ok -> ok
              {:error, _} = err -> err
            end

          {:error, _} ->
            {:error, original_reason}
        end

      {:error, :not_found} ->
        {:error, original_reason}

      {:error, _} = err ->
        err
    end
  end

  # Dedicated claim CAS — bypasses generic claim protection by design.
  defp claim_cas(%Record{} = observed, next_op) when is_map(next_op) do
    with :ok <- validate_target(observed.key),
         {:ok, observed_op} <- decode_operation(observed, observed.key),
         {:ok, next} <- admit(next_op),
         :ok <- same_target?(observed_op, next),
         :ok <- identity_preserved?(observed_op, next) do
      do_update(observed.key, observed, next)
    end
  end

  defp do_update(target, observed, next_op) do
    # Record CAS fences on generation+revision only, so first authoritatively
    # re-fetch the current durable Record and require the full stable envelope
    # (id/key/data/metadata/generation/revision) to equal the caller's observed
    # snapshot. This refuses any drift since observation — including a caller
    # who tampered the observed data while preserving its tokens to smuggle a
    # different operation under a stolen anchor. Only then does the CAS run,
    # against the caller's ORIGINAL observed Record (never the refetched
    # anchor).
    case fetch_record(target) do
      {:ok, current} ->
        with {:ok, _current_op} <- decode_operation(current, target) do
          if envelope_stable?(current, observed) do
            apply_observed_cas(target, observed, next_op)
          else
            {:error, :cas_conflict}
          end
        end

      {:error, :not_found} ->
        # The slot vanished — the observed snapshot is no longer anchored.
        {:error, :cas_conflict}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_observed_cas(target, observed, next_op) do
    replacement = replacement_record(target, next_op, observed.id)

    case acknowledged_cas(target, {:value, observed}, replacement) do
      {:ok, stored} ->
        # Defense in depth: the backend-returned record must still admit and
        # carry the expected physical key before it is handed back as the next
        # reducer-step snapshot.
        case decode_operation(stored, target) do
          {:ok, _operation} -> {:ok, stored}
          {:error, _reason} = error -> error
        end

      {:conflict} ->
        {:error, :cas_conflict}

      {:outcome_unknown} ->
        reconcile_update(target, observed, replacement)

      {:unavailable} ->
        {:error, :backend_unavailable}
    end
  end

  # The durable envelope is stable since observation iff every fencing-relevant
  # field of the current authoritative Record equals the caller's observed
  # snapshot. Record CAS compares generation+revision only; this full-envelope
  # precondition refuses any concurrent drift (including a tampered observed
  # data blob presented under preserved tokens) before the CAS is attempted.
  defp envelope_stable?(current, observed) do
    current.id == observed.id and
      current.key == observed.key and
      current.data == observed.data and
      current.metadata == observed.metadata and
      current.generation == observed.generation and
      current.revision == observed.revision
  end

  defp reconcile_update(target, observed, replacement) do
    # An acknowledged update mutation returned outcome_unknown. Decode the
    # authoritative backend value before any field access (malformed values
    # return bounded :invalid_record, never raise). Accept success ONLY for the
    # exact successor of the observed anchor: same logical id+generation, exact
    # next revision, the same physical key, the replacement metadata, and the
    # attempted operation data. Matching data under a different
    # generation/key/metadata (a delete/reinsert or a concurrent equal-data
    # write with different metadata) is NOT proof our update applied — that
    # remains genuinely ambiguous. Never create a second operation.
    case fetch_record(target) do
      {:ok, value} ->
        with {:ok, record} <- decode_record(value, target) do
          if successor_applied?(record, observed, replacement) do
            {:ok, record}
          else
            {:error, :outcome_unknown}
          end
        end

      {:error, :not_found} ->
        {:error, :outcome_unknown}

      {:error, _reason} = error ->
        error
    end
  end

  # An acknowledged anchored mutation applied iff the durable record is the
  # exact successor of the observed anchor: same logical id, same generation,
  # revision bumped by exactly one, the same physical key, the replacement
  # metadata, and the attempted operation data. Matching data under a different
  # generation/key/metadata (a delete/reinsert or a concurrent equal-data write
  # with different metadata) does NOT count — that remains genuinely ambiguous
  # and is reported as :outcome_unknown.
  defp successor_applied?(record, anchor, replacement) do
    record.id == anchor.id and
      record.key == replacement.key and
      record.generation == anchor.generation and
      record.revision == anchor.revision + 1 and
      record.data == replacement.data and
      record.metadata == replacement.metadata
  end

  # -------------------------------------------------------------------------
  # Acknowledged CAS wrapper (normalizes BufferedStore outcomes)
  # -------------------------------------------------------------------------

  defp acknowledged_cas(key, expected, replacement) do
    result =
      Persistence.buffered_store_acknowledged_compare_and_swap(
        @store,
        key,
        expected,
        replacement
      )

    case result do
      {:ok, stored} -> {:ok, stored}
      {:error, :conflict} -> {:conflict}
      {:error, :key_mismatch} -> {:conflict}
      {:error, :outcome_unknown} -> {:outcome_unknown}
      {:error, _reason} -> {:unavailable}
    end
  end

  # -------------------------------------------------------------------------
  # Authoritative read helpers
  # -------------------------------------------------------------------------

  defp fetch_record(target) do
    case Persistence.buffered_store_authoritative_get(@store, target) do
      {:ok, record} -> {:ok, record}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :invalid_backend_record} -> {:error, :invalid_record}
      {:error, :invalid_backend_response} -> {:error, :invalid_record}
      {:error, _reason} -> {:error, :backend_unavailable}
    end
  end

  defp authoritative_keys do
    case Persistence.buffered_store_authoritative_list(@store) do
      {:ok, keys} -> {:ok, keys}
      {:error, :inventory_limit_exceeded} -> {:error, :backend_unavailable}
      {:error, :invalid_backend_response} -> {:error, :invalid_record}
      {:error, _reason} -> {:error, :backend_unavailable}
    end
  end

  defp fetch_all(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case fetch_record(key) do
        {:ok, record} -> {:cont, {:ok, [{key, record} | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # -------------------------------------------------------------------------
  # Record / operation decoding
  # -------------------------------------------------------------------------

  # Validate the complete required persisted Record envelope of an authoritative
  # backend value and return the admitted Record. Fails closed (:invalid_record)
  # — never raises — on plain maps, malformed structs, a
  # missing/empty/oversized/non-UTF-8/non-binary logical id, non-map metadata,
  # malformed non-nil timestamps, wrong keys, invalid/nonpositive fence tokens,
  # or invalid operation data.
  # A persisted Record must carry a nonempty valid-UTF-8 logical id within the
  # 256-byte bound, map metadata, and positive integer generation+revision (the
  # backend stamps both to 1 on insert and advances them); generation/revision 0
  # or nil marks an unpersisted envelope. Timestamps are optional, but each
  # non-nil value must be a DateTime struct. Outcome-unknown reobservation uses
  # this so no Record field is read before the envelope is admitted.
  defp decode_record(
         %Record{
           id: id,
           key: key,
           data: data,
           metadata: metadata,
           generation: gen,
           revision: rev,
           inserted_at: inserted_at,
           updated_at: updated_at
         } = record,
         target
       )
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_record_id_bytes and
              is_map(data) and is_map(metadata) and is_integer(gen) and gen >= 1 and
              is_integer(rev) and rev >= 1 do
    with true <- valid_optional_timestamp?(inserted_at),
         true <- valid_optional_timestamp?(updated_at),
         true <- String.valid?(id),
         true <- key == target,
         {:ok, operation} <- Core.admit(data),
         true <- operation["target_agent_id"] == target do
      {:ok, record}
    else
      _ -> {:error, :invalid_record}
    end
  end

  defp decode_record(_value, _target), do: {:error, :invalid_record}

  defp valid_optional_timestamp?(nil), do: true
  defp valid_optional_timestamp?(%DateTime{}), do: true
  defp valid_optional_timestamp?(_value), do: false

  # Admit a persisted or caller payload through the pure core, returning the
  # operation map. Shares decode_record/2's full-envelope validation, so the
  # same fail-closed contract applies (never repairs or replaces in place).
  defp decode_operation(record, target) do
    case decode_record(record, target) do
      {:ok, %Record{data: data}} -> {:ok, data}
      {:error, _reason} = error -> error
    end
  end

  defp admit(value) do
    case Core.admit(value) do
      {:ok, _operation} = ok -> ok
      {:error, _reason} -> {:error, :invalid_record}
    end
  end

  defp decode_inventory(entries) do
    # Dedup by target_agent_id: one physical slot per target is an invariant; a
    # duplicate means corrupt durable state. Sort by target for determinism.
    # The inventory key (not record.key) is the decode target so a plain-map or
    # wrong-envelope backend value fails closed instead of raising on .key.
    entries
    |> Enum.reduce_while({:ok, %{}}, fn {key, record}, {:ok, seen} ->
      case decode_operation(record, key) do
        {:ok, operation} ->
          target = operation["target_agent_id"]

          if Map.has_key?(seen, target) do
            {:halt, {:error, :invalid_record}}
          else
            {:cont, {:ok, Map.put(seen, target, operation)}}
          end

        {:error, _reason} ->
          {:halt, {:error, :invalid_record}}
      end
    end)
    |> case do
      {:ok, map} ->
        operations =
          map
          |> Map.to_list()
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        {:ok, operations}

      {:error, _reason} = error ->
        error
    end
  end

  # -------------------------------------------------------------------------
  # Record construction & validation
  # -------------------------------------------------------------------------

  # A fresh insert takes a fresh logical id; an update preserves the observed
  # record's logical id (backends also preserve id on update, so passing it is
  # belt-and-suspenders). The physical key is always the exact target.
  defp replacement_record(target, operation, nil) do
    Record.new(target, operation)
  end

  defp replacement_record(target, operation, observed_id) do
    Record.new(target, operation, id: observed_id)
  end

  defp validate_target(target) when is_binary(target) do
    cond do
      # byte_size is O(1); check it before the O(n) UTF-8 scan so a
      # pathologically large key never reaches String.valid?/1.
      byte_size(target) > @max_agent_id_bytes ->
        {:error, :invalid_request}

      not String.valid?(target) ->
        {:error, :invalid_request}

      not Regex.match?(@agent_id_re, target) ->
        {:error, :invalid_request}

      true ->
        :ok
    end
  end

  defp validate_target(_target), do: {:error, :invalid_request}

  defp same_target?(observed_op, next_op) do
    target = observed_op["target_agent_id"]

    if is_binary(target) and target == next_op["target_agent_id"] do
      :ok
    else
      {:error, :invalid_request}
    end
  end

  defp identity_preserved?(observed_op, next_op) do
    if Enum.all?(@identity_keys, fn key -> observed_op[key] == next_op[key] end) do
      :ok
    else
      {:error, :identity_changed}
    end
  end
end
