defmodule Arbor.Agent.TemplateAuthorityReconciliationOperationCore do
  @moduledoc false

  # Pure CRC reducer for one Phase 4C template-authority reconciliation
  # operation record. Emits effects as closed JSON maps; never performs IO,
  # time, randomness, logging, process calls, or authority mutation.

  alias Arbor.Agent.ProfileAuthorityMutationCore
  alias Arbor.Agent.TemplateAuthorityCapabilityProjection
  alias Arbor.Agent.TemplateAuthorityPolicy

  @version 3
  @kind "template_authority_reconciliation_operation"

  @phases ~w(
    reserved
    fenced
    prepared
    deny_all_intent
    deny_all_installed
    runtime_quiesced
    capability_effects
    profile_commit
    desired_trust
    verifying
    runtime_restore
    completed
  )

  @phase_index @phases |> Enum.with_index() |> Map.new()

  @statuses ~w(active completed aborted_pre_effect blocked)
  @abortable_phases ~w(reserved fenced prepared)
  @blocked_kinds ~w(retry_exhausted non_retryable_conflict explicit_hold)
  @primary_outcome_phases ~w(
    reserved
    fenced
    prepared
    deny_all_intent
    deny_all_installed
    profile_commit
    desired_trust
    verifying
    runtime_restore
  )
  @pre_runtime_phases ~w(
    reserved
    fenced
    prepared
    deny_all_intent
    deny_all_installed
  )
  @post_runtime_phases ~w(
    runtime_quiesced
    capability_effects
    profile_commit
    desired_trust
    verifying
    runtime_restore
    completed
  )

  @journal_effect_types MapSet.new(~w(revoke_managed_capability grant_managed_capability))
  @journal_states MapSet.new(~w(pending needs_reconcile succeeded))

  @record_keys MapSet.new([
                 "version",
                 "kind",
                 "operation_id",
                 "target_agent_id",
                 "authorizing_caller_id",
                 "expected_preview_reconciliation_digest",
                 "desired_authority",
                 "scope",
                 "durability",
                 "phase",
                 "status",
                 "runtime_was_running",
                 "profile_cas",
                 "frozen_authority",
                 "profile_mutation_replay",
                 "reconciliation_required",
                 "retry",
                 "journal",
                 "terminal",
                 "fence_state",
                 "created_at_unix_ms",
                 "updated_at_unix_ms"
               ])

  @retry_keys MapSet.new(["attempt", "max_attempts", "last_code", "last_effect_id"])
  @fence_keys MapSet.new(["required", "installed", "cleanup_acked"])
  @journal_keys MapSet.new(["version", "entries"])
  @desired_keys MapSet.new(["envelope", "declaration_digest", "provenance"])
  @desired_input_keys MapSet.new(["envelope", "declaration_digest", "provenance"])
  @provenance_keys MapSet.new(["name", "layer"])
  @terminal_keys MapSet.new(["reason_code", "at_unix_ms", "phase_at_terminal", "blocked_kind"])
  @profile_cas_keys MapSet.new(["record_id", "generation", "revision"])
  @frozen_authority_keys MapSet.new(["repo_root", "effective_capabilities"])
  @reconciliation_keys MapSet.new(["phase", "effect_id"])
  @entry_keys MapSet.new([
                "effect_id",
                "seq",
                "effect_type",
                "state",
                "payload",
                "acked_at_unix_ms"
              ])
  @revoke_payload_keys MapSet.new(["capability_id", "resource"])
  @grant_payload_keys MapSet.new(["resource", "constraints", "provenance"])
  @grant_provenance_keys MapSet.new(["source", "version", "template", "template_digest"])
  @grant_plan_payload_keys MapSet.new(["resource", "constraints", "provenance"])
  @revoke_plan_payload_keys MapSet.new(["capability_id", "resource"])

  @new_fact_keys MapSet.new([
                   "operation_id",
                   "target_agent_id",
                   "authorizing_caller_id",
                   "expected_preview_reconciliation_digest",
                   "desired_authority",
                   "scope",
                   "durability",
                   "created_at_unix_ms",
                   "retry"
                 ])
  # Phase-specific acknowledge keysets: profile_cas + frozen_authority are only
  # admissible for the fenced→prepared transition, runtime_was_running only for
  # deny_all_installed. Supplying them in unrelated phases is rejected rather
  # than silently ignored.
  @ack_base_keys MapSet.new(["phase_intent", "at_unix_ms"])
  @ack_fenced_keys MapSet.new([
                     "phase_intent",
                     "at_unix_ms",
                     "profile_cas",
                     "frozen_authority",
                     "profile_mutation_replay"
                   ])
  @ack_deny_installed_keys MapSet.new(["phase_intent", "at_unix_ms", "runtime_was_running"])
  @prepare_fact_keys MapSet.new([
                       "at_unix_ms",
                       "profile_cas",
                       "frozen_authority",
                       "profile_mutation_replay"
                     ])
  @plan_fact_keys MapSet.new(["at_unix_ms", "entries"])
  @effect_ack_fact_keys MapSet.new(["effect_id", "at_unix_ms"])
  @effect_outcome_fact_keys MapSet.new(["effect_id", "outcome", "reason_code", "at_unix_ms"])
  @outcome_fact_keys MapSet.new(["phase_intent", "outcome", "reason_code", "at_unix_ms"])
  @abort_fact_keys MapSet.new(["reason_code", "at_unix_ms"])
  @hold_fact_keys MapSet.new(["reason_code", "at_unix_ms"])
  @cleanup_fact_keys MapSet.new(["at_unix_ms"])
  @note_retry_fact_keys MapSet.new(["at_unix_ms", "reason_code", "effect_id"])
  @clear_reconcile_fact_keys MapSet.new(["at_unix_ms"])
  @plan_entry_keys MapSet.new(["effect_id", "effect_type", "payload"])
  # Fresh new/1 retry input may configure max_attempts only; attempt and the
  # last_* fields are always constructed fresh (attempt=0, nil last fields).
  @retry_input_keys MapSet.new(["max_attempts"])

  @max_operation_id_bytes 128
  @max_agent_id_bytes 256
  @max_effect_id_bytes 128
  @max_capability_id_bytes 128
  @max_reason_bytes 64
  @max_template_name_bytes 256
  @max_profile_record_id_bytes 128
  @max_journal_entries 256
  @max_retry 10_000
  @max_json_safe_integer 9_007_199_254_740_991
  @max_json_nodes 4_096
  @max_depth 12
  @max_map_keys 128
  @max_list_len 256
  @max_string_bytes 1_024
  @max_input_string_bytes 65_536

  @operation_id_re ~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
  @agent_id_re ~r/\Aagent_[A-Za-z0-9_-]+\z/
  @digest_re ~r/\A[0-9a-f]{64}\z/
  @reason_code_re ~r/\A[a-z][a-z0-9_]*\z/
  @provenance_layers MapSet.new(~w(user shipped legacy_json))

  @type json_scalar :: String.t() | number() | boolean() | nil
  @type json_value :: json_scalar() | [json_value()] | %{optional(String.t()) => json_value()}
  @type record :: %{optional(String.t()) => json_value()}
  @type effect :: %{optional(String.t()) => json_value()}

  # ---------------------------------------------------------------------------
  # Construct
  # ---------------------------------------------------------------------------

  @spec new(map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def new(facts) when is_map(facts) do
    with {:ok, facts} <- admit_event_facts(facts, @new_fact_keys),
         {:ok, operation_id} <-
           require_id(facts, "operation_id", @max_operation_id_bytes, @operation_id_re),
         {:ok, target_agent_id} <-
           require_id(facts, "target_agent_id", @max_agent_id_bytes, @agent_id_re),
         {:ok, authorizing_caller_id} <-
           require_id(facts, "authorizing_caller_id", @max_agent_id_bytes, @agent_id_re),
         {:ok, digest} <- require_digest(facts, "expected_preview_reconciliation_digest"),
         {:ok, desired} <- admit_desired_authority(Map.get(facts, "desired_authority")),
         {:ok, scope} <- require_exact(facts, "scope", "local_owner", :scope_invalid),
         {:ok, durability} <-
           require_exact(facts, "durability", "node_restart", :durability_invalid),
         {:ok, created_at} <- require_time(facts, "created_at_unix_ms"),
         {:ok, retry} <- admit_retry(Map.get(facts, "retry")) do
      record = %{
        "version" => @version,
        "kind" => @kind,
        "operation_id" => operation_id,
        "target_agent_id" => target_agent_id,
        "authorizing_caller_id" => authorizing_caller_id,
        "expected_preview_reconciliation_digest" => digest,
        "desired_authority" => desired,
        "scope" => scope,
        "durability" => durability,
        "phase" => "reserved",
        "status" => "active",
        "runtime_was_running" => nil,
        "profile_cas" => nil,
        "frozen_authority" => nil,
        "profile_mutation_replay" => nil,
        "reconciliation_required" => nil,
        "retry" => retry,
        "journal" => empty_journal(),
        "terminal" => nil,
        "fence_state" => %{
          "required" => true,
          "installed" => false,
          "cleanup_acked" => false
        },
        "created_at_unix_ms" => created_at,
        "updated_at_unix_ms" => created_at
      }

      finish(record, &next_effects/1)
    end
  end

  def new(_), do: error(:invalid_new_input)

  # ---------------------------------------------------------------------------
  # Admit / predicates / derived effects
  # ---------------------------------------------------------------------------

  @spec admit(term()) :: {:ok, record()} | {:error, term()}
  def admit(record) when is_map(record) do
    with {:ok, record} <- normalize_string_keyed_map(record),
         :ok <- validate_record(record),
         :ok <- assert_json_clean(record) do
      {:ok, record}
    end
  end

  def admit(_), do: error(:invalid_record)

  @spec outstanding?(record()) :: boolean()
  def outstanding?(%{"status" => status}) when status in ~w(active blocked), do: true

  def outstanding?(%{"status" => status} = record)
      when status in ~w(completed aborted_pre_effect) do
    fence_required?(record)
  end

  def outstanding?(_), do: false

  @spec fence_required?(record()) :: boolean()
  def fence_required?(%{"fence_state" => %{"required" => true}}), do: true
  def fence_required?(_), do: false

  @spec replaceable?(record()) :: boolean()
  def replaceable?(%{"status" => status} = record)
      when status in ~w(completed aborted_pre_effect) do
    not fence_required?(record)
  end

  def replaceable?(_), do: false

  @spec next_effects(record()) :: [effect()]
  def next_effects(%{"status" => "active", "reconciliation_required" => recon} = record)
      when is_map(recon) do
    [reobserve_effect(record, recon["effect_id"])]
  end

  def next_effects(%{"status" => "active"} = record) do
    case journal_head(record) do
      %{"state" => "needs_reconcile"} = entry ->
        [reobserve_effect(record, entry["effect_id"])]

      _ ->
        primary_next_effects(record)
    end
  end

  def next_effects(_), do: []

  @spec cleanup_effects(record()) :: [effect()]
  def cleanup_effects(
        %{
          "status" => status,
          "fence_state" => %{
            "required" => true,
            "installed" => true,
            "cleanup_acked" => false
          }
        } = record
      )
      when status in ~w(completed aborted_pre_effect) do
    [remove_fence_effect(record)]
  end

  def cleanup_effects(_), do: []

  @spec version() :: pos_integer()
  def version, do: @version

  @spec kind() :: String.t()
  def kind, do: @kind

  @spec phases() :: [String.t()]
  def phases, do: @phases

  # Bounded vocabulary accessors exported so the status projection can source the
  # exact phase/status/kind sets the core admits, preventing validation-vocabulary
  # drift between the two modules without crossing the four-file boundary or
  # introducing a generic abstraction. Numeric bounds and ID grammars stay local.
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec abortable_phases() :: [String.t()]
  def abortable_phases, do: @abortable_phases

  @spec blocked_kinds() :: [String.t()]
  def blocked_kinds, do: @blocked_kinds

  # The primary retryable phase vocabulary: the exact phase set in which a
  # positive retry attempt is admissible as a phase-level retry (no journal
  # binding). capability_effects is deliberately excluded here because it is a
  # journal retry bound to the unresolved head, not a primary phase retry. The
  # status projection sources this list so the two modules cannot drift on
  # which phases permit attempt > 0.
  @spec primary_outcome_phases() :: [String.t()]
  def primary_outcome_phases, do: @primary_outcome_phases

  # ---------------------------------------------------------------------------
  # Reduce — acknowledge phase success
  # ---------------------------------------------------------------------------

  @spec acknowledge(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def acknowledge(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         {:ok, raw} <- normalize_string_keyed_map(facts),
         {:ok, phase_intent} <- require_string(raw, "phase_intent"),
         :ok <- require_phase_intent(record, phase_intent),
         {:ok, allowed} <- ack_keyset_for(phase_intent),
         :ok <- allow_only_keys(raw, allowed),
         {:ok, at} <- require_time(raw, "at_unix_ms"),
         :ok <- require_updated_at(record, at) do
      do_acknowledge(record, phase_intent, raw, at)
    end
  end

  def acknowledge(_, _), do: error(:invalid_record)

  defp ack_keyset_for("fenced"), do: {:ok, @ack_fenced_keys}
  defp ack_keyset_for("deny_all_installed"), do: {:ok, @ack_deny_installed_keys}

  defp ack_keyset_for(phase) when phase in @phases, do: {:ok, @ack_base_keys}

  defp ack_keyset_for(_), do: error(:transition_illegal)

  defp do_acknowledge(record, "reserved", _facts, at) do
    record
    |> put_phase("fenced")
    |> put_fence(%{"installed" => true})
    |> touch(at)
    |> reset_retry_on_success()
    |> finish(&next_effects/1)
  end

  defp do_acknowledge(record, "fenced", facts, at) do
    with {:ok, profile_cas} <- require_profile_cas(facts),
         :ok <- require_profile_cas_unset(record),
         {:ok, frozen} <- require_frozen_authority(facts, record),
         :ok <- require_frozen_authority_unset(record),
         {:ok, replay} <- require_profile_mutation_replay(facts),
         :ok <- require_profile_mutation_replay_unset(record) do
      record
      |> Map.put("profile_cas", profile_cas)
      |> Map.put("frozen_authority", frozen)
      |> Map.put("profile_mutation_replay", replay)
      |> put_phase("prepared")
      |> touch(at)
      |> reset_retry_on_success()
      |> finish(&next_effects/1)
    end
  end

  defp do_acknowledge(record, "prepared", _facts, at) do
    record
    |> put_phase("deny_all_intent")
    |> touch(at)
    |> reset_retry_on_success()
    |> finish(&next_effects/1)
  end

  defp do_acknowledge(record, "deny_all_intent", _facts, at) do
    record
    |> put_phase("deny_all_installed")
    |> touch(at)
    |> reset_retry_on_success()
    |> finish(&next_effects/1)
  end

  defp do_acknowledge(record, "deny_all_installed", facts, at) do
    case Map.fetch(facts, "runtime_was_running") do
      {:ok, running} when is_boolean(running) ->
        record
        |> Map.put("runtime_was_running", running)
        |> put_phase("runtime_quiesced")
        |> touch(at)
        |> reset_retry_on_success()
        |> finish(&next_effects/1)

      _ ->
        error(:runtime_fact_invalid)
    end
  end

  defp do_acknowledge(
         %{"phase" => "capability_effects"} = record,
         "capability_effects",
         _facts,
         at
       ) do
    if journal_all_succeeded?(record) do
      record
      |> put_phase("profile_commit")
      |> touch(at)
      |> reset_retry_on_success()
      |> finish(&next_effects/1)
    else
      error(:transition_illegal)
    end
  end

  defp do_acknowledge(record, "profile_commit", _facts, at) do
    record
    |> put_phase("desired_trust")
    |> touch(at)
    |> reset_retry_on_success()
    |> finish(&next_effects/1)
  end

  defp do_acknowledge(record, "desired_trust", _facts, at) do
    record
    |> put_phase("verifying")
    |> touch(at)
    |> reset_retry_on_success()
    |> finish(&next_effects/1)
  end

  defp do_acknowledge(record, "verifying", _facts, at) do
    record
    |> put_phase("runtime_restore")
    |> touch(at)
    |> reset_retry_on_success()
    |> finish(&next_effects/1)
  end

  defp do_acknowledge(record, "runtime_restore", _facts, at) do
    record
    |> put_phase("completed")
    |> Map.put("status", "completed")
    |> Map.put("terminal", %{
      "reason_code" => "completed",
      "at_unix_ms" => at,
      "phase_at_terminal" => "completed",
      "blocked_kind" => nil
    })
    |> touch(at)
    |> reset_retry_on_success()
    |> finish(&cleanup_effects/1)
  end

  defp do_acknowledge(_record, _phase, _facts, _at), do: error(:transition_illegal)

  # ---------------------------------------------------------------------------
  # Prepare (fenced → prepared with profile_cas + frozen_authority +
  # profile_mutation_replay). Replay commitment is shape/constants-admitted
  # only; digests are not re-derived without the private Record.
  # ---------------------------------------------------------------------------

  @spec prepare(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def prepare(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, facts} <- admit_event_facts(facts, @prepare_fact_keys) do
      acknowledge(
        record,
        Map.merge(facts, %{"phase_intent" => "fenced"})
      )
    end
  end

  def prepare(_, _), do: error(:invalid_record)

  # ---------------------------------------------------------------------------
  # Capability journal plan / ack / outcome
  # ---------------------------------------------------------------------------

  @spec plan_capability_effects(record(), map()) ::
          {:ok, record(), [effect()]} | {:error, term()}
  def plan_capability_effects(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         :ok <- require_phase(record, "runtime_quiesced"),
         :ok <- require_no_reconciliation(record),
         {:ok, facts} <- admit_event_facts(facts, @plan_fact_keys),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at),
         {:ok, entries} <- admit_plan_entries(Map.get(facts, "entries"), record) do
      journal = %{"version" => 1, "entries" => entries}

      record
      |> Map.put("journal", journal)
      |> put_phase("capability_effects")
      |> touch(at)
      |> reset_retry_on_success()
      |> finish(&next_effects/1)
    end
  end

  def plan_capability_effects(_, _), do: error(:invalid_record)

  @spec acknowledge_effect(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def acknowledge_effect(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         :ok <- require_phase(record, "capability_effects"),
         {:ok, facts} <- admit_event_facts(facts, @effect_ack_fact_keys),
         {:ok, effect_id} <-
           require_id(facts, "effect_id", @max_effect_id_bytes, @operation_id_re),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at),
         {:ok, record} <- mark_effect_succeeded(record, effect_id, at) do
      record = record |> touch(at) |> reset_retry_on_success()

      record =
        if journal_all_succeeded?(record) do
          put_phase(record, "profile_commit")
        else
          record
        end

      finish(record, &next_effects/1)
    end
  end

  def acknowledge_effect(_, _), do: error(:invalid_record)

  @spec report_effect_outcome(record(), map()) ::
          {:ok, record(), [effect()]} | {:error, term()}
  def report_effect_outcome(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         :ok <- require_phase(record, "capability_effects"),
         {:ok, facts} <- admit_event_facts(facts, @effect_outcome_fact_keys),
         {:ok, effect_id} <-
           require_id(facts, "effect_id", @max_effect_id_bytes, @operation_id_re),
         {:ok, outcome} <- require_string(facts, "outcome"),
         {:ok, reason_code} <- optional_reason(facts),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at) do
      handle_effect_outcome(record, effect_id, outcome, reason_code, at)
    end
  end

  def report_effect_outcome(_, _), do: error(:invalid_record)

  @spec report_outcome(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def report_outcome(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         :ok <- require_primary_outcome_phase(record),
         {:ok, facts} <- admit_event_facts(facts, @outcome_fact_keys),
         {:ok, phase_intent} <- require_string(facts, "phase_intent"),
         :ok <- require_phase_intent(record, phase_intent),
         {:ok, outcome} <- require_string(facts, "outcome"),
         {:ok, reason_code} <- optional_reason(facts),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at) do
      case outcome do
        "succeeded" ->
          error(:outcome_unknown)

        "non_retryable_conflict" ->
          block_record(
            record,
            at,
            reason_code || "non_retryable_conflict",
            "non_retryable_conflict"
          )

        outcome when outcome in ["uncertain", "retryable_failure"] ->
          with :ok <- require_no_reconciliation(record) do
            apply_retryable_phase(record, at, reason_code)
          end

        _ ->
          error(:outcome_unknown)
      end
    end
  end

  def report_outcome(_, _), do: error(:invalid_record)

  # ---------------------------------------------------------------------------
  # Clear reconciliation after observation proves not-applied (same identity)
  # ---------------------------------------------------------------------------

  @spec clear_reconcile(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def clear_reconcile(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         {:ok, facts} <- admit_event_facts(facts, @clear_reconcile_fact_keys),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at),
         {:ok, recon} <- require_reconciliation(record) do
      do_clear_reconcile(record, recon, at)
    end
  end

  def clear_reconcile(_, _), do: error(:invalid_record)

  defp do_clear_reconcile(record, %{"phase" => phase, "effect_id" => nil}, at) do
    if record["phase"] == phase and phase in @primary_outcome_phases do
      record
      |> Map.put("reconciliation_required", nil)
      |> touch(at)
      |> finish(&primary_next_effects/1)
    else
      error(:transition_illegal)
    end
  end

  defp do_clear_reconcile(
         record,
         %{"phase" => "capability_effects", "effect_id" => effect_id},
         at
       )
       when is_binary(effect_id) do
    with {:ok, record} <- mark_effect_pending(record, effect_id) do
      record =
        record
        |> Map.put("reconciliation_required", nil)
        |> touch(at)

      case journal_head(record) do
        %{"effect_id" => ^effect_id, "state" => "pending"} = entry ->
          finish(record, [journal_effect(record, entry)])

        _ ->
          error(:transition_illegal)
      end
    end
  end

  defp do_clear_reconcile(_record, _recon, _at), do: error(:transition_illegal)

  # ---------------------------------------------------------------------------
  # Abort / block / cleanup
  # ---------------------------------------------------------------------------

  @spec abort_pre_effect(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def abort_pre_effect(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         # An unresolved reconciliation_required (e.g. an uncertain reserved-phase
         # dispatch-fence outcome) must be acknowledged-as-applied or
         # cleared-and-retried before abort; aborting mid-fence would discard an
         # observation whose application state is genuinely unknown.
         :ok <- require_no_reconciliation(record),
         {:ok, facts} <- admit_event_facts(facts, @abort_fact_keys),
         {:ok, reason_code} <- require_reason(facts),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at) do
      phase = record["phase"]

      if phase in @abortable_phases do
        do_abort(record, phase, reason_code, at)
      else
        abort_illegal(phase)
      end
    end
  end

  def abort_pre_effect(_, _), do: error(:invalid_record)

  defp abort_illegal(phase) do
    if phase_index(phase) >= phase_index("deny_all_intent") do
      error(:abort_after_authority_intent)
    else
      error(:transition_illegal)
    end
  end

  defp do_abort(record, "reserved", reason_code, at) do
    record
    |> Map.put("status", "aborted_pre_effect")
    |> Map.put("terminal", terminal(reason_code, at, "reserved", nil))
    |> Map.put("reconciliation_required", nil)
    |> Map.put("fence_state", %{
      "required" => false,
      "installed" => false,
      "cleanup_acked" => true
    })
    |> touch(at)
    |> finish([])
  end

  defp do_abort(record, phase, reason_code, at) when phase in ~w(fenced prepared) do
    record
    |> Map.put("status", "aborted_pre_effect")
    |> Map.put("terminal", terminal(reason_code, at, phase, nil))
    |> Map.put("reconciliation_required", nil)
    |> Map.put("fence_state", %{
      "required" => true,
      "installed" => true,
      "cleanup_acked" => false
    })
    |> touch(at)
    |> finish(&cleanup_effects/1)
  end

  @spec hold_blocked(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def hold_blocked(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         {:ok, facts} <- admit_event_facts(facts, @hold_fact_keys),
         {:ok, reason_code} <- require_reason(facts),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at) do
      block_record(record, at, reason_code, "explicit_hold")
    end
  end

  def hold_blocked(_, _), do: error(:invalid_record)

  @spec ack_cleanup(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def ack_cleanup(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         {:ok, facts} <- admit_event_facts(facts, @cleanup_fact_keys),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at),
         :ok <- require_cleanup_status(record) do
      do_ack_cleanup(record, at)
    end
  end

  def ack_cleanup(_, _), do: error(:invalid_record)

  defp require_cleanup_status(%{"status" => status})
       when status in ~w(completed aborted_pre_effect),
       do: :ok

  defp require_cleanup_status(_), do: error(:cleanup_not_applicable)

  defp do_ack_cleanup(record, at) do
    fence = record["fence_state"]

    cond do
      fence["cleanup_acked"] == true ->
        finish(touch(record, at), [])

      not fence_required?(record) ->
        finish(touch(record, at), [])

      fence["installed"] != true ->
        record
        |> Map.put("fence_state", %{
          "required" => false,
          "installed" => false,
          "cleanup_acked" => true
        })
        |> touch(at)
        |> finish([])

      true ->
        record
        |> Map.put("fence_state", %{
          "required" => false,
          "installed" => true,
          "cleanup_acked" => true
        })
        |> touch(at)
        |> finish([])
    end
  end

  @spec note_retry(record(), map()) :: {:ok, record(), [effect()]} | {:error, term()}
  def note_retry(record, facts) when is_map(record) and is_map(facts) do
    with {:ok, record} <- admit(record),
         :ok <- require_active(record),
         {:ok, facts} <- admit_event_facts(facts, @note_retry_fact_keys),
         {:ok, at} <- require_time(facts, "at_unix_ms"),
         :ok <- require_updated_at(record, at),
         {:ok, reason_code} <- optional_reason(facts),
         {:ok, effect_id} <- optional_effect_id(facts) do
      route_note_retry(record, at, reason_code, effect_id)
    end
  end

  def note_retry(_, _), do: error(:invalid_record)

  defp route_note_retry(%{"phase" => "capability_effects"} = record, at, reason_code, effect_id) do
    # A second retry/uncertain report while reconciliation_required is already
    # set must be rejected: the caller must acknowledge-as-applied or
    # clear-and-retry first. Without this guard note_retry would re-increment the
    # attempt counter and re-emit a reobserve effect for an already-pending
    # reobservation.
    with :ok <- require_no_reconciliation(record),
         {:ok, effect_id} <- resolve_journal_retry_effect_id(record, effect_id) do
      apply_retryable_effect(record, effect_id, at, reason_code)
    end
  end

  defp route_note_retry(%{"phase" => phase} = record, at, reason_code, effect_id)
       when phase in @primary_outcome_phases do
    with :ok <- require_no_reconciliation(record) do
      if is_nil(effect_id) do
        apply_retryable_phase(record, at, reason_code)
      else
        error(:transition_illegal)
      end
    end
  end

  defp route_note_retry(_record, _at, _reason_code, _effect_id), do: error(:transition_illegal)

  defp resolve_journal_retry_effect_id(record, effect_id) do
    case journal_head(record) do
      %{"effect_id" => head_id, "state" => state}
      when state in ~w(pending needs_reconcile) and is_binary(head_id) ->
        if is_nil(effect_id) or effect_id == head_id do
          {:ok, head_id}
        else
          error(:journal_effect_not_head)
        end

      _ ->
        error(:transition_illegal)
    end
  end

  # ---------------------------------------------------------------------------
  # Primary next effects by phase
  # ---------------------------------------------------------------------------

  defp primary_next_effects(%{"phase" => "reserved"} = r),
    do: [base_effect(r, "install_target_dispatch_fence", "reserved")]

  defp primary_next_effects(%{"phase" => "fenced"} = r),
    do: [base_effect(r, "prepare_operation", "fenced")]

  defp primary_next_effects(%{"phase" => "prepared"} = r),
    do: [base_effect(r, "record_deny_all_intent", "prepared")]

  defp primary_next_effects(%{"phase" => "deny_all_intent"} = r),
    do: [base_effect(r, "install_deny_all_trust", "deny_all_intent")]

  defp primary_next_effects(%{"phase" => "deny_all_installed"} = r),
    do: [base_effect(r, "quiesce_runtime", "deny_all_installed")]

  defp primary_next_effects(%{"phase" => "runtime_quiesced"}), do: []

  defp primary_next_effects(%{"phase" => "capability_effects"} = r) do
    case journal_head(r) do
      %{"state" => "pending"} = entry ->
        [journal_effect(r, entry)]

      nil ->
        # Empty journal: shell should acknowledge capability_effects to advance.
        []

      _ ->
        []
    end
  end

  defp primary_next_effects(%{"phase" => "profile_commit"} = r),
    do: [base_effect(r, "commit_profile_marker", "profile_commit")]

  defp primary_next_effects(%{"phase" => "desired_trust"} = r),
    do: [base_effect(r, "install_desired_trust", "desired_trust")]

  defp primary_next_effects(%{"phase" => "verifying"} = r),
    do: [base_effect(r, "verify_authority", "verifying")]

  defp primary_next_effects(%{"phase" => "runtime_restore"} = r) do
    [
      r
      |> base_effect("restore_runtime", "runtime_restore")
      |> Map.put("runtime_was_running", r["runtime_was_running"])
    ]
  end

  defp primary_next_effects(_), do: []

  # ---------------------------------------------------------------------------
  # Retry / block helpers
  # ---------------------------------------------------------------------------

  defp handle_effect_outcome(record, effect_id, outcome, reason_code, at) do
    case journal_head(record) do
      %{"effect_id" => ^effect_id, "state" => state}
      when state in ~w(pending needs_reconcile) ->
        case outcome do
          "non_retryable_conflict" ->
            block_record(
              record,
              at,
              reason_code || "non_retryable_conflict",
              "non_retryable_conflict"
            )

          outcome when outcome in ["uncertain", "retryable_failure"] ->
            with :ok <- require_no_reconciliation(record) do
              apply_retryable_effect(record, effect_id, at, reason_code)
            end

          _ ->
            error(:outcome_unknown)
        end

      %{"effect_id" => ^effect_id} ->
        error(:journal_effect_not_resumable)

      %{"effect_id" => _other} ->
        error(:journal_effect_not_head)

      nil ->
        error(:journal_effect_id_unknown)
    end
  end

  defp apply_retryable_effect(record, effect_id, at, reason_code) do
    retry = record["retry"]
    attempt = retry["attempt"] + 1

    if attempt > retry["max_attempts"] do
      block_record(record, at, reason_code || "retry_exhausted", "retry_exhausted")
    else
      entries =
        Enum.map(record["journal"]["entries"], fn entry ->
          if entry["effect_id"] == effect_id do
            Map.put(entry, "state", "needs_reconcile")
          else
            entry
          end
        end)

      record
      |> put_in(["journal", "entries"], entries)
      |> Map.put("retry", %{
        "attempt" => attempt,
        "max_attempts" => retry["max_attempts"],
        "last_code" => reason_code,
        "last_effect_id" => effect_id
      })
      |> Map.put("reconciliation_required", %{
        "phase" => "capability_effects",
        "effect_id" => effect_id
      })
      |> touch(at)
      |> finish(fn r -> [reobserve_effect(r, effect_id)] end)
    end
  end

  defp apply_retryable_phase(record, at, reason_code) do
    retry = record["retry"]
    attempt = retry["attempt"] + 1

    if attempt > retry["max_attempts"] do
      block_record(record, at, reason_code || "retry_exhausted", "retry_exhausted")
    else
      record
      |> Map.put("retry", %{
        "attempt" => attempt,
        "max_attempts" => retry["max_attempts"],
        "last_code" => reason_code,
        "last_effect_id" => nil
      })
      |> Map.put("reconciliation_required", %{
        "phase" => record["phase"],
        "effect_id" => nil
      })
      |> touch(at)
      |> finish(fn r -> [reobserve_effect(r, nil)] end)
    end
  end

  defp block_record(record, at, reason_code, blocked_kind) do
    record
    |> Map.put("status", "blocked")
    |> Map.put("reconciliation_required", nil)
    |> Map.put("terminal", terminal(reason_code, at, record["phase"], blocked_kind))
    |> touch(at)
    |> finish([])
  end

  # ---------------------------------------------------------------------------
  # Journal helpers
  # ---------------------------------------------------------------------------

  defp empty_journal, do: %{"version" => 1, "entries" => []}

  defp journal_head(%{"journal" => %{"entries" => entries}}) when is_list(entries) do
    Enum.find(entries, fn e -> e["state"] in ~w(pending needs_reconcile) end)
  end

  defp journal_head(_), do: nil

  defp journal_all_succeeded?(%{"journal" => %{"entries" => entries}}) when is_list(entries) do
    Enum.all?(entries, &(&1["state"] == "succeeded"))
  end

  defp journal_all_succeeded?(_), do: false

  defp mark_effect_succeeded(record, effect_id, at) do
    case journal_head(record) do
      %{"effect_id" => ^effect_id, "state" => state} = _head
      when state in ~w(pending needs_reconcile) ->
        entries =
          Enum.map(record["journal"]["entries"], fn entry ->
            if entry["effect_id"] == effect_id do
              entry
              |> Map.put("state", "succeeded")
              |> Map.put("acked_at_unix_ms", at)
            else
              entry
            end
          end)

        {:ok, put_in(record, ["journal", "entries"], entries)}

      %{"effect_id" => ^effect_id} ->
        error(:journal_effect_not_resumable)

      %{"effect_id" => _} ->
        error(:journal_effect_not_head)

      nil ->
        error(:journal_effect_id_unknown)
    end
  end

  defp mark_effect_pending(record, effect_id) do
    case journal_head(record) do
      %{"effect_id" => ^effect_id, "state" => "needs_reconcile"} ->
        entries =
          Enum.map(record["journal"]["entries"], fn entry ->
            if entry["effect_id"] == effect_id do
              entry
              |> Map.put("state", "pending")
              |> Map.put("acked_at_unix_ms", nil)
            else
              entry
            end
          end)

        {:ok, put_in(record, ["journal", "entries"], entries)}

      %{"effect_id" => ^effect_id} ->
        error(:journal_effect_not_resumable)

      %{"effect_id" => _} ->
        error(:journal_effect_not_head)

      nil ->
        error(:journal_effect_id_unknown)
    end
  end

  defp admit_plan_entries(nil, _record), do: {:ok, []}
  defp admit_plan_entries([], _record), do: {:ok, []}

  defp admit_plan_entries(entries, record) when is_list(entries) do
    case admit_bounded_list_spine(entries, @max_journal_entries) do
      :ok -> admit_plan_entries(entries, record, 0, [], MapSet.new())
      :too_many -> error(:journal_overflow)
      :improper -> error(:improper_list)
    end
  end

  defp admit_plan_entries(_, _), do: error(:invalid_record)

  defp admit_plan_entries([], _record, _seq, acc, _seen), do: {:ok, Enum.reverse(acc)}

  defp admit_plan_entries([raw | rest], record, seq, acc, seen) do
    with {:ok, entry_in} <- admit_event_facts(raw, @plan_entry_keys),
         {:ok, effect_id} <-
           require_id(entry_in, "effect_id", @max_effect_id_bytes, @operation_id_re),
         :ok <- reject_duplicate_effect_id(seen, effect_id),
         {:ok, effect_type} <- require_string(entry_in, "effect_type"),
         :ok <- require_journal_effect_type(effect_type),
         {:ok, payload} <-
           admit_journal_payload(effect_type, Map.get(entry_in, "payload"), record) do
      entry = %{
        "effect_id" => effect_id,
        "seq" => seq,
        "effect_type" => effect_type,
        "state" => "pending",
        "payload" => payload,
        "acked_at_unix_ms" => nil
      }

      admit_plan_entries(rest, record, seq + 1, [entry | acc], MapSet.put(seen, effect_id))
    end
  end

  defp require_journal_effect_type(type) do
    if MapSet.member?(@journal_effect_types, type), do: :ok, else: error(:effect_unknown)
  end

  defp reject_duplicate_effect_id(seen, effect_id) do
    if MapSet.member?(seen, effect_id), do: error(:invalid_record), else: :ok
  end

  defp admit_journal_payload("revoke_managed_capability", payload, _record) do
    with {:ok, payload} <- admit_event_facts(payload || %{}, @revoke_plan_payload_keys),
         {:ok, cap_id} <-
           require_id(payload, "capability_id", @max_capability_id_bytes, @operation_id_re),
         {:ok, resource} <- admit_resource(Map.get(payload, "resource")) do
      {:ok, %{"capability_id" => cap_id, "resource" => resource}}
    end
  end

  defp admit_journal_payload("grant_managed_capability", payload, record) do
    with {:ok, payload} <- admit_event_facts(payload || %{}, @grant_plan_payload_keys),
         :ok <- reject_capability_id_key(payload),
         {:ok, resource, constraints} <-
           admit_grant_resource_constraints(
             Map.get(payload, "resource"),
             Map.get(payload, "constraints")
           ),
         {:ok, provenance} <- admit_grant_provenance(Map.get(payload, "provenance"), record) do
      {:ok,
       %{
         "resource" => resource,
         "constraints" => constraints,
         "provenance" => provenance
       }}
    end
  end

  defp admit_journal_payload(_, _, _), do: error(:effect_unknown)

  defp reject_capability_id_key(payload) do
    if Map.has_key?(payload, "capability_id") or Map.has_key?(payload, :capability_id) do
      error(:invalid_record)
    else
      :ok
    end
  end

  defp admit_resource(resource) do
    case TemplateAuthorityPolicy.normalize_capabilities([
           %{"resource" => resource, "constraints" => %{}}
         ]) do
      {:ok, [cap]} ->
        {:ok, cap["resource"]}

      {:error, {:template_authority_policy, reason}} ->
        error(reason)

      {:error, reason} ->
        error(reason)
    end
  end

  defp admit_grant_resource_constraints(resource, constraints) do
    case TemplateAuthorityPolicy.normalize_capabilities([
           %{"resource" => resource, "constraints" => constraints || %{}}
         ]) do
      {:ok, [cap]} ->
        {:ok, cap["resource"], cap["constraints"]}

      {:error, {:template_authority_policy, reason}} ->
        error(reason)

      {:error, reason} ->
        error(reason)
    end
  end

  defp admit_grant_provenance(nil, record) do
    {:ok, desired_grant_provenance(record)}
  end

  defp admit_grant_provenance(prov, record) when is_map(prov) do
    with {:ok, prov} <- admit_event_facts(prov, @grant_provenance_keys),
         desired = desired_grant_provenance(record),
         true <- prov == desired do
      {:ok, desired}
    else
      {:error, _} = err -> err
      false -> error(:invalid_record)
      _ -> error(:invalid_record)
    end
  end

  defp admit_grant_provenance(_, _), do: error(:invalid_record)

  defp desired_grant_provenance(record) do
    desired = record["desired_authority"]

    %{
      "source" => "template_authority_policy",
      "version" => 1,
      "template" => desired["provenance"]["name"],
      "template_digest" => desired["declaration_digest"]
    }
  end

  # ---------------------------------------------------------------------------
  # Desired authority admission
  # ---------------------------------------------------------------------------

  defp admit_desired_authority(input) when is_map(input) do
    with {:ok, input} <- normalize_string_keyed_map(input) do
      cond do
        Map.has_key?(input, "envelope") ->
          with :ok <- allow_only_keys(input, @desired_input_keys) do
            admit_desired_from_envelope(input)
          end

        envelope_shaped?(input) ->
          admit_desired_from_envelope(%{"envelope" => input})

        true ->
          error(:invalid_new_input)
      end
    end
  end

  defp admit_desired_authority(_), do: error(:invalid_new_input)

  defp envelope_shaped?(map) do
    Map.has_key?(map, "snapshot") or Map.has_key?(map, "digest") or
      Map.has_key?(map, :snapshot) or Map.has_key?(map, :digest)
  end

  defp admit_desired_from_envelope(%{"envelope" => envelope} = input) do
    with {:ok, validated} <- validate_policy_envelope(envelope),
         # The stored envelope MUST be the exact canonical envelope returned by
         # validate_envelope/1; unknown nested envelope/snapshot/capability
         # fields are rejected rather than dropped.
         true <- envelope == validated,
         {:ok, derived_provenance} <- derived_desired_provenance(validated),
         :ok <-
           reject_conflicting_declaration_digest(
             Map.get(input, "declaration_digest"),
             validated["digest"]
           ),
         :ok <-
           reject_conflicting_provenance(Map.get(input, "provenance"), derived_provenance),
         :ok <- validate_provenance(derived_provenance) do
      {:ok,
       %{
         "envelope" => validated,
         "declaration_digest" => validated["digest"],
         "provenance" => derived_provenance
       }}
    else
      {:error, _} = err -> err
      false -> error(:invalid_record)
    end
  end

  defp validate_policy_envelope(envelope) do
    case TemplateAuthorityPolicy.validate_envelope(envelope) do
      {:ok, validated} -> {:ok, validated}
      {:error, {:template_authority_policy, reason}} -> error(reason)
      {:error, reason} -> error(reason)
    end
  end

  defp derived_desired_provenance(validated) do
    snap = TemplateAuthorityPolicy.snapshot(validated)
    prov = TemplateAuthorityPolicy.provenance(snap)

    name = Map.get(prov, "name") || Map.get(snap, "template")
    layer = Map.get(prov, "layer")

    derived = %{"name" => name, "layer" => layer}
    {:ok, derived}
  end

  defp reject_conflicting_declaration_digest(nil, _digest), do: :ok

  defp reject_conflicting_declaration_digest(digest, expected) do
    if digest == expected, do: :ok, else: error(:invalid_record)
  end

  defp reject_conflicting_provenance(nil, _derived), do: :ok

  defp reject_conflicting_provenance(p, derived) when is_map(p) do
    with {:ok, p} <- normalize_string_keyed_map(p),
         :ok <- closed_keyset(p, @provenance_keys),
         true <- p == derived do
      :ok
    else
      {:error, _} = err -> err
      false -> error(:invalid_record)
      _ -> error(:invalid_record)
    end
  end

  defp reject_conflicting_provenance(_, _), do: error(:invalid_new_input)

  defp validate_provenance(prov) when is_map(prov) do
    with :ok <- closed_keyset(prov, @provenance_keys),
         name when is_binary(name) <- prov["name"],
         layer <- prov["layer"],
         true <-
           name != "" and byte_size(name) <= @max_template_name_bytes and String.valid?(name),
         true <- is_nil(layer) or (is_binary(layer) and layer in @provenance_layers) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_new_input)
    end
  end

  defp validate_provenance(_), do: error(:invalid_new_input)

  # ---------------------------------------------------------------------------
  # Record validation
  # ---------------------------------------------------------------------------

  defp validate_record(record) do
    with :ok <- closed_keyset(record, @record_keys),
         :ok <- require_version_kind(record),
         :ok <- validate_ids(record),
         :ok <- validate_times(record),
         :ok <- validate_status_phase(record),
         :ok <- validate_desired(record["desired_authority"]),
         :ok <- require_scope_durability(record),
         :ok <- validate_runtime(record),
         :ok <- validate_profile_cas(record),
         :ok <- validate_frozen_authority(record),
         :ok <- validate_profile_mutation_replay(record),
         :ok <- validate_journal(record["journal"], record),
         :ok <- validate_reconciliation_required(record),
         :ok <- validate_retry(record["retry"], record),
         :ok <- validate_terminal(record["terminal"], record) do
      validate_fence(record["fence_state"], record)
    end
  end

  defp require_scope_durability(%{"scope" => "local_owner", "durability" => "node_restart"}),
    do: :ok

  defp require_scope_durability(%{"scope" => scope}) when scope != "local_owner",
    do: error(:scope_invalid)

  defp require_scope_durability(_), do: error(:durability_invalid)

  defp require_version_kind(%{"version" => @version, "kind" => @kind}), do: :ok
  defp require_version_kind(_), do: error(:invalid_record)

  defp validate_ids(record) do
    with true <- valid_id?(record["operation_id"], @max_operation_id_bytes, @operation_id_re),
         true <- valid_id?(record["target_agent_id"], @max_agent_id_bytes, @agent_id_re),
         true <- valid_id?(record["authorizing_caller_id"], @max_agent_id_bytes, @agent_id_re),
         true <- valid_digest?(record["expected_preview_reconciliation_digest"]) do
      :ok
    else
      _ -> error(:invalid_record)
    end
  end

  defp validate_status_phase(%{"status" => status, "phase" => phase})
       when status in @statuses and phase in @phases do
    case status do
      "active" when phase != "completed" -> :ok
      "completed" when phase == "completed" -> :ok
      "aborted_pre_effect" when phase in @abortable_phases -> :ok
      "blocked" when phase != "completed" -> :ok
      _ -> error(:invalid_record)
    end
  end

  defp validate_status_phase(_), do: error(:phase_unknown)

  defp validate_desired(desired) when is_map(desired) do
    with :ok <- closed_keyset(desired, @desired_keys),
         true <- valid_digest?(desired["declaration_digest"]),
         :ok <- validate_provenance(desired["provenance"]),
         {:ok, validated} <- TemplateAuthorityPolicy.validate_envelope(desired["envelope"]),
         # Persisted envelope must equal the exact canonical form: reject any
         # unknown nested envelope/snapshot/capability fields on re-admission.
         true <- desired["envelope"] == validated,
         true <- desired["declaration_digest"] == validated["digest"],
         {:ok, derived} <- derived_desired_provenance(validated),
         true <- desired["provenance"] == derived do
      :ok
    else
      {:error, {:template_authority_policy, reason}} -> error(reason)
      {:error, _} = err -> err
      false -> error(:invalid_record)
      _ -> error(:invalid_record)
    end
  end

  defp validate_desired(_), do: error(:invalid_record)

  defp validate_runtime(%{"runtime_was_running" => nil, "phase" => phase})
       when phase in @pre_runtime_phases,
       do: :ok

  defp validate_runtime(%{"runtime_was_running" => v, "phase" => phase})
       when is_boolean(v) and phase in @post_runtime_phases,
       do: :ok

  defp validate_runtime(_), do: error(:runtime_fact_invalid)

  defp validate_profile_cas(%{"profile_cas" => nil, "phase" => phase})
       when phase in ~w(reserved fenced),
       do: :ok

  defp validate_profile_cas(%{"profile_cas" => cas, "phase" => phase})
       when is_map(cas) and phase not in ~w(reserved fenced) do
    validate_profile_cas_value(cas)
  end

  defp validate_profile_cas(_), do: error(:invalid_record)

  defp validate_profile_cas_value(cas) when is_map(cas) do
    with :ok <- closed_keyset(cas, @profile_cas_keys),
         true <-
           valid_id?(cas["record_id"], @max_profile_record_id_bytes, @operation_id_re),
         gen when is_integer(gen) and gen >= 1 and gen <= @max_json_safe_integer <-
           cas["generation"],
         rev when is_integer(rev) and rev >= 1 and rev <= @max_json_safe_integer <-
           cas["revision"] do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_record)
    end
  end

  defp validate_profile_cas_value(_), do: error(:invalid_record)

  # frozen_authority is nil before prepared and a closed re-derived map at and
  # after prepared. Re-admission re-projects declared capabilities from the
  # stored desired envelope + target + root and rejects tamper.
  defp validate_frozen_authority(%{"frozen_authority" => nil, "phase" => phase})
       when phase in ~w(reserved fenced),
       do: :ok

  defp validate_frozen_authority(%{"frozen_authority" => frozen, "phase" => phase} = record)
       when is_map(frozen) and phase not in ~w(reserved fenced) do
    validate_frozen_authority_value(frozen, record)
  end

  defp validate_frozen_authority(_), do: error(:invalid_record)

  defp validate_frozen_authority_value(frozen, record) when is_map(frozen) do
    # Re-admission never rewrites keys/caps before equality: atom aliases,
    # whitespace roots, and non-canonical reorderings fail closed.
    with :ok <- closed_keyset(frozen, @frozen_authority_keys),
         {:ok, _canonical} <- admit_and_rederive_frozen(frozen, record) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:frozen_authority_invalid)
    end
  end

  defp validate_frozen_authority_value(_, _), do: error(:frozen_authority_invalid)

  defp validate_reconciliation_required(%{"reconciliation_required" => nil} = record) do
    case {record["status"], journal_head(record)} do
      {"active", %{"state" => "needs_reconcile"}} ->
        error(:invalid_record)

      _ ->
        :ok
    end
  end

  defp validate_reconciliation_required(
         %{"reconciliation_required" => recon, "status" => "active"} = record
       )
       when is_map(recon) do
    with :ok <- closed_keyset(recon, @reconciliation_keys),
         true <- recon["phase"] == record["phase"],
         :ok <- validate_recon_binding(record, recon) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_record)
    end
  end

  defp validate_reconciliation_required(_), do: error(:invalid_record)

  defp validate_recon_binding(%{"phase" => "capability_effects"} = record, %{
         "effect_id" => effect_id
       })
       when is_binary(effect_id) do
    if valid_id?(effect_id, @max_effect_id_bytes, @operation_id_re) do
      case journal_head(record) do
        %{"effect_id" => ^effect_id, "state" => "needs_reconcile"} -> :ok
        _ -> error(:invalid_record)
      end
    else
      error(:invalid_record)
    end
  end

  defp validate_recon_binding(%{"phase" => phase}, %{"effect_id" => nil})
       when phase in @primary_outcome_phases,
       do: :ok

  defp validate_recon_binding(_, _), do: error(:invalid_record)

  defp validate_retry(retry, record) when is_map(retry) do
    with :ok <- closed_keyset(retry, @retry_keys),
         attempt when is_integer(attempt) and attempt >= 0 and attempt <= @max_retry <-
           retry["attempt"],
         max when is_integer(max) and max >= 1 and max <= @max_retry <- retry["max_attempts"],
         true <- attempt <= max,
         :ok <- validate_optional_code(retry["last_code"]),
         :ok <- validate_optional_effect_id(retry["last_effect_id"]),
         :ok <- validate_retry_coherence(retry, record) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:retry_bounds_invalid)
    end
  end

  defp validate_retry(_, _), do: error(:retry_bounds_invalid)

  defp validate_retry_coherence(%{"attempt" => 0} = retry, %{
         "reconciliation_required" => recon
       }) do
    # Fresh state: no retry has fired, so no reconciliation and no last fields.
    if is_nil(recon) and is_nil(retry["last_code"]) and is_nil(retry["last_effect_id"]) do
      :ok
    else
      error(:retry_bounds_invalid)
    end
  end

  defp validate_retry_coherence(%{"attempt" => attempt} = retry, record)
       when attempt > 0 do
    phase = record["phase"]
    last_effect_id = retry["last_effect_id"]

    cond do
      phase == "capability_effects" ->
        # last_effect_id, when present, must equal the current unresolved
        # journal head — whether reconciliation remains set (needs_reconcile
        # head) or was cleared for replay (pending head).
        case {last_effect_id, journal_head(record)} do
          {eff_id, %{"effect_id" => head_id}}
          when is_binary(eff_id) and eff_id == head_id ->
            :ok

          _ ->
            error(:invalid_record)
        end

      phase in @primary_outcome_phases ->
        if is_nil(last_effect_id), do: :ok, else: error(:invalid_record)

      true ->
        error(:invalid_record)
    end
  end

  defp validate_retry_coherence(_, _), do: error(:invalid_record)

  defp validate_optional_code(nil), do: :ok

  defp validate_optional_code(code) when is_binary(code) do
    if valid_reason_code?(code), do: :ok, else: error(:invalid_record)
  end

  defp validate_optional_code(_), do: error(:invalid_record)

  defp validate_optional_effect_id(nil), do: :ok

  defp validate_optional_effect_id(id) do
    if valid_id?(id, @max_effect_id_bytes, @operation_id_re),
      do: :ok,
      else: error(:invalid_record)
  end

  defp validate_journal(journal, record) do
    case journal do
      %{"version" => 1, "entries" => entries} when is_list(entries) ->
        with :ok <- closed_keyset(journal, @journal_keys),
             :ok <- admit_bounded_list_spine(entries, @max_journal_entries) |> spine_ok(),
             :ok <- validate_entries(entries, record) do
          validate_journal_phase_shape(entries, record)
        end

      _ ->
        error(:invalid_record)
    end
  end

  defp validate_journal_phase_shape(entries, %{"phase" => phase}) do
    cap_idx = phase_index("capability_effects")
    p_idx = phase_index(phase)

    cond do
      p_idx < 0 ->
        error(:invalid_record)

      p_idx < cap_idx ->
        if entries == [], do: :ok, else: error(:invalid_record)

      p_idx == cap_idx ->
        validate_capability_effects_journal_shape(entries)

      true ->
        if Enum.all?(entries, &(&1["state"] == "succeeded")),
          do: :ok,
          else: error(:invalid_record)
    end
  end

  defp validate_capability_effects_journal_shape(entries) do
    {_succeeded, rest} = Enum.split_while(entries, &(&1["state"] == "succeeded"))

    case rest do
      [] ->
        :ok

      [%{"state" => "needs_reconcile"} | tail] ->
        if Enum.all?(tail, &(&1["state"] == "pending")), do: :ok, else: error(:invalid_record)

      [%{"state" => "pending"} | tail] ->
        if Enum.all?(tail, &(&1["state"] == "pending")), do: :ok, else: error(:invalid_record)

      _ ->
        error(:invalid_record)
    end
  end

  defp spine_ok(:ok), do: :ok
  defp spine_ok(:too_many), do: error(:journal_overflow)
  defp spine_ok(:improper), do: error(:improper_list)

  defp validate_entries(entries, record) do
    validate_entries(entries, 0, MapSet.new(), record, nil)
  end

  defp validate_entries([], _seq, _seen, _record, _prev_acked_at), do: :ok

  defp validate_entries([entry | rest], seq, seen, record, prev_acked_at) do
    with :ok <- closed_keyset(entry, @entry_keys),
         true <- entry["seq"] == seq,
         true <- valid_id?(entry["effect_id"], @max_effect_id_bytes, @operation_id_re),
         true <- not MapSet.member?(seen, entry["effect_id"]),
         true <- MapSet.member?(@journal_effect_types, entry["effect_type"]),
         true <- MapSet.member?(@journal_states, entry["state"]),
         :ok <- validate_entry_payload(entry, record),
         :ok <- validate_acked_at(entry, record, prev_acked_at) do
      next_prev =
        if entry["state"] == "succeeded", do: entry["acked_at_unix_ms"], else: prev_acked_at

      validate_entries(rest, seq + 1, MapSet.put(seen, entry["effect_id"]), record, next_prev)
    else
      {:error, _} = err -> err
      _ -> error(:invalid_record)
    end
  end

  defp validate_entry_payload(
         %{"effect_type" => "revoke_managed_capability", "payload" => payload},
         _record
       )
       when is_map(payload) do
    with :ok <- closed_keyset(payload, @revoke_payload_keys),
         true <- valid_id?(payload["capability_id"], @max_capability_id_bytes, @operation_id_re),
         {:ok, resource} <- admit_resource(payload["resource"]),
         true <- payload["resource"] == resource do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_record)
    end
  end

  defp validate_entry_payload(
         %{"effect_type" => "grant_managed_capability", "payload" => payload},
         record
       )
       when is_map(payload) do
    with :ok <- closed_keyset(payload, @grant_payload_keys),
         true <- not Map.has_key?(payload, "capability_id"),
         {:ok, resource, constraints} <-
           admit_grant_resource_constraints(payload["resource"], payload["constraints"]),
         true <- payload["resource"] == resource,
         true <- payload["constraints"] == constraints,
         :ok <- closed_keyset(payload["provenance"], @grant_provenance_keys),
         true <- payload["provenance"] == desired_grant_provenance(record) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_record)
    end
  end

  defp validate_entry_payload(_, _), do: error(:invalid_record)

  defp validate_acked_at(
         %{"state" => "succeeded", "acked_at_unix_ms" => t},
         record,
         prev_acked_at
       ) do
    cond do
      not valid_time?(t) ->
        error(:timestamp_invalid)

      t < record["created_at_unix_ms"] or t > record["updated_at_unix_ms"] ->
        error(:invalid_record)

      prev_acked_at != nil and t < prev_acked_at ->
        # Succeeded ack timestamps must be nondecreasing by journal sequence.
        error(:invalid_record)

      true ->
        :ok
    end
  end

  defp validate_acked_at(%{"state" => state, "acked_at_unix_ms" => nil}, _record, _prev_acked_at)
       when state in ~w(pending needs_reconcile),
       do: :ok

  defp validate_acked_at(_, _, _), do: error(:invalid_record)

  defp validate_terminal(nil, %{"status" => "active"}), do: :ok

  defp validate_terminal(terminal, %{"status" => status} = record)
       when status in ~w(completed aborted_pre_effect blocked) and is_map(terminal) do
    with :ok <- closed_keyset(terminal, @terminal_keys),
         true <- valid_reason_code?(terminal["reason_code"]),
         true <- valid_time?(terminal["at_unix_ms"]),
         true <- terminal["at_unix_ms"] >= record["created_at_unix_ms"],
         true <- terminal["at_unix_ms"] <= record["updated_at_unix_ms"],
         :ok <- validate_terminal_shape(terminal, record) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_record)
    end
  end

  defp validate_terminal(_, _), do: error(:invalid_record)

  defp validate_terminal_shape(
         %{
           "reason_code" => "completed",
           "phase_at_terminal" => "completed",
           "blocked_kind" => nil
         },
         %{"status" => "completed", "phase" => "completed"}
       ),
       do: :ok

  defp validate_terminal_shape(
         %{"phase_at_terminal" => phase, "blocked_kind" => nil, "reason_code" => code},
         %{"status" => "aborted_pre_effect", "phase" => phase}
       )
       when phase in @abortable_phases and code != "completed",
       do: :ok

  defp validate_terminal_shape(
         %{"phase_at_terminal" => phase, "blocked_kind" => kind, "reason_code" => code},
         %{"status" => "blocked", "phase" => phase}
       )
       when kind in @blocked_kinds and is_binary(code) and code != "completed",
       do: :ok

  defp validate_terminal_shape(_, _), do: error(:invalid_record)

  defp validate_fence(fence, record) when is_map(fence) do
    with :ok <- closed_keyset(fence, @fence_keys),
         true <- is_boolean(fence["required"]),
         true <- is_boolean(fence["installed"]),
         true <- is_boolean(fence["cleanup_acked"]),
         :ok <- validate_fence_invariants(fence, record) do
      :ok
    else
      {:error, _} = err -> err
      _ -> error(:invalid_record)
    end
  end

  defp validate_fence(_, _), do: error(:invalid_record)

  defp validate_fence_invariants(fence, %{"status" => status, "phase" => phase}) do
    case status do
      "active" -> validate_fence_active(fence, phase)
      "blocked" -> validate_fence_blocked(fence, phase)
      "completed" -> validate_fence_completed(fence)
      "aborted_pre_effect" -> validate_fence_aborted(fence, phase)
      _ -> error(:invalid_record)
    end
  end

  defp validate_fence_active(
         %{"required" => true, "installed" => false, "cleanup_acked" => false},
         "reserved"
       ),
       do: :ok

  defp validate_fence_active(
         %{"required" => true, "installed" => true, "cleanup_acked" => false},
         phase
       )
       when phase != "reserved",
       do: :ok

  defp validate_fence_active(_, _), do: error(:invalid_record)

  defp validate_fence_blocked(
         %{"required" => true, "installed" => false, "cleanup_acked" => false},
         "reserved"
       ),
       do: :ok

  defp validate_fence_blocked(
         %{"required" => true, "installed" => true, "cleanup_acked" => false},
         phase
       )
       when phase != "reserved",
       do: :ok

  defp validate_fence_blocked(_, _), do: error(:invalid_record)

  defp validate_fence_completed(%{
         "required" => true,
         "installed" => true,
         "cleanup_acked" => false
       }),
       do: :ok

  defp validate_fence_completed(%{
         "required" => false,
         "installed" => true,
         "cleanup_acked" => true
       }),
       do: :ok

  defp validate_fence_completed(_), do: error(:invalid_record)

  defp validate_fence_aborted(
         %{"required" => false, "installed" => false, "cleanup_acked" => true},
         "reserved"
       ),
       do: :ok

  defp validate_fence_aborted(
         %{"required" => true, "installed" => true, "cleanup_acked" => false},
         phase
       )
       when phase in ~w(fenced prepared),
       do: :ok

  defp validate_fence_aborted(
         %{"required" => false, "installed" => true, "cleanup_acked" => true},
         phase
       )
       when phase in ~w(fenced prepared),
       do: :ok

  defp validate_fence_aborted(_, _), do: error(:invalid_record)

  defp validate_times(%{
         "created_at_unix_ms" => c,
         "updated_at_unix_ms" => u
       }) do
    if valid_time?(c) and valid_time?(u) and u >= c, do: :ok, else: error(:timestamp_invalid)
  end

  defp validate_times(_), do: error(:timestamp_invalid)

  # ---------------------------------------------------------------------------
  # Effect builders
  # ---------------------------------------------------------------------------

  # `idempotent_replay: true` is the effect contract for a re-emitted identity:
  # the shell MUST treat the operation/effect as at-least-once (the underlying
  # effect may already have been applied) and reobserve the outcome rather than
  # blindly re-applying. It is set whenever retry.attempt > 0 (a prior attempt
  # exists) and on every reobserve_reconcile. The identity (operation_id,
  # effect_id, phase_intent) is preserved across replay and reobservation.
  defp base_effect(record, type, phase_intent) do
    effect = %{
      "version" => 1,
      "effect_type" => type,
      "operation_id" => record["operation_id"],
      "target_agent_id" => record["target_agent_id"],
      "phase_intent" => phase_intent,
      "expected_preview_reconciliation_digest" => record["expected_preview_reconciliation_digest"]
    }

    if record["retry"]["attempt"] > 0 do
      Map.put(effect, "idempotent_replay", true)
    else
      effect
    end
  end

  defp journal_effect(record, entry) do
    record
    |> base_effect(entry["effect_type"], "capability_effects")
    |> Map.put("effect_id", entry["effect_id"])
    |> Map.put("payload", entry["payload"])
  end

  defp reobserve_effect(record, effect_id) do
    effect =
      base_effect(record, "reobserve_reconcile", record["phase"])
      |> Map.put("idempotent_replay", true)

    if is_binary(effect_id) and effect_id != "" do
      Map.put(effect, "effect_id", effect_id)
    else
      effect
    end
  end

  defp remove_fence_effect(record) do
    %{
      "version" => 1,
      "effect_type" => "remove_target_dispatch_fence",
      "operation_id" => record["operation_id"],
      "target_agent_id" => record["target_agent_id"],
      "phase_intent" => "terminal_cleanup",
      "expected_preview_reconciliation_digest" => record["expected_preview_reconciliation_digest"]
    }
  end

  # ---------------------------------------------------------------------------
  # Record mutators
  # ---------------------------------------------------------------------------

  defp put_phase(record, phase), do: Map.put(record, "phase", phase)

  defp put_fence(record, overrides) do
    Map.update!(record, "fence_state", &Map.merge(&1, overrides))
  end

  defp touch(record, at), do: Map.put(record, "updated_at_unix_ms", at)

  # Clears the retry/reconciliation runtime once a phase or effect is observed
  # to have succeeded (acknowledge / acknowledge_effect / plan): a fresh
  # attempt counter and nil last fields, and no pending reconciliation. The
  # max_attempts bound is preserved. This is NOT a runtime-was-running reset.
  defp reset_retry_on_success(record) do
    record
    |> Map.put("reconciliation_required", nil)
    |> Map.update!("retry", fn retry ->
      %{
        "attempt" => 0,
        "max_attempts" => retry["max_attempts"],
        "last_code" => nil,
        "last_effect_id" => nil
      }
    end)
  end

  defp terminal(reason_code, at, phase, blocked_kind) do
    %{
      "reason_code" => reason_code,
      "at_unix_ms" => at,
      "phase_at_terminal" => phase,
      "blocked_kind" => blocked_kind
    }
  end

  # ---------------------------------------------------------------------------
  # Admission helpers
  # ---------------------------------------------------------------------------

  defp admit_event_facts(map, allowed) when is_map(map) and not is_struct(map) do
    with {:ok, normalized} <- normalize_string_keyed_map(map),
         :ok <- allow_only_keys(normalized, allowed) do
      {:ok, normalized}
    end
  end

  defp admit_event_facts(_, _), do: error(:invalid_new_input)

  defp allow_only_keys(map, allowed) when is_map(map) do
    keys = Map.keys(map) |> MapSet.new()

    if MapSet.subset?(keys, allowed) and Enum.all?(Map.keys(map), &is_binary/1) do
      :ok
    else
      error(:unexpected_field)
    end
  end

  defp allow_only_keys(_, _), do: error(:invalid_record)

  defp normalize_string_keyed_map(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.reduce_while({:ok, %{}}, fn {k, v}, {:ok, acc} ->
      case normalize_key(k) do
        {:ok, key} ->
          if Map.has_key?(acc, key) do
            {:halt, error(:duplicate_field_conflict)}
          else
            {:cont, {:ok, Map.put(acc, key, v)}}
          end

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} ->
        if atom_string_conflict?(map) do
          error(:duplicate_field_conflict)
        else
          {:ok, normalized}
        end

      other ->
        other
    end
  end

  defp normalize_string_keyed_map(_), do: error(:invalid_record)

  defp normalize_key(k) when is_binary(k), do: {:ok, k}
  defp normalize_key(k) when is_atom(k), do: {:ok, Atom.to_string(k)}
  defp normalize_key(_), do: error(:invalid_record)

  defp atom_string_conflict?(map) do
    keys = Map.keys(map)

    string_keys = for k <- keys, is_binary(k), do: k
    atom_as_string = for k <- keys, is_atom(k), do: Atom.to_string(k)

    MapSet.size(MapSet.intersection(MapSet.new(string_keys), MapSet.new(atom_as_string))) > 0
  end

  defp require_id(facts, key, max, re) do
    case Map.fetch(facts, key) do
      {:ok, id} ->
        if valid_id?(id, max, re), do: {:ok, id}, else: error(:invalid_new_input)

      :error ->
        error(:invalid_new_input)
    end
  end

  defp require_digest(facts, key) do
    case Map.fetch(facts, key) do
      {:ok, digest} ->
        if valid_digest?(digest), do: {:ok, digest}, else: error(:digest_missing_or_invalid)

      :error ->
        error(:digest_missing_or_invalid)
    end
  end

  defp require_exact(facts, key, expected, err_tag) do
    case Map.fetch(facts, key) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _} -> error(err_tag)
      :error -> error(err_tag)
    end
  end

  defp require_time(facts, key) do
    case Map.fetch(facts, key) do
      {:ok, t} ->
        if valid_time?(t), do: {:ok, t}, else: error(:timestamp_invalid)

      :error ->
        error(:timestamp_invalid)
    end
  end

  defp require_string(facts, key) do
    case Map.fetch(facts, key) do
      {:ok, v}
      when is_binary(v) and v != "" and byte_size(v) <= @max_string_bytes ->
        if String.valid?(v), do: {:ok, v}, else: error(:invalid_record)

      _ ->
        error(:invalid_record)
    end
  end

  defp require_reason(facts) do
    case Map.fetch(facts, "reason_code") do
      {:ok, code} ->
        if valid_reason_code?(code), do: {:ok, code}, else: error(:invalid_record)

      _ ->
        error(:invalid_record)
    end
  end

  defp optional_reason(facts) do
    case Map.fetch(facts, "reason_code") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, code} ->
        if valid_reason_code?(code), do: {:ok, code}, else: error(:invalid_record)
    end
  end

  defp optional_effect_id(facts) do
    case Map.fetch(facts, "effect_id") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, id} ->
        if valid_id?(id, @max_effect_id_bytes, @operation_id_re),
          do: {:ok, id},
          else: error(:invalid_record)
    end
  end

  defp require_profile_cas(facts) do
    case Map.fetch(facts, "profile_cas") do
      {:ok, cas} when is_map(cas) and not is_struct(cas) ->
        with {:ok, cas} <- normalize_string_keyed_map(cas),
             :ok <- validate_profile_cas_value(cas) do
          {:ok, canonicalize_profile_cas(cas)}
        end

      {:ok, _} ->
        error(:invalid_record)

      :error ->
        error(:profile_cas_required)
    end
  end

  defp canonicalize_profile_cas(%{
         "record_id" => record_id,
         "generation" => generation,
         "revision" => revision
       }) do
    %{
      "record_id" => record_id,
      "generation" => generation,
      "revision" => revision
    }
  end

  defp require_profile_cas_unset(%{"profile_cas" => nil}), do: :ok
  defp require_profile_cas_unset(_), do: error(:profile_cas_immutable)

  defp require_frozen_authority_unset(%{"frozen_authority" => nil}), do: :ok
  defp require_frozen_authority_unset(_), do: error(:frozen_authority_immutable)

  defp require_profile_mutation_replay_unset(%{"profile_mutation_replay" => nil}), do: :ok
  defp require_profile_mutation_replay_unset(_), do: error(:profile_mutation_replay_immutable)

  # Shape/constants/alias admission only. Cannot re-derive digests without the
  # private Record; Preparation recomputes under private evidence and freezes
  # the admitted commitment here.
  defp require_profile_mutation_replay(facts) do
    case Map.fetch(facts, "profile_mutation_replay") do
      {:ok, replay} when is_map(replay) and not is_struct(replay) ->
        case ProfileAuthorityMutationCore.admit_commitment(replay) do
          {:ok, admitted} ->
            {:ok, admitted}

          {:error, :ambiguous_keys} ->
            error(:profile_mutation_replay_invalid)

          {:error, :commitment_shape} ->
            error(:profile_mutation_replay_invalid)

          {:error, _} ->
            error(:profile_mutation_replay_invalid)
        end

      {:ok, _} ->
        error(:profile_mutation_replay_invalid)

      :error ->
        error(:profile_mutation_replay_required)
    end
  end

  defp validate_profile_mutation_replay(%{"profile_mutation_replay" => nil, "phase" => phase})
       when phase in ~w(reserved fenced),
       do: :ok

  defp validate_profile_mutation_replay(%{"profile_mutation_replay" => replay, "phase" => phase})
       when is_map(replay) and phase not in ~w(reserved fenced) do
    case ProfileAuthorityMutationCore.admit_commitment(replay) do
      {:ok, _} -> :ok
      {:error, _} -> error(:profile_mutation_replay_invalid)
    end
  end

  defp validate_profile_mutation_replay(_), do: error(:invalid_record)

  defp require_frozen_authority(facts, record) do
    case Map.fetch(facts, "frozen_authority") do
      {:ok, frozen} when is_map(frozen) and not is_struct(frozen) ->
        # Closed binary keys only — never atom/string alias normalization before
        # equality (that would admit key aliases the caller did not freeze).
        with :ok <- closed_keyset(frozen, @frozen_authority_keys),
             {:ok, canonical} <- admit_and_rederive_frozen(frozen, record) do
          {:ok, canonical}
        else
          {:error, _} = err -> err
          _ -> error(:frozen_authority_invalid)
        end

      {:ok, _} ->
        error(:frozen_authority_invalid)

      :error ->
        error(:frozen_authority_required)
    end
  end

  # Independently re-derive effective capabilities from the operation's
  # canonical desired envelope + target_agent_id + supplied root. The supplied
  # root and caps must already be the exact canonical form: raw supplied
  # values are compared with === to the independent derivation (no pre-normalize
  # that would admit aliases, duplicates, reorderings, or trailing-slash roots).
  defp admit_and_rederive_frozen(frozen, record) do
    supplied_root = Map.get(frozen, "repo_root")
    supplied_caps = Map.get(frozen, "effective_capabilities")

    with {:ok, admitted_root} <- admit_frozen_repo_root(supplied_root),
         true <- is_binary(supplied_root) and supplied_root === admitted_root,
         :ok <- require_raw_capability_list(supplied_caps),
         {:ok, derived} <- derive_effective_capabilities(record, admitted_root),
         true <- derived === supplied_caps do
      {:ok, %{"repo_root" => admitted_root, "effective_capabilities" => derived}}
    else
      {:error, _} = err -> err
      false -> error(:frozen_authority_invalid)
      _ -> error(:frozen_authority_invalid)
    end
  end

  defp admit_frozen_repo_root(root) do
    case TemplateAuthorityCapabilityProjection.admit_canonical_repo_root(root) do
      {:ok, admitted} ->
        {:ok, admitted}

      {:error, {:template_authority_projection, _reason}} ->
        error(:frozen_authority_invalid)

      {:error, _reason} ->
        error(:frozen_authority_invalid)
    end
  end

  # Spine + binary-key shape only. Never Policy.normalize here — that would
  # rewrite aliases/duplicates into the canonical form before equality.
  defp require_raw_capability_list(caps) when is_list(caps) do
    case admit_bounded_list_spine(caps, @max_list_len) do
      :ok -> require_binary_keyed_cap_maps(caps)
      _ -> error(:frozen_authority_invalid)
    end
  end

  defp require_raw_capability_list(_), do: error(:frozen_authority_invalid)

  defp require_binary_keyed_cap_maps([]), do: :ok

  defp require_binary_keyed_cap_maps([cap | rest]) when is_list(rest) do
    if is_map(cap) and not is_struct(cap) and Enum.all?(Map.keys(cap), &is_binary/1) do
      require_binary_keyed_cap_maps(rest)
    else
      error(:frozen_authority_invalid)
    end
  end

  defp require_binary_keyed_cap_maps(_), do: error(:frozen_authority_invalid)

  defp derive_effective_capabilities(record, repo_root) do
    desired = record["desired_authority"]
    envelope = desired && desired["envelope"]
    target = record["target_agent_id"]

    with true <- is_map(envelope),
         snap when is_map(snap) <- TemplateAuthorityPolicy.snapshot(envelope),
         declared when is_list(declared) <- TemplateAuthorityPolicy.capabilities(snap) do
      case TemplateAuthorityCapabilityProjection.project_normalized(declared, target,
             repo_root: repo_root
           ) do
        {:ok, derived} ->
          {:ok, derived}

        {:error, _} ->
          error(:frozen_authority_invalid)
      end
    else
      _ -> error(:frozen_authority_invalid)
    end
  end

  defp require_reconciliation(%{"reconciliation_required" => recon})
       when is_map(recon),
       do: {:ok, recon}

  defp require_reconciliation(_), do: error(:reconciliation_not_required)

  defp require_no_reconciliation(%{"reconciliation_required" => nil}), do: :ok
  defp require_no_reconciliation(_), do: error(:transition_illegal)

  defp admit_retry(nil) do
    {:ok, default_retry(3)}
  end

  defp admit_retry(retry) when is_map(retry) do
    with {:ok, retry} <- admit_event_facts(retry, @retry_input_keys),
         max <- Map.get(retry, "max_attempts", 3),
         true <- is_integer(max) and max >= 1 and max <= @max_retry do
      {:ok, default_retry(max)}
    else
      {:error, _} = err -> err
      _ -> error(:retry_bounds_invalid)
    end
  end

  defp admit_retry(_), do: error(:retry_bounds_invalid)

  defp default_retry(max) do
    %{"attempt" => 0, "max_attempts" => max, "last_code" => nil, "last_effect_id" => nil}
  end

  defp finish(record, effects_fun) when is_function(effects_fun, 1) do
    with {:ok, admitted} <- admit(record) do
      {:ok, admitted, effects_fun.(admitted)}
    end
  end

  defp finish(record, effects) when is_list(effects) do
    with {:ok, admitted} <- admit(record) do
      {:ok, admitted, effects}
    end
  end

  defp require_active(%{"status" => "active"}), do: :ok
  defp require_active(%{"status" => "blocked"}), do: error(:status_blocked)
  defp require_active(_), do: error(:status_not_active)

  defp require_phase(%{"phase" => phase}, phase), do: :ok
  defp require_phase(_, _), do: error(:transition_illegal)

  defp require_phase_intent(%{"phase" => phase}, phase), do: :ok
  defp require_phase_intent(_, _), do: error(:transition_illegal)

  defp require_primary_outcome_phase(%{"phase" => phase})
       when phase in @primary_outcome_phases,
       do: :ok

  defp require_primary_outcome_phase(_), do: error(:transition_illegal)

  defp require_updated_at(%{"updated_at_unix_ms" => prev}, at) when at >= prev, do: :ok
  defp require_updated_at(_, _), do: error(:timestamp_invalid)

  defp phase_index(phase), do: Map.get(@phase_index, phase, -1)

  defp valid_id?(id, max, re)
       when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= max do
    String.valid?(id) and Regex.match?(re, id)
  end

  defp valid_id?(_, _, _), do: false

  defp valid_digest?(digest) when is_binary(digest) do
    byte_size(digest) == 64 and Regex.match?(@digest_re, digest)
  end

  defp valid_digest?(_), do: false

  defp valid_reason_code?(code)
       when is_binary(code) and byte_size(code) > 0 and byte_size(code) <= @max_reason_bytes do
    String.valid?(code) and Regex.match?(@reason_code_re, code)
  end

  defp valid_reason_code?(_), do: false

  defp valid_time?(t) when is_integer(t) and t >= 0 and t <= @max_json_safe_integer, do: true
  defp valid_time?(_), do: false

  defp closed_keyset(map, expected) when is_map(map) do
    keys = Map.keys(map) |> MapSet.new()

    if MapSet.equal?(keys, expected) and Enum.all?(Map.keys(map), &is_binary/1) do
      :ok
    else
      error(:invalid_record)
    end
  end

  defp closed_keyset(_, _), do: error(:invalid_record)

  defp admit_bounded_list_spine(list, max) when is_list(list) and is_integer(max) and max >= 0 do
    admit_bounded_list_spine(list, max, 0)
  end

  defp admit_bounded_list_spine(_, _), do: :improper

  defp admit_bounded_list_spine([], _max, _count), do: :ok

  defp admit_bounded_list_spine([_h | t], max, count) when count < max do
    admit_bounded_list_spine(t, max, count + 1)
  end

  defp admit_bounded_list_spine([_h | _t], _max, _count), do: :too_many
  defp admit_bounded_list_spine(_improper, _max, _count), do: :improper

  defp assert_json_clean(value) do
    case walk_json(value, 0, @max_depth, @max_json_nodes) do
      {:ok, _} -> :ok
      :error -> error(:invalid_record)
    end
  end

  defp walk_json(_value, _depth, _max_depth, nodes_left) when nodes_left <= 0, do: :error
  defp walk_json(nil, _d, _m, n), do: {:ok, n - 1}
  defp walk_json(v, _d, _m, n) when is_boolean(v), do: {:ok, n - 1}

  defp walk_json(v, _d, _m, n) when is_integer(v) do
    if abs(v) <= @max_json_safe_integer, do: {:ok, n - 1}, else: :error
  end

  defp walk_json(v, _d, _m, n) when is_float(v), do: {:ok, n - 1}

  defp walk_json(v, _d, _m, n) when is_binary(v) do
    if byte_size(v) <= @max_input_string_bytes and String.valid?(v),
      do: {:ok, n - 1},
      else: :error
  end

  defp walk_json(list, depth, max_depth, n) when is_list(list) do
    if depth >= max_depth, do: :error, else: walk_json_list(list, depth, max_depth, n - 1, 0)
  end

  defp walk_json(map, depth, max_depth, n) when is_map(map) and not is_struct(map) do
    if depth >= max_depth or map_size(map) > @max_map_keys do
      :error
    else
      Enum.reduce_while(map, {:ok, n - 1}, fn
        {k, v}, {:ok, left} when is_binary(k) ->
          case walk_json(v, depth + 1, max_depth, left) do
            {:ok, left2} -> {:cont, {:ok, left2}}
            :error -> {:halt, :error}
          end

        _, _ ->
          {:halt, :error}
      end)
    end
  end

  defp walk_json(_, _, _, _), do: :error

  defp walk_json_list([], _d, _m, n, _count), do: {:ok, n}

  defp walk_json_list([h | t], depth, max_depth, n, count) when count < @max_list_len do
    case walk_json(h, depth + 1, max_depth, n) do
      {:ok, n2} -> walk_json_list(t, depth, max_depth, n2, count + 1)
      :error -> :error
    end
  end

  defp walk_json_list([_ | _], _, _, _, _), do: :error
  defp walk_json_list(_, _, _, _, _), do: :error

  defp error(reason), do: {:error, {:template_authority_reconciliation_operation, reason}}
end
