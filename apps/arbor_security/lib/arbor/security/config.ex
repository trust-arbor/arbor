defmodule Arbor.Security.Config do
  @moduledoc """
  Application configuration for the Arbor.Security library.

  Wraps `Application.get_env/3` with baked-in defaults.

  A closed set of fail-open-when-false enforcement toggles can be frozen so
  later `Application.put_env/3` cannot weaken the public readers. Production
  `Arbor.Security.Application.start/2` installs the claim table and freezes;
  the test env installs the table but does not auto-freeze.

  Durable AuthorityStore identity is a config-owned absolute state root, frozen
  through an Application-owned ETS claim. `:authority_state_root` is canonical;
  `config :arbor_security, Arbor.Security.Store.JSONFile, base_dir: ...` is a
  legacy alias. Equal canonical paths are one root; unequal paths fail closed.
  Freeze runs only when startup will start durable (non-nil backend) stores.

  ## Configuration

      config :arbor_security,
        authority_state_root: "/var/lib/arbor/security", # canonical durable store root
        identity_verification: true,           # require signed requests for authorization
        nonce_ttl_seconds: 300,                 # nonces expire after 5 minutes
        timestamp_max_drift_seconds: 60,        # accept timestamps within ±60s of now
        capability_signing_required: false       # require signed capabilities (false for migration)
  """

  @app :arbor_security
  @default_consensus_module Module.concat(["Arbor", "Consensus"])
  @default_interaction_router Module.concat(["Arbor", "Comms", "InteractionRouter"])
  @default_signing_authority_bootstrap_grace_ms 60_000
  @max_signing_authority_bootstrap_grace_ms 3_600_000
  @default_signing_authority_broker_call_timeout_ms 5_000
  @max_signing_authority_broker_call_timeout_ms 30_000
  @enforcement_toggle_persistent_key {__MODULE__, :enforcement_toggles}
  @enforcement_toggle_claim_table __MODULE__.EnforcementToggleClaim
  @enforcement_toggle_claim_key :claimed
  # :protected in non-test so only the Application owner can write. Test is
  # :public because ExUnit freeze/restore and the Task-exit regression run
  # outside Application.start/2 and must insert_new/delete the snapshot.
  @enforcement_toggle_claim_table_access if(Mix.env() == :test, do: :public, else: :protected)
  @authority_root_persistent_key {__MODULE__, :authority_root}
  @authority_root_claim_table __MODULE__.AuthorityRootClaim
  @authority_root_claim_key :claimed
  @authority_root_claim_table_access if(Mix.env() == :test, do: :public, else: :protected)
  @json_file_env Arbor.Security.Store.JSONFile
  @config_env Mix.env()
  @repo_root Path.expand("../../../../..", __DIR__)
  @development_authority_root Path.expand(".arbor/security", @repo_root)
  @authority_root_sources [:configured, :legacy_jsonfile_base_dir, :development_default]
  @audit_journal_modes [:durable, :ephemeral, :disabled]
  @default_audit_journal_mode if(@config_env == :test, do: :ephemeral, else: :durable)
  @default_audit_journal_call_timeout_ms 5_000
  @max_audit_journal_call_timeout_ms 30_000
  @type startup_inputs :: %{
          start_children: term(),
          start_profile: atom(),
          backend: module() | nil,
          capabilities_hydration_limit: pos_integer(),
          journal_mode: :durable | :ephemeral | :disabled | :invalid
        }
  @type startup_store_snapshot :: %{
          start_children: term(),
          start_profile: atom(),
          backend: module() | nil,
          capabilities_hydration_limit: pos_integer(),
          root: String.t() | nil,
          journal_mode: :durable | :ephemeral | :disabled,
          journal_reason: :none | :disabled | :activation_only
        }
  @enforcement_toggle_defaults [
    identity_verification: true,
    capability_signing_required: true,
    constraint_enforcement_enabled: true,
    reflex_checking_enabled: true,
    consensus_escalation_enabled: true,
    quota_enforcement_enabled: true,
    policy_enforcer_enabled: true,
    delegation_chain_verification_enabled: true,
    strict_identity_mode: false,
    distributed_signals: true
  ]

  @doc """
  Snapshot the closed fail-open-when-false enforcement toggles.

  The first installer wins atomically by `insert_new` of the snapshot
  itself into the Application-owned ETS table. `persist_if_absent` to
  `persistent_term` may follow that insert; an existing `persistent_term`
  map is never overwritten. If `persistent_term` is absent, readers and
  later freeze use or complete that exact ETS snapshot rather than
  re-reading Application env. Later `Application.put_env/3` of a frozen
  key cannot change the matching public reader. Recreating the claim
  table after Application stop/start rehydrates the table from that
  snapshot and does not re-read Application env. Production application
  start installs the Application-owned claim table and calls
  `maybe_freeze_enforcement_toggles/1`; tests that need the pin must call
  this explicitly and restore afterward. This function never creates the
  claim table; a missing table fails closed.
  """
  @spec freeze_enforcement_toggles() :: :ok
  def freeze_enforcement_toggles do
    case installed_enforcement_toggle_snapshot() do
      {:ok, snapshot} ->
        complete_enforcement_toggle_snapshot(snapshot)

      :absent ->
        snapshot = snapshot_enforcement_toggles()

        if insert_enforcement_toggle_snapshot_if_absent(snapshot) do
          run_enforcement_toggle_freeze_after_ets_insert_test_seam()
          persist_enforcement_toggle_snapshot_if_absent(snapshot)
        else
          case lookup_enforcement_toggle_ets_snapshot() do
            {:ok, existing} -> persist_enforcement_toggle_snapshot_if_absent(existing)
            :absent -> :ok
          end
        end
    end

    :ok
  end

  @doc false
  @spec ensure_enforcement_toggle_claim_table() :: :ok | {:error, term()}
  def ensure_enforcement_toggle_claim_table do
    result =
      case :ets.whereis(@enforcement_toggle_claim_table) do
        :undefined ->
          create_enforcement_toggle_claim_table()

        _tid ->
          accept_owned_enforcement_toggle_claim_table()
      end

    with :ok <- result do
      rehydrate_enforcement_toggle_claim_from_snapshot()
    end
  end

  @doc """
  Freeze enforcement toggles on application start, except in `:test`.
  """
  @spec maybe_freeze_enforcement_toggles(atom()) :: :ok
  def maybe_freeze_enforcement_toggles(:test), do: :ok
  def maybe_freeze_enforcement_toggles(_env), do: freeze_enforcement_toggles()

  if Mix.env() == :test do
    @doc false
    @spec restore_enforcement_toggles() :: :ok
    def restore_enforcement_toggles do
      :persistent_term.erase(@enforcement_toggle_persistent_key)
      release_enforcement_toggle_freeze_claim()
      :ok
    end

    @doc false
    @spec restore_authority_root() :: :ok
    def restore_authority_root do
      :persistent_term.erase(@authority_root_persistent_key)
      release_authority_root_freeze_claim()
      :ok
    end

    defp release_enforcement_toggle_freeze_claim do
      case :ets.whereis(@enforcement_toggle_claim_table) do
        :undefined -> :ok
        tid -> :ets.delete(tid, @enforcement_toggle_claim_key)
      end
    end

    defp release_authority_root_freeze_claim do
      case :ets.whereis(@authority_root_claim_table) do
        :undefined -> :ok
        tid -> :ets.delete(tid, @authority_root_claim_key)
      end
    end
  end

  @doc """
  Whether identity verification is enabled for authorization checks.

  When disabled, `authorize/4` skips signed request verification, allowing
  legacy string agent IDs to work without cryptographic identity.
  """
  @spec identity_verification_enabled?() :: boolean()
  def identity_verification_enabled? do
    enforcement_toggle(:identity_verification, true)
  end

  @doc """
  How long nonces are remembered for replay protection (in seconds).
  """
  @spec nonce_ttl_seconds() :: pos_integer()
  def nonce_ttl_seconds do
    Application.get_env(@app, :nonce_ttl_seconds, 300)
  end

  @doc """
  Maximum allowed clock drift between request timestamp and server time (in seconds).
  """
  @spec timestamp_max_drift_seconds() :: pos_integer()
  def timestamp_max_drift_seconds do
    Application.get_env(@app, :timestamp_max_drift_seconds, 60)
  end

  @doc """
  Grace period for an unclaimed or reclaimable signing-authority bootstrap.

  Defaults to 60 seconds. Invalid configuration falls back to the secure
  packaged default, and oversized values are capped at one hour rather than
  creating an unsafe or timer-hostile slot.
  """
  @spec signing_authority_bootstrap_grace_ms() :: pos_integer()
  def signing_authority_bootstrap_grace_ms do
    case Application.get_env(
           @app,
           :signing_authority_bootstrap_grace_ms,
           @default_signing_authority_bootstrap_grace_ms
         ) do
      grace_ms when is_integer(grace_ms) and grace_ms > 0 ->
        min(grace_ms, @max_signing_authority_bootstrap_grace_ms)

      _invalid ->
        @default_signing_authority_bootstrap_grace_ms
    end
  end

  @doc false
  @spec signing_authority_bootstrap_max_grace_ms() :: pos_integer()
  def signing_authority_bootstrap_max_grace_ms,
    do: @max_signing_authority_bootstrap_grace_ms

  @doc """
  Timeout for calls into the signing-authority broker.

  The value is bounded to keep one-shot key-holder lifetimes and caller waits
  finite even under bad runtime configuration.
  """
  @spec signing_authority_broker_call_timeout_ms() :: pos_integer()
  def signing_authority_broker_call_timeout_ms do
    case Application.get_env(
           @app,
           :signing_authority_broker_call_timeout_ms,
           @default_signing_authority_broker_call_timeout_ms
         ) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        min(timeout_ms, @max_signing_authority_broker_call_timeout_ms)

      _invalid ->
        @default_signing_authority_broker_call_timeout_ms
    end
  end

  @doc false
  @spec run_signing_authority_ephemeral_open_test_seam(reference()) :: :ok
  if Mix.env() == :test do
    def run_signing_authority_ephemeral_open_test_seam(request_id) do
      case Application.get_env(@app, :signing_authority_ephemeral_open_test_seam) do
        %{delay_ms: delay_ms, notify_pid: notify_pid} = seam
        when map_size(seam) == 2 and is_integer(delay_ms) and delay_ms in 1..1_000 and
               is_pid(notify_pid) ->
          send(notify_pid, {:ephemeral_open_committed, request_id})
          Process.sleep(delay_ms)
          :ok

        _disabled_or_invalid ->
          :ok
      end
    end
  else
    def run_signing_authority_ephemeral_open_test_seam(_request_id), do: :ok
  end

  @doc false
  @spec run_signing_authority_persistent_open_test_seam(reference()) :: :ok
  if Mix.env() == :test do
    def run_signing_authority_persistent_open_test_seam(request_id) do
      case Application.get_env(@app, :signing_authority_persistent_open_test_seam) do
        %{delay_ms: delay_ms, notify_pid: notify_pid} = seam
        when map_size(seam) == 2 and is_integer(delay_ms) and delay_ms in 1..1_000 and
               is_pid(notify_pid) ->
          send(notify_pid, {:persistent_open_committed, request_id})
          Process.sleep(delay_ms)
          :ok

        _disabled_or_invalid ->
          :ok
      end
    end
  else
    def run_signing_authority_persistent_open_test_seam(_request_id), do: :ok
  end

  @doc false
  @spec run_signing_authority_persistent_finalize_test_seam(reference()) :: :ok
  if Mix.env() == :test do
    def run_signing_authority_persistent_finalize_test_seam(request_id) do
      case Application.get_env(@app, :signing_authority_persistent_finalize_test_seam) do
        %{delay_ms: delay_ms, notify_pid: notify_pid} = seam
        when map_size(seam) == 2 and is_integer(delay_ms) and delay_ms in 1..1_000 and
               is_pid(notify_pid) ->
          send(notify_pid, {:persistent_finalize_prepared, request_id})
          Process.sleep(delay_ms)
          :ok

        _disabled_or_invalid ->
          :ok
      end
    end
  else
    def run_signing_authority_persistent_finalize_test_seam(_request_id), do: :ok
  end

  @doc false
  @spec run_enforcement_toggle_freeze_after_ets_insert_test_seam() :: :ok
  if Mix.env() == :test do
    def run_enforcement_toggle_freeze_after_ets_insert_test_seam do
      case Application.get_env(@app, :enforcement_toggle_freeze_after_ets_insert_test_seam) do
        %{delay_ms: delay_ms, notify_pid: notify_pid} = seam
        when map_size(seam) == 2 and is_integer(delay_ms) and delay_ms in 1..1_000 and
               is_pid(notify_pid) ->
          send(notify_pid, :enforcement_toggle_ets_snapshot_inserted)
          Process.sleep(delay_ms)
          :ok

        _disabled_or_invalid ->
          :ok
      end
    end
  else
    def run_enforcement_toggle_freeze_after_ets_insert_test_seam, do: :ok
  end

  @doc false
  @spec run_authority_root_freeze_after_ets_insert_test_seam() :: :ok
  if Mix.env() == :test do
    def run_authority_root_freeze_after_ets_insert_test_seam do
      case Application.get_env(@app, :authority_root_freeze_after_ets_insert_test_seam) do
        %{delay_ms: delay_ms, notify_pid: notify_pid} = seam
        when map_size(seam) == 2 and is_integer(delay_ms) and delay_ms in 1..1_000 and
               is_pid(notify_pid) ->
          send(notify_pid, :authority_root_ets_snapshot_inserted)
          Process.sleep(delay_ms)
          :ok

        _disabled_or_invalid ->
          :ok
      end
    end
  else
    def run_authority_root_freeze_after_ets_insert_test_seam, do: :ok
  end

  @doc """
  Whether capability signing is required for authorization.

  When `true` (default), all capabilities must have a valid issuer signature.
  When `false`, unsigned capabilities are accepted (backward compatibility only).
  """
  @spec capability_signing_required?() :: boolean()
  def capability_signing_required? do
    enforcement_toggle(:capability_signing_required, true)
  end

  @doc """
  Whether constraint enforcement is enabled for authorization.

  When `true` (default), constraints on capabilities are evaluated during `authorize/4`.
  When `false`, constraints are metadata-only and not enforced.
  """
  @spec constraint_enforcement_enabled?() :: boolean()
  def constraint_enforcement_enabled? do
    enforcement_toggle(:constraint_enforcement_enabled, true)
  end

  @doc """
  Whether reflex checking is enabled for authorization.

  When `true` (default), reflexes are checked before capability verification.
  Reflexes provide instant safety blocks for obviously dangerous actions.
  When `false`, reflexes are skipped entirely.
  """
  @spec reflex_checking_enabled?() :: boolean()
  def reflex_checking_enabled? do
    enforcement_toggle(:reflex_checking_enabled, true)
  end

  @doc """
  The period over which rate limit tokens fully refill (in seconds).

  A capability with `rate_limit: 100` gets 100 tokens per refill period.
  Default: 3600 (1 hour).
  """
  @spec rate_limit_refill_period_seconds() :: pos_integer()
  def rate_limit_refill_period_seconds do
    Application.get_env(@app, :rate_limit_refill_period_seconds, 3600)
  end

  @doc """
  How long an inactive rate limit bucket is kept before cleanup (in seconds).

  Default: 3600 (1 hour).
  """
  @spec rate_limit_bucket_ttl_seconds() :: pos_integer()
  def rate_limit_bucket_ttl_seconds do
    Application.get_env(@app, :rate_limit_bucket_ttl_seconds, 3600)
  end

  @doc """
  Interval between stale bucket cleanup sweeps (in milliseconds).

  Default: 300_000 (5 minutes).
  """
  @spec rate_limit_cleanup_interval_ms() :: pos_integer()
  def rate_limit_cleanup_interval_ms do
    Application.get_env(@app, :rate_limit_cleanup_interval_ms, 300_000)
  end

  @doc """
  Whether consensus escalation is enabled for `requires_approval` constraints.

  When `true` (default), capabilities with `requires_approval: true` trigger
  consensus submission through the configured `consensus_module`.
  When `false`, `requires_approval` is ignored (treated as always approved).
  """
  @spec consensus_escalation_enabled?() :: boolean()
  def consensus_escalation_enabled? do
    enforcement_toggle(:consensus_escalation_enabled, true)
  end

  @doc """
  The module to use for consensus submission.

  Must implement `submit/2` returning `{:ok, proposal_id}` or `{:error, reason}`.
  Default: `Arbor.Consensus` (if available).

  Set to `nil` to disable consensus integration entirely.
  """
  @spec consensus_module() :: module() | nil
  def consensus_module do
    Application.get_env(@app, :consensus_module, @default_consensus_module)
  end

  @doc """
  Whether `Escalation.maybe_escalate/3` should route through
  `interaction_router/0` (non-blocking) instead of the legacy
  `Consensus.Coordinator.submit` path (blocking 30s GenServer call).

  Default `false` for backward compatibility. When the InteractionRouter
  + at least one channel adapter is wired and operators have verified
  the new approval UX, flip to `true`. Setting to `true` requires the
  configured router (default `Arbor.Comms.InteractionRouter`) to be
  loaded at runtime; if it isn't the code falls back to the consensus
  path automatically.
  """
  @spec use_interaction_router_for_approval?() :: boolean()
  def use_interaction_router_for_approval? do
    Application.get_env(@app, :use_interaction_router_for_approval, false)
  end

  @doc """
  Module implementing `Arbor.Security.Contracts.InteractionRouter`.

  Default: `Arbor.Comms.InteractionRouter`, resolved at runtime via
  `Module.concat/1` so this library does not compile against arbor_comms.
  Tests inject a local fake. When the configured module is not loaded or
  does not export `request/2`, escalation falls back to the consensus path.
  """
  @spec interaction_router() :: module()
  def interaction_router do
    Application.get_env(@app, :interaction_router, @default_interaction_router)
  end

  # ===========================================================================
  # Quota Configuration (Phase 7)
  # ===========================================================================

  @doc """
  Maximum number of capabilities a single agent can hold.

  Default: 1000. When exceeded, `grant/1` returns
  `{:error, {:quota_exceeded, :per_agent_capability_limit, ...}}`.
  """
  @spec max_capabilities_per_agent() :: pos_integer()
  def max_capabilities_per_agent do
    Application.get_env(@app, :max_capabilities_per_agent, 1000)
  end

  @doc """
  Maximum total capabilities stored in the system.

  Default: 100_000. When exceeded, `grant/1` returns
  `{:error, {:quota_exceeded, :global_capability_limit, ...}}`.
  """
  @spec max_global_capabilities() :: pos_integer()
  def max_global_capabilities do
    Application.get_env(@app, :max_global_capabilities, 100_000)
  end

  @doc """
  Maximum delegation chain depth allowed.

  Default: 10. Capabilities with `delegation_depth > max_delegation_depth`
  are rejected on store with `{:error, {:quota_exceeded, :delegation_depth_limit, ...}}`.
  """
  @spec max_delegation_depth() :: non_neg_integer()
  def max_delegation_depth do
    Application.get_env(@app, :max_delegation_depth, 10)
  end

  @doc """
  Whether quota enforcement is enabled.

  Default: true. When false, all quota checks are skipped.
  Useful for testing or migration scenarios.
  """
  @spec quota_enforcement_enabled?() :: boolean()
  def quota_enforcement_enabled? do
    enforcement_toggle(:quota_enforcement_enabled, true)
  end

  @doc """
  Compatibility reader for the trust-layer PolicyEnforcer switch.

  A1 moved JIT policy minting out of `arbor_security`; `authorize/4` no longer
  consults this flag. `Arbor.Trust.Config.policy_enforcer_enabled?/0` reads the
  trust key first and falls back to this historical key during config migration.
  """
  @spec policy_enforcer_enabled?() :: boolean()
  def policy_enforcer_enabled? do
    enforcement_toggle(:policy_enforcer_enabled, true)
  end

  @doc """
  The registration-authorization policy module (C10), or `nil`.

  When set, `Identity.Registry.register/2` calls
  `policy.authorize_registration(identity, opts) :: :ok | {:error, reason}`
  before creating a NEW identity — the chokepoint for gating who may mint
  identities once an external registration path exists (e.g. require a signed
  enrollment token or operator approval).

  Default `nil` (allow): every current registration caller is internal
  (agent lifecycle, scheduler) and trusted. The self-certifying check
  (`agent_id == hash(pubkey)`) runs regardless of policy and a configured
  policy that crashes fails closed.
  """
  @spec registration_policy() :: module() | nil
  def registration_policy do
    Application.get_env(@app, :registration_policy, nil)
  end

  @doc """
  The module used to look up authorizing capabilities.

  Must implement `find_authorizing/2`. Defaults to
  `Arbor.Security.CapabilityStore`. Overridable so tests can simulate a
  store outage (a stub whose `find_authorizing/2` raises) and exercise the
  preloaded-capability fallback path.
  """
  @spec capability_store_module() :: module()
  def capability_store_module do
    Application.get_env(@app, :capability_store_module, Arbor.Security.CapabilityStore)
  end

  @doc """
  The module used to verify human session tokens during authorization.

  Must implement `verify/1` returning `{:ok, principal_id}` or `{:error, reason}`.
  Defaults to `Arbor.Security.SessionToken`. Overridable so public-path tests
  can prove error/raise/throw/exit outcomes fail closed without a public
  collaborator argument on `authorize/4`.
  """
  @spec session_token_module() :: module()
  def session_token_module do
    Application.get_env(@app, :session_token_module, Arbor.Security.SessionToken)
  end

  @doc """
  The module used to verify capability delegation-chain signatures.

  Must implement `verify_delegation_chain/2`. Defaults to
  `Arbor.Security.Signer`. Overridable so tests can substitute a stub
  (e.g. one that raises, to prove the auth chain fails closed when
  delegation verification crashes).
  """
  @spec delegation_signer_module() :: module()
  def delegation_signer_module do
    Application.get_env(@app, :delegation_signer_module, Arbor.Security.Signer)
  end

  @doc """
  The module used for capability-bound filesystem path checks.

  Must implement `authorize/3` and `normalize_uri_path_for_capability/2`.
  Defaults to `Arbor.Security.FileGuard`. Overridable so tests can
  substitute a stub (e.g. one that raises, to prove the auth chain fails
  closed when path validation is unavailable).
  """
  @spec file_guard_module() :: module()
  def file_guard_module do
    Application.get_env(@app, :file_guard_module, Arbor.Security.FileGuard)
  end

  @doc """
  Whether strict identity mode is enabled.

  When `true`, unknown (unregistered) identities are rejected during
  authorization. When `false` (default), unknown identities proceed to
  capability check — the capability lookup handles unknown principals.

  Enable in production for fail-closed identity enforcement (H2).
  """
  @spec strict_identity_mode?() :: boolean()
  def strict_identity_mode? do
    enforcement_toggle(:strict_identity_mode, false)
  end

  # ===========================================================================
  # Invocation Receipts
  # ===========================================================================

  @doc """
  Whether signed invocation receipts are generated on authorization.

  When `true`, every successful authorization produces a signed receipt
  that cryptographically proves who did what, when, and with which capability.
  Default: false (opt-in, since it adds a GenServer call per authorization).
  """
  @spec invocation_receipts_enabled?() :: boolean()
  def invocation_receipts_enabled? do
    Application.get_env(@app, :invocation_receipts_enabled, false)
  end

  # ===========================================================================
  # Delegation Chain Verification
  # ===========================================================================

  @doc """
  Whether delegation chain verification is enabled during authorization.

  When `true` (default), capabilities with delegation chains have each
  delegation record's signature verified against the delegator's public key.
  When `false`, delegation chains are accepted without cryptographic verification.
  """
  @spec delegation_chain_verification_enabled?() :: boolean()
  def delegation_chain_verification_enabled? do
    enforcement_toggle(:delegation_chain_verification_enabled, true)
  end

  # ===========================================================================
  # Role Configuration
  # ===========================================================================

  @doc """
  Default role assigned to human identities after OIDC authentication.

  M1: default used to be `:admin` — every OIDC user got root-equivalent
  capabilities. Now `:viewer` (least privilege). Operators that want a
  different default opt in via `config :arbor_security, :default_human_role`.
  """
  @spec default_human_role() :: atom()
  def default_human_role do
    Application.get_env(@app, :default_human_role, :viewer)
  end

  # ===========================================================================
  # Distributed Security
  # ===========================================================================

  @doc """
  Whether the SystemAuthority keypair should be persisted across restarts.

  When `:persistent` (default), the keypair is saved to the signing keys
  BufferedStore and loaded on subsequent startups. All nodes in the cluster
  share the same keypair, enabling cross-node capability verification.

  When `:ephemeral`, a fresh keypair is generated on every startup (legacy
  behavior for single-node or test environments).
  """
  @spec system_authority_mode() :: :persistent | :ephemeral
  def system_authority_mode do
    Application.get_env(@app, :system_authority_mode, :persistent)
  end

  @doc """
  Whether to emit distributed signals on capability state changes.

  When `true`, the CapabilityStore and Identity.Registry emit `:security`
  signals when capabilities are granted/revoked and identities are
  registered/deregistered. Peer nodes subscribe to these signals and
  invalidate their local caches.

  Default: `true` when the flag is unset. Effective enablement also
  requires a usable Signals security-sync subscriber map. An empty or
  missing map is local-only so a fresh VM can start without aborting
  on `:unauthorized` cluster subscriptions.
  """
  @spec distributed_signals_enabled?() :: boolean()
  def distributed_signals_enabled? do
    enforcement_toggle(:distributed_signals, true) and
      Arbor.Security.SignalSync.transport_configured?()
  end

  # Production is "a connected node could accept a replayed signed request",
  # which `ReplayPeers` narrows from bare `Node.list() != []` to peers that
  # actually run :arbor_security — see that module for why, and for the
  # fail-closed rules (anything not positively foreign counts as a peer).
  # The :test seam can only add presence and cannot hide connected peers or
  # re-open multi-node acceptance.
  @doc false
  @spec cluster_peers_present?() :: boolean()
  def cluster_peers_present? do
    Arbor.Security.Identity.ReplayPeers.peers_present?() or
      test_injected_cluster_peers_present?()
  end

  @doc """
  Whether signed-request replay protection holds well enough to accept one.

  Refuses when a connected node could accept the same `SignedRequest`
  replayed against it — that is, a peer running `:arbor_security`. Peers
  that cannot verify the signature at all are not replay targets and do not
  refuse the request; see `Arbor.Security.Identity.ReplayPeers`.

  Deliberately does NOT consult `authenticated_security_sync_transport?`.
  That flag governs whether remote *capability and identity* mutations may
  be applied; it says nothing about nonce propagation, which no transport
  currently performs. Reading it here implied that enabling security sync
  would make multi-node signed requests safe, which is false. The real
  successor is per-nonce ownership within the zone — see the 2026-08-19
  section of `.arbor/roadmap/1-brainstorming/`
  `trust-zone-segmentation-architecture.md`.
  """
  @spec admit_cluster_signed_request_replay_protection() ::
          :ok | {:error, :cluster_replay_protection_unavailable}
  def admit_cluster_signed_request_replay_protection do
    if cluster_peers_present?() do
      {:error, :cluster_replay_protection_unavailable}
    else
      :ok
    end
  end

  if Mix.env() == :test do
    @doc false
    @spec inject_test_cluster_peers_present(boolean()) :: :ok
    def inject_test_cluster_peers_present(present) when is_boolean(present) do
      Process.put({__MODULE__, :test_inject_cluster_peers_present}, present)
      :ok
    end

    defp test_injected_cluster_peers_present? do
      Process.get({__MODULE__, :test_inject_cluster_peers_present}) == true
    end
  else
    defp test_injected_cluster_peers_present?, do: false
  end

  # ===========================================================================
  # OIDC Configuration
  # ===========================================================================

  @doc """
  Returns the full OIDC configuration.

  Delegates to `Arbor.Security.OIDC.Config.get/0`.
  """
  @spec oidc_config() :: keyword()
  defdelegate oidc_config, to: Arbor.Security.OIDC.Config, as: :get

  @doc """
  Whether OIDC authentication is enabled.

  Returns `true` if at least one provider or device flow is configured.
  """
  @spec oidc_enabled?() :: boolean()
  defdelegate oidc_enabled?, to: Arbor.Security.OIDC.Config, as: :enabled?

  # ===========================================================================
  # Interactive Disclosure Capability (VP-05D2A0)
  # ===========================================================================

  @default_disclosure_ttl_seconds 900
  @max_disclosure_ttl_seconds 3600

  @doc """
  Maximum lifetime, in seconds, of an interactive disclosure capability.

  Default 900 (15 minutes). A configured value must be a positive integer;
  malformed or oversized configuration falls back to the packaged default /
  is hard-capped at 3600, never propagated as-is.
  """
  @spec disclosure_capability_max_ttl_seconds() :: pos_integer()
  def disclosure_capability_max_ttl_seconds do
    case Application.get_env(
           @app,
           :disclosure_capability_max_ttl_seconds,
           @default_disclosure_ttl_seconds
         ) do
      ttl when is_integer(ttl) and ttl > 0 -> min(ttl, @max_disclosure_ttl_seconds)
      _invalid -> @default_disclosure_ttl_seconds
    end
  end

  @default_disclosure_route_field_max_bytes 256
  @max_disclosure_route_field_max_bytes 1024

  @doc """
  Maximum byte length of a disclosure capability route field (destination,
  provider, runtime, model). Default 256, hard-capped at 1024.
  """
  @spec disclosure_capability_route_field_max_bytes() :: pos_integer()
  def disclosure_capability_route_field_max_bytes do
    case Application.get_env(
           @app,
           :disclosure_capability_route_field_max_bytes,
           @default_disclosure_route_field_max_bytes
         ) do
      n when is_integer(n) and n > 0 -> min(n, @max_disclosure_route_field_max_bytes)
      _invalid -> @default_disclosure_route_field_max_bytes
    end
  end

  # No `disclosure_accepted_providers`/`disclosure_accepted_runtimes` config
  # accessors here (deliberately removed per operator correction): `provider`
  # is the caller's exact selected catalog/provider route identity — Arbor's
  # live provider catalog lives in arbor_llm/arbor_ai, both above
  # arbor_security in the dependency hierarchy, so this layer cannot and must
  # not gate it behind a fixed allowlist. `runtime` is validated in
  # `Arbor.Security.DisclosureCapability` against Arbor's own source-owned
  # runtime axis (`"arbor"` / `"acp"`) as a hardcoded structural constant, not
  # an operator-configurable value.

  @doc """
  Module implementing `Arbor.Security.Contracts.EventLogAdapter`, or `nil`.

  Unset by default. The host composes an implementation; persist failures
  remain best-effort in `Arbor.Security.Events`.
  """
  @spec event_log_adapter() :: module() | nil
  def event_log_adapter do
    Application.get_env(@app, :event_log_adapter, nil)
  end

  # ===========================================================================
  # Authority state root freeze
  # ===========================================================================

  @doc """
  Canonical accessor for the configured Application-owned AuthorityStore backend.

  Defaults to `Arbor.Security.Store.JSONFile`. `nil` selects ephemeral stores.
  """
  @spec storage_backend() :: module() | nil
  def storage_backend do
    Application.get_env(@app, :storage_backend, @json_file_env)
  end

  @doc false
  @spec development_authority_root() :: String.t()
  def development_authority_root, do: @development_authority_root

  @doc """
  Snapshot start_children, start_profile, backend, hydration limit, and journal mode once.

  Does not freeze or read the authority root.
  """
  @spec snapshot_startup_inputs() :: startup_inputs()
  def snapshot_startup_inputs do
    %{
      start_children: Application.get_env(@app, :start_children, true),
      start_profile: Arbor.KernelRuntime.Config.start_profile(),
      backend: storage_backend(),
      capabilities_hydration_limit: max_global_capabilities(),
      journal_mode: configured_journal_mode()
    }
  end

  @doc """
  Compute the durable child-spec snapshot, freezing the authority root when needed.

  `context` is `:application` or `:test_bootstrap`. Freeze runs only when that
  context will start durable (non-nil backend) AuthorityStore children or a
  serving durable audit journal.
  """
  @spec startup_store_snapshot(:application | :test_bootstrap) ::
          {:ok, startup_store_snapshot()} | {:error, term()}
  def startup_store_snapshot(context) when context in [:application, :test_bootstrap] do
    inputs = snapshot_startup_inputs()

    with {:ok, journal_mode, journal_reason} <- effective_journal_mode(inputs) do
      inputs =
        inputs
        |> Map.put(:journal_mode, journal_mode)
        |> Map.put(:journal_reason, journal_reason)

      if needs_durable_root?(inputs, context) do
        with :ok <- freeze_authority_root(),
             {:ok, root} <- authority_root() do
          {:ok, Map.put(inputs, :root, root)}
        end
      else
        {:ok, Map.put(inputs, :root, nil)}
      end
    end
  end

  @doc """
  Frozen absolute authority state root, or `{:error, :authority_root_not_frozen}`.
  """
  @spec authority_root() :: {:ok, String.t()} | {:error, :authority_root_not_frozen}
  def authority_root do
    case installed_authority_root_snapshot() do
      {:ok, %{root: root}} when is_binary(root) and byte_size(root) > 0 ->
        {:ok, root}

      _not_frozen ->
        {:error, :authority_root_not_frozen}
    end
  end

  @doc """
  Freeze the canonical absolute authority root.

  ETS `insert_new` of the snapshot map is the atomic claim. `persistent_term`
  persist-if-absent may follow; it is not the claim. A missing claim table
  fails closed. An already-installed snapshot is completed, never replaced.
  """
  @spec freeze_authority_root() :: :ok | {:error, term()}
  def freeze_authority_root do
    case installed_authority_root_snapshot() do
      {:ok, snapshot} ->
        complete_authority_root_snapshot(snapshot)
        :ok

      :absent ->
        case compute_authority_root_candidate() do
          {:ok, snapshot} -> claim_authority_root_snapshot(snapshot)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc false
  @spec ensure_authority_root_claim_table() :: :ok | {:error, term()}
  def ensure_authority_root_claim_table do
    result =
      case :ets.whereis(@authority_root_claim_table) do
        :undefined ->
          create_authority_root_claim_table()

        _tid ->
          accept_owned_authority_root_claim_table()
      end

    with :ok <- result do
      rehydrate_authority_root_claim_from_snapshot()
    end
  end

  @doc """
  Keyword options for one Application/TestBootstrap AuthorityStore child.

  `snapshot.backend` and, when the backend is a module, `snapshot.root` as
  `base_dir` are the final overrides. Extra `:backend`, `:backend_opts`,
  `:name`, and `:namespace` cannot replace them.
  """
  @spec authority_store_start_opts(atom(), String.t(), map(), keyword()) :: keyword()
  def authority_store_start_opts(name, namespace, snapshot, extra \\ [])
      when is_atom(name) and is_map(snapshot) and is_list(extra) do
    dropped = Keyword.drop(extra, [:backend, :backend_opts, :name, :namespace])

    backend_opts0 =
      case Keyword.get(extra, :backend_opts, []) do
        opts when is_list(opts) -> opts
        _invalid -> []
      end

    backend_opts =
      if is_nil(snapshot.backend) do
        backend_opts0
      else
        Keyword.put(backend_opts0, :base_dir, snapshot.root)
      end

    dropped
    |> Keyword.merge(name: name, namespace: namespace, backend: snapshot.backend)
    |> Keyword.put(:backend_opts, backend_opts)
  end

  @doc """
  Closed keyword options for the Application/TestBootstrap audit-journal owner.

  Callers cannot select a path, file module, callback, backend, or name.
  Non-durable modes never receive a root.
  """
  @spec audit_journal_start_opts(map()) :: keyword()
  def audit_journal_start_opts(snapshot) when is_map(snapshot) do
    mode = Map.get(snapshot, :journal_mode)
    reason = Map.get(snapshot, :journal_reason, :none)
    root = Map.get(snapshot, :root)

    case {mode, reason, root} do
      {:disabled, :activation_only, _root} ->
        [mode: :disabled, reason: :activation_only]

      {:disabled, :disabled, _root} ->
        [mode: :disabled, reason: :disabled]

      {:ephemeral, :none, _root} ->
        [mode: :ephemeral]

      {:durable, :none, root} when is_binary(root) and byte_size(root) > 0 ->
        [mode: :durable, root: root]

      _other ->
        raise ArgumentError, "invalid audit journal snapshot"
    end
  end

  @doc """
  Timeout for calls into the audit-journal owner.

  Bounded so a stuck writer cannot block callers indefinitely.
  """
  @spec audit_journal_call_timeout_ms() :: pos_integer()
  def audit_journal_call_timeout_ms do
    case Application.get_env(
           @app,
           :audit_journal_call_timeout_ms,
           @default_audit_journal_call_timeout_ms
         ) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        min(timeout_ms, @max_audit_journal_call_timeout_ms)

      _invalid ->
        @default_audit_journal_call_timeout_ms
    end
  end

  defp enforcement_toggle(key, default) do
    case installed_enforcement_toggle_snapshot() do
      {:ok, %{^key => value}} -> value
      _not_frozen -> Application.get_env(@app, key, default)
    end
  end

  defp snapshot_enforcement_toggles do
    Map.new(@enforcement_toggle_defaults, fn {key, default} ->
      {key, Application.get_env(@app, key, default)}
    end)
  end

  # ETS insert_new of the snapshot is the single-winner claim. A boolean
  # :claimed followed by a later persistent_term.put leaves readers on
  # mutable env if the winner dies in that window. persist_if_absent may
  # follow the insert; if persistent_term is absent, readers and later
  # freeze use that exact ETS snapshot. The Application process owns the
  # table; never create it here. A missing table fails closed so a later
  # caller cannot reopen freeze.
  defp installed_enforcement_toggle_snapshot do
    case :persistent_term.get(@enforcement_toggle_persistent_key, :not_frozen) do
      snapshot when is_map(snapshot) ->
        {:ok, snapshot}

      _not_frozen ->
        lookup_enforcement_toggle_ets_snapshot()
    end
  end

  defp complete_enforcement_toggle_snapshot(snapshot) do
    insert_enforcement_toggle_snapshot_if_absent(snapshot)
    persist_enforcement_toggle_snapshot_if_absent(snapshot)
  end

  defp insert_enforcement_toggle_snapshot_if_absent(snapshot) do
    case :ets.whereis(@enforcement_toggle_claim_table) do
      :undefined ->
        false

      tid ->
        try do
          :ets.insert_new(tid, {@enforcement_toggle_claim_key, snapshot})
        rescue
          ArgumentError ->
            false
        end
    end
  end

  defp lookup_enforcement_toggle_ets_snapshot do
    case :ets.whereis(@enforcement_toggle_claim_table) do
      :undefined ->
        :absent

      tid ->
        try do
          case :ets.lookup(tid, @enforcement_toggle_claim_key) do
            [{@enforcement_toggle_claim_key, snapshot}] when is_map(snapshot) ->
              {:ok, snapshot}

            _missing_or_invalid ->
              :absent
          end
        rescue
          ArgumentError ->
            :absent
        end
    end
  end

  # First snapshot wins for the VM lifetime. persist_if_absent never
  # overwrites an existing persistent_term map, including extra keys.
  defp persist_enforcement_toggle_snapshot_if_absent(snapshot) do
    case :persistent_term.get(@enforcement_toggle_persistent_key, :not_frozen) do
      existing when is_map(existing) ->
        :ok

      _not_frozen ->
        :persistent_term.put(@enforcement_toggle_persistent_key, snapshot)
    end

    :ok
  end

  # Recreated tables start empty. If a freeze snapshot already exists in
  # persistent_term, insert that exact snapshot so a later freeze cannot
  # insert_new a re-read of Application env.
  defp rehydrate_enforcement_toggle_claim_from_snapshot do
    case :persistent_term.get(@enforcement_toggle_persistent_key, :not_frozen) do
      snapshot when is_map(snapshot) ->
        insert_enforcement_toggle_snapshot_if_absent(snapshot)
        :ok

      _not_frozen ->
        :ok
    end
  end

  defp create_enforcement_toggle_claim_table do
    try do
      :ets.new(@enforcement_toggle_claim_table, [
        :named_table,
        :set,
        @enforcement_toggle_claim_table_access,
        read_concurrency: true
      ])

      :ok
    rescue
      ArgumentError ->
        accept_owned_enforcement_toggle_claim_table()
    end
  end

  # Application.start must not adopt a squat named table. Only the current
  # Application process may own the claim table.
  defp accept_owned_enforcement_toggle_claim_table do
    case :ets.info(@enforcement_toggle_claim_table, :owner) do
      owner when owner == self() ->
        :ok

      owner when is_pid(owner) ->
        {:error, {:enforcement_toggle_claim_table_foreign_owner, owner}}

      _unavailable ->
        {:error, :enforcement_toggle_claim_table_unavailable}
    end
  end

  defp needs_durable_root?(inputs, :application) do
    start_children?(inputs.start_children) and stores_included?(inputs.start_profile) and
      (not is_nil(inputs.backend) or inputs.journal_mode == :durable)
  end

  defp needs_durable_root?(inputs, :test_bootstrap) do
    stores_included?(inputs.start_profile) and
      (not is_nil(inputs.backend) or inputs.journal_mode == :durable)
  end

  defp configured_journal_mode do
    case Application.get_env(@app, :audit_journal_mode, @default_audit_journal_mode) do
      mode when mode in @audit_journal_modes -> mode
      _invalid -> :invalid
    end
  end

  defp effective_journal_mode(%{journal_mode: :invalid}),
    do: {:error, :audit_journal_mode_invalid}

  defp effective_journal_mode(%{start_profile: :activation_only}),
    do: {:ok, :disabled, :activation_only}

  defp effective_journal_mode(%{journal_mode: :disabled}), do: {:ok, :disabled, :disabled}
  defp effective_journal_mode(%{journal_mode: :ephemeral}), do: {:ok, :ephemeral, :none}
  defp effective_journal_mode(%{journal_mode: :durable}), do: {:ok, :durable, :none}
  defp effective_journal_mode(_inputs), do: {:error, :audit_journal_mode_invalid}

  defp start_children?(false), do: false
  defp start_children?(nil), do: false
  defp start_children?(_value), do: true

  defp stores_included?(:activation_only), do: false
  defp stores_included?(_profile), do: true

  defp compute_authority_root_candidate do
    with {:ok, primary} <- fetch_primary_authority_root(),
         {:ok, legacy} <- fetch_legacy_jsonfile_base_dir() do
      combine_authority_root_candidates(primary, legacy)
    end
  end

  defp fetch_primary_authority_root do
    case Application.fetch_env(@app, :authority_state_root) do
      :error -> {:ok, :absent}
      {:ok, value} -> canonicalize_authority_root_value(value)
    end
  end

  defp fetch_legacy_jsonfile_base_dir do
    case Application.get_env(@app, @json_file_env, []) do
      env when is_list(env) ->
        if Keyword.keyword?(env) do
          case Keyword.fetch(env, :base_dir) do
            :error -> {:ok, :absent}
            {:ok, value} -> canonicalize_authority_root_value(value)
          end
        else
          {:error, :authority_root_invalid_legacy}
        end

      _invalid ->
        {:error, :authority_root_invalid_legacy}
    end
  end

  defp canonicalize_authority_root_value(value) when is_binary(value) and byte_size(value) > 0 do
    case Path.type(value) do
      :absolute ->
        {:ok, Path.expand(value)}

      _relative ->
        if @config_env == :dev do
          {:ok, Path.expand(value, @repo_root)}
        else
          {:error, :authority_root_not_absolute}
        end
    end
  end

  defp canonicalize_authority_root_value(_invalid), do: {:error, :authority_root_not_absolute}

  defp combine_authority_root_candidates(:absent, :absent) do
    if @config_env == :dev do
      {:ok, %{root: @development_authority_root, source: :development_default}}
    else
      {:error, :authority_root_unconfigured}
    end
  end

  defp combine_authority_root_candidates(primary, :absent) when is_binary(primary) do
    {:ok, %{root: primary, source: :configured}}
  end

  defp combine_authority_root_candidates(:absent, legacy) when is_binary(legacy) do
    {:ok, %{root: legacy, source: :legacy_jsonfile_base_dir}}
  end

  defp combine_authority_root_candidates(primary, legacy)
       when is_binary(primary) and is_binary(legacy) and primary == legacy do
    {:ok, %{root: primary, source: :configured}}
  end

  defp combine_authority_root_candidates(_primary, _legacy),
    do: {:error, :authority_root_conflict}

  defp claim_authority_root_snapshot(snapshot) do
    if insert_authority_root_snapshot_if_absent(snapshot) do
      run_authority_root_freeze_after_ets_insert_test_seam()
      persist_authority_root_snapshot_if_absent(snapshot)
      :ok
    else
      case lookup_authority_root_ets_snapshot() do
        {:ok, existing} ->
          persist_authority_root_snapshot_if_absent(existing)
          :ok

        :absent ->
          {:error, :authority_root_claim_table_unavailable}
      end
    end
  end

  defp installed_authority_root_snapshot do
    case :persistent_term.get(@authority_root_persistent_key, :not_frozen) do
      snapshot when is_map(snapshot) ->
        case validate_authority_root_snapshot(snapshot) do
          {:ok, valid} -> {:ok, valid}
          :absent -> lookup_authority_root_ets_snapshot()
        end

      _not_frozen ->
        lookup_authority_root_ets_snapshot()
    end
  end

  defp validate_authority_root_snapshot(%{root: root, source: source} = snapshot)
       when is_binary(root) and byte_size(root) > 0 and source in @authority_root_sources do
    {:ok, snapshot}
  end

  defp validate_authority_root_snapshot(_invalid), do: :absent

  defp complete_authority_root_snapshot(snapshot) do
    insert_authority_root_snapshot_if_absent(snapshot)
    persist_authority_root_snapshot_if_absent(snapshot)
  end

  defp insert_authority_root_snapshot_if_absent(snapshot) do
    case :ets.whereis(@authority_root_claim_table) do
      :undefined ->
        false

      tid ->
        try do
          :ets.insert_new(tid, {@authority_root_claim_key, snapshot})
        rescue
          ArgumentError ->
            false
        end
    end
  end

  defp lookup_authority_root_ets_snapshot do
    case :ets.whereis(@authority_root_claim_table) do
      :undefined ->
        :absent

      tid ->
        try do
          case :ets.lookup(tid, @authority_root_claim_key) do
            [{@authority_root_claim_key, snapshot}] when is_map(snapshot) ->
              validate_authority_root_snapshot(snapshot)

            _missing_or_invalid ->
              :absent
          end
        rescue
          ArgumentError ->
            :absent
        end
    end
  end

  defp persist_authority_root_snapshot_if_absent(snapshot) do
    case :persistent_term.get(@authority_root_persistent_key, :not_frozen) do
      existing when is_map(existing) ->
        :ok

      _not_frozen ->
        :persistent_term.put(@authority_root_persistent_key, snapshot)
    end

    :ok
  end

  defp rehydrate_authority_root_claim_from_snapshot do
    case :persistent_term.get(@authority_root_persistent_key, :not_frozen) do
      snapshot when is_map(snapshot) ->
        insert_authority_root_snapshot_if_absent(snapshot)
        :ok

      _not_frozen ->
        :ok
    end
  end

  defp create_authority_root_claim_table do
    try do
      :ets.new(@authority_root_claim_table, [
        :named_table,
        :set,
        @authority_root_claim_table_access,
        read_concurrency: true
      ])

      :ok
    rescue
      ArgumentError ->
        accept_owned_authority_root_claim_table()
    end
  end

  defp accept_owned_authority_root_claim_table do
    case :ets.info(@authority_root_claim_table, :owner) do
      owner when owner == self() ->
        :ok

      owner when is_pid(owner) ->
        {:error, {:authority_root_claim_table_foreign_owner, owner}}

      _unavailable ->
        {:error, :authority_root_claim_table_unavailable}
    end
  end
end
