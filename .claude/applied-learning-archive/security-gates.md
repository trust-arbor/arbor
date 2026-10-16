# Applied Learning archive: security-gates

Retired entries, kept for history and revival. Not loaded by default.

<!-- applied-learning: treat-genserver-from-as-untrusted-protocol-data -->
<a id="applied-learning-treat-genserver-from-as-untrusted-protocol-data"></a>
**Treat GenServer `from` as untrusted protocol data when mutation authority matters.**
A normal `GenServer.call` exposes the caller PID, but any local process can send a
raw `:"$gen_call"` with a victim PID and an attacker-owned reply alias. Exact-PID
checks and mailbox challenge replies alone do not authenticate high-value
mutations: `Process.info(pid, :messages)` exposes a non-sensitive victim's queued
challenge, and temporarily setting sensitivity only protects a legitimate call
while it is active. Use an unpredictable challenge plus a write that only the
claimed owner can perform, such as a one-shot protected ETS table whose ownership
is rechecked; mark long-lived privileged principals sensitive from startup as
defense in depth. Treat reply references as untrusted too: ordinary refs and
deactivated aliases pass `is_reference/1` but `send/2` can raise, so every reply,
rejection, and expiry path must drop invalid destinations without crashing and
must clear pending records and timers. `GenServer.cast` carries no caller identity,
so it cannot establish provenance and legacy raw mutation casts must be retired.
Trace every authority-bearing value back to its first ingress: an authenticated
forwarder still launders attacker content when its trusted producer accepted that
content through an unauthenticated call or cast. Regress the forged upstream hop
and the terminal privileged effect together. Test forged raw protocol messages,
mailbox scraping, transferred custody, and invalid reply aliases (found 2026-10-07
closing Relay, Bus, AuditJournal, and Monitor deputies).

<!-- applied-learning: long-lived-agents-do-not-automatically-inherit-later-template-authority-changes -->
<a id="applied-learning-long-lived-agents-do-not-automatically-inherit-later-template-authority-changes"></a>
**Long-lived agents do not automatically inherit later template authority changes.** Updating a template's `required_capabilities` and trust preset fixes newly instantiated agents, but an already-running coding agent keeps its persisted grants and profile rules. Before dogfooding a newly enabled validation profile, inspect both `Arbor.Security.list_capabilities/1` and `Arbor.Trust.get_trust_profile/1`; reconcile the existing principal through the public facades or recreate it, otherwise the first profile action can fail `:unauthorized` even though the template and template tests are correct (found 2026-07-10 on the first real `cross_app` run).

<!-- applied-learning: template-trust-policy-changes-do-not-retroactively-update-existing-agents -->
<a id="applied-learning-template-trust-policy-changes-do-not-retroactively-update-existing-agents"></a>
**Template trust-policy changes do not retroactively update existing agents.** Restarting an agent preserves its stored `Arbor.Trust` profile, so a long-lived coding coordinator can hold newly granted action capabilities while its older baseline/rules still block them. Before dogfooding a newly added template capability, compare the live stored profile with the shipped template preset and explicitly reconcile through the Trust facade; do not diagnose the resulting capability-granted/trust-denied sequence as a worker or validator failure (found 2026-07-11 when cross-app validation and council review-tree reads failed for a reused coordinator).

<!-- applied-learning: telemetry-bridged-security-audits-are-observations-not-sync-mutations -->
<a id="applied-learning-telemetry-bridged-security-audits-are-observations-not-sync-mutations"></a>
**Telemetry-bridged security audits are observations, not sync mutations.**
Security lifecycle audit events are reflected onto the same restricted topics used by the
temporary distributed-sync transport and carry `permanent: true`. A sync reducer must reject
that marker before classifying remote authority direction; otherwise a delayed local suspension
audit can re-suspend an identity after resume, while the corresponding authority-restoring echo
is correctly denied and cannot repair the state. Preserve the audit payload distinction instead
of adding sync provenance to it, which would also make observers count both the direct mutation
and its audit reflection as sync events (found 2026-08-21 during the approval CLI Security-suite
verification).
